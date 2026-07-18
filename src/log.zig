//! 跨平台分级日志框架 — 基于 std.log 集成
//!
//! 平台适配：
//! - Android: __android_log_write (logcat)
//! - iOS / macOS: syslog
//! - Linux / Windows: stderr (ANSI 颜色)
//!
//! 通过 `std_options.logFn` 覆盖 std.log 的默认行为，
//! 使所有 `std.log.info(...)` 等调用走平台适配的输出。
//!
//! Zig 0.16.0 的 `std.log.Level` 包含四个级别：err / warn / info / debug。
//!
//! 使用示例：
//! ```
//! const logger = @import("zigfoundation").log;
//!
//! // 在 main.zig 中设置 std_options（每个二进制一次）
//! pub const std_options: std.Options = logger.logOptions();
//!
//! // 在运行时初始化日志级别
//! logger.init(.info);
//! std.log.info("server started on port {}", .{8080});
//! ```

const std = @import("std");
const builtin = @import("builtin");

// ============================================================
// 日志级别
// ============================================================

pub const Level = std.log.Level;

/// 全局日志级别（运行时可变）。
var log_level: Level = .info;

/// 初始化日志级别。
pub fn init(level: Level) void {
    log_level = level;
}

/// 动态调整日志级别。
pub fn setLevel(level: Level) void {
    log_level = level;
}

/// 获取当前日志级别。
pub fn getLevel() Level {
    return log_level;
}

// ============================================================
// std.log 集成
// ============================================================

/// 返回覆盖了 logFn 的 std.Options。
/// 调用者在根文件中将此赋值给 pub const std_options。
pub fn logOptions() std.Options {
    return .{
        .logFn = logImpl,
    };
}

// ============================================================
// std.log 回调入口
// ============================================================

fn logImpl(
    comptime level: Level,
    comptime scope: @EnumLiteral(),
    comptime fmt: []const u8,
    args: anytype,
) void {
    const level_int = @intFromEnum(level);
    const current_int = @intFromEnum(log_level);
    if (level_int > current_int) return;

    const scope_name: ?[]const u8 = if (scope == .default) null else @tagName(scope);
    platformWrite(level, scope_name, fmt, args);
}

// ============================================================
// 平台分发
// ============================================================

fn platformWrite(
    level: Level,
    scope: ?[]const u8,
    comptime fmt: []const u8,
    args: anytype,
) void {
    const msg = std.fmt.allocPrint(std.heap.page_allocator, fmt, args) catch return;
    defer std.heap.page_allocator.free(msg);

    const prefix = if (scope) |s|
        std.fmt.allocPrint(std.heap.page_allocator, "[{s}] ", .{s}) catch "(?) "
    else
        "";
    defer if (prefix.len > 0) std.heap.page_allocator.free(prefix);

    if (builtin.abi.isAndroid()) {
        androidLog(level, prefix, msg);
    } else switch (builtin.os.tag) {
        .ios, .macos, .tvos, .watchos => darwinLog(level, prefix, msg),
        .linux, .windows => desktopLog(level, prefix, msg),
        else => desktopLog(level, prefix, msg),
    }
}

// ============================================================
// Android — logcat
// ============================================================

fn androidLog(level: Level, prefix: []const u8, msg: []const u8) void {
    const combined = std.fmt.allocPrint(std.heap.page_allocator, "{s}{s}", .{ prefix, msg }) catch return;
    defer std.heap.page_allocator.free(combined);

    const c_str = std.heap.page_allocator.alloc(u8, combined.len + 1) catch return;
    defer std.heap.page_allocator.free(c_str);
    @memcpy(c_str[0..combined.len], combined);
    c_str[combined.len] = 0;

    const priority: c_int = switch (level) {
        .err => 3, // ANDROID_LOG_ERROR
        .warn => 4, // ANDROID_LOG_WARN
        .info => 5, // ANDROID_LOG_INFO
        .debug => 6, // ANDROID_LOG_DEBUG
    };

    _ = __android_log_write(priority, "zigfoundation", c_str.ptr);
}

extern fn __android_log_write(prio: c_int, tag: [*]const u8, text: [*]const u8) c_int;

// ============================================================
// iOS / macOS — syslog
// ============================================================

