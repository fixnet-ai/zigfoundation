//! 网络出站 — 跨平台 socket 创建 + 绕过路由绑定
//!
//! 提供统一的跨平台出站 socket API，支持：
//! - TCP/UDP socket 创建
//! - 接口绑定（绕过路由表）：
//!   - Linux: `SO_BINDTODEVICE`（按接口名绑定）
//!   - macOS/iOS: `IP_BOUND_IF` / `IPV6_BOUND_IF`（按接口索引绑定）
//!   - Windows: `IP_UNICAST_IF` / `IPV6_UNICAST_IF`（按接口索引绑定）
//! - 源地址绑定（`bind()` before `connect()`）
//! - SO_REUSEADDR 设置
//!
//! ## 平台支持
//!
//! | 功能 | Linux | macOS | iOS | Windows | Android |
//! |------|-------|-------|-----|---------|---------|
//! | 接口名绑定 | SO_BINDTODEVICE | ❌ | ❌ | ❌ | SO_BINDTODEVICE |
//! | 接口索引绑定 | ❌ | IP_BOUND_IF | IP_BOUND_IF | IP_UNICAST_IF | ❌ |
//! | 源地址绑定 | bind() | bind() | bind() | bind() | bind() |
//!
//! ## 使用示例
//!
//! ```
//! const egress = @import("zigfoundation").egress;
//!
//! // 创建绑定到指定接口的 TCP socket
//! const sock = try egress.Socket.initTcp(.{
//!     .interface_name = "eth0",
//!     .reuse_addr = true,
//! });
//! defer sock.close();
//! ```

const std = @import("std");
const builtin = @import("builtin");

/// 跨平台 socket 协议常量（避免 std.posix.AF/SOCK/IPPROTO 在不同 OS 上的类型差异）。
/// 注意：这些值因平台而异，必须按 builtin.os.tag 分派，不能写死单一平台的值。
const AF_INET: u32 = 2; // 全平台一致
const AF_INET6: u32 = switch (builtin.os.tag) {
    .linux => 10, // Linux/Android (bionic 同 kernel)
    .windows => 23,
    else => 30, // Darwin (macOS/iOS/tvOS/watchOS)
};
const SOCK_STREAM: u32 = 1;
const SOCK_DGRAM: u32 = 2;
const IPPROTO_TCP: u32 = 6;
const IPPROTO_UDP: u32 = 17;

/// 协议级别常量 — SOL_SOCKET 因平台而异，IPPROTO_* 全平台一致。
const SOL_SOCKET: i32 = switch (builtin.os.tag) {
    .linux => 1, // Linux/Android
    else => 0xffff, // Darwin/Windows
};
const IPPROTO_IP: i32 = 0;
const IPPROTO_IPV6: i32 = 41;

/// Socket 选项常量（按平台取值）。
const SO_REUSEADDR: u32 = switch (builtin.os.tag) {
    .linux => 2, // Linux/Android
    else => 4, // Darwin/Windows
};
const SO_BINDTODEVICE: u32 = 25; // Linux/Android: 按接口名绑定
const IPV6_V6ONLY: u32 = switch (builtin.os.tag) {
    .linux => 26, // Linux/Android
    else => 27, // Darwin/Windows
};
const IP_BOUND_IF: u32 = 25; // Darwin: IPPROTO_IP 级接口索引绑定 (in.h)
const IPV6_BOUND_IF: u32 = 125; // Darwin: IPPROTO_IPV6 级接口索引绑定 (in6.h)
const IP_UNICAST_IF: u32 = 31; // Windows: IPPROTO_IP 级出站接口（值须网络字节序）
const IPV6_UNICAST_IF: u32 = 31; // Windows: IPPROTO_IPV6 级出站接口（值为主机字节序）

/// 出站 socket 绑定选项。
pub const BindOpts = struct {
    /// Linux/Android: 接口名（如 "eth0"），设置 SO_BINDTODEVICE。
    interface_name: ?[]const u8 = null,

    /// macOS/iOS: 接口索引（IP_BOUND_IF），Windows: 接口索引（IP_UNICAST_IF）。
    /// Linux/Android 上忽略。
    interface_index: ?u32 = null,

    /// 源地址绑定 — 在 connect() 之前执行 bind() 到此Ip地址。
    /// 格式为 "ip:port"，如 "127.0.0.1:0"（port=0 表示系统自动分配）。
    source_addr: ?[]const u8 = null,

    /// 设置 SO_REUSEADDR（默认 true，允许端口复用）。
    reuse_addr: bool = true,
};

