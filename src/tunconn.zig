//! 网络连接 vtable 接口 — TUN/代理组件间的共享契约
//!
//! 纯 vtable 接口（ptr + *const VTable），零平台/零 TUN 内部逻辑。
//! 作为以下组件间的共享抽象层：
//!   - TUN 协议栈（zigtun 的 system_stack、lwip_stack）
//!   - 代理处理器（zigproxy 的 TunHandler、zigbox 的 ZigboxHandler）
//!   - 出站中继（direct、代理协议）
//!
//! 依赖：zigfoundation.net (SocksAddr)、std.posix.socket_t

const std = @import("std");
const net = @import("net.zig");

// ============================================================================
// SocksAddr — re-exported from net.zig
// ============================================================================

pub const SocksAddr = net.SocksAddr;

// ============================================================================
// NetworkType
// ============================================================================

/// Network type tag for Handler.prepareConnection().
pub const NetworkType = enum(u8) {
    tcp = 0,
    udp = 1,
    icmp = 2,
};

// ============================================================================
// Helper for DirectRouteContext.none sentinel
// ============================================================================

fn directRouteCtxNoneWrite(_: *anyopaque, _: []const u8) anyerror!void {}

// ============================================================================
// DirectRouteContext (vtable)
// ============================================================================

/// Context for direct (bypass) route packet writing.
/// When a handler returns a DirectRouteDestination, the stack bypasses
/// normal processing and sends packets through this context.
pub const DirectRouteContext = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        writePacketFn: *const fn (ptr: *anyopaque, packet: []const u8) anyerror!void,
    };

    /// Write a raw IP packet bypassing the protocol stack.
    pub fn writePacket(self: DirectRouteContext, packet: []const u8) anyerror!void {
        return self.vtable.writePacketFn(self.ptr, packet);
    }

    /// Safe no-op sentinel. Use when direct routing is not needed.
    /// writePacket() on this sentinel is a no-op — never undefined behavior.
    pub const none: DirectRouteContext = .{
        .ptr = @ptrFromInt(1),
        .vtable = &.{ .writePacketFn = directRouteCtxNoneWrite },
    };
};

// ============================================================================
// DirectRouteDestination (vtable)
// ============================================================================

/// Destination for a direct-routed connection.
/// Returned by Handler.prepareConnection() when the connection should
/// be bypassed (not processed by the proxy).
pub const DirectRouteDestination = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        writePacketFn: *const fn (ptr: *anyopaque, packet: []const u8) anyerror!void,
        closeFn: *const fn (ptr: *anyopaque) void,
        isClosedFn: *const fn (ptr: *anyopaque) bool,
    };

    pub fn writePacket(self: DirectRouteDestination, packet: []const u8) anyerror!void {
        return self.vtable.writePacketFn(self.ptr, packet);
    }

    pub fn close(self: DirectRouteDestination) !void {
        return self.vtable.closeFn(self.ptr);
    }

    pub fn isClosed(self: DirectRouteDestination) bool {
        return self.vtable.isClosedFn(self.ptr);
    }
};

// ============================================================================
// TcpConn (vtable)
// ============================================================================

/// Vtable for TCP connections passed to Handler.newConnection().
/// Corresponds to Go `net.Conn` interface (subset).
pub const TcpConn = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        readFn: *const fn (ptr: *anyopaque, buf: []u8) anyerror!usize,
        writeFn: *const fn (ptr: *anyopaque, data: []const u8) anyerror!usize,
        closeFn: *const fn (ptr: *anyopaque) void,
        localAddrFn: *const fn (ptr: *anyopaque) SocksAddr,
        remoteAddrFn: *const fn (ptr: *anyopaque) SocksAddr,
        /// 返回底层 fd (System Stack) 或 null (lwIP)。
        /// 用于 libxev 异步 I/O: 有 fd 可用 xev.TCP.initFd, 无 fd 需 Timer 轮询。
        fdFn: ?*const fn (ptr: *anyopaque) ?std.posix.socket_t = null,
    };

    pub fn read(self: TcpConn, buf: []u8) anyerror!usize {
        return self.vtable.readFn(self.ptr, buf);
    }

    pub fn write(self: TcpConn, data: []const u8) anyerror!usize {
        return self.vtable.writeFn(self.ptr, data);
    }

    pub fn close(self: TcpConn) void {
        self.vtable.closeFn(self.ptr);
    }

    pub fn localAddr(self: TcpConn) SocksAddr {
        return self.vtable.localAddrFn(self.ptr);
    }

    pub fn remoteAddr(self: TcpConn) SocksAddr {
        return self.vtable.remoteAddrFn(self.ptr);
    }

    /// 返回底层 fd，若无则返回 null (lwIP 连接无 fd)。
    pub fn fd(self: TcpConn) ?std.posix.socket_t {
        if (self.vtable.fdFn) |f| return f(self.ptr);
        return null;
    }
};

