//! 字符串常用处理 — 大小写转换、拼接、大小写不敏感比较、切分
//!
//! zigfoundation 原创模块，补充 Zig 标准库 std.mem 未提供的字符串工具。
//! 遵循注入模式：Allocator 作为参数传入，模块内部无全局状态。

const std = @import("std");

// ============================================================
// 大小写转换
// ============================================================

/// 将字符串转换为小写，通过 allocator 分配新字符串返回。
/// 调用者负责释放返回的内存。
pub fn toLower(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    const result = try allocator.alloc(u8, s.len);
    for (s, 0..) |c, i| {
        result[i] = std.ascii.toLower(c);
    }
    return result;
}

/// 将字符串转换为大写，通过 allocator 分配新字符串返回。
/// 调用者负责释放返回的内存。
pub fn toUpper(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    const result = try allocator.alloc(u8, s.len);
    for (s, 0..) |c, i| {
        result[i] = std.ascii.toUpper(c);
    }
    return result;
}

/// 原地将字符串转换为小写。
pub fn toLowerInPlace(s: []u8) void {
    for (s) |*c| {
        c.* = std.ascii.toLower(c.*);
    }
}

/// 原地将字符串转换为大写。
pub fn toUpperInPlace(s: []u8) void {
    for (s) |*c| {
        c.* = std.ascii.toUpper(c.*);
    }
}

// ============================================================
// 子串搜索
// ============================================================

/// 检查 haystack 是否包含 needle 子串。
pub fn contains(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

/// 大小写不敏感子串包含检查。
pub fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var matched = true;
        for (needle, 0..) |nc, j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(nc)) {
                matched = false;
                break;
            }
        }
        if (matched) return true;
    }
    return false;
}

// ============================================================
// 前缀/后缀匹配（大小写不敏感）
// ============================================================

/// 大小写不敏感前缀匹配。
pub fn startsWithIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    for (needle, 0..) |nc, i| {
        if (std.ascii.toLower(haystack[i]) != std.ascii.toLower(nc)) return false;
    }
    return true;
}

/// 大小写不敏感后缀匹配。
pub fn endsWithIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    const offset = haystack.len - needle.len;
    for (needle, 0..) |nc, i| {
        if (std.ascii.toLower(haystack[offset + i]) != std.ascii.toLower(nc)) return false;
    }
    return true;
}

// ============================================================
// 字符串拼接
// ============================================================

/// 用分隔符连接字符串切片数组。
/// 调用者负责释放返回的内存。
pub fn join(allocator: std.mem.Allocator, parts: []const []const u8, separator: []const u8) ![]u8 {
    if (parts.len == 0) return &[0]u8{};

    // 计算总长度
    var total_len: usize = separator.len * (parts.len - 1);
    for (parts) |p| {
        total_len += p.len;
    }

    const result = try allocator.alloc(u8, total_len);
    var pos: usize = 0;
    for (parts, 0..) |p, i| {
        if (i > 0) {
            @memcpy(result[pos..][0..separator.len], separator);
            pos += separator.len;
        }
        @memcpy(result[pos..][0..p.len], p);
        pos += p.len;
    }
    return result;
}

// ============================================================
// 切分工具
// ============================================================

/// 按行切分（按 '\n' 分割），返回迭代器。
/// 等同于 std.mem.splitScalar(u8, s, '\n') 的语义化别名。
pub fn splitLines(s: []const u8) std.mem.SplitIterator(u8, .scalar) {
    return std.mem.splitScalar(u8, s, '\n');
}

/// 按分隔符切分并对每段去除首尾空白。
/// 返回值为调用者可直接遍历的结构体迭代器。
pub fn splitTrim(s: []const u8, delimiter: u8) SplitTrimIterator {
    return .{ .inner = std.mem.splitScalar(u8, s, delimiter) };
}

/// splitTrim 的迭代器类型。
pub const SplitTrimIterator = struct {
    inner: std.mem.SplitIterator(u8, .scalar),

    /// 返回下一段已去除首尾空白的切片，无更多段时返回 null。
    pub fn next(self: *SplitTrimIterator) ?[]const u8 {
        while (self.inner.next()) |part| {
            const trimmed = std.mem.trim(u8, part, " \t\r\n");
            if (trimmed.len > 0) return trimmed;
        }
        return null;
    }
};

// ============================================================
// 测试
// ============================================================

const testing = std.testing;

test "strings: reference all pub decls (lazy-analysis guard)" {
    testing.refAllDecls(@This());
}

// ---- 大小写转换测试 ----

test "toLower: allocates lowercase copy" {
    const result = try toLower(testing.allocator, "Hello World!");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("hello world!", result);
}

test "toLower: empty string" {
    const result = try toLower(testing.allocator, "");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("", result);
}

test "toUpper: allocates uppercase copy" {
    const result = try toUpper(testing.allocator, "Hello World!");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("HELLO WORLD!", result);
}

test "toLowerInPlace: modifies in place" {
    var buf: [12]u8 = .{ 'H', 'e', 'L', 'l', 'O', ' ', 'W', 'o', 'R', 'l', 'd', '!' };
    toLowerInPlace(&buf);
    try testing.expectEqualStrings("hello world!", &buf);
}