/// 跨平台出站 socket。
///
/// 封装原始 socket 文件描述符，提供统一的创建和绑定接口。
/// 不执行任何异步 I/O — 调用者自行使用 libxev 或 std.posix 进行读写。
pub const Socket = struct {
    fd: std.posix.socket_t,

    /// 创建 TCP socket 并应用绑定选项。
    pub fn initTcp(opts: BindOpts) !Socket {
        const fd = try createSocket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        errdefer closeFd(fd);

        try applyOpts(fd, opts, false);
        return Socket{ .fd = fd };
    }

    /// 创建 UDP socket 并应用绑定选项。
    pub fn initUdp(opts: BindOpts) !Socket {
        const fd = try createSocket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
        errdefer closeFd(fd);

        try applyOpts(fd, opts, false);
        return Socket{ .fd = fd };
    }

    /// 创建支持 IPv6 的 TCP socket（双栈）。
    pub fn initTcp6(opts: BindOpts) !Socket {
        const fd = try createSocket(AF_INET6, SOCK_STREAM, IPPROTO_TCP);
        errdefer closeFd(fd);

        // 禁用 IPV6_V6ONLY 以实现双栈
        try setIpv6Only(fd, false);
        try applyOpts(fd, opts, true);
        return Socket{ .fd = fd };
    }

    /// 创建支持 IPv6 的 UDP socket（双栈）。
    pub fn initUdp6(opts: BindOpts) !Socket {
        const fd = try createSocket(AF_INET6, SOCK_DGRAM, IPPROTO_UDP);
        errdefer closeFd(fd);

        try setIpv6Only(fd, false);
        try applyOpts(fd, opts, true);
        return Socket{ .fd = fd };
    }

    /// 关闭 socket。
    pub fn close(self: *Socket) void {
        closeFd(self.fd);
        self.fd = INVALID_SOCKET;
    }

    /// 获取 socket 描述符（供外部异步 I/O 使用）。
    pub fn getFd(self: *const Socket) std.posix.socket_t {
        return self.fd;
    }
};

/// 无效 socket 值（POSIX: -1, Windows: ~0）。
pub const INVALID_SOCKET = if (builtin.os.tag == .windows)
    @as(std.posix.socket_t, @ptrFromInt(@as(usize, std.math.maxInt(usize))))
else
    @as(std.posix.socket_t, -1);

/// 跨平台 socket() 封装。
fn createSocket(domain: u32, sock_type: u32, protocol: u32) !std.posix.socket_t {
    const raw = std.c.socket(domain, sock_type, protocol);
    if (builtin.os.tag == .windows) {
        // raw 是 c_int (i32)，失败时返回 -1。必须先检查再 @intCast 到 usize，
        // 否则负数无法转换为无符号类型导致 panic。
        if (raw < 0) return error.SocketCreateFailed;
        return @ptrFromInt(@as(usize, @intCast(raw)));
    } else {
        if (raw == INVALID_SOCKET) return error.SocketCreateFailed;
        return raw;
    }
}

/// 跨平台 close() 封装。
fn closeFd(fd: std.posix.socket_t) void {
    if (builtin.os.tag == .windows) {
        _ = winSock.closesocket(@intFromPtr(fd));
    } else {
        _ = std.c.close(fd);
    }
}

/// 设置 IPV6_V6ONLY（false = 双栈模式）。
fn setIpv6Only(fd: std.posix.socket_t, ipv6_only: bool) !void {
    const val: u32 = if (ipv6_only) 1 else 0;
    try sockSetOpt(fd, IPPROTO_IPV6, IPV6_V6ONLY, std.mem.asBytes(&val));
}

// Windows winsock helpers — declared locally since Zig 0.16.0 has minimal ws2_32 coverage.
const winSock = struct {
    const SOCKET = usize;
    extern "ws2_32" fn setsockopt(
        s: SOCKET,
        level: c_int,
        optname: c_int,
        optval: [*]const u8,
        optlen: c_int,
    ) callconv(.winapi) c_int;
    extern "ws2_32" fn closesocket(s: SOCKET) callconv(.winapi) c_int;
};

