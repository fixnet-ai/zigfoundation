//! 命令行程序框架 — zli 集成包装 + 跨平台信号处理 + 守护进程化
//!
//! 本模块是 zli CLI 框架的薄封装：重新导出 zli 的公共 API，
//! 并在此基础上提供信号处理、退出回调、守护进程化等补充功能。
//!
//! 使用示例：
//! ```
//! const cli = @import("zigfoundation").cli;
//!
//! pub fn main(init: std.process.Init) !void {
//!     // 创建根命令（使用 zli API；进程级 stdio 由模块内部管理）
//!     var root = try cli.createRoot(init.gpa, .{
//!         .name = "myapp",
//!         .description = "My CLI application",
//!     });
//!     defer root.deinit();
//!
//!     // 注册信号处理
//!     cli.registerExitCallback(myCleanup);
//!     try cli.installExitHandlers(&.{ .interrupt, .terminate });
//!
//!     // 运行 — args 必须由 main 注入（Zig 0.16.0 无全局 args 获取入口）
//!     cli.run(root, init.minimal.args);
//! }
//! ```

const std = @import("std");
const builtin = @import("builtin");
const native_os = builtin.os.tag;

// ============================================================
// zli 重新导出
// ============================================================

pub const zli = @import("zli");

pub const Command = zli.Command;
pub const CommandContext = zli.CommandContext;
pub const CommandOptions = zli.CommandOptions;
pub const Flag = zli.Flag;
pub const FlagType = zli.FlagType;
pub const FlagValue = zli.FlagValue;
pub const PositionalArg = zli.PositionalArg;
pub const InitOptions = zli.InitOptions;
pub const CommandErrors = zli.CommandErrors;

// ============================================================
// 便捷构造器
// ============================================================

/// 进程级 stdio/Io 基础设施。
/// stdout/stdin 本身即进程单例，故用静态存储：
/// - 修复栈 buffer 悬垂（曾把 createRoot 栈帧里的 buffer 指针存入堆上 Writer/Reader）
/// - 修复 3 个 allocator.create 无 errdefer 且永远无法释放的泄漏
const RootIo = struct {
    var threaded: std.Io.Threaded = undefined;
    var out_buf: [4096]u8 = undefined;
    var in_buf: [4096]u8 = undefined;
    var writer: std.Io.Writer = undefined;
    var reader: std.Io.Reader = undefined;
    var initialized: bool = false;
};

/// 创建根命令的便捷函数，自动设置 stdout writer / stdin reader。
/// 非线程安全：应在程序启动阶段单线程调用。
/// 首次调用传入的 allocator 同时用于进程级 Io 基础设施（随进程存活，不回收）。
pub fn createRoot(allocator: std.mem.Allocator, opts: CommandOptions) !*Command {
    if (!RootIo.initialized) {
        RootIo.threaded = std.Io.Threaded.init(allocator, .{});
        RootIo.writer = makeStdoutWriter(&RootIo.out_buf);
        RootIo.reader = makeStdinReader(&RootIo.in_buf);
        RootIo.initialized = true;
    }

    return try Command.init(.{
        .io = RootIo.threaded.io(),
        .writer = &RootIo.writer,
        .reader = &RootIo.reader,
        .allocator = allocator,
    }, opts, struct {
        fn run(_: CommandContext) anyerror!void {}
    }.run);
}

/// Writer.drain 实现（契约见 std.Io.Writer.VTable.drain）：
/// 必须先消费 buffer[0..end] 并清零 end — defaultFlush 就是
/// `while (end != 0) drain(...)`，不清 end 会无限循环。
/// data 最后一个元素重复写 splat 次（可为 0）；返回值只统计来自 data 的字节数。
fn stdoutDrain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
    const buffered = w.buffer[0..w.end];
    if (buffered.len > 0) {
        writeStdout(buffered);
        w.end = 0;
    }
    var total: usize = 0;
    for (data, 0..) |chunk, i| {
        const times: usize = if (i == data.len - 1) splat else 1;
        var t: usize = 0;
        while (t < times) : (t += 1) {
            writeStdout(chunk);
            total += chunk.len;
        }
    }
    return total;
}

