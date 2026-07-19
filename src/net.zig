//! 网络工具 — IP 格式化/解析、CIDR 匹配、域名验证、host:port 解析
//!
//! 提取自 zproxy/src/utils.zig + zproxy/src/core/ip_cidr6.zig
//! + zproxy/src/proxy/rules/ip_cidr.zig，适配 Zig 0.16.0，去除 zio 依赖。
//!
//! 不含 checksum 函数（按项目决策排除）。

const std = @import("std");
const endian = @import("endian.zig");

// ============================================================
// 类型别名
// ============================================================

/// IPv4 地址 — 4 字节网络字节序（大端）
pub const Ip4Addr = [4]u8;

/// IPv6 地址 — 16 字节网络字节序（大端）
pub const Ip6Addr = [16]u8;

// ============================================================
// 常量
// ============================================================

/// IPv4 格式化最大长度 "255.255.255.255" = 15 + null
pub const max_addr_buf = 64;

/// IPv6 格式化最大长度 "xxxx:xxxx:xxxx:xxxx:xxxx:xxxx:xxxx:xxxx" ≈ 39 字符
const max_ipv6_buf = 80;

/// "host:port" 字符串最大长度
pub const max_host_port_len = 128;

// ============================================================
// IP 格式化
// ============================================================

/// 格式化 IPv4 字节为 "a.b.c.d" 字符串。
/// bytes 必须至少 4 字节，否则返回占位符。
pub fn formatIpv4(bytes: []const u8, buf: *[max_addr_buf]u8) []const u8 {
    if (bytes.len < 4) return "invalid-ipv4";
    return std.fmt.bufPrint(buf, "{}.{}.{}.{}", .{
        bytes[0], bytes[1], bytes[2], bytes[3],
    }) catch return "ipv4-overflow";
}

/// 格式化 IPv6 字节为扩展十六进制 "x:x:x:x:x:x:x:x" 字符串。
/// bytes 必须至少 16 字节，否则返回占位符。
pub fn formatIpv6(bytes: []const u8, buf: *[max_ipv6_buf]u8) []const u8 {
    if (bytes.len < 16) return "invalid-ipv6";
    const result = std.fmt.bufPrint(buf, "{x}:{x}:{x}:{x}:{x}:{x}:{x}:{x}", .{
        endian.readU16Big(bytes[0..2]),
        endian.readU16Big(bytes[2..4]),
        endian.readU16Big(bytes[4..6]),
        endian.readU16Big(bytes[6..8]),
        endian.readU16Big(bytes[8..10]),
        endian.readU16Big(bytes[10..12]),
        endian.readU16Big(bytes[12..14]),
        endian.readU16Big(bytes[14..16]),
    }) catch return "ipv6-overflow";
    return buf[0..result.len];
}

// ============================================================
// IP 字节 ↔ 整数转换
// ============================================================

/// IPv4 字节（网络序）→ u32（主机序，byte[0] 在 MSB）。
/// 例: [192, 168, 1, 1] → 0xC0A80101
pub fn ip4ToInt(bytes: []const u8) u32 {
    return @as(u32, bytes[0]) << 24 |
        @as(u32, bytes[1]) << 16 |
        @as(u32, bytes[2]) << 8 |
        @as(u32, bytes[3]);
}

/// u32（主机序）→ IPv4 字节（网络序）。
/// 例: 0xC0A80101 → [192, 168, 1, 1]
pub fn intToIp4(val: u32) Ip4Addr {
    return .{
        @as(u8, @intCast((val >> 24) & 0xff)),
        @as(u8, @intCast((val >> 16) & 0xff)),
        @as(u8, @intCast((val >> 8) & 0xff)),
        @as(u8, @intCast(val & 0xff)),
    };
}

/// IPv6 字节（网络序）→ u128（主机序，byte[0] 在 MSB，与 ip4ToInt 语义一致）。
/// 例: ::1 → 1，fe80::1 → 0xfe80_0000_..._0001
pub fn ip6ToInt(bytes: []const u8) u128 {
    return endian.readIntBig(u128, bytes);
}

/// u128（主机序）→ IPv6 字节（网络序，MSB 在 byte[0]）。
pub fn intToIp6(val: u128) Ip6Addr {
    var out: Ip6Addr = undefined;
    endian.writeIntBig(u128, &out, val);
    return out;
}

// ============================================================
// IP 字符串解析
// ============================================================

/// 解析 IPv4 字符串 "a.b.c.d" 为 [4]u8 字节。
pub fn parseIpv4(str: []const u8) !Ip4Addr {
    const parsed = try std.Io.net.Ip4Address.parse(str, 0);
    return parsed.bytes;
}

/// 解析 IPv6 字符串为 [16]u8 字节。
/// 支持 RFC 5952 压缩格式（::）和扩展格式。
pub fn parseIpv6(str: []const u8) !Ip6Addr {
    const parsed = try std.Io.net.Ip6Address.parse(str, 0);
    return parsed.bytes;
}

// ============================================================
// 地址类型判断
// ============================================================

/// 地址字节是否表示 IPv4 字面量（恰好 4 字节）。
pub fn isIpv4(addr: []const u8) bool {
    return addr.len == 4;
}

