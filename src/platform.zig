//! 平台抽象 — 跨平台检测、时间、系统资源、DNS 探测
//!
//! 合并自 zigproxy/src/platform.zig + zproxy/src/platform/time.zig
//! + zproxy/src/platform/system.zig，适配 Zig 0.16.0。
//!
//! 关键 0.16.0 API 变更:
//! - std.posix.clock_gettime → std.c.clock_gettime
//! - std.fs.cwd() → std.Io.Dir.cwd()
//! - 信号处理不在本模块——见 cli.zig (Phase 3)。

const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const native_os = builtin.os.tag;

// ============================================================
// 平台检测编译期常量
// ============================================================

pub const isDarwin = switch (native_os) {
    .macos, .ios, .tvos, .watchos, .visionos => true,
    else => false,
};

pub const isLinux = native_os == .linux;
pub const isWindows = native_os == .windows;
pub const isMobile = switch (native_os) {
    .ios, .tvos, .watchos, .visionos, .android => true,
    else => false,
};

// ============================================================
// 跨平台时间（单调时钟 + 绝对时钟）
// ============================================================

/// 单调时钟毫秒时间戳。跨平台，不受系统时间调整影响。
/// Windows: GetTickCount64; POSIX: clock_gettime(CLOCK_MONOTONIC)。
pub fn monoMillis() i64 {
    if (native_os == .windows) {
        const Win32 = struct {
            extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
        };
        return @as(i64, @intCast(Win32.GetTickCount64()));
    }
    var ts: c.timespec = undefined;
    _ = c.clock_gettime(c.CLOCK.MONOTONIC, &ts);
    return @as(i64, ts.sec) * std.time.ms_per_s + @divFloor(@as(i64, ts.nsec), std.time.ns_per_ms);
}

/// 单调时钟微秒时间戳。
pub fn monoMicros() i64 {
    if (native_os == .windows) {
        const Win32 = struct {
            extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
        };
        return @as(i64, @intCast(Win32.GetTickCount64() * 1000));
    }
    var ts: c.timespec = undefined;
    _ = c.clock_gettime(c.CLOCK.MONOTONIC, &ts);
    return @as(i64, ts.sec) * std.time.us_per_s + @divFloor(@as(i64, ts.nsec), std.time.ns_per_us);
}

/// 单调时钟纳秒时间戳。
/// Windows: QueryPerformanceCounter; POSIX: clock_gettime(CLOCK_MONOTONIC)。
pub fn monoNanos() i64 {
    if (native_os == .windows) {
        const Win32 = struct {
            extern "kernel32" fn QueryPerformanceCounter(counter: *i64) callconv(.winapi) i32;
            extern "kernel32" fn QueryPerformanceFrequency(freq: *i64) callconv(.winapi) i32;
        };
        var freq: i64 = 0;
        if (Win32.QueryPerformanceFrequency(&freq) == 0 or freq <= 0) return 0;
        var counter: i64 = 0;
        if (Win32.QueryPerformanceCounter(&counter) == 0) return 0;
        return @divTrunc(counter * std.time.ns_per_s, freq);
    }
    var ts: c.timespec = undefined;
    _ = c.clock_gettime(c.CLOCK.MONOTONIC, &ts);
    return @as(i64, ts.sec) * std.time.ns_per_s + @as(i64, ts.nsec);
}

/// 绝对（挂钟）毫秒时间戳。可能受 NTP/手动时间调整影响。
/// Windows: GetSystemTimeAsFileTime; POSIX: clock_gettime(CLOCK_REALTIME)。
pub fn absoluteMillis() i64 {
    if (native_os == .windows) {
        const Win32 = struct {
            extern "kernel32" fn GetSystemTimeAsFileTime(filetime: *u64) callconv(.winapi) void;
        };
        var ft: u64 = 0;
        Win32.GetSystemTimeAsFileTime(&ft);
        return @as(i64, @intCast(ft / 10_000));
    }
    var ts: c.timespec = undefined;
    _ = c.clock_gettime(c.CLOCK.REALTIME, &ts);
    return @as(i64, ts.sec) * std.time.ms_per_s + @divFloor(@as(i64, ts.nsec), std.time.ns_per_ms);
}

// ============================================================
// 系统资源探测
// ============================================================

/// CPU 核心数（在线处理器）。失败时返回 2。
pub fn getCpuCount() usize {
    return std.Thread.getCpuCount() catch 2;
}

