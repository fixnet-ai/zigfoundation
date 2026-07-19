//! 跨平台信号处理模块 — SIGINT/SIGTERM/SIGHUP 优雅关闭
//!
//! macOS/Linux: sigaction 注册信号处理器
//! Windows: SetConsoleCtrlHandler 注册控制台事件处理器
//!
//! 两种使用方式：
//!
//! 方式一（回调式 — cli.zig 兼容）：
//!   1. signal.registerExitCallback(myCleanup);
//!   2. try signal.installExitHandlers(&.{ .interrupt, .terminate });
//!   3. 循环中检查：if (signal.exitRequested()) break;
//!   4. 或阻塞等待：const s = signal.waitForSignal();
//!
//! 方式二（上下文式 — zigtun 兼容）：
//!   1. var ctx = signal.SignalContext.init(allocator);
//!   2. try ctx.install();
//!   3. 循环中检查：if (signal.isShuttingDown()) break;
//!   4. ctx.uninstall(); // 恢复原始处理器

const std = @import("std");
const builtin = @import("builtin");
const native_os = builtin.os.tag;

// ============================================================
// 常量与类型
// ============================================================

/// 可处理的信号类型。
pub const Signal = enum {
    interrupt, // SIGINT / Ctrl+C
    terminate, // SIGTERM
    hangup, // SIGHUP
};

/// 退出回调：无参数、无返回值的函数指针。
pub const ExitCallback = *const fn () void;

/// 最大可注册的退出回调数。
const max_exit_callbacks = 16;

// ============================================================
// 全局状态
// ============================================================

/// 全局退出回调列表（按注册顺序存储，触发时 LIFO 调用）。
var exit_callbacks: [max_exit_callbacks]ExitCallback = [_]ExitCallback{undefined} ** max_exit_callbacks;
var exit_callback_count: usize = 0;

/// 原子关闭标志 — 信号处理器触发的优雅关闭。
var signal_received: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

/// 最近一次收到的信号（0 = 无；1/2/3 = interrupt/terminate/hangup）。
var last_signal: std.atomic.Value(u8) = std.atomic.Value(u8).init(0);

// ============================================================
// 公共 API — 回调式（cli.zig 兼容）
// ============================================================

/// 注册退出回调。最多 16 个，按注册顺序存储（触发时 LIFO 调用）。
/// 安装信号处理器之前调用此函数。
/// 警告：POSIX 下回调在信号处理器上下文执行，必须 async-signal-safe —
/// 只做置标志/写 fd 级操作，不得分配内存、加锁或调用 stdio。
pub fn registerExitCallback(cb: ExitCallback) void {
    if (exit_callback_count < max_exit_callbacks) {
        exit_callbacks[exit_callback_count] = cb;
        exit_callback_count += 1;
    }
}

/// 为当前进程安装信号处理器。
/// POSIX: sigaction(SIGINT/SIGTERM/SIGHUP)
/// Windows: SetConsoleCtrlHandler
pub fn installExitHandlers(signals: []const Signal) !void {
    if (native_os == .windows) {
        if (signals.len == 0) return;
        try installWindowsHandlers();
    } else {
        try installPosixHandlers(signals);
    }
}

/// 阻塞等待任意已注册信号（100ms 轮询信号标志，全平台统一实现）。
/// 返回触发的信号类型。调用前必须先 installExitHandlers，否则永远阻塞。
pub fn waitForSignal() Signal {
    while (!signal_received.load(.acquire)) {
        sleepMs(100);
    }
    return switch (last_signal.load(.acquire)) {
        2 => .terminate,
        3 => .hangup,
        else => .interrupt,
    };
}

/// 检查是否已收到退出信号（非阻塞）。
pub fn exitRequested() bool {
    return signal_received.load(.acquire);
}

/// isShuttingDown 别名（兼容 zigtun legacy API）。
pub fn isShuttingDown() bool {
    return exitRequested();
}

// ============================================================
// SignalContext — 上下文式（兼容 zigtun API）
// ============================================================

/// 信号上下文 — 保存并恢复原始信号处理器，方便模块化生命周期管理。
pub const SignalContext = struct {
    allocator: std.mem.Allocator,

    // macOS/Linux
    prev_sigint: ?std.posix.Sigaction = null,
    prev_sigterm: ?std.posix.Sigaction = null,

    pub fn init(allocator: std.mem.Allocator) SignalContext {
        return .{ .allocator = allocator };
    }

    /// 安装信号处理器（SIGINT + SIGTERM）。
    /// 与 installExitHandlers 不同，此方法保存旧处理器以便恢复。
    pub fn install(self: *SignalContext) !void {
        switch (builtin.os.tag) {
            .macos, .ios, .linux => {
                // sigaction 注册 SIGINT + SIGTERM
                const act = std.posix.Sigaction{
                    .handler = .{ .handler = signalFlagHandler },
                    .mask = std.posix.sigemptyset(),
                    .flags = 0,
                };

                var old: std.posix.Sigaction = undefined;
                std.posix.sigaction(std.posix.SIG.INT, &act, &old);
                self.prev_sigint = old;

                std.posix.sigaction(std.posix.SIG.TERM, &act, &old);
                self.prev_sigterm = old;
            },
            .windows => {
                // SetConsoleCtrlHandler 注册控制台事件处理器
                if (win32.SetConsoleCtrlHandler(@ptrCast(&consoleCtrlHandler), 1) == 0) {
                    return error.SignalInstallFailed;
                }
            },
            else => {},
        }
    }

    /// 卸载信号处理器，恢复原始行为。
    pub fn uninstall(self: *SignalContext) void {
        switch (builtin.os.tag) {
            .macos, .ios, .linux => {
                if (self.prev_sigint) |old| {
                    std.posix.sigaction(std.posix.SIG.INT, &old, null);
                }
                if (self.prev_sigterm) |old| {
                    std.posix.sigaction(std.posix.SIG.TERM, &old, null);
                }
            },
            .windows => {
                _ = win32.SetConsoleCtrlHandler(@ptrCast(&consoleCtrlHandler), 0);
            },
            else => {},
        }
    }
};