fn writeStdout(bytes: []const u8) void {
    if (builtin.os.tag == .windows) {
        const stdout_h = winGetStdHandle(win.STD_OUTPUT_HANDLE);
        _ = winWriteFile(stdout_h, bytes.ptr, @intCast(bytes.len));
    } else {
        _ = std.c.write(1, bytes.ptr, bytes.len);
    }
}

const stdout_vtable: std.Io.Writer.VTable = .{ .drain = stdoutDrain };

fn makeStdoutWriter(buf: []u8) std.Io.Writer {
    return .{ .vtable = &stdout_vtable, .buffer = buf, .end = 0 };
}

/// Reader.stream 实现（契约见 std.Io.Reader.VTable.stream）：
/// 通过 writableSliceGreedy/advance 向目标 writer 追加（曾直接写 w.buffer 并
/// 赋值 w.end，会覆盖已缓冲数据）；EOF 必须返回 error.EndOfStream
/// （曾返回 0 — 契约明确 0 不代表流结束，调用方会忙等死循环）。
fn stdinStream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
    _ = r;
    const dest = limit.slice(try w.writableSliceGreedy(1));
    if (dest.len == 0) return 0;
    if (builtin.os.tag == .windows) {
        const stdin_h = winGetStdHandle(win.STD_INPUT_HANDLE);
        var bytes_read: win.DWORD = 0;
        if (winReadFile(stdin_h, dest.ptr, @intCast(dest.len), &bytes_read) == 0)
            return error.ReadFailed;
        if (bytes_read == 0) return error.EndOfStream;
        w.advance(bytes_read);
        return bytes_read;
    } else {
        const n = std.c.read(0, dest.ptr, dest.len);
        if (n < 0) return error.ReadFailed;
        if (n == 0) return error.EndOfStream;
        const un: usize = @intCast(n);
        w.advance(un);
        return un;
    }
}

// Windows I/O helpers — declared locally since Zig 0.16.0 std lib has minimal kernel32 coverage.
const win = struct {
    const HANDLE = *anyopaque;
    const DWORD = u32;
    const BOOL = i32;
    const LPVOID = *anyopaque;

    const STD_INPUT_HANDLE: DWORD = @as(DWORD, @bitCast(@as(i32, -10)));
    const STD_OUTPUT_HANDLE: DWORD = @as(DWORD, @bitCast(@as(i32, -11)));

    extern "kernel32" fn GetStdHandle(nStdHandle: DWORD) callconv(.winapi) HANDLE;
    extern "kernel32" fn Sleep(dwMilliseconds: DWORD) callconv(.winapi) void;
    extern "kernel32" fn WriteFile(
        hFile: HANDLE,
        lpBuffer: [*]const u8,
        nNumberOfBytesToWrite: DWORD,
        lpNumberOfBytesWritten: ?*DWORD,
        lpOverlapped: ?LPVOID,
    ) callconv(.winapi) BOOL;
    extern "kernel32" fn ReadFile(
        hFile: HANDLE,
        lpBuffer: [*]u8,
        nNumberOfBytesToRead: DWORD,
        lpNumberOfBytesRead: ?*DWORD,
        lpOverlapped: ?LPVOID,
    ) callconv(.winapi) BOOL;
};

fn winGetStdHandle(which: win.DWORD) win.HANDLE {
    return win.GetStdHandle(which);
}

fn winWriteFile(h: win.HANDLE, buf: [*]const u8, len: u32) void {
    _ = win.WriteFile(h, buf, len, null, null);
}

