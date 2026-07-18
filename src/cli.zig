//! 命令行程序框架 — 参数解析、跨平台信号处理、守护进程化
//!
//! 信号处理参考 zig-codegen.md §8.1：macOS/BSD handler 签名为 fn(SIG) callconv(.c) void，
//! Linux 为 fn(c_int) callconv(.c) void，统一使用 fn(SIG) 签名。

const std = @import("std");
const builtin = @import("builtin");
const native_os = builtin.os.tag;

// ============================================================
// 命令行参数解析
// ============================================================

/// 参数解析错误集
pub const CliError = error{
    MissingValue,
    UnknownFlag,
    OutOfMemory,
};

/// 解析后的标志（boolean）。
pub const Flag = struct {
    name: []const u8,
    short: ?u8 = null,
    present: bool = false,
};

/// 解析后的选项（key=value）。
pub const Option = struct {
    name: []const u8,
    short: ?u8 = null,
    value: ?[]const u8 = null,
};

/// 命令行参数解析器。
/// 支持 `--flag`、`-f`、`--key=value`、`--key value` 以及位置参数。
pub const CliArgs = struct {
    flags: []Flag,
    options: []Option,
    _positionals: [][]const u8,
    _allocator: std.mem.Allocator,

    /// 解析命令行参数。args 通常来自 `std.process.argsAlloc(allocator)`。
    /// 程序名 (args[0]) 将被跳过。
    /// flags_defs 和 options_defs 定义可接受的标志和选项。
    pub fn parse(
        allocator: std.mem.Allocator,
        args: []const []const u8,
        flags_defs: []const Flag,
        options_defs: []const Option,
    ) !CliArgs {
        // 复制标志和选项定义（内部记录 present/value）
        const flags = try allocator.alloc(Flag, flags_defs.len);
        @memcpy(flags, flags_defs);
        const options = try allocator.alloc(Option, options_defs.len);
        @memcpy(options, options_defs);

        // 位置参数数组：最大 args.len 个
        const pos_list = try allocator.alloc([]const u8, args.len);
        var pos_count: usize = 0;
        errdefer allocator.free(pos_list);

        var i: usize = 1; // 跳过 args[0]（程序名）
        while (i < args.len) : (i += 1) {
            const arg = args[i];

            if (std.mem.startsWith(u8, arg, "--")) {
                i = try parseLongArg(arg, args, i, flags, options, pos_list, &pos_count);
            } else if (std.mem.startsWith(u8, arg, "-") and arg.len == 2) {
                try parseShortArg(arg[1], flags, options);
            } else {
                pos_list[pos_count] = arg;
                pos_count += 1;
            }
        }

        // 收缩到实际大小
        const trimmed = try allocator.realloc(pos_list, pos_count);
        return .{
            .flags = flags,
            .options = options,
            ._positionals = trimmed,
            ._allocator = allocator,
        };
    }

    /// 检查标志是否存在（仅检查 long name 或 short name）。
    pub fn flag(self: *const CliArgs, name: []const u8) bool {
        for (self.flags) |f| {
            if (std.mem.eql(u8, f.name, name)) return f.present;
            if (f.short) |s| {
                if (s == name[0] and name.len == 1) return f.present;
            }
        }
        return false;
    }

    /// 获取选项值。返回 null 表示未设置。
    pub fn option(self: *const CliArgs, name: []const u8) ?[]const u8 {
        for (self.options) |o| {
            if (std.mem.eql(u8, o.name, name)) return o.value;
            if (o.short) |s| {
                if (s == name[0] and name.len == 1) return o.value;
            }
        }
        return null;
    }

    /// 获取位置参数（按索引）。超出范围返回 null。
    pub fn positional(self: *const CliArgs, index: usize) ?[]const u8 {
        if (index >= self._positionals.len) return null;
        return self._positionals[index];
    }

    /// 获取全部位置参数。
    pub fn positionals(self: *const CliArgs) []const []const u8 {
        return self._positionals;
    }

    /// 释放解析器分配的内存。
    pub fn deinit(self: *CliArgs) void {
        self._allocator.free(self.flags);
        self._allocator.free(self.options);
        self._allocator.free(self._positionals);
    }

    /// 解析 --key=value 或 --flag 参数。
    fn parseLongArg(
        arg: []const u8,
        all_args: []const []const u8,
        i: usize,
        flags: []Flag,
        options: []Option,
        pos_list: [][]const u8,
        pos_count: *usize,
    ) !usize {
        const stripped = arg[2..]; // 移除 "--"

        // 检查 = 分隔符: --key=value
        if (std.mem.indexOfScalar(u8, stripped, '=')) |eq_idx| {
            const name = stripped[0..eq_idx];
            const value = stripped[eq_idx + 1 ..];
            for (options) |*o| {
                if (std.mem.eql(u8, o.name, name)) {
                    o.value = value;
                    return i;
                }
            }
            // Unknown option — store as positional
            pos_list[pos_count.*] = arg;
            pos_count.* += 1;
        } else {
            const name = stripped;

            // 先检查是否匹配某个选项 — 如果是，下一个 arg 是其值
            for (options) |*o| {
                if (std.mem.eql(u8, o.name, name)) {
                    if (i + 1 < all_args.len) {
                        const next = all_args[i + 1];
                        if (!std.mem.startsWith(u8, next, "-")) {
                            o.value = next;
                            return i + 1; // 消耗下一个 arg
                        }
                    }
                    // 无值跟随 → 设为空字符串表示已存在
                    o.value = "";
                    return i;
                }
            }

            // 检查是否匹配某个标志
            for (flags) |*f| {
                if (std.mem.eql(u8, f.name, name)) {
                    f.present = true;
                    return i;
                }
            }

            // Next check --no- prefix flags
            if (std.mem.startsWith(u8, name, "no-")) {
                const real_name = name[3..];
                for (flags) |*f| {
                    if (std.mem.eql(u8, f.name, real_name)) {
                        f.present = false;
                        return i;
                    }
                }
            }

            // Unknown — store as positional
            pos_list[pos_count.*] = arg;
            pos_count.* += 1;
        }
        return i;
    }

    /// 解析 -x 短参数。
    fn parseShortArg(
        ch: u8,
        flags: []Flag,
        options: []Option,
    ) !void {
        for (flags) |*f| {
            if (f.short) |s| {
                if (s == ch) {
                    f.present = true;
                    return;
                }
            }
        }
        for (options) |*o| {
            if (o.short) |s| {
                if (s == ch) {
                    // 短选项需要下一个 arg 作为值（由调用方处理）
                    return;
                }
            }
        }
        return error.UnknownFlag;
    }
};

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