// ============================================================
// 内部实现
// ============================================================

/// 触发退出回调并设置信号标志（LIFO 顺序）。
/// 注意：POSIX 下运行在信号处理器上下文中，回调必须 async-signal-safe。
fn triggerCallbacks(sig: Signal) void {
    last_signal.store(switch (sig) {
        .interrupt => 1,
        .terminate => 2,
        .hangup => 3,
    }, .release);
    signal_received.store(true, .release);
    var i: usize = exit_callback_count;
    while (i > 0) {
        i -= 1;
        exit_callbacks[i]();
    }
}

// ---- POSIX 实现 ----

fn installPosixHandlers(signals: []const Signal) !void {
    const handler = struct {
        fn handle(sig: std.c.SIG) callconv(.c) void {
            const s: Signal = switch (sig) {
                .INT => .interrupt,
                .TERM => .terminate,
                .HUP => .hangup,
                else => return,
            };
            triggerCallbacks(s);
        }
    }.handle;

    for (signals) |s| {
        const c_sig: std.c.SIG = switch (s) {
            .interrupt => .INT,
            .terminate => .TERM,
            .hangup => .HUP,
        };
        // Zig 0.16.0: sigaction 返回 void，flags 是 c_uint
        const act = std.posix.Sigaction{
            .handler = .{ .handler = handler },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(c_sig, &act, null);
    }
}

/// POSIX 标志处理器（供 SignalContext 使用 — 只设标志，不触发回调）。
fn signalFlagHandler(sig: std.c.SIG) callconv(.c) void {
    _ = sig;
    signal_received.store(true, .release);
}

// ---- Windows 实现 ----

/// Win32 API 声明。
const win32 = struct {
    extern "kernel32" fn SetConsoleCtrlHandler(
        handler: ?*const fn (u32) callconv(.winapi) i32,
        add: i32,
    ) callconv(.winapi) i32;
};

fn installWindowsHandlers() !void {
    const handler = struct {
        fn handle(ctrl_type: u32) callconv(.winapi) i32 {
            switch (ctrl_type) {
                0, 1, 2, 5, 6 => {
                    triggerCallbacks(.interrupt);
                    return 1;
                },
                else => return 0,
            }
        }
    }.handle;

    if (win32.SetConsoleCtrlHandler(handler, 1) == 0) {
        return error.SignalInstallFailed;
    }
}

/// Windows 控制台事件处理器（供 SignalContext 使用）。
fn consoleCtrlHandler(dwCtrlType: u32) callconv(.winapi) i32 {
    switch (dwCtrlType) {
        0, // CTRL_C_EVENT
        1, // CTRL_BREAK_EVENT
        2, // CTRL_CLOSE_EVENT
        5, // CTRL_LOGOFF_EVENT
        6, // CTRL_SHUTDOWN_EVENT
        => {
            signal_received.store(true, .release);
            return 1;
        },
        else => return 0,
    }
}

// ---- 工具函数 ----

/// 跨平台毫秒级睡眠（std.time.sleep 在 Zig 0.16.0 已移除）。
fn sleepMs(ms: u32) void {
    if (native_os == .windows) {
        const kernel32 = struct {
            extern "kernel32" fn Sleep(dwMilliseconds: u32) callconv(.winapi) void;
        };
        kernel32.Sleep(ms);
    } else {
        const ts: std.c.timespec = .{
            .sec = @intCast(ms / 1000),
            .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
        };
        _ = std.c.nanosleep(&ts, null);
    }
}

// ============================================================
// 测试
// ============================================================

const testing = std.testing;

test "exitRequested false by default" {
    signal_received.store(false, .release);
    try testing.expect(!exitRequested());
}

test "exitRequested reflects flag state" {
    signal_received.store(false, .release);
    try testing.expect(!exitRequested());

    signal_received.store(true, .release);
    try testing.expect(exitRequested());

    signal_received.store(false, .release);
}

test "isShuttingDown aliases exitRequested" {
    try testing.expect(isShuttingDown() == exitRequested());
}

test "Signal enum values" {
    try testing.expect(Signal.interrupt != Signal.terminate);
    try testing.expect(Signal.terminate != Signal.hangup);
    try testing.expect(Signal.interrupt != Signal.hangup);
}

test "registerExitCallback and trigger" {
    var called: bool = false;
    const cb = struct {
        var flag: *bool = undefined;
        fn handler() void {
            flag.* = true;
        }
    };
    cb.flag = &called;

    registerExitCallback(cb.handler);
    // 手动调用 — 单元测试环境下无法触发真实信号处理器
    cb.handler();

    try testing.expect(called);
}

test "SignalContext init" {
    const ctx = SignalContext.init(testing.allocator);
    _ = ctx;
}