/// 地址字节是否表示 IPv6 字面量（恰好 16 字节）。
pub fn isIpv6(addr: []const u8) bool {
    return addr.len == 16;
}

/// 地址字节是否表示域名（非 IP 字面量）。
pub fn isDomain(addr: []const u8) bool {
    return addr.len != 4 and addr.len != 16;
}

// ============================================================
// 验证函数
// ============================================================

/// 端口号是否在有效范围（1-65535）。
pub fn isValidPort(port: u16) bool {
    return port >= 1 and port <= 65535;
}

/// 验证 IPv4 字符串格式 "a.b.c.d"。
/// 每段 0-255，恰好 4 段，由点分隔。
pub fn isValidIpv4String(str: []const u8) bool {
    // 长度范围: "0.0.0.0"(7) 至 "255.255.255.255"(15)
    if (str.len < 7 or str.len > 15) return false;

    var seg_idx: usize = 0;
    var seg_start: usize = 0;
    var dot_count: usize = 0;

    for (str, 0..) |c, i| {
        if (c == '.') {
            dot_count += 1;
            if (dot_count > 3) return false;
            if (i == 0 or i == str.len - 1) return false;
            const seg_len = i - seg_start;
            if (seg_len == 0 or seg_len > 3) return false;
            const seg = std.fmt.parseInt(u8, str[seg_start..i], 10) catch return false;
            if (seg > 255) return false;
            seg_idx += 1;
            seg_start = i + 1;
        } else if (c < '0' or c > '9') {
            return false;
        }
    }

    // 最后一段
    if (seg_start >= str.len) return false;
    const seg = std.fmt.parseInt(u8, str[seg_start..], 10) catch return false;
    _ = seg;

    return dot_count == 3 and seg_idx == 3;
}

/// 验证 IPv6 字符串格式。
/// 支持 RFC 4291 扩展格式（8 组）和压缩格式（::，至少压缩一个零组）。
/// 可选方括号（[addr] 或 [addr]:port）。不支持 IPv4 嵌入形式（::ffff:1.2.3.4）。
pub fn isValidIpv6String(str: []const u8) bool {
    const inner: []const u8 = if (str.len >= 2 and str[0] == '[')
        if (std.mem.indexOfScalar(u8, str, ']')) |close_idx|
            str[1..close_idx]
        else
            return false
    else
        str;

    if (inner.len < 2 or inner.len > 45) return false;

    // 前导单冒号非法（"::" 开头除外）
    if (inner[0] == ':' and inner[1] != ':') return false;

    var groups: usize = 0; // 显式 hex 组数
    var double_colon_seen: bool = false;
    var prev_was_colon: bool = false;
    var chars_since_colon: usize = 0;

    for (inner, 0..) |c, i| {
        if (c == ':') {
            if (prev_was_colon) {
                if (double_colon_seen) return false; // 第二个 "::" 或 ":::"
                double_colon_seen = true;
            }
            prev_was_colon = true;
            chars_since_colon = 0;
        } else if ((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F')) {
            if (i == 0 or prev_was_colon) groups += 1; // 新组开始
            prev_was_colon = false;
            chars_since_colon += 1;
            if (chars_since_colon > 4) return false;
        } else {
            return false;
        }
    }

    // 尾部单冒号非法（"::" 结尾除外）
    if (prev_was_colon and !std.mem.endsWith(u8, inner, "::")) return false;

    if (double_colon_seen) {
        // "::" 至少压缩一个零组 → 显式组最多 7 个
        // （按冒号计数会误拒 "1:2:3:4:5:6:7::" 等合法 8 冒号形式）
        return groups <= 7;
    }
    return groups == 8;
}

/// 验证域名（RFC 1123）。
/// - 总长 1-255 字符
/// - 每段标签 1-63 字符，字母数字 + 连字符
/// - 标签不能以连字符开头或结尾
/// - 不能有连续点号、首尾不能是点号
pub fn isValidDomain(domain: []const u8) bool {
    if (domain.len < 1 or domain.len > 255) return false;
    if (domain[0] == '.' or domain[domain.len - 1] == '.') return false;

    var label_start: usize = 0;
    var prev_dot: bool = false;

    for (domain, 0..) |c, i| {
        if (c == '.') {
            if (prev_dot) return false;
            const label_len = i - label_start;
            if (label_len < 1 or label_len > 63) return false;

            const label = domain[label_start..i];
            if (label.len > 0 and (label[0] == '-' or label[label.len - 1] == '-')) {
                return false;
            }
            prev_dot = true;
            label_start = i + 1;
        } else if (c == '-') {
            if (i == label_start) return false;
            prev_dot = false;
        } else if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9')) {
            prev_dot = false;
        } else {
            return false;
        }
    }

    // 最后一段标签
    const last_label_len = domain.len - label_start;
    if (last_label_len < 1 or last_label_len > 63) return false;
    const last_label = domain[label_start..];
    if (last_label[0] == '-' or last_label[last_label_len - 1] == '-') return false;

    return true;
}

/// 验证主机字符串（有效 IPv4 或有效域名）。
pub fn isValidHost(host: []const u8) bool {
    if (host.len == 0) return false;
    if (isValidIpv4String(host)) return true;
    return isValidDomain(host);
}

// ============================================================
// IPv4 CIDR
// ============================================================