test "toUpperInPlace: modifies in place" {
    var buf: [12]u8 = .{ 'H', 'e', 'L', 'l', 'O', ' ', 'W', 'o', 'R', 'l', 'd', '!' };
    toUpperInPlace(&buf);
    try testing.expectEqualStrings("HELLO WORLD!", &buf);
}

test "toLower / toUpper round-trip" {
    const original = "AbCdEfGh";
    const lower = try toLower(testing.allocator, original);
    defer testing.allocator.free(lower);
    const upper = try toUpper(testing.allocator, lower);
    defer testing.allocator.free(upper);
    try testing.expectEqualStrings("ABCDEFGH", upper);
}

// ---- 子串搜索测试 ----

test "contains: found" {
    try testing.expect(contains("hello world", "world"));
    try testing.expect(contains("hello world", "hello"));
    try testing.expect(contains("hello world", "lo wo"));
}

test "contains: not found" {
    try testing.expect(!contains("hello world", "xyz"));
    try testing.expect(!contains("hello", "hello world"));
}

test "contains: edge cases" {
    try testing.expect(contains("hello", "")); // empty needle always found (stdlib semantics)
    try testing.expect(!contains("", "hello"));
}

test "containsIgnoreCase: found" {
    try testing.expect(containsIgnoreCase("Hello World", "world"));
    try testing.expect(containsIgnoreCase("Hello World", "HELLO"));
    try testing.expect(containsIgnoreCase("Hello World", "Lo Wo"));
}

test "containsIgnoreCase: not found" {
    try testing.expect(!containsIgnoreCase("Hello World", "xyz"));
}

test "containsIgnoreCase: empty needle" {
    try testing.expect(containsIgnoreCase("hello", ""));
    try testing.expect(!containsIgnoreCase("", "hello"));
}

// ---- 大小写不敏感前后缀测试 ----

test "startsWithIgnoreCase: basic" {
    try testing.expect(startsWithIgnoreCase("Hello World", "hello"));
    try testing.expect(startsWithIgnoreCase("Hello World", "HELLO"));
    try testing.expect(!startsWithIgnoreCase("Hello World", "world"));
    try testing.expect(!startsWithIgnoreCase("Hello", "Hello World"));
}

test "startsWithIgnoreCase: empty needle" {
    try testing.expect(startsWithIgnoreCase("hello", ""));
}

test "endsWithIgnoreCase: basic" {
    try testing.expect(endsWithIgnoreCase("Hello World", "world"));
    try testing.expect(endsWithIgnoreCase("Hello World", "WORLD"));
    try testing.expect(!endsWithIgnoreCase("Hello World", "hello"));
    try testing.expect(!endsWithIgnoreCase("World", "Hello World"));
}

test "endsWithIgnoreCase: empty needle" {
    try testing.expect(endsWithIgnoreCase("hello", ""));
}

// ---- 字符串拼接测试 ----

test "join: simple" {
    const parts = &[_][]const u8{ "a", "b", "c" };
    const result = try join(testing.allocator, parts, ", ");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("a, b, c", result);
}

test "join: single part (no separator)" {
    const parts = &[_][]const u8{"hello"};
    const result = try join(testing.allocator, parts, ", ");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("hello", result);
}

test "join: empty parts" {
    const result = try join(testing.allocator, &[_][]const u8{}, ", ");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("", result);
}

test "join: empty separator" {
    const parts = &[_][]const u8{ "a", "b", "c" };
    const result = try join(testing.allocator, parts, "");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("abc", result);
}

test "join: path-like" {
    const parts = &[_][]const u8{ "usr", "local", "bin" };
    const result = try join(testing.allocator, parts, "/");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("usr/local/bin", result);
}

// ---- 切分测试 ----

test "splitLines: basic" {
    const text = "line1\nline2\nline3";
    var iter = splitLines(text);
    try testing.expectEqualStrings("line1", iter.next().?);
    try testing.expectEqualStrings("line2", iter.next().?);
    try testing.expectEqualStrings("line3", iter.next().?);
    try testing.expectEqual(@as(?[]const u8, null), iter.next());
}

test "splitLines: trailing newline" {
    const text = "a\nb\n";
    var iter = splitLines(text);
    try testing.expectEqualStrings("a", iter.next().?);
    try testing.expectEqualStrings("b", iter.next().?);
    try testing.expectEqualStrings("", iter.next().?);
}

test "splitTrim: skips empty and trims whitespace" {
    var iter = splitTrim("a, b ,  c  ,,d", ',');
    try testing.expectEqualStrings("a", iter.next().?);
    try testing.expectEqualStrings("b", iter.next().?);
    try testing.expectEqualStrings("c", iter.next().?);
    try testing.expectEqualStrings("d", iter.next().?);
    try testing.expectEqual(@as(?[]const u8, null), iter.next());
}

test "splitTrim: all whitespace-only parts" {
    var iter = splitTrim("  , \t , ", ',');
    try testing.expectEqual(@as(?[]const u8, null), iter.next());
}

test "splitTrim: no delimiter present" {
    var iter = splitTrim("hello", ',');
    try testing.expectEqualStrings("hello", iter.next().?);
    try testing.expectEqual(@as(?[]const u8, null), iter.next());
}