// ============================================================================
// UdpConn (vtable)
// ============================================================================

/// Vtable for UDP packet connections passed to Handler.newPacketConnection().
/// Corresponds to Go `N.PacketConn` interface (subset).
pub const UdpConn = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        readFromFn: *const fn (ptr: *anyopaque, buf: []u8) anyerror!ReadFromResult,
        writeToFn: *const fn (ptr: *anyopaque, data: []const u8, addr: SocksAddr) anyerror!usize,
        closeFn: *const fn (ptr: *anyopaque) void,
        localAddrFn: *const fn (ptr: *anyopaque) SocksAddr,
        /// 返回底层 fd (System Stack) 或 null (lwIP)。
        fdFn: ?*const fn (ptr: *anyopaque) ?std.posix.socket_t = null,
    };

    pub const ReadFromResult = struct {
        n: usize,
        addr: SocksAddr,
    };

    pub fn readFrom(self: UdpConn, buf: []u8) anyerror!ReadFromResult {
        return self.vtable.readFromFn(self.ptr, buf);
    }

    pub fn writeTo(self: UdpConn, data: []const u8, addr: SocksAddr) anyerror!usize {
        return self.vtable.writeToFn(self.ptr, data, addr);
    }

    pub fn close(self: UdpConn) void {
        self.vtable.closeFn(self.ptr);
    }

    pub fn localAddr(self: UdpConn) SocksAddr {
        return self.vtable.localAddrFn(self.ptr);
    }

    /// 返回底层 fd，若无则返回 null。
    pub fn fd(self: UdpConn) ?std.posix.socket_t {
        if (self.vtable.fdFn) |f| return f(self.ptr);
        return null;
    }
};

// ============================================================================
// Handler (vtable)
// ============================================================================

/// Handler receives new connections from the TUN protocol stack.
/// Implemented by the proxy core (e.g., zproxy handler).
///
/// Corresponds to Go `Handler` interface:
///   PrepareConnection + TCPConnectionHandlerEx + UDPConnectionHandlerEx
pub const Handler = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Called before establishing a full connection. The handler can:
        /// - Return a DirectRouteDestination to bypass the proxy (direct route)
        /// - Return an error (ErrDrop/ErrReset/ErrBypass) to reject
        /// - Return a zero DirectRouteDestination for normal proxy processing
        prepareConnectionFn: *const fn (
            ptr: *anyopaque,
            network: NetworkType,
            source: SocksAddr,
            destination: SocksAddr,
            route_ctx: DirectRouteContext,
            timeout_ms: u64,
        ) anyerror!DirectRouteDestination,

        /// Called when a new TCP connection is established (post handshake).
        newConnectionFn: *const fn (
            ptr: *anyopaque,
            conn: TcpConn,
            source: SocksAddr,
            destination: SocksAddr,
        ) anyerror!void,

        /// Called when a new UDP "connection" is received.
        newPacketConnectionFn: *const fn (
            ptr: *anyopaque,
            conn: UdpConn,
            source: SocksAddr,
            destination: SocksAddr,
        ) anyerror!void,

        /// Android VPN protect socket — marks a socket fd so it bypasses the VPN.
        /// Prevents routing loops: traffic from protected sockets goes directly
        /// to the physical network instead of being re-routed through the TUN device.
        /// Non-Android platforms provide a no-op implementation.
        protectFn: *const fn (ptr: *anyopaque, fd: std.posix.socket_t) anyerror!void,
    };

    pub fn prepareConnection(
        self: Handler,
        network: NetworkType,
        source: SocksAddr,
        destination: SocksAddr,
        route_ctx: DirectRouteContext,
        timeout_ms: u64,
    ) anyerror!DirectRouteDestination {
        return self.vtable.prepareConnectionFn(self.ptr, network, source, destination, route_ctx, timeout_ms);
    }

    pub fn newConnection(
        self: Handler,
        conn: TcpConn,
        source: SocksAddr,
        destination: SocksAddr,
    ) anyerror!void {
        return self.vtable.newConnectionFn(self.ptr, conn, source, destination);
    }

    pub fn newPacketConnection(
        self: Handler,
        conn: UdpConn,
        source: SocksAddr,
        destination: SocksAddr,
    ) anyerror!void {
        return self.vtable.newPacketConnectionFn(self.ptr, conn, source, destination);
    }

    /// Android VPN protect socket — marks `fd` so its traffic bypasses the VPN.
    /// Non-Android handlers use a no-op stub.
    pub fn protect(self: Handler, fd: std.posix.socket_t) anyerror!void {
        return self.vtable.protectFn(self.ptr, fd);
    }
};