/// IPv4 CIDR — 网络前缀 + 掩码位数（0-32）。
/// network 字段为字节 [0] 在 MSB 的主机序 u32。
pub const Cidr4 = struct {
    network: u32, // 主机序 u32
    mask_bits: u8, // 0..32

    /// 解析 "a.b.c.d/n" CIDR 字符串。
    /// 主机位会被清零归一化（"192.168.1.5/24" → network 192.168.1.0）。
    pub fn parse(s: []const u8) !Cidr4 {
        const slash = std.mem.indexOfScalar(u8, s, '/') orelse
            return error.InvalidCidr;
        const ip_str = s[0..slash];
        const bits_str = s[slash + 1 ..];
        const bits = std.fmt.parseInt(u8, bits_str, 10) catch return error.InvalidCidr;
        if (bits > 32) return error.InvalidCidr;

        const ip_bytes = parseIpv4(ip_str) catch return error.InvalidCidr;
        const mask: u32 = if (bits == 0) 0 else @as(u32, 0xFFFFFFFF) << @intCast(32 - bits);
        return .{ .network = ip4ToInt(&ip_bytes) & mask, .mask_bits = bits };
    }

    /// 检查 IP（主机序 u32）是否在此 CIDR 范围内。
    pub fn contains(self: Cidr4, ip_host: u32) bool {
        if (self.mask_bits == 0) return true;
        const mask: u32 = if (self.mask_bits == 32)
            @as(u32, 0xFFFFFFFF)
        else
            (@as(u32, 0xFFFFFFFF) << @intCast(32 - self.mask_bits));
        return (ip_host & mask) == (self.network & mask);
    }

    /// 检查字节形式的 IP 是否在此 CIDR 范围内。
    pub fn containsIp4(self: Cidr4, ip: Ip4Addr) bool {
        return self.contains(ip4ToInt(&ip));
    }

    /// 返回网络地址（主机序 u32）。
    pub fn networkAddr(self: Cidr4) u32 {
        return self.network;
    }

    /// 返回网络地址的字节表示。
    pub fn networkBytes(self: Cidr4) Ip4Addr {
        return intToIp4(self.network);
    }

    /// 返回广播地址（主机序 u32）。
    /// /31 (RFC 3021) 和 /32 无广播地址，返回网络地址本身。
    pub fn broadcastAddr(self: Cidr4) u32 {
        // /0 必须特判：32 - 0 = 32 无法 @intCast 到 u5（会 panic）
        if (self.mask_bits == 0) return 0xFFFFFFFF;
        if (self.mask_bits >= 31) return self.network;
        const host_bits: u5 = @intCast(32 - self.mask_bits);
        const host_mask: u32 = (@as(u32, 1) << host_bits) - 1;
        return self.network | host_mask;
    }

    /// 返回广播地址的字节表示。
    pub fn broadcastBytes(self: Cidr4) Ip4Addr {
        return intToIp4(self.broadcastAddr());
    }

    /// 返回子网掩码（主机序 u32）。
    pub fn netmask(self: Cidr4) u32 {
        if (self.mask_bits == 0) return 0;
        return @as(u32, 0xFFFFFFFF) << @intCast(32 - self.mask_bits);
    }

    /// 前缀长度。
    pub fn prefixLen(self: Cidr4) u8 {
        return self.mask_bits;
    }

    /// 格式化 CIDR 为 "a.b.c.d/n" 字符串。
    pub fn format(self: Cidr4, buf: *[max_addr_buf]u8) ![]const u8 {
        const ip_bytes = self.networkBytes();
        return std.fmt.bufPrint(buf, "{}.{}.{}.{}/{}", .{
            ip_bytes[0], ip_bytes[1], ip_bytes[2], ip_bytes[3], self.mask_bits,
        });
    }
};

// ============================================================
// IPv6 CIDR
// ============================================================

