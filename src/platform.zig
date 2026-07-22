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
const net = @import("net.zig");

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
    .ios, .tvos, .watchos, .visionos => true,
    else => builtin.abi.isAndroid(),
};

// ============================================================
// 跨平台时间（单调时钟 + 绝对时钟）
// ============================================================

/// 单调时钟毫秒时间戳。跨平台，不受系统时间调整影响。
/// Windows: GetTickCount64; POSIX: clock_gettime（macOS/non-Linux: CLOCK_MONOTONIC;
/// Linux: CLOCK_BOOTTIME，含 suspend 时间，对齐 zigtun NAT 超时语义）。
pub fn monoMillis() i64 {
    if (native_os == .windows) {
        const Win32 = struct {
            extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
        };
        return @as(i64, @intCast(Win32.GetTickCount64()));
    }
    var ts: c.timespec = undefined;
    // Linux 使用 CLOCK_BOOTTIME（含 suspend 时间），对齐 zigtun NAT 超时语义
    const clock_id = if (native_os == .linux)
        @as(c.CLOCK, @enumFromInt(7)) // CLOCK_BOOTTIME
    else
        c.CLOCK.MONOTONIC;
    _ = c.clock_gettime(clock_id, &ts);
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
        const wide = @as(i128, counter) * std.time.ns_per_s;
        return @intCast(@divTrunc(wide, freq));
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
        // Windows FILETIME epoch is 1601-01-01; Unix epoch is 1970-01-01.
        const ft_ms: i64 = @intCast(ft / 10_000);
        return ft_ms - 11644473600000; // 1601→1970 epoch delta in ms
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
// 跨平台睡眠
// ============================================================

/// 跨平台纳秒级睡眠。Windows 使用 kernel32 Sleep (毫秒精度)，其他平台使用 nanosleep。
pub fn sleepNs(ns: u64) void {
    if (native_os == .windows) {
        const ms = ns / std.time.ns_per_ms;
        if (ms == 0) return;
        const Win32 = struct {
            extern "kernel32" fn Sleep(dwMilliseconds: u32) callconv(.winapi) void;
        };
        Win32.Sleep(@intCast(@min(ms, std.math.maxInt(u32))));
    } else {
        const s: u64 = ns / std.time.ns_per_s;
        const remainder: u64 = ns % std.time.ns_per_s;
        _ = c.nanosleep(&.{ .sec = @intCast(s), .nsec = @intCast(remainder) }, null);
    }
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
// 系统 DNS 状态管理与替换（TUN auto_route 模式）
// ============================================================

/// 系统 DNS 状态快照，保存原始 DNS 配置以在退出时恢复。
pub const SystemDnsState = struct {
    /// 是否实际修改了系统 DNS
    changed: bool,
    /// 分配器（deinit 时用于释放内存）
    allocator: std.mem.Allocator,

    data: Data,

    const Data = union(enum) {
        macos: MacOSState,
        linux: LinuxState,
        none: void,
    };

    const MacOSState = struct {
        /// 修改了 DNS 的网络服务列表
        services: []MacOSServiceEntry = &.{},

        const MacOSServiceEntry = struct {
            /// 网络服务名（如 "Wi-Fi"）
            name: []const u8,
            /// 原始 DNS 服务器 IP 列表
            servers: []const []const u8,
        };
    };

    const LinuxState = struct {
        /// /etc/resolv.conf 原始内容
        original_content: ?[]const u8 = null,
    };

    /// 创建未修改状态的占位实例。
    pub fn initUnchanged() SystemDnsState {
        return .{ .changed = false, .allocator = undefined, .data = .none };
    }

    /// 释放所有持有的内存。
    pub fn deinit(self: *SystemDnsState) void {
        if (!self.changed) {
            self.* = undefined;
            return;
        }
        switch (self.data) {
            .macos => |*m| {
                for (m.services) |*svc| {
                    self.allocator.free(svc.name);
                    for (svc.servers) |s| self.allocator.free(s);
                    self.allocator.free(svc.servers);
                }
                self.allocator.free(m.services);
            },
            .linux => |*l| {
                if (l.original_content) |c2| self.allocator.free(c2);
            },
            .none => {},
        }
        self.* = undefined;
    }
};

/// 检测当前系统 DNS 服务器。若为非公网地址（DHCP 网关、私有 IP 等），
/// 保存原始配置并返回 .changed = true。若已为公网地址则返回 .changed = false。
///
/// macOS: 通过 networksetup 检测所有网络服务的 DNS 配置。
/// Linux: 直接读取 /etc/resolv.conf。
/// Windows: 返回 initUnchanged()（sing-tun 已在适配器层处理 DNS）。
pub fn saveSystemDns(allocator: std.mem.Allocator) !SystemDnsState {
    if (isDarwin) {
        return saveSystemDnsDarwin(allocator);
    } else if (isLinux) {
        return saveSystemDnsLinux(allocator);
    }
    return SystemDnsState.initUnchanged();
}

/// 将系统 DNS 替换为指定地址。仅在 state.changed = true 时有效。
pub fn setSystemDns(allocator: std.mem.Allocator, state: *const SystemDnsState, dns_ip: []const u8) !void {
    if (!state.changed) return;
    if (isDarwin) {
        try setSystemDnsDarwin(state, dns_ip);
    } else if (isLinux) {
        try setSystemDnsLinux(allocator, state, dns_ip);
    }
}

/// 恢复原始系统 DNS。仅在 state.changed = true 时执行。
/// 失败时不返回错误（best-effort 恢复）。
pub fn restoreSystemDns(state: *SystemDnsState) void {
    if (!state.changed) return;
    if (isDarwin) {
        restoreSystemDnsDarwin(state);
    } else if (isLinux) {
        restoreSystemDnsLinux(state);
    }
}

// ============================================================
// macOS DNS 实现（networksetup）
// ============================================================

/// 在子进程中执行命令，捕获 stdout 输出。返回分配器分配的字符串。
fn execCaptureOutput(allocator: std.mem.Allocator, cmd: []const u8, args: []const []const u8) ![]const u8 {
    var pipe_fds: [2]c.fd_t = undefined;
    if (c.pipe(&pipe_fds) != 0) return error.PipeFailed;

    const pid = c.fork();
    if (pid < 0) return error.ForkFailed;

    if (pid == 0) {
        // 子进程：stdout → 管道，关闭 stderr
        _ = c.close(pipe_fds[0]);
        _ = c.dup2(pipe_fds[1], c.STDOUT_FILENO);
        _ = c.close(pipe_fds[1]);
        _ = c.close(c.STDERR_FILENO);

        // 构建 argv（null 结尾数组，元素为可空指针）
        const argv_len = args.len + 1; // cmd + args
        const argv = allocator.allocSentinel(?[*:0]const u8, argv_len, null) catch {
            c._exit(1);
        };
        defer allocator.free(argv);
        argv[0] = @ptrCast(cmd.ptr);
        for (args, 0..) |arg, i| {
            argv[i + 1] = @ptrCast(arg.ptr);
        }
        // 最后一个元素已由 allocSentinel 设为 null

        const envp: [1:null]?[*:0]const u8 = .{null};
        _ = c.execve(@ptrCast(cmd.ptr), argv.ptr, &envp);
        c._exit(1);
    }

    _ = c.close(pipe_fds[1]);

    var buf: [4096]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const n = c.read(pipe_fds[0], buf[total..].ptr, buf.len - total);
        if (n <= 0) break;
        total += @intCast(n);
    }
    _ = c.close(pipe_fds[0]);
    _ = c.waitpid(pid, null, 0);

    const result = try allocator.alloc(u8, total);
    @memcpy(result, buf[0..total]);
    return result;
}

/// 检查 IP 字符串是否是非公网地址（私有、环回、链路本地、组播、未指定）。
fn isPrivateIpStr(ip_str: []const u8) bool {
    const ip = net.parseIpv4(ip_str) catch return false;
    return net.isNonPublicV4(ip);
}

fn saveSystemDnsDarwin(allocator: std.mem.Allocator) !SystemDnsState {
    // 1. 列出所有网络服务
    const services_output = execCaptureOutput(allocator, "/usr/sbin/networksetup", &.{"-listallnetworkservices"}) catch |err| {
        std.log.warn("[dns] networksetup -listallnetworkservices 失败: {}", .{err});
        return SystemDnsState.initUnchanged();
    };
    defer allocator.free(services_output);

    // 解析服务名（跳过含 * 的标题行和空行）
    var all_services: std.ArrayList([]const u8) = .empty;
    defer all_services.deinit(allocator);
    var lines = std.mem.splitScalar(u8, services_output, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (std.mem.indexOfScalar(u8, trimmed, '*') != null) continue;
        const name = try allocator.dupe(u8, trimmed);
        try all_services.append(allocator, name);
    }

    // 2. 对每个服务获取 DNS 配置，检查是否为非公网地址
    var changed_services: std.ArrayList(SystemDnsState.MacOSState.MacOSServiceEntry) = .empty;
    defer changed_services.deinit(allocator);

    for (all_services.items) |svc_name| {
        const dns_output = execCaptureOutput(allocator, "/usr/sbin/networksetup", &.{ "-getdnsservers", svc_name }) catch |err| {
            std.log.warn("[dns] networksetup -getdnsservers {s} 失败: {}", .{ svc_name, err });
            allocator.free(svc_name);
            continue;
        };
        defer allocator.free(dns_output);

        const trimmed_out = std.mem.trim(u8, dns_output, " \t\r\n");
        // "There aren't any DNS Servers set on ..." → 跳过
        if (trimmed_out.len == 0 or std.mem.startsWith(u8, trimmed_out, "There aren't any")) {
            allocator.free(svc_name);
            continue;
        }

        // 解析 DNS IP 列表（每行一个 IP）
        var servers: std.ArrayList([]const u8) = .empty;
        var has_private = false;
        var dns_lines = std.mem.splitScalar(u8, trimmed_out, '\n');
        while (dns_lines.next()) |dns_line| {
            const ip_str = std.mem.trim(u8, dns_line, " \t\r");
            if (ip_str.len == 0) continue;
            // IPv4 → 检查是否为非公网
            if (net.parseIpv4(ip_str)) |ip| {
                const s = try allocator.dupe(u8, ip_str);
                try servers.append(allocator, s);
                if (net.isNonPublicV4(ip)) {
                    has_private = true;
                }
            } else |_| {
                // IPv6 或其他格式 → 也保存（可能是公网）
                const s = try allocator.dupe(u8, ip_str);
                try servers.append(allocator, s);
            }
        }

        if (servers.items.len > 0 and has_private) {
            try changed_services.append(allocator, .{
                .name = svc_name,
                .servers = try servers.toOwnedSlice(allocator),
            });
        } else {
            // 公网 DNS → 不需要修改此服务
            allocator.free(svc_name);
            for (servers.items) |s| allocator.free(s);
            servers.deinit(allocator);
        }
    }

    if (changed_services.items.len == 0) {
        // 所有服务已是公网 DNS
        return SystemDnsState.initUnchanged();
    }

    return SystemDnsState{
        .changed = true,
        .allocator = allocator,
        .data = .{ .macos = .{ .services = try changed_services.toOwnedSlice(allocator) } },
    };
}

fn setSystemDnsDarwin(state: *const SystemDnsState, dns_ip: []const u8) !void {
    for (state.data.macos.services) |svc| {
        _ = execCaptureOutput(state.allocator, "/usr/sbin/networksetup", &.{ "-setdnsservers", svc.name, dns_ip }) catch |err| {
            std.log.warn("[dns] networksetup -setdnsservers {s} 失败: {}", .{ svc.name, err });
            return err;
        };
    }
    // 刷新 DNS 缓存
    _ = execCaptureOutput(state.allocator, "/usr/sbin/dscacheutil", &.{"-flushcache"}) catch {};
}

fn restoreSystemDnsDarwin(state: *SystemDnsState) void {
    for (state.data.macos.services) |svc| {
        if (svc.servers.len == 0) {
            _ = execCaptureOutput(state.allocator, "/usr/sbin/networksetup", &.{ "-setdnsservers", svc.name, "Empty" }) catch |err| {
                std.log.warn("[dns] networksetup 恢复 {s} 失败: {}", .{ svc.name, err });
            };
        } else {
            // 构建参数: networksetup -setdnsservers <name> <ip1> <ip2> ...
            var args: std.ArrayList([]const u8) = .empty;
            args.append(state.allocator, "-setdnsservers") catch continue;
            args.append(state.allocator, svc.name) catch continue;
            for (svc.servers) |s| {
                args.append(state.allocator, s) catch break;
            }
            _ = execCaptureOutput(state.allocator, "/usr/sbin/networksetup", args.items) catch |err| {
                std.log.warn("[dns] networksetup 恢复 {s} 失败: {}", .{ svc.name, err });
            };
        }
    }
    // 刷新 DNS 缓存
    _ = execCaptureOutput(state.allocator, "/usr/sbin/dscacheutil", &.{"-flushcache"}) catch {};
}

// ============================================================
// Linux DNS 实现（/etc/resolv.conf）
// ============================================================

fn isSystemdResolvedStub() bool {
    // 检查 /etc/resolv.conf 是否指向 systemd-resolved stub
    var link_buf: [4096]u8 = undefined;
    const n = c.readlink("/etc/resolv.conf", &link_buf, link_buf.len);
    if (n < 0) return false; // 不是符号链接
    const target = link_buf[0..@intCast(n)];
    return std.mem.indexOf(u8, target, "systemd/resolve") != null;
}

fn readResolvConf(allocator: std.mem.Allocator) ![]const u8 {
    const f = c.fopen("/etc/resolv.conf", "r") orelse return error.FileNotFound;
    defer _ = c.fclose(f);

    var buf: [4096]u8 = undefined;
    const n = c.fread(&buf, 1, buf.len, f);
    const content = buf[0..n];
    return allocator.dupe(u8, content);
}

fn saveSystemDnsLinux(allocator: std.mem.Allocator) !SystemDnsState {
    if (isSystemdResolvedStub()) {
        std.log.debug("[dns] /etc/resolv.conf 由 systemd-resolved 管理，跳过 DNS 替换", .{});
        return SystemDnsState.initUnchanged();
    }

    const content = readResolvConf(allocator) catch |err| {
        std.log.warn("[dns] 无法读取 /etc/resolv.conf: {}", .{err});
        return SystemDnsState.initUnchanged();
    };

    // 检查第一个 nameserver 是否为非公网
    var iter = std.mem.splitScalar(u8, content, '\n');
    var has_private = false;
    while (iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "nameserver")) {
            var parts = std.mem.splitAny(u8, trimmed, " \t");
            _ = parts.next(); // skip "nameserver"
            if (parts.next()) |ip_str| {
                if (isPrivateIpStr(ip_str)) {
                    has_private = true;
                    break;
                }
            }
            break; // 只检查第一个 nameserver
        }
    }

    if (!has_private) {
        allocator.free(content);
        return SystemDnsState.initUnchanged();
    }

    return SystemDnsState{
        .changed = true,
        .allocator = allocator,
        .data = .{ .linux = .{ .original_content = content } },
    };
}