// =============================================================================
// 测试 — vtable 接口验证
// =============================================================================

const testing = std.testing;

// ---- NetworkType ----

test "tunconn: NetworkType enum values" {
    try testing.expectEqual(@as(u8, 0), @intFromEnum(NetworkType.tcp));
    try testing.expectEqual(@as(u8, 1), @intFromEnum(NetworkType.udp));
    try testing.expectEqual(@as(u8, 2), @intFromEnum(NetworkType.icmp));
    try testing.expectEqual(NetworkType.tcp, @as(NetworkType, @enumFromInt(0)));
    try testing.expectEqual(NetworkType.udp, @as(NetworkType, @enumFromInt(1)));
    try testing.expectEqual(NetworkType.icmp, @as(NetworkType, @enumFromInt(2)));
}

// ---- DirectRouteContext mock ----

const MockDirectRouteCtx = struct {
    written_buf: [64]u8 = [_]u8{0} ** 64,
    written_len: usize = 0,

    fn writePacketFn(ptr: *anyopaque, packet: []const u8) anyerror!void {
        const self: *MockDirectRouteCtx = @ptrCast(@alignCast(ptr));
        @memcpy(self.written_buf[self.written_len..][0..packet.len], packet);
        self.written_len += packet.len;
    }

    fn toContext(self: *MockDirectRouteCtx) DirectRouteContext {
        return .{
            .ptr = self,
            .vtable = &.{ .writePacketFn = writePacketFn },
        };
    }
};

test "tunconn: DirectRouteContext vtable dispatch" {
    var mock = MockDirectRouteCtx{};
    const ctx = mock.toContext();
    try ctx.writePacket(&.{ 1, 2, 3 });
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, mock.written_buf[0..mock.written_len]);
}

test "tunconn: DirectRouteContext.none is no-op" {
    try DirectRouteContext.none.writePacket(&.{ 1, 2, 3 });
    // 无 panic / 无副作用 = 通过
}

// ---- DirectRouteDestination mock ----

const MockDirectRouteDest = struct {
    written: ?[]const u8 = null,
    closed: bool = false,

    fn writePacketFn(ptr: *anyopaque, packet: []const u8) anyerror!void {
        const self: *MockDirectRouteDest = @ptrCast(@alignCast(ptr));
        self.written = packet;
    }

    fn closeFn(ptr: *anyopaque) void {
        const self: *MockDirectRouteDest = @ptrCast(@alignCast(ptr));
        self.closed = true;
    }

    fn isClosedFn(ptr: *anyopaque) bool {
        const self: *MockDirectRouteDest = @ptrCast(@alignCast(ptr));
        return self.closed;
    }

    fn toDest(self: *MockDirectRouteDest) DirectRouteDestination {
        return .{
            .ptr = self,
            .vtable = &.{
                .writePacketFn = writePacketFn,
                .closeFn = closeFn,
                .isClosedFn = isClosedFn,
            },
        };
    }
};

test "tunconn: DirectRouteDestination writePacket" {
    var mock = MockDirectRouteDest{};
    const dest = mock.toDest();
    try dest.writePacket(&.{ 0xde, 0xad });
    try testing.expectEqualSlices(u8, &.{ 0xde, 0xad }, mock.written.?);
}

test "tunconn: DirectRouteDestination close + isClosed" {
    var mock = MockDirectRouteDest{};
    const dest = mock.toDest();
    try testing.expect(!dest.isClosed());
    try dest.close();
    try testing.expect(dest.isClosed());
}