/// 系统最大文件描述符数（预留 stdin/stdout/stderr/server 各 1）。
/// - Unix: getrlimit(RLIMIT_NOFILE)，先尝试提升软限制
/// - Windows: 16384（保守默认）
pub fn getMaxFds() usize {
    if (native_os == .windows) {
        return 16384 - 4;
    }
    raiseMaxFdsImpl() catch {};

    const rl = std.posix.getrlimit(.NOFILE) catch return 1024 - 4;
    const unlimited = std.math.maxInt(u64);
    if (rl.cur == unlimited) {
        return 32767 - 4;
    }
    return @as(usize, @intCast(rl.cur)) -| 4;
}

/// 提升 fd 软限制至 2048（仅在低于该值时）。非 Windows。
pub fn raiseMaxFds() void {
    raiseMaxFdsImpl() catch {};
}

fn raiseMaxFdsImpl() !void {
    if (native_os == .windows) return;
    const rl = std.posix.getrlimit(.NOFILE) catch return;
    if (rl.cur >= 2048) return;
    const unlimited = std.math.maxInt(u64);
    const new_soft: usize = if (rl.max == unlimited) 2048 else @min(2048, @as(usize, @intCast(rl.max)));
    try std.posix.setrlimit(.NOFILE, .{ .cur = new_soft, .max = rl.max });
}

/// 推荐会话池大小。公式: maxFds / 2 - 4，夹紧至 [16, 32767]。
pub fn getRecommendedPoolSize() usize {
    const max_fds = getMaxFds();
    const pool = max_fds / 2;
    const with_margin = pool -| 4;
    return @max(16, @min(with_margin, 32767));
}

// ============================================================
// 系统 DNS 探测
// ============================================================

/// 从系统配置检测 DNS 服务器地址。
/// 返回 IPv4 字符串（如 "192.168.64.1"），调用者通过 allocator 释放。
/// 解析失败时回退到 "8.8.8.8"。
pub fn detectSystemDns(allocator: std.mem.Allocator) []const u8 {
    if (!isWindows) {
        if (detectDnsFromResolvConf(allocator)) |ns| return ns;
    }
    return allocator.dupe(u8, "8.8.8.8") catch @panic("OOM");
}

/// 解析 /etc/resolv.conf，返回第一个 nameserver 地址。
/// 使用 C fopen/fread 读取整个文件到缓冲区后解析（Zig 0.16.0 无 fgets）。
fn detectDnsFromResolvConf(allocator: std.mem.Allocator) ?[]const u8 {
    const f = c.fopen("/etc/resolv.conf", "r") orelse return null;
    defer _ = c.fclose(f);

    var buf: [4096]u8 = undefined;
    const n = c.fread(&buf, 1, buf.len, f);
    const content = buf[0..n];

    var iter = std.mem.splitScalar(u8, content, '\n');
    while (iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "nameserver")) {
            var parts = std.mem.splitAny(u8, trimmed, " \t");
            _ = parts.next(); // skip "nameserver"
            if (parts.next()) |ip| {
                _ = std.Io.net.IpAddress.parse(ip, 53) catch continue;
                return allocator.dupe(u8, ip) catch continue;
            }
        }
    }
    return null;
}

// ============================================================
// 测试
// ============================================================

const testing = std.testing;

test "platform: detection compiles (compile-time constants)" {
    try testing.expect(isDarwin or isLinux or isWindows);
}

test "platform: monoMillis increasing" {
    const a = monoMillis();
    const b = monoMillis();
    try testing.expect(b >= a);
}

test "platform: monoMicros increasing" {
    const a = monoMicros();
    const b = monoMicros();
    try testing.expect(b >= a);
}

test "platform: monoNanos increasing" {
    const a = monoNanos();
    const b = monoNanos();
    try testing.expect(b >= a);
}

test "platform: absoluteMillis returns valid timestamp" {
    const t = absoluteMillis();
    try testing.expect(t > 0);
}

test "platform: getCpuCount positive" {
    const n = getCpuCount();
    try testing.expect(n >= 1);
}

test "platform: getMaxFds reasonable" {
    const n = getMaxFds();
    try testing.expect(n >= 12);
}

test "platform: getRecommendedPoolSize clamped" {
    const n = getRecommendedPoolSize();
    try testing.expect(n >= 16);
    try testing.expect(n <= 32767);
}

test "platform: detectSystemDns returns valid string" {
    const ns = detectSystemDns(testing.allocator);
    defer testing.allocator.free(ns);
    try testing.expect(ns.len >= 7); // shortest valid IP "1.1.1.1" is 7 chars
}