/// IPv6 CIDR — 网络前缀 + 掩码位数（0-128）。
pub const Cidr6 = struct {
    base: Ip6Addr, // 网络前缀（网络字节序）
    mask_bits: u8, // 0..128

    /// 解析 "::/8"、"2000::/3"、"::1/128" 等 CIDR 字符串。
    /// 主机位会被清零归一化（"2001:db8::1/64" → base 2001:db8::）。
    pub fn parse(s: []const u8) !Cidr6 {
        const slash_idx = std.mem.lastIndexOfScalar(u8, s, '/') orelse
            return error.InvalidCidr;
        const addr_str = s[0..slash_idx];
        const mask_str = s[slash_idx + 1 ..];

        const bits = std.fmt.parseInt(u8, mask_str, 10) catch return error.InvalidCidr;
        if (bits > 128) return error.InvalidCidr;

        const addr = std.Io.net.Ip6Address.parse(addr_str, 0) catch return error.InvalidCidr;

        // 清零主机位
        var base = addr.bytes;
        const full_bytes = bits / 8;
        const rem_bits = bits % 8;
        if (full_bytes < 16) {
            if (rem_bits != 0) {
                const mask: u8 = @as(u8, 0xff) << @intCast(8 - rem_bits);
                base[full_bytes] &= mask;
                for (base[full_bytes + 1 ..]) |*b| b.* = 0;
            } else {
                for (base[full_bytes..]) |*b| b.* = 0;
            }
        }

        return .{ .base = base, .mask_bits = bits };
    }

    /// 检查 IP（[16]u8 网络字节序）是否在此 CIDR 范围内。
    pub fn contains(self: Cidr6, ip: Ip6Addr) bool {
        if (self.mask_bits == 0) return true;
        var i: usize = 0;
        const full_bytes = self.mask_bits / 8;
        const rem_bits = self.mask_bits % 8;
        while (i < full_bytes) : (i += 1) {
            if (self.base[i] != ip[i]) return false;
        }
        if (rem_bits == 0) return true;
        const mask: u8 = (@as(u8, 0xff) << @intCast(8 - rem_bits)) & 0xff;
        return (self.base[full_bytes] & mask) == (ip[full_bytes] & mask);
    }

    /// 返回网络基址（[16]u8 网络字节序）。
    pub fn network(self: Cidr6) Ip6Addr {
        return self.base;
    }

    /// 前缀长度。
    pub fn prefixLen(self: Cidr6) u8 {
        return self.mask_bits;
    }

    /// 返回此 CIDR 基址之后的下一个地址（128 位带进位递增）。
    /// 全 FF 地址回绕为全 0。调用者负责检查结果是否仍在 CIDR 范围内。
    pub fn next(self: Cidr6) Ip6Addr {
        var result = self.base;
        var i: usize = 16;
        while (i > 0) {
            i -= 1;
            result[i] +%= 1;
            if (result[i] != 0) break; // 无进位则结束；byte[0] 也参与进位
        }
        return result;
    }

    /// 格式化 CIDR 为 "x::x/n" 字符串。
    pub fn format(self: Cidr6, buf: *[max_ipv6_buf]u8) ![]const u8 {
        var ip_buf: [max_ipv6_buf]u8 = undefined;
        const ip_str = formatIpv6(&self.base, &ip_buf);
        return std.fmt.bufPrint(buf, "{s}/{}", .{ ip_str, self.mask_bits });
    }
};

// ============================================================
// Host/Port 解析
// ============================================================

/// 解析 "host:port" 或 "[ipv6]:port" 字符串。
/// 返回 host 切片（指向原字符串）和 port 号。
pub fn parseHostPort(host_port: []const u8) !struct { host: []const u8, port: u16 } {
    // 方括号包裹的 IPv6: [ipv6]:port
    if (host_port.len > 2 and host_port[0] == '[') {
        const close_bracket = std.mem.indexOfScalar(u8, host_port, ']');
        if (close_bracket) |bracket_idx| {
            const host = host_port[1..bracket_idx];
            const port_str = host_port[bracket_idx + 1 ..];
            if (port_str.len < 2 or port_str[0] != ':') {
                return error.InvalidHostPort;
            }
            const port = std.fmt.parseInt(u16, port_str[1..], 10) catch
                return error.InvalidHostPort;
            return .{ .host = host, .port = port };
        }
    }

    // 普通 host:port — 找最后一个冒号
    const last_colon = std.mem.lastIndexOfScalar(u8, host_port, ':') orelse {
        return error.InvalidHostPort;
    };
    const host = host_port[0..last_colon];
    const port_str = host_port[last_colon + 1 ..];
    if (port_str.len == 0) {
        return error.InvalidHostPort;
    }
    const port = std.fmt.parseInt(u16, port_str, 10) catch return error.InvalidHostPort;
    return .{ .host = host, .port = port };
}

/// 构建 "host:port" 字符串。
pub fn buildHostPort(host: []const u8, port: u16, buf: *[max_host_port_len]u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{s}:{d}", .{ host, port });
}

// ============================================================
// 测试
// ============================================================

const testing = std.testing;

// ---- IP 格式化测试 ----

test "formatIpv4: known values" {
    var buf: [max_addr_buf]u8 = undefined;
    try testing.expectEqualStrings("192.168.1.1", formatIpv4(&[_]u8{ 192, 168, 1, 1 }, &buf));
    try testing.expectEqualStrings("0.0.0.0", formatIpv4(&[_]u8{ 0, 0, 0, 0 }, &buf));
    try testing.expectEqualStrings("255.255.255.255", formatIpv4(&[_]u8{ 255, 255, 255, 255 }, &buf));
}

test "formatIpv4: short input returns placeholder" {
    var buf: [max_addr_buf]u8 = undefined;
    try testing.expectEqualStrings("invalid-ipv4", formatIpv4(&[_]u8{ 1, 2, 3 }, &buf));
}

test "formatIpv6: known values" {
    var buf: [max_ipv6_buf]u8 = undefined;
    const bytes = [_]u8{ 0x26, 0x06, 0x47, 0x00, 0x47, 0x00, 0, 0, 0, 0, 0, 0, 0, 0, 0x11, 0x11 };
    const result = formatIpv6(&bytes, &buf);
    try testing.expectEqualStrings("2606:4700:4700:0:0:0:0:1111", result);
}