// ---- TcpConn mock ----

const MockTcpConn = struct {
    read_buf: []u8 = &.{},
    written: ?[]const u8 = null,
    closed: bool = false,
    fd_val: ?std.posix.socket_t = null,

    fn readFn(ptr: *anyopaque, buf: []u8) anyerror!usize {
        const self: *MockTcpConn = @ptrCast(@alignCast(ptr));
        const n = @min(self.read_buf.len, buf.len);
        @memcpy(buf[0..n], self.read_buf[0..n]);
        return n;
    }

    fn writeFn(ptr: *anyopaque, data: []const u8) anyerror!usize {
        const self: *MockTcpConn = @ptrCast(@alignCast(ptr));
        self.written = data;
        return data.len;
    }

    fn closeFn(ptr: *anyopaque) void {
        const self: *MockTcpConn = @ptrCast(@alignCast(ptr));
        self.closed = true;
    }

    fn localAddrFn(ptr: *anyopaque) SocksAddr {
        _ = ptr;
        return SocksAddr{ .addr = .{ .v4 = .{ 127, 0, 0, 1 } }, .port = 12345 };
    }

    fn remoteAddrFn(ptr: *anyopaque) SocksAddr {
        _ = ptr;
        return SocksAddr{ .addr = .{ .v4 = .{ 10, 0, 0, 1 } }, .port = 443 };
    }

    fn fdFn(ptr: *anyopaque) ?std.posix.socket_t {
        const self: *MockTcpConn = @ptrCast(@alignCast(ptr));
        return self.fd_val;
    }

    fn toConn(self: *MockTcpConn) TcpConn {
        return .{
            .ptr = self,
            .vtable = &.{
                .readFn = readFn,
                .writeFn = writeFn,
                .closeFn = closeFn,
                .localAddrFn = localAddrFn,
                .remoteAddrFn = remoteAddrFn,
                .fdFn = fdFn,
            },
        };
    }
};

test "tunconn: TcpConn read/write" {
    var read_data = [_]u8{ 0xca, 0xfe };
    var mock = MockTcpConn{ .read_buf = &read_data };
    const conn = mock.toConn();

    var buf: [4]u8 = undefined;
    const n = try conn.read(&buf);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(@as(u8, 0xca), buf[0]);
    try testing.expectEqual(@as(u8, 0xfe), buf[1]);

    const wn = try conn.write(&.{ 0xbe, 0xef });
    try testing.expectEqual(@as(usize, 2), wn);
    try testing.expectEqualSlices(u8, &.{ 0xbe, 0xef }, mock.written.?);
}

test "tunconn: TcpConn close" {
    var mock = MockTcpConn{};
    const conn = mock.toConn();
    try testing.expect(!mock.closed);
    conn.close();
    try testing.expect(mock.closed);
}

test "tunconn: TcpConn localAddr / remoteAddr" {
    var mock = MockTcpConn{};
    const conn = mock.toConn();

    const local = conn.localAddr();
    try testing.expectEqual(@as(u16, 12345), local.port);
    try testing.expectEqual(@as(u8, 127), local.addr.v4[0]);

    const remote = conn.remoteAddr();
    try testing.expectEqual(@as(u16, 443), remote.port);
    try testing.expectEqual(@as(u8, 10), remote.addr.v4[0]);
}

test "tunconn: TcpConn fd present" {
    var mock = MockTcpConn{ .fd_val = 42 };
    const conn = mock.toConn();
    try testing.expectEqual(@as(?std.posix.socket_t, 42), conn.fd());
}

test "tunconn: TcpConn fd null" {
    var mock = MockTcpConn{ .fd_val = null };
    const conn = mock.toConn();
    try testing.expectEqual(@as(?std.posix.socket_t, null), conn.fd());
}

test "tunconn: TcpConn fd 无 fdFn" {
    const vtable_no_fd = TcpConn.VTable{
        .readFn = MockTcpConn.readFn,
        .writeFn = MockTcpConn.writeFn,
        .closeFn = MockTcpConn.closeFn,
        .localAddrFn = MockTcpConn.localAddrFn,
        .remoteAddrFn = MockTcpConn.remoteAddrFn,
        .fdFn = null,
    };
    var mock = MockTcpConn{};
    const conn = TcpConn{ .ptr = &mock, .vtable = &vtable_no_fd };
    try testing.expectEqual(@as(?std.posix.socket_t, null), conn.fd());
}

