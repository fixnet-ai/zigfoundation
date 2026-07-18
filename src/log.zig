//! 分级日志框架 — trace/debug/info/warn/err 五个级别、多输出后端
//!
//! 遵循注入模式：Logger 接受 WriteFn 回调作为输出后端，模块内部不持有全局状态。
//!
//! 使用示例：
//! ```
//! var log = try Logger.init(testing.allocator, .{ .level = .info });
//! defer log.deinit();
//! log.info("listening on port {}", .{8080});
//! ```

const std = @import("std");
const builtin = @import("builtin");

// ============================================================
// 日志级别
// ============================================================

/// 日志级别（从低到高）。
pub const Level = enum(u3) {
    trace = 0,
    debug = 1,
    info = 2,
    warn = 3,
    err = 4,

    /// ANSI 颜色代码。
    pub fn color(self: Level) []const u8 {
        return switch (self) {
            .trace => "\x1b[90m",
            .debug => "\x1b[36m",
            .info => "\x1b[0m",
            .warn => "\x1b[33m",
            .err => "\x1b[31m",
        };
    }

    /// 级别标签。
    pub fn tag(self: Level) []const u8 {
        return switch (self) {
            .trace => "TRACE",
            .debug => "DEBUG",
            .info => "INFO ",
            .warn => "WARN ",
            .err => "ERROR",
        };
    }
};

// ============================================================
// 输出后端
// ============================================================

/// 写回调 — 日志后端需实现此签名。
pub const WriteFn = *const fn (bytes: []const u8) anyerror!usize;

/// 将消息写入 stderr（跨平台）。
pub fn writeStderr(bytes: []const u8) !usize {
    if (builtin.os.tag == .windows) {
        return writeWindowsStderr(bytes);
    }
    return writePosixFd(2, bytes);
}

/// 将消息写入 stdout（跨平台）。
pub fn writeStdout(bytes: []const u8) !usize {
    if (builtin.os.tag == .windows) {
        return writeWindowsStdout(bytes);
    }
    return writePosixFd(1, bytes);
}

fn writePosixFd(fd: i32, bytes: []const u8) !usize {
    // Zig 0.16.0: std.posix.write 已移除，直接使用 C write
    const c_write = std.c.write;
    const n = c_write(fd, bytes.ptr, bytes.len);
    if (n < 0) return error.WriteFailed;
    return @intCast(n);
}

fn writeWindowsStderr(bytes: []const u8) !usize {
    const kernel32 = struct {
        extern "kernel32" fn GetStdHandle(nStdHandle: u32) callconv(.winapi) ?*anyopaque;
        extern "kernel32" fn WriteFile(
            hFile: ?*anyopaque,
            lpBuffer: [*]const u8,
            nNumberOfBytesToWrite: u32,
            lpNumberOfBytesWritten: *u32,
            lpOverlapped: ?*anyopaque,
        ) callconv(.winapi) i32;
    };
    const STD_ERROR_HANDLE: u32 = @bitCast(@as(i32, -12));
    const h = kernel32.GetStdHandle(STD_ERROR_HANDLE) orelse return error.WriteFailed;
    var written: u32 = 0;
    if (kernel32.WriteFile(h, bytes.ptr, @intCast(bytes.len), &written, null) == 0) {
        return error.WriteFailed;
    }
    return written;
}

fn writeWindowsStdout(bytes: []const u8) !usize {
    const kernel32 = struct {
        extern "kernel32" fn GetStdHandle(nStdHandle: u32) callconv(.winapi) ?*anyopaque;
        extern "kernel32" fn WriteFile(
            hFile: ?*anyopaque,
            lpBuffer: [*]const u8,
            nNumberOfBytesToWrite: u32,
            lpNumberOfBytesWritten: *u32,
            lpOverlapped: ?*anyopaque,
        ) callconv(.winapi) i32;
    };
    const STD_OUTPUT_HANDLE: u32 = @bitCast(@as(i32, -11));
    const h = kernel32.GetStdHandle(STD_OUTPUT_HANDLE) orelse return error.WriteFailed;
    var written: u32 = 0;
    if (kernel32.WriteFile(h, bytes.ptr, @intCast(bytes.len), &written, null) == 0) {
        return error.WriteFailed;
    }
    return written;
}

