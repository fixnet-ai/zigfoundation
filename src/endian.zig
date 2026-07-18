//! 大小端转换 — 统一字节序读写 API
//!
//! 封装 `std.mem.readInt` / `std.mem.writeInt`，提供便捷的类型化接口，
//! 消除各处散落的样板代码。
//!
//! 命名惯例：`read{Type}{Endian}` / `write{Type}{Endian}`。

const std = @import("std");

/// 大端读取 u16。
pub inline fn readU16Big(bytes: *const [2]u8) u16 {
    return std.mem.readInt(u16, bytes, .big);
}

/// 小端读取 u16。
pub inline fn readU16Little(bytes: *const [2]u8) u16 {
    return std.mem.readInt(u16, bytes, .little);
}

/// 大端读取 u32。
pub inline fn readU32Big(bytes: *const [4]u8) u32 {
    return std.mem.readInt(u32, bytes, .big);
}

/// 小端读取 u32。
pub inline fn readU32Little(bytes: *const [4]u8) u32 {
    return std.mem.readInt(u32, bytes, .little);
}

/// 大端读取 u64。
pub inline fn readU64Big(bytes: *const [8]u8) u64 {
    return std.mem.readInt(u64, bytes, .big);
}

/// 小端读取 u64。
pub inline fn readU64Little(bytes: *const [8]u8) u64 {
    return std.mem.readInt(u64, bytes, .little);
}

/// 大端写入 u16。
pub inline fn writeU16Big(bytes: *[2]u8, val: u16) void {
    std.mem.writeInt(u16, bytes, val, .big);
}

/// 小端写入 u16。
pub inline fn writeU16Little(bytes: *[2]u8, val: u16) void {
    std.mem.writeInt(u16, bytes, val, .little);
}

/// 大端写入 u32。
pub inline fn writeU32Big(bytes: *[4]u8, val: u32) void {
    std.mem.writeInt(u32, bytes, val, .big);
}

/// 小端写入 u32。
pub inline fn writeU32Little(bytes: *[4]u8, val: u32) void {
    std.mem.writeInt(u32, bytes, val, .little);
}

/// 大端写入 u64。
pub inline fn writeU64Big(bytes: *[8]u8, val: u64) void {
    std.mem.writeInt(u64, bytes, val, .big);
}

/// 小端写入 u64。
pub inline fn writeU64Little(bytes: *[8]u8, val: u64) void {
    std.mem.writeInt(u64, bytes, val, .little);
}

/// 通用大端读取 — 指定整数类型 T，从切片读取。
pub inline fn readIntBig(comptime T: type, bytes: []const u8) T {
    return std.mem.readInt(T, bytes[0..@sizeOf(T)], .big);
}

/// 通用小端读取 — 指定整数类型 T，从切片读取。
pub inline fn readIntLittle(comptime T: type, bytes: []const u8) T {
    return std.mem.readInt(T, bytes[0..@sizeOf(T)], .little);
}

/// 通用大端写入 — 指定整数类型 T，写入切片。
pub inline fn writeIntBig(comptime T: type, bytes: []u8, val: T) void {
    std.mem.writeInt(T, bytes[0..@sizeOf(T)], val, .big);
}

/// 通用小端写入 — 指定整数类型 T，写入切片。
pub inline fn writeIntLittle(comptime T: type, bytes: []u8, val: T) void {
    std.mem.writeInt(T, bytes[0..@sizeOf(T)], val, .little);
}

// ============================================================
// 测试
// ============================================================

const testing = std.testing;

test "endian: readU16Big" {
    const bytes = [_]u8{ 0x12, 0x34 };
    try testing.expectEqual(@as(u16, 0x1234), readU16Big(&bytes));
}

test "endian: readU16Little" {
    const bytes = [_]u8{ 0x34, 0x12 };
    try testing.expectEqual(@as(u16, 0x1234), readU16Little(&bytes));
}

test "endian: readU32Big" {
    const bytes = [_]u8{ 0x12, 0x34, 0x56, 0x78 };
    try testing.expectEqual(@as(u32, 0x12345678), readU32Big(&bytes));
}

test "endian: readU32Little" {
    const bytes = [_]u8{ 0x78, 0x56, 0x34, 0x12 };
    try testing.expectEqual(@as(u32, 0x12345678), readU32Little(&bytes));
}

test "endian: readU64Big" {
    const bytes = [_]u8{ 0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0 };
    try testing.expectEqual(@as(u64, 0x123456789ABCDEF0), readU64Big(&bytes));
}

test "endian: readU64Little" {
    const bytes = [_]u8{ 0xF0, 0xDE, 0xBC, 0x9A, 0x78, 0x56, 0x34, 0x12 };
    try testing.expectEqual(@as(u64, 0x123456789ABCDEF0), readU64Little(&bytes));
}

test "endian: writeU16Big round-trip" {
    var buf: [2]u8 = undefined;
    writeU16Big(&buf, 0xABCD);
    try testing.expectEqual(@as(u16, 0xABCD), readU16Big(&buf));
}

test "endian: writeU16Little round-trip" {
    var buf: [2]u8 = undefined;
    writeU16Little(&buf, 0xABCD);
    try testing.expectEqual(@as(u16, 0xABCD), readU16Little(&buf));
}

test "endian: writeU32Big round-trip" {
    var buf: [4]u8 = undefined;
    writeU32Big(&buf, 0xDEADBEEF);
    try testing.expectEqual(@as(u32, 0xDEADBEEF), readU32Big(&buf));
}

test "endian: writeU32Little round-trip" {
    var buf: [4]u8 = undefined;
    writeU32Little(&buf, 0xDEADBEEF);
    try testing.expectEqual(@as(u32, 0xDEADBEEF), readU32Little(&buf));
}

test "endian: writeU64Big round-trip" {
    var buf: [8]u8 = undefined;
    writeU64Big(&buf, 0x0123456789ABCDEF);
    try testing.expectEqual(@as(u64, 0x0123456789ABCDEF), readU64Big(&buf));
}

test "endian: writeU64Little round-trip" {
    var buf: [8]u8 = undefined;
    writeU64Little(&buf, 0x0123456789ABCDEF);
    try testing.expectEqual(@as(u64, 0x0123456789ABCDEF), readU64Little(&buf));
}

test "endian: generic readIntBig" {
    const bytes = [_]u8{ 0x01, 0x02, 0x03, 0x04 };
    try testing.expectEqual(@as(u32, 0x01020304), readIntBig(u32, &bytes));
}

test "endian: generic readIntLittle" {
    const bytes = [_]u8{ 0x04, 0x03, 0x02, 0x01 };
    try testing.expectEqual(@as(u32, 0x01020304), readIntLittle(u32, &bytes));
}

test "endian: generic writeIntBig round-trip" {
    var buf: [4]u8 = [_]u8{0} ** 4;
    writeIntBig(u32, &buf, 0xCAFEBABE);
    try testing.expectEqual(@as(u32, 0xCAFEBABE), readIntBig(u32, &buf));
}

test "endian: generic writeIntLittle round-trip" {
    var buf: [4]u8 = [_]u8{0} ** 4;
    writeIntLittle(u32, &buf, 0xCAFEBABE);
    try testing.expectEqual(@as(u32, 0xCAFEBABE), readIntLittle(u32, &buf));
}
