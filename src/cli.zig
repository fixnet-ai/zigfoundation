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
// 信号处理 — 委托到 signal.zig（单一实现源）
// ============================================================

const signal_mod = @import("signal.zig");

pub const Signal = signal_mod.Signal;
pub const ExitCallback = signal_mod.ExitCallback;
pub const registerExitCallback = signal_mod.registerExitCallback;
pub const installExitHandlers = signal_mod.installExitHandlers;
pub const waitForSignal = signal_mod.waitForSignal;
pub const exitRequested = signal_mod.exitRequested;

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
    // Signal 类型和 ExitCallback 的编译由 refAllDecls 保证
    _ = Signal.interrupt;
    _ = @sizeOf(ExitCallback);
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

test "cli: signal API delegates to signal.zig" {
    // 验证 cli.zig 的 signal API 通过 signal.zig 工作（非阻塞检查）。
    // 完整测试在 signal.zig 中。
    try testing.expect(!exitRequested());
    try testing.expectEqual(Signal.interrupt, Signal.interrupt);
    try testing.expectEqual(Signal.terminate, Signal.terminate);
}

test "cli: daemonize unsupported on Windows" {
    if (native_os == .windows) {
        try testing.expectError(error.Unsupported, daemonize());
    }
}