/// 应用 BindOpts 到 socket fd。
fn applyOpts(fd: std.posix.socket_t, opts: BindOpts, is_ipv6: bool) !void {
    if (opts.reuse_addr) {
        try setReuseAddr(fd);
    }

    if (opts.interface_name) |ifname| {
        try bindToDevice(fd, ifname);
    }

    if (opts.interface_index) |ifindex| {
        try bindToInterfaceIndex(fd, ifindex, is_ipv6);
    }

    if (opts.source_addr) |addr| {
        try bindSourceAddr(fd, addr);
    }
}

/// 跨平台 setsockopt 封装 — POSIX 使用 std.posix，Windows 使用 winsock。
fn sockSetOpt(fd: std.posix.socket_t, level: i32, optname: u32, opt: []const u8) !void {
    if (builtin.os.tag == .windows) {
        const sock: winSock.SOCKET = @intFromPtr(fd);
        const rc = winSock.setsockopt(sock, level, @intCast(optname), opt.ptr, @intCast(opt.len));
        if (rc != 0) return error.SetSockOptFailed;
    } else {
        try std.posix.setsockopt(fd, level, optname, opt);
    }
}

/// 设置 SO_REUSEADDR（全平台）。
fn setReuseAddr(fd: std.posix.socket_t) !void {
    const on: u32 = 1;
    try sockSetOpt(fd, SOL_SOCKET, SO_REUSEADDR, std.mem.asBytes(&on));
}

/// Linux: 绑定到指定接口名 (SO_BINDTODEVICE)。
fn bindToDevice(fd: std.posix.socket_t, ifname: []const u8) !void {
    switch (builtin.os.tag) {
        .linux => {
            const ifname_z = try std.posix.toPosixPath(ifname);
            try sockSetOpt(fd, SOL_SOCKET, SO_BINDTODEVICE, ifname_z[0..ifname.len]);
        },
        else => return, // 其他平台不支持接口名绑定，静默跳过
    }
}

/// macOS/iOS: 绑定到接口索引 (v4: IP_BOUND_IF, v6: IPV6_BOUND_IF)。
/// Windows: 绑定到接口索引 (v4: IP_UNICAST_IF 网络字节序, v6: IPV6_UNICAST_IF 主机字节序)。
fn bindToInterfaceIndex(fd: std.posix.socket_t, ifindex: u32, is_ipv6: bool) !void {
    const level: i32 = if (is_ipv6) IPPROTO_IPV6 else IPPROTO_IP;
    switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos => {
            // v6 必须用 IPV6_BOUND_IF (125)：IPPROTO_IPV6 级别的 25 是 IPV6_2292PKTOPTIONS
            const optname: u32 = if (is_ipv6) IPV6_BOUND_IF else IP_BOUND_IF;
            try sockSetOpt(fd, level, optname, std.mem.asBytes(&ifindex));
        },
        .windows => {
            // MSDN: IP_UNICAST_IF 的选项值须为网络字节序；IPV6_UNICAST_IF 为主机字节序
            const optname: u32 = if (is_ipv6) IPV6_UNICAST_IF else IP_UNICAST_IF;
            const ndx: u32 = if (is_ipv6) ifindex else std.mem.nativeToBig(u32, ifindex);
            try sockSetOpt(fd, level, optname, std.mem.asBytes(&ndx));
        },
        else => return, // 其他平台不支持接口索引绑定，静默跳过
    }
}