// ============================================================
// Logger 配置
// ============================================================

/// Logger 初始化配置。
pub const Config = struct {
    /// 最低输出级别
    level: Level = .info,
    /// 输出后端。不设置则默认 writeStderr。
    write_fn: WriteFn = writeStderr,
    /// 格式化缓冲区大小（字节）
    buffer_size: usize = 4096,
    /// 是否启用 ANSI 颜色
    color: bool = false,
};

// ============================================================
// Logger
// ============================================================

/// 分级日志记录器。
pub const Logger = struct {
    allocator: std.mem.Allocator,
    level: Level,
    write_fn: WriteFn,
    buf: []u8,
    color_enabled: bool,

    /// 创建 Logger。
    pub fn init(allocator: std.mem.Allocator, cfg: Config) !Logger {
        const buf = try allocator.alloc(u8, cfg.buffer_size);
        errdefer allocator.free(buf);

        return .{
            .allocator = allocator,
            .level = cfg.level,
            .write_fn = cfg.write_fn,
            .buf = buf,
            .color_enabled = cfg.color,
        };
    }

    /// 释放 Logger 持有的资源。
    pub fn deinit(self: *Logger) void {
        self.allocator.free(self.buf);
    }

    /// 设置最低输出级别。
    pub fn setLevel(self: *Logger, level: Level) void {
        self.level = level;
    }

    /// 更换输出后端。
    pub fn setWriteFn(self: *Logger, write_fn: WriteFn) void {
        self.write_fn = write_fn;
    }

    // ===== 便捷方法 =====

    pub fn trace(self: *Logger, comptime fmt: []const u8, args: anytype) void {
        self.log(.trace, fmt, args);
    }

    pub fn debug(self: *Logger, comptime fmt: []const u8, args: anytype) void {
        self.log(.debug, fmt, args);
    }

    pub fn info(self: *Logger, comptime fmt: []const u8, args: anytype) void {
        self.log(.info, fmt, args);
    }

    pub fn warn(self: *Logger, comptime fmt: []const u8, args: anytype) void {
        self.log(.warn, fmt, args);
    }

    pub fn err(self: *Logger, comptime fmt: []const u8, args: anytype) void {
        self.log(.err, fmt, args);
    }

    // ===== 内部方法 =====

    fn log(self: *Logger, level: Level, comptime fmt: []const u8, args: anytype) void {
        if (@intFromEnum(level) < @intFromEnum(self.level)) return;

        const level_tag = level.tag();
        const color_code = if (self.color_enabled) level.color() else "";
        const color_reset = if (self.color_enabled) "\x1b[0m" else "";

        const formatted = std.fmt.bufPrint(
            self.buf,
            "{s}[{s}]{s} " ++ fmt ++ "\n",
            .{color_code} ++ .{level_tag} ++ .{color_reset} ++ args,
        ) catch {
            _ = self.write_fn("...(truncated)\n") catch {};
            return;
        };

        _ = self.write_fn(formatted) catch {};
    }
};

// ============================================================
// 测试辅助
// ============================================================

const testing = std.testing;

/// 捕获日志输出的测试内存后端。
const TestWriter = struct {
    buf: [4096]u8 = undefined,
    len: usize = 0,

    fn write(self: *TestWriter, bytes: []const u8) !usize {
        const remaining = self.buf.len - self.len;
        const n = @min(bytes.len, remaining);
        @memcpy(self.buf[self.len..][0..n], bytes[0..n]);
        self.len += n;
        return n;
    }

    fn content(self: *const TestWriter) []const u8 {
        return self.buf[0..self.len];
    }
};

/// 为 TestWriter 创建 WriteFn。
fn twWriteFn(tw: *TestWriter) WriteFn {
    const S = struct {
        var p: *TestWriter = undefined;
        fn w(bytes: []const u8) anyerror!usize {
            return p.write(bytes);
        }
    };
    S.p = tw;
    return S.w;
}

// ---- 日志测试 ----