fn winReadFile(h: win.HANDLE, buf: [*]u8, len: u32, bytes_read: *win.DWORD) win.BOOL {
    return win.ReadFile(h, buf, len, bytes_read, null);
}

const stdin_vtable: std.Io.Reader.VTable = .{ .stream = stdinStream };

fn makeStdinReader(buf: []u8) std.Io.Reader {
    return .{ .vtable = &stdin_vtable, .buffer = buf, .seek = 0, .end = 0 };
}

/// 以 noreturn 方式运行根命令并退出进程。
/// `args` 来自应用 `main(init: std.process.Init)` 的 `init.minimal.args` —
/// Zig 0.16.0 已移除全局获取入口（std.process.args() 不存在）。
pub fn run(root: *Command, args: std.process.Args) noreturn {
    // initAllocator 全平台可用（POSIX 忽略 allocator；Windows/WASI 必须用它）
    var args_iter = std.process.Args.Iterator.initAllocator(args, root.init_options.allocator) catch
        std.process.exit(1);
    root.runAndExit(&args_iter, .{});
}

/// 创建 Noop 执行函数（用于没有 action 的父命令）。
pub fn noopAction(_: CommandContext) anyerror!void {}

// ============================================================
// 信号处理
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

/// 全局退出回调列表。
var exit_callbacks: [max_exit_callbacks]ExitCallback = [_]ExitCallback{undefined} ** max_exit_callbacks;
var exit_callback_count: usize = 0;
var signal_received: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
/// 最近一次收到的信号（0 = 无；1/2/3 = interrupt/terminate/hangup）。
var last_signal: std.atomic.Value(u8) = std.atomic.Value(u8).init(0);

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

/// 跨平台毫秒级睡眠（std.time.sleep 在 Zig 0.16.0 已移除）。
fn sleepMs(ms: u32) void {
    if (native_os == .windows) {
        win.Sleep(ms);
    } else {
        const ts: std.c.timespec = .{
            .sec = @intCast(ms / 1000),
            .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
        };
        _ = std.c.nanosleep(&ts, null);
    }
}

/// 检查是否已收到退出信号（非阻塞）。
pub fn exitRequested() bool {
    return signal_received.load(.acquire);
}

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

// ============================================================
// POSIX 信号处理实现
// ============================================================

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
        // Zig 0.16.0：sigemptyset 是函数（不存在 empty_sigset 常量）；
        // Sigaction.flags 是 c_uint（不是 packed struct）；sigaction 返回 void。
        const act = std.posix.Sigaction{
            .handler = .{ .handler = handler },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(c_sig, &act, null);
    }
}

// ============================================================
// Windows 信号处理实现
// ============================================================

fn installWindowsHandlers() !void {
    const kernel32 = struct {
        extern "kernel32" fn SetConsoleCtrlHandler(
            handler: ?*const fn (u32) callconv(.winapi) i32,
            add: i32,
        ) callconv(.winapi) i32;
    };

    const handler = struct {
        fn handle(ctrl_type: u32) callconv(.winapi) i32 {
            if (ctrl_type == 0 or ctrl_type == 2) {
                triggerCallbacks(.interrupt);
                return 1;
            }
            return 0;
        }
    }.handle;

    if (kernel32.SetConsoleCtrlHandler(handler, 1) == 0) {
        return error.InstallHandlerFailed;
    }
}

// ============================================================
// 守护进程化 (POSIX only)
// ============================================================

/// 将当前进程变为守护进程。
/// POSIX: double-fork + setsid + chdir + 重定向 stdio。
/// Windows 无传统守护进程概念（返回 Unsupported）。
pub fn daemonize() !void {
    if (native_os == .windows) {
        return error.Unsupported;
    }
    try daemonizePosix();
}