fn darwinLog(level: Level, prefix: []const u8, msg: []const u8) void {
    const combined = std.fmt.allocPrint(std.heap.page_allocator, "{s}{s}", .{ prefix, msg }) catch return;
    defer std.heap.page_allocator.free(combined);

    // 分配 null-terminated C 字符串
    const c_str = std.heap.page_allocator.alloc(u8, combined.len + 1) catch return;
    defer std.heap.page_allocator.free(c_str);
    @memcpy(c_str[0..combined.len], combined);
    c_str[combined.len] = 0;

    const priority: c_int = switch (level) {
        .err => 3, // LOG_ERR
        .warn => 4, // LOG_WARNING
        .info => 6, // LOG_INFO
        .debug => 7, // LOG_DEBUG
    };

    _ = syslog(priority, "%s", c_str.ptr);
}

extern fn syslog(priority: c_int, format: [*]const u8, ...) void;

// ============================================================
// 桌面 — stderr（ANSI 颜色）
// ============================================================

fn desktopLog(level: Level, prefix: []const u8, msg: []const u8) void {
    const color = switch (level) {
        .err => "\x1b[31m",
        .warn => "\x1b[33m",
        .info => "\x1b[32m",
        .debug => "\x1b[36m",
    };
    const reset = "\x1b[0m";

    const line = std.fmt.allocPrint(std.heap.page_allocator, "{s}{s}{s}{s}\n", .{ color, prefix, msg, reset }) catch return;
    defer std.heap.page_allocator.free(line);

    if (builtin.os.tag == .windows) {
        const stderr_h = logWinGetStdHandle(logWin.STD_ERROR_HANDLE);
        _ = logWin.WriteFile(stderr_h, line.ptr, @intCast(line.len), null, null);
    } else {
        _ = std.c.write(2, line.ptr, line.len);
    }
}

// Windows I/O — declared locally since Zig 0.16.0 has minimal kernel32 in std lib.
const logWin = struct {
    const HANDLE = *anyopaque;
    const DWORD = u32;
    const BOOL = i32;
    const LPVOID = *anyopaque;

    const STD_ERROR_HANDLE: DWORD = @as(DWORD, @bitCast(@as(i32, -12)));

    extern "kernel32" fn GetStdHandle(nStdHandle: DWORD) callconv(.winapi) HANDLE;
    extern "kernel32" fn WriteFile(
        hFile: HANDLE,
        lpBuffer: [*]const u8,
        nNumberOfBytesToWrite: DWORD,
        lpNumberOfBytesWritten: ?*DWORD,
        lpOverlapped: ?LPVOID,
    ) callconv(.winapi) BOOL;
};

fn logWinGetStdHandle(which: logWin.DWORD) logWin.HANDLE {
    return logWin.GetStdHandle(which);
}

// ============================================================
// 测试
// ============================================================

const testing = std.testing;

test "log: init sets level" {
    init(.debug);
    try testing.expectEqual(Level.debug, getLevel());
    init(.info); // restore default
}

test "log: setLevel changes runtime level" {
    setLevel(.err);
    try testing.expectEqual(Level.err, getLevel());
    setLevel(.info); // restore
    try testing.expectEqual(Level.info, getLevel());
}

test "log: getLevel returns current level" {
    setLevel(.warn);
    const l = getLevel();
    try testing.expectEqual(Level.warn, l);
    setLevel(.info); // restore
}

test "log: level ordering is correct" {
    // Zig 0.16.0: err=0 < warn=1 < info=2 < debug=3 (越详细值越大)
    try testing.expect(@intFromEnum(Level.debug) > @intFromEnum(Level.info));
    try testing.expect(@intFromEnum(Level.info) > @intFromEnum(Level.warn));
    try testing.expect(@intFromEnum(Level.warn) > @intFromEnum(Level.err));
}

test "log: logOptions returns valid Options" {
    const opts = logOptions();
    try testing.expect(@TypeOf(opts.logFn) != void);
}

test "log: init with all four levels" {
    inline for (@typeInfo(Level).@"enum".fields) |f| {
        const l: Level = @enumFromInt(f.value);
        init(l);
        try testing.expectEqual(l, getLevel());
    }
    init(.info); // restore
}