fn setSystemDnsLinux(allocator: std.mem.Allocator, state: *const SystemDnsState, dns_ip: []const u8) !void {
    const original = state.data.linux.original_content orelse return;

    // 构建新内容：nameserver <dns_ip> + 原有的非 nameserver 行
    var new_content: std.ArrayList(u8) = .empty;
    defer new_content.deinit(allocator);

    // 先写入新的 nameserver 行
    try new_content.appendSlice(allocator, "nameserver ");
    try new_content.appendSlice(allocator, dns_ip);
    try new_content.append(allocator, '\n');

    // 保留原有的非 nameserver 行
    var iter = std.mem.splitScalar(u8, original, '\n');
    while (iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "nameserver")) continue;
        try new_content.appendSlice(allocator, line);
        try new_content.append(allocator, '\n');
    }

    const content = new_content.items;
    const f = c.fopen("/etc/resolv.conf", "w") orelse return error.FileNotFound;
    defer _ = c.fclose(f);
    _ = c.fwrite(content.ptr, 1, content.len, f);
}

fn restoreSystemDnsLinux(state: *SystemDnsState) void {
    const original = state.data.linux.original_content orelse return;

    const f = c.fopen("/etc/resolv.conf", "w") orelse {
        std.log.warn("[dns] 无法打开 /etc/resolv.conf 进行恢复", .{});
        return;
    };
    defer _ = c.fclose(f);
    _ = c.fwrite(original.ptr, 1, original.len, f);
}

// ============================================================
// 测试
// ============================================================

const testing = std.testing;

test "platform: reference all pub decls (lazy-analysis guard)" {
    testing.refAllDecls(@This());
}

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