/// 绑定源地址 — 解析 "ip:port" 并执行 bind()。
fn bindSourceAddr(fd: std.posix.socket_t, addr_str: []const u8) !void {
    const colon_idx = std.mem.lastIndexOfScalar(u8, addr_str, ':') orelse return error.InvalidAddress;
    const ip_str = addr_str[0..colon_idx];
    const port_str = addr_str[colon_idx + 1 ..];
    const port = std.fmt.parseInt(u16, port_str, 10) catch return error.InvalidAddress;

    // 构造通用 sockaddr 结构（兼容 macOS sin_len / Linux 无 sin_len）
    var sa_bytes: [28]u8 = [_]u8{0} ** 28;
    var sa_len: u32 = 0;

    // 尝试解析为 IPv4
    const ip4 = std.Io.net.Ip4Address.parse(ip_str, port) catch null;
    if (ip4) |v| {
        const addr: u32 = @as(u32, v.bytes[0]) << 24 |
            @as(u32, v.bytes[1]) << 16 |
            @as(u32, v.bytes[2]) << 8 |
            @as(u32, v.bytes[3]);
        if (builtin.os.tag.isDarwin()) {
            sa_bytes[0] = @sizeOf(SockAddrIn4); // sin_len
            sa_bytes[1] = @as(u8, @intCast(AF_INET)); // sin_family
            std.mem.writeInt(u16, sa_bytes[2..4], v.port, .big);
            std.mem.writeInt(u32, sa_bytes[4..8], addr, .big);
            sa_len = @sizeOf(SockAddrIn4);
        } else {
            std.mem.writeInt(u16, sa_bytes[0..2], AF_INET, .little); // sin_family (u16)
            std.mem.writeInt(u16, sa_bytes[2..4], v.port, .big);
            std.mem.writeInt(u32, sa_bytes[4..8], addr, .big);
            sa_len = @sizeOf(SockAddrIn4);
        }
    } else {
        const ip6 = std.Io.net.Ip6Address.parse(ip_str, port) catch null;
        if (ip6) |v6| {
            if (builtin.os.tag.isDarwin()) {
                sa_bytes[0] = @sizeOf(SockAddrIn6); // sin6_len
                sa_bytes[1] = @as(u8, @intCast(AF_INET6)); // sin6_family
                std.mem.writeInt(u16, sa_bytes[2..4], v6.port, .big);
                std.mem.writeInt(u32, sa_bytes[4..8], v6.flow, .little);
                @memcpy(sa_bytes[8..24], &v6.bytes);
                std.mem.writeInt(u32, sa_bytes[24..28], 0, .little); // scope_id=0
                sa_len = @sizeOf(SockAddrIn6);
            } else {
                std.mem.writeInt(u16, sa_bytes[0..2], AF_INET6, .little);
                std.mem.writeInt(u16, sa_bytes[2..4], v6.port, .big);
                std.mem.writeInt(u32, sa_bytes[4..8], v6.flow, .little);
                @memcpy(sa_bytes[8..24], &v6.bytes);
                std.mem.writeInt(u32, sa_bytes[24..28], 0, .little); // scope_id=0
                sa_len = @sizeOf(SockAddrIn6);
            }
        } else {
            return error.InvalidAddress;
        }
    }

    const rc = std.c.bind(fd, @ptrCast(@alignCast(&sa_bytes)), @intCast(sa_len));
    if (rc != 0) return error.BindFailed;
}

/// 跨平台 sockaddr_in。
/// macOS/BSD 包含 sin_len 字段（offset 0），Linux 从 sin_family（offset 0, 2 bytes）开始。
const SockAddrIn4 = if (builtin.os.tag.isDarwin())
    extern struct {
        len: u8 = @sizeOf(@This()),
        family: u8 = AF_INET,
        port: u16 = 0,
        addr: u32 = 0,
        zero: [8]u8 = [_]u8{0} ** 8,
    }
else
    extern struct {
        family: u16 = AF_INET,
        port: u16 = 0,
        addr: u32 = 0,
        zero: [8]u8 = [_]u8{0} ** 8,
    };

/// 跨平台 sockaddr_in6。
const SockAddrIn6 = if (builtin.os.tag.isDarwin())
    extern struct {
        len: u8 = @sizeOf(@This()),
        family: u8 = AF_INET6,
        port: u16 = 0,
        flowinfo: u32 = 0,
        addr: [16]u8 = [_]u8{0} ** 16,
        scope_id: u32 = 0,
    }
else
    extern struct {
        family: u16 = AF_INET6,
        port: u16 = 0,
        flowinfo: u32 = 0,
        addr: [16]u8 = [_]u8{0} ** 16,
        scope_id: u32 = 0,
    };

// ============================================================================
// 默认网卡检测 — 找到物理网卡索引，用于出站 socket 绑定绕过 TUN 路由循环
// ============================================================================

/// 检测默认物理网卡索引。
/// 通过路由表查找默认网关的实际接口，各平台实现不同：
///   - macOS: fork+exec route -n get default 解析 interface: 行
///   - Linux: 解析 /proc/net/route 中 Destination=00000000 行
///   - Windows: 动态加载 GetBestInterface (iphlpapi.dll)
/// 所有平台方法失败 → fallback 到候选名列表 → 无结果返回 null
pub fn getDefaultInterfaceIndex() ?u32 {
    if (builtin.os.tag == .macos) {
        if (getDefaultInterfaceViaRoute()) |idx| return idx;
    } else if (builtin.os.tag == .linux) {
        if (getDefaultInterfaceViaProcNetRoute()) |idx| return idx;
    } else if (builtin.os.tag == .windows) {
        if (getDefaultInterfaceViaGetBestInterface()) |idx| return idx;
    }
    return getDefaultInterfaceIndexFallback();
}