test "formatIpv6: link-local fe80::1" {
    var buf: [max_ipv6_buf]u8 = undefined;
    const bytes = [_]u8{ 0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
    const result = formatIpv6(&bytes, &buf);
    try testing.expectEqualStrings("fe80:0:0:0:0:0:0:1", result);
}

test "formatIpv6: short input returns placeholder" {
    var buf: [max_ipv6_buf]u8 = undefined;
    try testing.expectEqualStrings("invalid-ipv6", formatIpv6(&[_]u8{1} ** 15, &buf));
}

// ---- IP 转换测试 ----

test "ip4ToInt / intToIp4: round-trip" {
    const bytes = [_]u8{ 192, 168, 1, 1 };
    const val = ip4ToInt(&bytes);
    const restored = intToIp4(val);
    try testing.expectEqualSlices(u8, &bytes, &restored);
}

test "ip4ToInt: known conversions" {
    try testing.expectEqual(@as(u32, 0xC0A80101), ip4ToInt(&[_]u8{ 192, 168, 1, 1 }));
    try testing.expectEqual(@as(u32, 0x00000000), ip4ToInt(&[_]u8{ 0, 0, 0, 0 }));
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), ip4ToInt(&[_]u8{ 255, 255, 255, 255 }));
}

test "ip6ToInt / intToIp6: round-trip" {
    const bytes = [_]u8{ 0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
    const val = ip6ToInt(&bytes);
    const restored = intToIp6(val);
    try testing.expectEqualSlices(u8, &bytes, &restored);
}

test "ip6ToInt: known conversions (big-endian semantics, regression)" {
    // 回归：曾用 @bitCast 导致小端平台数值颠倒（::1 变成 1 << 120）
    const loopback = [_]u8{0} ** 15 ++ [_]u8{1};
    try testing.expectEqual(@as(u128, 1), ip6ToInt(&loopback));

    const fe80_1 = [_]u8{ 0xfe, 0x80 } ++ [_]u8{0} ** 13 ++ [_]u8{1};
    try testing.expectEqual(@as(u128, 0xfe80_0000_0000_0000_0000_0000_0000_0001), ip6ToInt(&fe80_1));

    // 与 ip4ToInt 语义一致：byte[0] 在 MSB
    const restored = intToIp6(1);
    try testing.expectEqual(@as(u8, 1), restored[15]);
    try testing.expectEqual(@as(u8, 0), restored[0]);
}

// ---- IP 解析测试 ----

test "parseIpv4: valid addresses" {
    const result = try parseIpv4("192.168.1.1");
    try testing.expectEqualSlices(u8, &[_]u8{ 192, 168, 1, 1 }, &result);

    const zeros = try parseIpv4("0.0.0.0");
    try testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 0 }, &zeros);

    const max = try parseIpv4("255.255.255.255");
    try testing.expectEqualSlices(u8, &[_]u8{ 255, 255, 255, 255 }, &max);
}

test "parseIpv4: invalid addresses" {
    // std.Io.net.Ip4Address.parse error types vary by input:
    // 256 → Overflow, too few octets/empty → Incomplete, non-IP → InvalidCharacter
    try testing.expectError(error.Overflow, parseIpv4("256.0.0.0"));
    try testing.expectError(error.Incomplete, parseIpv4("1.2.3"));
    try testing.expectError(error.Incomplete, parseIpv4(""));
    try testing.expectError(error.InvalidCharacter, parseIpv4("abc.def.ghi.jkl"));
}

test "parseIpv6: valid addresses" {
    const loopback = try parseIpv6("::1");
    try testing.expectEqual(@as(u8, 1), loopback[15]);

    const full = try parseIpv6("fe80:0:0:0:0:0:0:1");
    try testing.expectEqual(@as(u8, 0xfe), full[0]);
    try testing.expectEqual(@as(u8, 0x80), full[1]);
    try testing.expectEqual(@as(u8, 1), full[15]);

    const cloudflare = try parseIpv6("2606:4700:4700::1111");
    try testing.expectEqual(@as(u8, 0x26), cloudflare[0]);
    try testing.expectEqual(@as(u8, 0x06), cloudflare[1]);
}

// ---- 地址类型判断测试 ----

test "isIpv4 / isIpv6 / isDomain" {
    try testing.expect(isIpv4(&[_]u8{ 1, 2, 3, 4 }));
    try testing.expect(!isIpv4(&[_]u8{ 1, 2, 3, 4, 5 }));

    try testing.expect(isIpv6(&[_]u8{0} ** 16));
    try testing.expect(!isIpv6(&[_]u8{0} ** 15));

    try testing.expect(isDomain("example.com"));
    try testing.expect(!isDomain(&[_]u8{ 1, 2, 3, 4 }));
}

// ---- 验证函数测试 ----

test "isValidPort: range check" {
    try testing.expect(!isValidPort(0));
    try testing.expect(isValidPort(1));
    try testing.expect(isValidPort(65535));
}

test "isValidIpv4String: accepts and rejects" {
    try testing.expect(isValidIpv4String("0.0.0.0"));
    try testing.expect(isValidIpv4String("255.255.255.255"));
    try testing.expect(isValidIpv4String("192.168.1.1"));
    try testing.expect(!isValidIpv4String("256.0.0.0"));
    try testing.expect(!isValidIpv4String("1.2.3"));
    try testing.expect(!isValidIpv4String("1.2.3.4.5"));
    try testing.expect(!isValidIpv4String(""));
}