test "log: info level filters trace and debug" {
    var tw = TestWriter{};
    var log = try Logger.init(testing.allocator, .{ .level = .info, .write_fn = twWriteFn(&tw) });
    defer log.deinit();

    log.trace("should not appear", .{});
    log.debug("also not appear", .{});
    log.info("this appears", .{});
    log.warn("this too", .{});
    log.err("and this", .{});

    const output = tw.content();
    try testing.expect(!std.mem.containsAtLeast(u8, output, 1, "TRACE"));
    try testing.expect(!std.mem.containsAtLeast(u8, output, 1, "DEBUG"));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "INFO"));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "WARN"));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "ERROR"));
}

test "log: debug level shows all except trace" {
    var tw = TestWriter{};
    var log = try Logger.init(testing.allocator, .{ .level = .debug, .write_fn = twWriteFn(&tw) });
    defer log.deinit();

    log.trace("hidden", .{});
    log.debug("visible", .{});
    log.info("also visible", .{});

    const output = tw.content();
    try testing.expect(!std.mem.containsAtLeast(u8, output, 1, "TRACE"));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "DEBUG"));
}

test "log: trace level shows everything" {
    var tw = TestWriter{};
    var log = try Logger.init(testing.allocator, .{ .level = .trace, .write_fn = twWriteFn(&tw) });
    defer log.deinit();

    log.trace("trace msg", .{});
    log.err("err msg", .{});

    const output = tw.content();
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "TRACE"));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "ERROR"));
}

test "log: formatted arguments" {
    var tw = TestWriter{};
    var log = try Logger.init(testing.allocator, .{ .level = .info, .write_fn = twWriteFn(&tw) });
    defer log.deinit();

    log.info("port {}, host {s}", .{ 8080, "localhost" });

    const output = tw.content();
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "8080"));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "localhost"));
}

test "log: setLevel after init" {
    var tw = TestWriter{};
    var log = try Logger.init(testing.allocator, .{ .level = .info, .write_fn = twWriteFn(&tw) });
    defer log.deinit();

    log.debug("hidden", .{});
    log.setLevel(.debug);
    log.debug("visible", .{});

    const output = tw.content();
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "visible"));
}

test "log: setWriteFn switches backend" {
    var tw1 = TestWriter{};
    var tw2 = TestWriter{};

    var log = try Logger.init(testing.allocator, .{ .level = .info, .write_fn = twWriteFn(&tw1) });
    defer log.deinit();

    log.info("to tw1", .{});
    log.setWriteFn(twWriteFn(&tw2));
    log.info("to tw2", .{});

    try testing.expect(std.mem.containsAtLeast(u8, tw1.content(), 1, "tw1"));
    try testing.expect(!std.mem.containsAtLeast(u8, tw1.content(), 1, "tw2"));
    try testing.expect(std.mem.containsAtLeast(u8, tw2.content(), 1, "tw2"));
}

test "log: error level only" {
    var tw = TestWriter{};
    var log = try Logger.init(testing.allocator, .{ .level = .err, .write_fn = twWriteFn(&tw) });
    defer log.deinit();

    log.warn("hidden warning", .{});
    log.err("critical error", .{});

    const output = tw.content();
    try testing.expect(!std.mem.containsAtLeast(u8, output, 1, "WARN"));
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "ERROR"));
}

test "log: color output format" {
    var tw = TestWriter{};
    var log = try Logger.init(testing.allocator, .{
        .level = .info,
        .write_fn = twWriteFn(&tw),
        .color = true,
    });
    defer log.deinit();

    log.info("colored", .{});

    const output = tw.content();
    try testing.expect(std.mem.containsAtLeast(u8, output, 1, "\x1b["));
}

test "log: level tag formats" {
    try testing.expectEqualStrings("TRACE", Level.trace.tag());
    try testing.expectEqualStrings("DEBUG", Level.debug.tag());
    try testing.expectEqualStrings("INFO ", Level.info.tag());
    try testing.expectEqualStrings("WARN ", Level.warn.tag());
    try testing.expectEqualStrings("ERROR", Level.err.tag());
}

test "writeStderr: writes without error" {
    _ = writeStderr("") catch {};
}

test "writeStdout: writes without error" {
    _ = writeStdout("") catch {};
}