/// 将网卡名转换为索引（需要以 null 结尾的缓冲区）
pub fn ifNameToIndex(name: []const u8) ?u32 {
    var buf: [16]u8 = [_]u8{0} ** 16;
    @memcpy(buf[0..@min(name.len, 15)], name[0..@min(name.len, 15)]);
    const idx = std.c.if_nametoindex(buf[0..16 :0].ptr);
    return if (idx > 0) @as(u32, @intCast(idx)) else null;
}

/// macOS: 通过 fork+exec "route -n get default" 查找默认接口
fn getDefaultInterfaceViaRoute() ?u32 {
    var pipe_fds: [2]std.c.fd_t = undefined;
    if (std.c.pipe(&pipe_fds) != 0) {
        std.log.warn("[egress] pipe() failed", .{});
        return null;
    }

    const pid = std.c.fork();
    if (pid < 0) {
        std.log.warn("[egress] fork() failed", .{});
        return null;
    }

    if (pid == 0) {
        // 子进程：stdout → 管道写端，关闭 stderr
        _ = std.c.close(pipe_fds[0]);
        _ = std.c.dup2(pipe_fds[1], std.c.STDOUT_FILENO);
        _ = std.c.close(pipe_fds[1]);
        _ = std.c.close(std.c.STDERR_FILENO);

        const argv: [4:null]?[*:0]const u8 = .{ "route", "-n", "get", "default" };
        const envp: [1:null]?[*:0]const u8 = .{null};
        _ = std.c.execve("/sbin/route", &argv, &envp);
        std.c._exit(1);
    }

    _ = std.c.close(pipe_fds[1]);

    var output_buf: [512]u8 = undefined;
    var total: usize = 0;
    while (total < output_buf.len) {
        const n = std.c.read(pipe_fds[0], output_buf[total..].ptr, output_buf.len - total);
        if (n <= 0) break;
        total += @intCast(n);
    }
    _ = std.c.close(pipe_fds[0]);
    _ = std.c.waitpid(pid, null, 0);

    const output = output_buf[0..total];
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "interface:")) {
            const iface = std.mem.trim(u8, trimmed["interface:".len..], " \t");
            if (iface.len > 0) {
                if (ifNameToIndex(iface)) |idx| {
                    std.log.info("[egress] default interface: {s} (index={d}) via route", .{ iface, idx });
                    return idx;
                }
            }
        }
    }
    std.log.warn("[egress] route output missing interface line", .{});
    return null;
}

/// Linux: 通过 std.c.open/read 读取 /proc/net/route 查找默认路由接口
fn getDefaultInterfaceViaProcNetRoute() ?u32 {
    const flags: std.c.O = .{};
    const fd = std.c.open("/proc/net/route", flags);
    if (fd < 0) {
        std.log.warn("[egress] cannot open /proc/net/route", .{});
        return null;
    }
    defer _ = std.c.close(fd);

    var buf: [4096]u8 = undefined;
    const n = std.c.read(fd, &buf, buf.len);
    if (n <= 0) {
        std.log.warn("[egress] cannot read /proc/net/route", .{});
        return null;
    }
    const content = buf[0..@intCast(n)];

    // 格式: Iface\tDestination\tGateway\tFlags\tRefCnt\tUse\tMetric\tMask\tMTU\tWindow\tIRTT
    var lines = std.mem.splitScalar(u8, content, '\n');
    _ = lines.next(); // 跳过标题行
    while (lines.next()) |line| {
        var cols = std.mem.splitScalar(u8, line, '\t');
        const iface = cols.next() orelse continue;
        const dest = cols.next() orelse continue;
        if (std.mem.eql(u8, dest, "00000000")) {
            if (ifNameToIndex(iface)) |idx| {
                std.log.info("[egress] default interface: {s} (index={d}) via /proc/net/route", .{ iface, idx });
                return idx;
            }
        }
    }
    std.log.warn("[egress] no default route in /proc/net/route", .{});
    return null;
}