test "isValidIpv6String: accepts fully-expanded form" {
    try testing.expect(isValidIpv6String("2606:4700:4700:0:0:0:0:1111"));
    try testing.expect(isValidIpv6String("fe80:0:0:0:0:0:0:1"));
    try testing.expect(isValidIpv6String("0:0:0:0:0:0:0:1"));
    try testing.expect(isValidIpv6String("[2606:4700:4700:0:0:0:0:1111]"));
}

test "isValidIpv6String: accepts compressed form" {
    try testing.expect(isValidIpv6String("::1"));
    try testing.expect(isValidIpv6String("fe80::1"));
    try testing.expect(isValidIpv6String("2606:4700:4700::1111"));
    try testing.expect(isValidIpv6String("[::]:1080"));
    try testing.expect(isValidIpv6String("::"));
    try testing.expect(isValidIpv6String("2001:db8::"));
    // 8 冒号但合法的压缩形式（曾被按冒号计数误拒）
    try testing.expect(isValidIpv6String("1:2:3:4:5:6:7::"));
    try testing.expect(isValidIpv6String("::1:2:3:4:5:6:7"));
}

test "isValidIpv6String: rejects malformed" {
    try testing.expect(!isValidIpv6String("10.0.0.1"));
    try testing.expect(!isValidIpv6String("gggg:0:0:0:0:0:0:1"));
    try testing.expect(!isValidIpv6String("::1::"));
    try testing.expect(!isValidIpv6String(""));
    try testing.expect(!isValidIpv6String("1:2:3:4:5:6:7")); // 7 组不足 8
    try testing.expect(!isValidIpv6String("1:2:3:4:5:6:7:8:9")); // 9 组超出
    try testing.expect(!isValidIpv6String(":1:2:3:4:5:6:7")); // 前导单冒号（曾被误收）
    try testing.expect(!isValidIpv6String("1:2:3:4:5:6:7:8:")); // 尾部单冒号
    try testing.expect(!isValidIpv6String("1:2:3:4:5:6:7:8::")); // 8 显式组 + "::" 共 9 组
    try testing.expect(!isValidIpv6String("12345::1")); // 组超 4 位
}

test "isValidDomain: accepts valid domains" {
    try testing.expect(isValidDomain("example.com"));
    try testing.expect(isValidDomain("subdomain.example.com"));
    try testing.expect(isValidDomain("test-domain.com"));
    try testing.expect(isValidDomain("a.co"));
    try testing.expect(isValidDomain("test123.com"));
}

test "isValidDomain: rejects invalid domains" {
    try testing.expect(!isValidDomain("")); // 空
    try testing.expect(!isValidDomain(".example.com")); // 前导点
    try testing.expect(!isValidDomain("example.com.")); // 尾随点
    try testing.expect(!isValidDomain("example..com")); // 连续点
    try testing.expect(!isValidDomain("-example.com")); // 前导连字符
    try testing.expect(!isValidDomain("example-.com")); // 尾随连字符（标签）
}

test "isValidHost: domain or IPv4" {
    try testing.expect(isValidHost("example.com"));
    try testing.expect(isValidHost("192.168.1.1"));
    try testing.expect(!isValidHost(""));
    // "256.0.0.0" looks like a domain name (digits + dots valid in DNS),
    // so it passes isValidDomain — this is expected behaviour from zproxy.
}

// ---- Cidr4 测试 ----

test "Cidr4.parse: valid CIDR" {
    const cidr = try Cidr4.parse("192.168.1.0/24");
    try testing.expectEqual(@as(u32, 0xC0A80100), cidr.network);
    try testing.expectEqual(@as(u8, 24), cidr.mask_bits);
}

test "Cidr4.parse: /32 single host" {
    const cidr = try Cidr4.parse("10.0.0.1/32");
    try testing.expectEqual(@as(u8, 32), cidr.mask_bits);
}

test "Cidr4.parse: /0 default route" {
    const cidr = try Cidr4.parse("0.0.0.0/0");
    try testing.expectEqual(@as(u8, 0), cidr.mask_bits);
}

test "Cidr4.parse: rejects malformed" {
    try testing.expectError(error.InvalidCidr, Cidr4.parse("192.168.1.0")); // missing /
    try testing.expectError(error.InvalidCidr, Cidr4.parse("192.168.1.0/33")); // > 32
    try testing.expectError(error.InvalidCidr, Cidr4.parse("invalid/24"));
}

test "Cidr4.contains: 192.168.1.0/24" {
    const cidr = try Cidr4.parse("192.168.1.0/24");
    try testing.expect(cidr.contains(ip4ToInt(&[_]u8{ 192, 168, 1, 1 })));
    try testing.expect(cidr.contains(ip4ToInt(&[_]u8{ 192, 168, 1, 255 })));
    try testing.expect(!cidr.contains(ip4ToInt(&[_]u8{ 192, 168, 2, 0 })));
}

test "Cidr4.contains: 10.0.0.0/8" {
    const cidr = try Cidr4.parse("10.0.0.0/8");
    try testing.expect(cidr.contains(ip4ToInt(&[_]u8{ 10, 0, 0, 0 })));
    try testing.expect(cidr.contains(ip4ToInt(&[_]u8{ 10, 255, 255, 255 })));
    try testing.expect(!cidr.contains(ip4ToInt(&[_]u8{ 11, 0, 0, 0 })));
}