// ---- UdpConn mock ----

const MockUdpConn = struct {
    read_result: ?UdpConn.ReadFromResult = null,
    written_data: ?[]const u8 = null,
    written_addr: ?SocksAddr = null,
    closed: bool = false,
    fd_val: ?std.posix.socket_t = null,

    fn readFromFn(ptr: *anyopaque, _: []u8) anyerror!UdpConn.ReadFromResult {
        const self: *MockUdpConn = @ptrCast(@alignCast(ptr));
        return self.read_result.?;
    }

    fn writeToFn(ptr: *anyopaque, data: []const u8, addr: SocksAddr) anyerror!usize {
        const self: *MockUdpConn = @ptrCast(@alignCast(ptr));
        self.written_data = data;
        self.written_addr = addr;
        return data.len;
    }

    fn closeFn(ptr: *anyopaque) void {
        const self: *MockUdpConn = @ptrCast(@alignCast(ptr));
        self.closed = true;
    }

    fn localAddrFn(ptr: *anyopaque) SocksAddr {
        _ = ptr;
        return SocksAddr{ .addr = .{ .v4 = .{ 0, 0, 0, 0 } }, .port = 5353 };
    }

    fn fdFn(ptr: *anyopaque) ?std.posix.socket_t {
        const self: *MockUdpConn = @ptrCast(@alignCast(ptr));
        return self.fd_val;
    }

    fn toConn(self: *MockUdpConn) UdpConn {
        return .{
            .ptr = self,
            .vtable = &.{
                .readFromFn = readFromFn,
                .writeToFn = writeToFn,
                .closeFn = closeFn,
                .localAddrFn = localAddrFn,
                .fdFn = fdFn,
            },
        };
    }
};

test "tunconn: UdpConn readFrom" {
    const expected = UdpConn.ReadFromResult{
        .n = 10,
        .addr = SocksAddr{ .addr = .{ .v4 = .{ 8, 8, 8, 8 } }, .port = 53 },
    };
    var mock = MockUdpConn{ .read_result = expected };
    const conn = mock.toConn();

    var buf: [64]u8 = undefined;
    const result = try conn.readFrom(&buf);
    try testing.expectEqual(expected.n, result.n);
    try testing.expectEqual(expected.addr.port, result.addr.port);
    try testing.expectEqual(expected.addr.addr.v4, result.addr.addr.v4);
}

test "tunconn: UdpConn writeTo" {
    var mock = MockUdpConn{};
    const conn = mock.toConn();
    const addr = SocksAddr{ .addr = .{ .v6 = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 } }, .port = 9999 };

    const n = try conn.writeTo(&.{ 0xde, 0xad, 0xbe, 0xef }, addr);
    try testing.expectEqual(@as(usize, 4), n);
    try testing.expectEqualSlices(u8, &.{ 0xde, 0xad, 0xbe, 0xef }, mock.written_data.?);
    try testing.expectEqual(addr.port, mock.written_addr.?.port);
}

test "tunconn: UdpConn close" {
    var mock = MockUdpConn{};
    const conn = mock.toConn();
    try testing.expect(!mock.closed);
    conn.close();
    try testing.expect(mock.closed);
}

test "tunconn: UdpConn localAddr" {
    var mock = MockUdpConn{};
    const conn = mock.toConn();
    const addr = conn.localAddr();
    try testing.expectEqual(@as(u16, 5353), addr.port);
}

test "tunconn: UdpConn fd present" {
    var mock = MockUdpConn{ .fd_val = 99 };
    const conn = mock.toConn();
    try testing.expectEqual(@as(?std.posix.socket_t, 99), conn.fd());
}

test "tunconn: UdpConn fd null" {
    var mock = MockUdpConn{ .fd_val = null };
    const conn = mock.toConn();
    try testing.expectEqual(@as(?std.posix.socket_t, null), conn.fd());
}

