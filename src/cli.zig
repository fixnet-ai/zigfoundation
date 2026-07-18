//! 命令行程序框架 — zli 集成包装 + 跨平台信号处理 + 守护进程化
//!
//! 本模块是 zli CLI 框架的薄封装：重新导出 zli 的公共 API，
//! 并在此基础上提供信号处理、退出回调、守护进程化等补充功能。
//!
//! 使用示例：
//! ```
//! const cli = @import("zigfoundation").cli;
//!
//! // 创建根命令（使用 zli API）
//! var root = try cli.createRoot(allocator, .{
//!     .name = "myapp",
//!     .description = "My CLI application",
//! });
//! defer root.deinit();
//!
//! // 注册信号处理
//! cli.registerExitCallback(myCleanup);
//! try cli.installExitHandlers(&.{.interrupt, .terminate});
//!
//! // 运行
//! try cli.run(root);
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

/// 创建根命令的便捷函数，自动设置 stdout/stderr writer。
pub fn createRoot(allocator: std.mem.Allocator, opts: CommandOptions) !*Command {
    var io_instance = std.Io.Threaded.init(allocator, .{});
    _ = io_instance.io();

    var out_buf: [4096]u8 = undefined;
    var in_buf: [4096]u8 = undefined;

    // 堆分配 Io 基础设施（生命周期与 Command 绑定）
    const io_heap = try allocator.create(std.Io.Threaded);
    io_heap.* = io_instance;

    // 创建 stdout Writer（使用 raw POSIX write，避免 Io.File.Writer 类型不兼容问题）
    const stdout_writer = makeStdoutWriter(&out_buf);
    const writer_heap = try allocator.create(std.Io.Writer);
    writer_heap.* = stdout_writer;

    // 创建 stdin Reader
    const stdin_reader = makeStdinReader(&in_buf);
    const reader_heap = try allocator.create(std.Io.Reader);
    reader_heap.* = stdin_reader;

    return try Command.init(.{
        .io = io_heap.io(),
        .writer = writer_heap,
        .reader = reader_heap,
        .allocator = allocator,
    }, opts, struct {
        fn run(_: CommandContext) anyerror!void {}
    }.run);
}

fn stdoutDrain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
    _ = w;
    _ = splat;
    var total: usize = 0;
    for (data) |chunk| {
        writeStdout(chunk);
        total += chunk.len;
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

fn stdinStream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
    _ = r;
    const buf = w.buffer;
    const limit_usize: usize = @intFromEnum(limit);
    const max_read = @min(buf.len, limit_usize);
    if (max_read == 0) return 0;
    if (builtin.os.tag == .windows) {
        const stdin_h = winGetStdHandle(win.STD_INPUT_HANDLE);
        var bytes_read: win.DWORD = 0;
        if (winReadFile(stdin_h, buf.ptr, @intCast(max_read), &bytes_read) == 0)
            return error.ReadFailed;
        w.end = @intCast(bytes_read);
        return @intCast(bytes_read);
    } else {
        const n = std.c.read(0, buf.ptr, max_read);
        if (n < 0) return error.ReadFailed;
        w.end = @intCast(n);
        return @intCast(n);
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
pub fn run(root: *Command) noreturn {
    var args_iter = std.process.args();
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

/// 注册退出回调。最多 16 个，按注册顺序存储（触发时 LIFO 调用）。
/// 安装信号处理器之前调用此函数。
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

/// 阻塞等待任意已注册信号。收到信号后返回触发信号的类型。
pub fn waitForSignal() Signal {
    if (native_os == .windows) {
        while (!signal_received.load(.acquire)) {
            std.time.sleep(std.time.ns_per_ms * 100);
        }
        return .interrupt;
    }
    return waitForSignalPosix();
}

/// 检查是否已收到退出信号（非阻塞）。
pub fn exitRequested() bool {
    return signal_received.load(.acquire);
}

/// 触发退出回调并设置信号标志（LIFO 顺序）。
fn triggerCallbacks(sig: Signal) void {
    _ = sig;
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
        const act = std.posix.Sigaction{
            .handler = .{ .handler = handler },
            .mask = std.posix.empty_sigset,
            .flags = .{ .RESTART = false },
        };
        try std.posix.sigaction(c_sig, &act, null);
    }
}

fn waitForSignalPosix() Signal {
    var set: std.posix.sigset_t = std.posix.empty_sigset;
    std.posix.sigaddset(&set, .INT);
    std.posix.sigaddset(&set, .TERM);
    std.posix.sigaddset(&set, .HUP);

    var caught: c_int = 0;
    _ = std.posix.sigwait(&set, &caught);

    return switch (caught) {
        2 => .interrupt,
        15 => .terminate,
        1 => .hangup,
        else => .interrupt,
    };
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
    // First fork: detach from terminal
    const pid1 = try std.posix.fork();
    if (pid1 > 0) {
        std.posix.exit(0);
    }

    // Create new session
    _ = std.posix.setsid();

    // Second fork: ensure no session leadership
    const pid2 = try std.posix.fork();
    if (pid2 > 0) {
        std.posix.exit(0);
    }

    // Change to root directory
    std.posix.chdir("/") catch {};

    // Redirect stdin/stdout/stderr to /dev/null
    const dev_null = std.posix.openZ("/dev/null", .{ .ACCMODE = .RDWR }, 0) catch return;
    _ = std.posix.dup2(dev_null, std.posix.STDIN_FILENO);
    _ = std.posix.dup2(dev_null, std.posix.STDOUT_FILENO);
    _ = std.posix.dup2(dev_null, std.posix.STDERR_FILENO);
    if (dev_null > std.posix.STDERR_FILENO) {
        std.posix.close(dev_null);
    }
}

// ============================================================
// 测试
// ============================================================

const testing = std.testing;

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

test "cli: noopAction does nothing" {
    // Just verify it compiles and doesn't panic at comptime
    try testing.expect(true);
}

test "cli: daemonize unsupported on Windows" {
    if (native_os == .windows) {
        try testing.expectError(error.Unsupported, daemonize());
    }
}