test "Cidr4.contains: /32 exact match" {
    const cidr = try Cidr4.parse("172.16.0.1/32");
    try testing.expect(cidr.contains(ip4ToInt(&[_]u8{ 172, 16, 0, 1 })));
    try testing.expect(!cidr.contains(ip4ToInt(&[_]u8{ 172, 16, 0, 2 })));
}

test "Cidr4.contains: /0 matches all" {
    const cidr = try Cidr4.parse("0.0.0.0/0");
    try testing.expect(cidr.contains(ip4ToInt(&[_]u8{ 1, 2, 3, 4 })));
    try testing.expect(cidr.contains(ip4ToInt(&[_]u8{ 255, 255, 255, 255 })));
}

test "Cidr4.netmask / broadcast" {
    const cidr = try Cidr4.parse("192.168.1.0/24");
    try testing.expectEqual(@as(u32, 0xFFFFFF00), cidr.netmask());
    try testing.expectEqual(@as(u32, 0xC0A801FF), cidr.broadcastAddr());
}

test "Cidr4.format: round-trip" {
    const cidr = try Cidr4.parse("10.0.0.0/8");
    var buf: [max_addr_buf]u8 = undefined;
    const s = try cidr.format(&buf);
    try testing.expectEqualStrings("10.0.0.0/8", s);
}

test "Cidr4.containsIp4: convenience wrapper" {
    const cidr = try Cidr4.parse("192.168.1.0/24");
    try testing.expect(cidr.containsIp4([_]u8{ 192, 168, 1, 100 }));
    try testing.expect(!cidr.containsIp4([_]u8{ 10, 0, 0, 1 }));
}

test "Cidr4.broadcast: /31 and /32 edge cases" {
    const c31 = try Cidr4.parse("192.168.1.0/31");
    try testing.expectEqual(ip4ToInt(&[_]u8{ 192, 168, 1, 0 }), c31.broadcastAddr());

    const c32 = try Cidr4.parse("192.168.1.1/32");
    try testing.expectEqual(ip4ToInt(&[_]u8{ 192, 168, 1, 1 }), c32.broadcastAddr());
}

test "Cidr4.broadcast: /0 does not panic (regression)" {
    // 回归：/0 时 32 - 0 = 32 曾被 @intCast 到 u5 触发 panic
    const c0 = try Cidr4.parse("0.0.0.0/0");
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), c0.broadcastAddr());
    const bc = c0.broadcastBytes();
    try testing.expectEqualSlices(u8, &[_]u8{ 255, 255, 255, 255 }, &bc);
}

test "Cidr4.parse: normalizes host bits" {
    const cidr = try Cidr4.parse("192.168.1.5/24");
    try testing.expectEqual(@as(u32, 0xC0A80100), cidr.network);
    var buf: [max_addr_buf]u8 = undefined;
    try testing.expectEqualStrings("192.168.1.0/24", try cidr.format(&buf));
}

// ---- Cidr6 测试 ----

test "Cidr6.parse: ::/8" {
    const cidr = try Cidr6.parse("::/8");
    try testing.expectEqual(@as(u8, 0), cidr.base[0]);
    try testing.expectEqual(@as(u8, 8), cidr.mask_bits);
}

test "Cidr6.parse: 2000::/3" {
    const cidr = try Cidr6.parse("2000::/3");
    try testing.expectEqual(@as(u8, 0x20), cidr.base[0]);
    try testing.expectEqual(@as(u8, 3), cidr.mask_bits);
}

test "Cidr6.parse: ::1/128" {
    const cidr = try Cidr6.parse("::1/128");
    try testing.expectEqual(@as(u8, 0), cidr.base[0]);
    try testing.expectEqual(@as(u8, 0), cidr.base[14]);
    try testing.expectEqual(@as(u8, 1), cidr.base[15]);
    try testing.expectEqual(@as(u8, 128), cidr.mask_bits);
}

test "Cidr6.parse: rejects invalid" {
    try testing.expectError(error.InvalidCidr, Cidr6.parse("::/129"));
    try testing.expectError(error.InvalidCidr, Cidr6.parse("::1"));
}

test "Cidr6.parse: RFC 5952 compressed = expanded" {
    const c1 = try Cidr6.parse("::1/128");
    const c2 = try Cidr6.parse("0:0:0:0:0:0:0:1/128");
    try testing.expectEqualSlices(u8, &c1.base, &c2.base);
}

test "Cidr6.contains: /64 prefix" {
    const cidr = try Cidr6.parse("fc00::/64");
    var ip = [_]u8{0xfc} ++ [_]u8{0} ** 14 ++ [_]u8{1};
    try testing.expect(cidr.contains(ip));
    ip[0] = 0xfd;
    try testing.expect(!cidr.contains(ip));
}

test "Cidr6.contains: /128 exact" {
    const cidr = try Cidr6.parse("2001:db8::1/128");
    var ip1 = [_]u8{ 0x20, 0x01, 0x0d, 0xb8 } ++ [_]u8{0} ** 11 ++ [_]u8{1};
    try testing.expect(cidr.contains(ip1));
    ip1[15] = 2;
    try testing.expect(!cidr.contains(ip1));
}