test "tunconn: UdpConn fd 无 fdFn" {
    const vtable_no_fd = UdpConn.VTable{
        .readFromFn = MockUdpConn.readFromFn,
        .writeToFn = MockUdpConn.writeToFn,
        .closeFn = MockUdpConn.closeFn,
        .localAddrFn = MockUdpConn.localAddrFn,
        .fdFn = null,
    };
    var mock = MockUdpConn{ .read_result = UdpConn.ReadFromResult{ .n = 0, .addr = .{ .addr = .{ .v4 = .{ 0, 0, 0, 0 } }, .port = 0 } } };
    const conn = UdpConn{ .ptr = &mock, .vtable = &vtable_no_fd };
    try testing.expectEqual(@as(?std.posix.socket_t, null), conn.fd());
}

// ---- Handler mock ----

const MockHandler = struct {
    prepared: bool = false,
    new_conn_called: bool = false,
    new_pkt_called: bool = false,
    protected_fd: ?std.posix.socket_t = null,

    fn prepareConnectionFn(
        ptr: *anyopaque,
        _: NetworkType,
        _: SocksAddr,
        _: SocksAddr,
        _: DirectRouteContext,
        _: u64,
    ) anyerror!DirectRouteDestination {
        const self: *MockHandler = @ptrCast(@alignCast(ptr));
        self.prepared = true;
        return DirectRouteDestination{ .ptr = undefined, .vtable = undefined };
    }

    fn newConnectionFn(
        ptr: *anyopaque,
        _: TcpConn,
        _: SocksAddr,
        _: SocksAddr,
    ) anyerror!void {
        const self: *MockHandler = @ptrCast(@alignCast(ptr));
        self.new_conn_called = true;
    }

    fn newPacketConnectionFn(
        ptr: *anyopaque,
        _: UdpConn,
        _: SocksAddr,
        _: SocksAddr,
    ) anyerror!void {
        const self: *MockHandler = @ptrCast(@alignCast(ptr));
        self.new_pkt_called = true;
    }

    fn protectFn(ptr: *anyopaque, fd: std.posix.socket_t) anyerror!void {
        const self: *MockHandler = @ptrCast(@alignCast(ptr));
        self.protected_fd = fd;
    }

    fn toHandler(self: *MockHandler) Handler {
        return .{
            .ptr = self,
            .vtable = &.{
                .prepareConnectionFn = prepareConnectionFn,
                .newConnectionFn = newConnectionFn,
                .newPacketConnectionFn = newPacketConnectionFn,
                .protectFn = protectFn,
            },
        };
    }
};

test "tunconn: Handler prepareConnection" {
    var mock = MockHandler{};
    const h = mock.toHandler();
    _ = try h.prepareConnection(
        .tcp,
        SocksAddr{ .addr = .{ .v4 = .{ 192, 168, 1, 1 } }, .port = 8080 },
        SocksAddr{ .addr = .{ .v4 = .{ 10, 0, 0, 1 } }, .port = 80 },
        DirectRouteContext.none,
        5000,
    );
    try testing.expect(mock.prepared);
}

test "tunconn: Handler newConnection" {
    var mock = MockHandler{};
    const h = mock.toHandler();

    var tcp_mock = MockTcpConn{};
    const tcp_conn = tcp_mock.toConn();

    try h.newConnection(
        tcp_conn,
        SocksAddr{ .addr = .{ .v4 = .{ 1, 2, 3, 4 } }, .port = 1234 },
        SocksAddr{ .addr = .{ .v4 = .{ 5, 6, 7, 8 } }, .port = 80 },
    );
    try testing.expect(mock.new_conn_called);
}

test "tunconn: Handler newPacketConnection" {
    var mock = MockHandler{};
    const h = mock.toHandler();

    var udp_mock = MockUdpConn{ .read_result = UdpConn.ReadFromResult{ .n = 0, .addr = .{ .addr = .{ .v4 = .{ 0, 0, 0, 0 } }, .port = 0 } } };
    const udp_conn = udp_mock.toConn();

    try h.newPacketConnection(
        udp_conn,
        SocksAddr{ .addr = .{ .v4 = .{ 4, 3, 2, 1 } }, .port = 5678 },
        SocksAddr{ .addr = .{ .v4 = .{ 8, 8, 8, 8 } }, .port = 53 },
    );
    try testing.expect(mock.new_pkt_called);
}

test "tunconn: Handler protect" {
    var mock = MockHandler{};
    const h = mock.toHandler();
    try h.protect(123);
    try testing.expectEqual(@as(?std.posix.socket_t, 123), mock.protected_fd);
}