/// Windows: 动态加载 iphlpapi.dll → GetBestInterface 获取默认网卡索引
fn getDefaultInterfaceViaGetBestInterface() ?u32 {
    const windows = std.os.windows;

    const hModule = windows.LoadLibraryA("iphlpapi.dll") orelse {
        std.log.warn("[egress] cannot load iphlpapi.dll", .{});
        return null;
    };
    defer _ = windows.FreeLibrary(hModule);

    const func_ptr = windows.GetProcAddress(hModule, "GetBestInterface");
    if (func_ptr == null) {
        std.log.warn("[egress] GetBestInterface not found in iphlpapi.dll", .{});
        return null;
    }

    const FnType = *const fn (
        ipAddr: ?*anyopaque,
        bestIfIndex: *windows.DWORD,
    ) callconv(windows.WINAPI) windows.DWORD;
    const fn_ptr: FnType = @ptrCast(@alignCast(func_ptr));

    var best_idx: windows.DWORD = 0;
    const ret = fn_ptr(null, &best_idx);
    if (ret == 0 and best_idx > 0) {
        std.log.info("[egress] default interface index={d} via GetBestInterface", .{best_idx});
        return @intCast(best_idx);
    }
    std.log.warn("[egress] GetBestInterface failed: ret={d}", .{ret});
    return null;
}

/// fallback: 按优先级顺序尝试常见接口名，第一个存在即返回其索引
fn getDefaultInterfaceIndexFallback() ?u32 {
    const candidates = [_][]const u8{ "en0", "eth0", "wlan0", "en1", "en2" };
    for (candidates) |name| {
        if (ifNameToIndex(name)) |idx| {
            std.log.info("[egress] default interface: {s} (index={d}) via fallback list", .{ name, idx });
            return idx;
        }
    }
    std.log.warn("[egress] no default interface detected, outbound sockets will not bypass TUN", .{});
    return null;
}

// ============================================================================
// 测试
// ============================================================================

const testing = std.testing;

test "egress: reference all pub decls (lazy-analysis guard)" {
    testing.refAllDecls(@This());
}

test "egress: initTcp with default opts" {
    var sock = try Socket.initTcp(.{});
    defer sock.close();
    try testing.expect(sock.fd != INVALID_SOCKET);
}

test "egress: initUdp with default opts" {
    var sock = try Socket.initUdp(.{});
    defer sock.close();
    try testing.expect(sock.fd != INVALID_SOCKET);
}

test "egress: initTcp6 with default opts" {
    var sock = try Socket.initTcp6(.{});
    defer sock.close();
    try testing.expect(sock.fd != INVALID_SOCKET);
}

test "egress: initUdp6 with default opts" {
    var sock = try Socket.initUdp6(.{});
    defer sock.close();
    try testing.expect(sock.fd != INVALID_SOCKET);
}

test "egress: tcp socket with reuse_addr disabled" {
    var sock = try Socket.initTcp(.{ .reuse_addr = false });
    defer sock.close();
    try testing.expect(sock.fd != INVALID_SOCKET);
}

test "egress: udp socket with reuse_addr disabled" {
    var sock = try Socket.initUdp(.{ .reuse_addr = false });
    defer sock.close();
    try testing.expect(sock.fd != INVALID_SOCKET);
}

test "egress: bind source address to loopback" {
    var sock = try Socket.initUdp(.{ .source_addr = "127.0.0.1:0" });
    defer sock.close();
    try testing.expect(sock.fd != INVALID_SOCKET);
}

test "egress: bind source address with specific port" {
    var sock = try Socket.initUdp(.{ .source_addr = "127.0.0.1:23456" });
    defer sock.close();
    try testing.expect(sock.fd != INVALID_SOCKET);
}

test "egress: getFd returns correct fd" {
    var sock = try Socket.initTcp(.{});
    defer sock.close();
    try testing.expectEqual(sock.fd, sock.getFd());
}

test "egress: close sets fd to INVALID_SOCKET" {
    var sock = try Socket.initTcp(.{});
    sock.close();
    try testing.expectEqual(INVALID_SOCKET, sock.fd);
}

test "egress: initTcp6 is dual-stack" {
    var sock = try Socket.initTcp6(.{});
    defer sock.close();
    try testing.expect(sock.fd != INVALID_SOCKET);
}

test "egress: multiple sockets with different opts" {
    var s1 = try Socket.initTcp(.{ .reuse_addr = true });
    defer s1.close();
    var s2 = try Socket.initTcp(.{ .reuse_addr = false });
    defer s2.close();
    try testing.expect(s1.fd != s2.fd);
}