test "Cidr6.network / prefixLen" {
    const cidr = try Cidr6.parse("fe80::/10");
    try testing.expectEqual(@as(u8, 0xfe), cidr.network()[0]);
    try testing.expectEqual(@as(u8, 0x80), cidr.network()[1]);
    try testing.expectEqual(@as(u8, 10), cidr.prefixLen());
}

test "Cidr6.next: increments correctly" {
    const cidr = try Cidr6.parse("::/8");
    const next_addr = cidr.next();
    try testing.expectEqual(@as(u8, 0), next_addr[0]);
    try testing.expectEqual(@as(u8, 1), next_addr[15]);

    // next() should still be within ::/8
    try testing.expect(cidr.contains(next_addr));
}

test "Cidr6.next: carry propagates through byte 0 (regression)" {
    // 回归：循环条件 while (i > 0) : (i -= 1) 曾跳过 byte[0]，进位丢失
    const c1 = Cidr6{ .base = [_]u8{0} ** 15 ++ [_]u8{0xff}, .mask_bits = 0 };
    const n1 = c1.next();
    try testing.expectEqual(@as(u8, 0), n1[15]);
    try testing.expectEqual(@as(u8, 1), n1[14]);

    // 00ff:ffff:...:ffff + 1 → 0100:0000:...:0000（进位穿越 byte[1] 抵达 byte[0]）
    const c2 = Cidr6{ .base = [_]u8{0x00} ++ [_]u8{0xff} ** 15, .mask_bits = 0 };
    const n2 = c2.next();
    try testing.expectEqual(@as(u8, 0x01), n2[0]);
    for (n2[1..]) |b| try testing.expectEqual(@as(u8, 0), b);

    // 全 FF 回绕为全 0
    const c3 = Cidr6{ .base = [_]u8{0xff} ** 16, .mask_bits = 0 };
    const n3 = c3.next();
    for (n3) |b| try testing.expectEqual(@as(u8, 0), b);
}

test "Cidr6.parse: normalizes host bits" {
    const cidr = try Cidr6.parse("2001:db8::1/64");
    try testing.expectEqual(@as(u8, 0x20), cidr.base[0]);
    try testing.expectEqual(@as(u8, 0x01), cidr.base[1]);
    for (cidr.base[8..]) |b| try testing.expectEqual(@as(u8, 0), b);

    // 非字节对齐前缀：fe80::1/10 → fe80:: 之外 base[1] 高 2 位保留
    const c10 = try Cidr6.parse("febf::1/10");
    try testing.expectEqual(@as(u8, 0xfe), c10.base[0]);
    try testing.expectEqual(@as(u8, 0x80), c10.base[1]); // 0xbf & 0xc0 = 0x80
    for (c10.base[2..]) |b| try testing.expectEqual(@as(u8, 0), b);
}

// ---- Host/Port 测试 ----

test "parseHostPort: IPv4 with explicit port" {
    const p = try parseHostPort("108.187.42.200:5178");
    try testing.expectEqualStrings("108.187.42.200", p.host);
    try testing.expectEqual(@as(u16, 5178), p.port);
}

test "parseHostPort: missing port is an error" {
    try testing.expectError(error.InvalidHostPort, parseHostPort("example.com"));
    try testing.expectError(error.InvalidHostPort, parseHostPort(""));
}

test "parseHostPort: invalid port string" {
    try testing.expectError(error.InvalidHostPort, parseHostPort("host:abc"));
    try testing.expectError(error.InvalidHostPort, parseHostPort("host:99999999"));
    try testing.expectError(error.InvalidHostPort, parseHostPort("host:"));
}

test "parseHostPort: bracketed IPv6" {
    const p = try parseHostPort("[::1]:8080");
    try testing.expectEqualStrings("::1", p.host);
    try testing.expectEqual(@as(u16, 8080), p.port);

    const p2 = try parseHostPort("[2606:4700:4700::1111]:53");
    try testing.expectEqualStrings("2606:4700:4700::1111", p2.host);
    try testing.expectEqual(@as(u16, 53), p2.port);
}

test "parseHostPort: common ports" {
    inline for ([_]u16{ 21, 22, 25, 53, 80, 110, 143, 443, 587, 993, 995, 1080, 5178, 8080, 65535 }) |port| {
        var buf: [32]u8 = undefined;
        const s = try std.fmt.bufPrint(&buf, "host:{d}", .{port});
        const p = try parseHostPort(s);
        try testing.expectEqual(port, p.port);
    }
}

test "parseHostPort: uses last colon for IPv4" {
    const p = try parseHostPort("host:80");
    try testing.expectEqualStrings("host", p.host);
    try testing.expectEqual(@as(u16, 80), p.port);
}

test "buildHostPort: round-trips with parseHostPort" {
    var buf: [max_host_port_len]u8 = undefined;
    const s = try buildHostPort("example.com", 443, &buf);
    const p = try parseHostPort(s);
    try testing.expectEqualStrings("example.com", p.host);
    try testing.expectEqual(@as(u16, 443), p.port);
}

test "buildHostPort: domain with port" {
    var buf: [max_host_port_len]u8 = undefined;
    const s = try buildHostPort("test.example.com", 8080, &buf);
    try testing.expectEqualStrings("test.example.com:8080", s);
}