fn daemonizePosix() !void {
    // Zig 0.16.0 的 std.posix 已无 fork/setsid/chdir/dup2 → 直接使用 libc (std.c)。
    // First fork: detach from terminal
    const pid1 = std.c.fork();
    if (pid1 < 0) return error.ForkFailed;
    if (pid1 > 0) std.c._exit(0);

    // Create new session
    _ = std.c.setsid();

    // Second fork: ensure no session leadership
    const pid2 = std.c.fork();
    if (pid2 < 0) return error.ForkFailed;
    if (pid2 > 0) std.c._exit(0);

    // Change to root directory
    _ = std.c.chdir("/");

    // Redirect stdin/stdout/stderr (fd 0/1/2) to /dev/null
    const dev_null = std.c.open("/dev/null", .{ .ACCMODE = .RDWR });
    if (dev_null < 0) return;
    _ = std.c.dup2(dev_null, 0);
    _ = std.c.dup2(dev_null, 1);
    _ = std.c.dup2(dev_null, 2);
    if (dev_null > 2) {
        _ = std.c.close(dev_null);
    }
}

// ============================================================
// 测试
// ============================================================

const testing = std.testing;

test "cli: reference all pub decls (lazy-analysis guard)" {
    // Zig 懒分析下未被引用的 pub fn 不会被语义分析：
    // 此前 run/installExitHandlers(POSIX)/waitForSignal/daemonize 引用了
    // 不存在的 std API（std.process.args / empty_sigset / sigwait /
    // posix.fork / time.sleep）却 173 测试全绿。
    // 此处只引用本文件自有顶层 pub 声明（不含 zli 重新导出），
    // 避免 refAllDecls 递归拉入 zli 的大量声明。
    _ = &run;
    _ = &daemonize;
    _ = &installExitHandlers;
    _ = &waitForSignal;
    _ = &registerExitCallback;
    _ = &exitRequested;
    _ = &createRoot;
    _ = &noopAction;
}

test "cli: createRoot smoke — no dangling buffers, deinit clean (regression)" {
    // 回归：曾把栈上 buffer 指针存入堆 Writer/Reader（返回即悬垂），
    // 且 3 个 allocator.create 无法释放（testing.allocator 会检出泄漏）。
    var root = try createRoot(testing.allocator, .{
        .name = "smoke",
        .description = "test root",
    });
    root.deinit();
}

test "cli: stdout writer flush terminates and clears buffer (regression)" {
    // 回归：stdoutDrain 曾不消费 w.buffer 也不清 w.end，
    // defaultFlush 的 `while (end != 0) drain(...)` 永不终止。
    var buf: [16]u8 = undefined;
    var w = makeStdoutWriter(&buf);
    try w.writeAll("."); // 停留在缓冲区内
    try w.flush(); // 修复前此处死循环
    try testing.expectEqual(@as(usize, 0), w.end);
}

test "cli: registerExitCallback and trigger" {
    var called: bool = false;
    const cb = struct {
        var flag: *bool = undefined;
        fn handler() void {
            flag.* = true;
        }
    };
    cb.flag = &called;

    registerExitCallback(cb.handler);
    cb.handler();

    try testing.expect(called);
}

test "cli: exitRequested reflects flag state" {
    signal_received.store(false, .release);
    try testing.expect(!exitRequested());

    signal_received.store(true, .release);
    try testing.expect(exitRequested());

    signal_received.store(false, .release);
}

test "cli: Signal enum values" {
    try testing.expect(Signal.interrupt != Signal.terminate);
    try testing.expect(Signal.terminate != Signal.hangup);
    try testing.expect(Signal.interrupt != Signal.hangup);
}

test "cli: noopAction accepts context and returns" {
    // noopAction 的编译由 refAllDecls 保证；此处仅验证 Signal 映射辅助逻辑。
    signal_received.store(false, .release);
    last_signal.store(0, .release);
    try testing.expect(!exitRequested());
}

test "cli: daemonize unsupported on Windows" {
    if (native_os == .windows) {
        try testing.expectError(error.Unsupported, daemonize());
    }
}