/// 全局退出回调列表（仅用于 async-signal-safe 操作）。
var exit_callbacks: [max_exit_callbacks]ExitCallback = [_]ExitCallback{undefined} ** max_exit_callbacks;
var exit_callback_count: usize = 0;
var signal_received: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

/// 注册退出回调。最多 16 个，按注册顺序调用。
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
/// POSIX: sigwait; Windows: Sleep 循环。
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

/// 触发退出回调并设置信号标志。
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
            // CTRL_C_EVENT = 0, CTRL_BREAK_EVENT = 1,
            // CTRL_CLOSE_EVENT = 2
            if (ctrl_type == 0 or ctrl_type == 2) {
                triggerCallbacks(.interrupt);
                return 1; // 已处理，不传递给下一个 handler
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
        // Parent exits
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

// ---- 参数解析测试 ----

test "CliArgs: flags and options" {
    const args = [_][]const u8{
        "prog",
        "--verbose",
        "--port=8080",
        "--host",
        "localhost",
        "input.txt",
        "output.txt",
    };

    const flags_defs = [_]Flag{
        .{ .name = "verbose", .short = 'v' },
        .{ .name = "debug", .short = 'd' },
    };
    const options_defs = [_]Option{
        .{ .name = "port", .short = 'p' },
        .{ .name = "host", .short = 'h' },
    };

    var cli = try CliArgs.parse(testing.allocator, &args, &flags_defs, &options_defs);
    defer cli.deinit();

    try testing.expect(cli.flag("verbose"));
    try testing.expect(!cli.flag("debug"));
    try testing.expectEqualStrings("8080", cli.option("port").?);
    try testing.expectEqualStrings("localhost", cli.option("host").?);

    try testing.expectEqualStrings("input.txt", cli.positional(0).?);
    try testing.expectEqualStrings("output.txt", cli.positional(1).?);
    try testing.expectEqual(@as(usize, 2), cli.positionals().len);
}

test "CliArgs: short flags" {
    const args = [_][]const u8{ "prog", "-v", "-d" };
    const flags_defs = [_]Flag{
        .{ .name = "verbose", .short = 'v' },
        .{ .name = "debug", .short = 'd' },
    };
    const options_defs = [_]Option{};

    var cli = try CliArgs.parse(testing.allocator, &args, &flags_defs, &options_defs);
    defer cli.deinit();

    try testing.expect(cli.flag("v"));
    try testing.expect(cli.flag("d"));
    try testing.expect(cli.flag("verbose"));
}

test "CliArgs: --no- prefix" {
    const args = [_][]const u8{ "prog", "--no-verbose" };
    const flags_defs = [_]Flag{
        .{ .name = "verbose", .short = 'v' },
    };
    const options_defs = [_]Option{};

    var cli = try CliArgs.parse(testing.allocator, &args, &flags_defs, &options_defs);
    defer cli.deinit();

    try testing.expect(!cli.flag("verbose"));
}

test "CliArgs: no arguments" {
    const args = [_][]const u8{"prog"};
    const flags_defs = [_]Flag{.{ .name = "help", .short = 'h' }};
    const options_defs = [_]Option{};

    var cli = try CliArgs.parse(testing.allocator, &args, &flags_defs, &options_defs);
    defer cli.deinit();

    try testing.expect(!cli.flag("help"));
    try testing.expectEqual(@as(usize, 0), cli.positionals().len);
}

test "CliArgs: option not set returns null" {
    const args = [_][]const u8{"prog"};
    const flags_defs = [_]Flag{};
    const options_defs = [_]Option{.{ .name = "config" }};

    var cli = try CliArgs.parse(testing.allocator, &args, &flags_defs, &options_defs);
    defer cli.deinit();

    try testing.expectEqual(@as(?[]const u8, null), cli.option("config"));
}

test "CliArgs: positional only" {
    const args = [_][]const u8{ "prog", "src/main.zig", "build.zig" };
    const flags_defs = [_]Flag{};
    const options_defs = [_]Option{};

    var cli = try CliArgs.parse(testing.allocator, &args, &flags_defs, &options_defs);
    defer cli.deinit();

    try testing.expectEqualStrings("src/main.zig", cli.positional(0).?);
    try testing.expectEqualStrings("build.zig", cli.positional(1).?);
    try testing.expectEqual(@as(?[]const u8, null), cli.positional(2));
}

test "CliArgs: option with short name via --long" {
    const args = [_][]const u8{ "prog", "--port", "9090" };
    const flags_defs = [_]Flag{};
    const options_defs = [_]Option{.{ .name = "port", .short = 'p' }};

    var cli = try CliArgs.parse(testing.allocator, &args, &flags_defs, &options_defs);
    defer cli.deinit();

    try testing.expectEqualStrings("9090", cli.option("port").?);
    // Also check by short name
    try testing.expectEqualStrings("9090", cli.option("p").?);
}

test "CliArgs: option with equals sign" {
    const args = [_][]const u8{ "prog", "--port=9090" };
    const flags_defs = [_]Flag{};
    const options_defs = [_]Option{.{ .name = "port" }};

    var cli = try CliArgs.parse(testing.allocator, &args, &flags_defs, &options_defs);
    defer cli.deinit();

    try testing.expectEqualStrings("9090", cli.option("port").?);
}

// ---- 信号处理测试 ----

test "exit callbacks: register and trigger" {
    var called: bool = false;
    const cb = struct {
        var flag: *bool = undefined;
        fn handler() void {
            flag.* = true;
        }
    };
    cb.flag = &called;

    registerExitCallback(cb.handler);
    // simulate signal trigger
    signal_received.store(true, .release);
    cb.handler();

    try testing.expect(called);
}

test "exit callbacks: multiple in registration order" {
    var order: [3]u8 = [_]u8{0} ** 3;
    var count: usize = 0;

    // Clear state
    exit_callback_count = 0;
    signal_received.store(false, .release);

    // Each callback writes a value to order[i] then increments count
    const cb1 = struct {
        var o: *[3]u8 = undefined;
        var c: *usize = undefined;
        fn h1() void {
            o.*[0] = 1;
            c.* += 1;
        }
        fn h2() void {
            o.*[1] = 2;
            c.* += 1;
        }
        fn h3() void {
            o.*[2] = 3;
            c.* += 1;
        }
    };
    cb1.o = &order;
    cb1.c = &count;

    registerExitCallback(cb1.h1);
    registerExitCallback(cb1.h2);
    registerExitCallback(cb1.h3);

    // Trigger manually (reverse order — callbacks fire LIFO)
    var i: usize = exit_callback_count;
    while (i > 0) {
        i -= 1;
        exit_callbacks[i]();
    }

    try testing.expectEqual(@as(u8, 1), order[0]);
    try testing.expectEqual(@as(u8, 2), order[1]);
    try testing.expectEqual(@as(u8, 3), order[2]);
    try testing.expectEqual(@as(usize, 3), count);
}

test "exitRequested: reflects flag state" {
    signal_received.store(false, .release);
    try testing.expect(!exitRequested());

    signal_received.store(true, .release);
    try testing.expect(exitRequested());

    signal_received.store(false, .release);
}
