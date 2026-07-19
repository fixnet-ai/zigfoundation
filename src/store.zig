//! 持久化键值存储 — 基于文件系统的通用 KV 缓存
//!
//! ## 设计
//!
//! 每个键存储为独立文件，路径为 `{dir}/{hex(key)}`。
//! 文件格式：8 字节到期时间戳 (u64, 大端序, 0 = 永不过期) + 值字节。
//!
//! 原子写入：先写 `{key}.tmp`，再 rename 到正式文件名（不显式 fsync，依赖 OS 回写）。
//!
//! ## 平台
//!
//! 全平台支持（Windows / macOS / Linux / iOS / Android），不依赖 LMDB 或其他外部库。
//!
//! ## 约束
//!
//! - 键最大 125 字节（hex 文件名 250 字节 + `.tmp` 后缀 = 254，≤ 常见文件系统 255 文件名上限）
//! - 值最大 16 MB
//! - 空值是合法内容，与"键不存在"（null）可区分
//! - 不绑定任何业务逻辑（DNS、代理等）

const std = @import("std");
const builtin = @import("builtin");
const endian = @import("endian.zig");

/// 文件头部大小：8 字节到期时间戳
const HEADER_SIZE: usize = 8;

/// 键最大字节长度。
/// hex 编码文件名为 2×key.len，加 ".tmp" 后缀须 ≤ 255（常见文件系统单文件名上限）：
/// 2×125 + 4 = 254。曾为 256，实际 key ≥ 126 时 set() 必然失败。
pub const MAX_KEY_LEN: usize = 125;

/// 值最大字节长度
pub const MAX_VALUE_LEN: usize = 16 * 1024 * 1024; // 16 MB

/// 持久化 KV 存储。
///
/// 路径由调用者注入，I/O 通过注入的 `io: std.Io` 执行。
/// 读取的值由 allocator 分配，调用者负责释放。
pub const Store = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,

    /// 创建存储实例。`dir_path` 目录不存在时自动创建（含父目录）。
    /// 调用者拥有 `dir_path` 内存的所有权。
    /// 内部将 `dir_path` 解析为绝对路径存储。
    pub fn init(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8) !Store {
        // 确保目录存在（含父目录）
        const cwd = std.Io.Dir.cwd();
        cwd.createDirPath(io, dir_path) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        // 解析为绝对路径
        const abs_path = if (std.fs.path.isAbsolute(dir_path))
            try allocator.dupe(u8, dir_path)
        else blk: {
            var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
            const cwd_ptr = std.c.getcwd(&cwd_buf, cwd_buf.len) orelse return error.GetCwdFailed;
            const cwd_path: []const u8 = std.mem.sliceTo(cwd_ptr, 0);
            break :blk try std.fs.path.join(allocator, &.{ cwd_path, dir_path });
        };
        return Store{
            .allocator = allocator,
            .io = io,
            .dir_path = abs_path,
        };
    }

    /// 释放资源（释放 dir_path 内存，目录和文件保留在磁盘上）。
    pub fn deinit(self: *Store) void {
        self.allocator.free(self.dir_path);
    }

    /// 按键查询，未找到或已过期返回 null。
    /// 返回值由 allocator 分配，调用者负责释放。
    pub fn get(self: *Store, key: []const u8) !?[]const u8 {
        if (key.len == 0 or key.len > MAX_KEY_LEN) return error.InvalidKey;

        const file_path = try self.keyPath(key);
        defer self.allocator.free(file_path);

        // 读取整个文件内容。
        // limit 语义是"达到或超过即报 StreamTooLong"，须比最大合法内容多 1，
        // 否则值恰好为 MAX_VALUE_LEN 的条目会读取失败。
        const data = std.Io.Dir.readFileAlloc(
            .cwd(),
            self.io,
            file_path,
            self.allocator,
            std.Io.Limit.limited(HEADER_SIZE + MAX_VALUE_LEN + 1),
        ) catch |err| {
            if (err == error.FileNotFound) return null;
            return err;
        };
        defer self.allocator.free(data);

        if (data.len < HEADER_SIZE) return null;

        const expiry: u64 = endian.readU64Big(data[0..HEADER_SIZE]);

        // 检查是否过期
        if (expiry > 0) {
            const now = nowSeconds();
            if (now >= expiry) return null;
        }

        const value = data[HEADER_SIZE..];

        // 空值是合法存储内容（与"键不存在"返回 null 区分）
        // 复制值给调用者（readFileAlloc 的所有权在我们手里）
        const owned = try self.allocator.alloc(u8, value.len);
        @memcpy(owned, value);
        return owned;
    }

    /// 写入键值对。`ttl_seconds` 为 0 时永不过期。
    /// 使用原子写入：先写临时文件，rename 原子替换（无显式 fsync，依赖 OS 回写）。
    pub fn set(self: *Store, key: []const u8, value: []const u8, ttl_seconds: u64) !void {
        if (key.len == 0 or key.len > MAX_KEY_LEN) return error.InvalidKey;
        if (value.len > MAX_VALUE_LEN) return error.ValueTooLarge;

        const file_path = try self.keyPath(key);
        defer self.allocator.free(file_path);

        // 计算到期时间戳（饱和加法防止 ttl 极大值回绕成"已过期"）
        const expiry: u64 = if (ttl_seconds > 0) nowSeconds() +| ttl_seconds else 0;

        // 构建文件内容：header + value
        const data_len = HEADER_SIZE + value.len;
        const data = try self.allocator.alloc(u8, data_len);
        defer self.allocator.free(data);
        endian.writeU64Big(data[0..HEADER_SIZE], expiry);
        @memcpy(data[HEADER_SIZE..], value);

        // 写入临时文件
        const tmp_path = try std.mem.concat(self.allocator, u8, &.{ file_path, ".tmp" });
        defer self.allocator.free(tmp_path);

        std.Io.Dir.writeFile(.cwd(), self.io, .{
            .sub_path = tmp_path,
            .data = data,
        }) catch |err| {
            std.Io.Dir.deleteFileAbsolute(self.io, tmp_path) catch {};
            return err;
        };

        // 原子 rename
        std.Io.Dir.renameAbsolute(tmp_path, file_path, self.io) catch |err| {
            std.Io.Dir.deleteFileAbsolute(self.io, tmp_path) catch {};
            return err;
        };
    }

    /// 删除键。键不存在时静默忽略。
    pub fn delete(self: *Store, key: []const u8) !void {
        if (key.len == 0 or key.len > MAX_KEY_LEN) return error.InvalidKey;

        const file_path = try self.keyPath(key);
        defer self.allocator.free(file_path);

        std.Io.Dir.deleteFileAbsolute(self.io, file_path) catch |err| {
            if (err == error.FileNotFound) return;
            return err;
        };
    }

    /// 清理所有过期条目。返回清理的条目数。
    pub fn cleanExpired(self: *Store) !usize {
        // 必须显式 .iterate = true：默认 OpenOptions 打开的目录不可迭代
        // （曾用 .{} 导致 iterate() 一个条目都不产出，cleanExpired 永远返回 0）。
        const dir = try std.Io.Dir.openDirAbsolute(self.io, self.dir_path, .{ .iterate = true });
        defer dir.close(self.io);

        const now = nowSeconds();
        var cleaned: usize = 0;

        var it = dir.iterate();
        const entry = try it.next(self.io);
        var opt_entry = entry;
        while (opt_entry) |e| : (opt_entry = try it.next(self.io)) {
            if (e.kind != .file) continue;
            // 跳过临时文件
            if (std.mem.endsWith(u8, e.name, ".tmp")) continue;

            const entry_path = try std.fs.path.join(self.allocator, &.{ self.dir_path, e.name });
            defer self.allocator.free(entry_path);

            // 只读取头部 8 字节检查到期时间。
            // 不能用 readFileAlloc + Limit.limited(8)：该 limit 语义是
            // "内容达到或超过上限即报 StreamTooLong"，任何带值的条目都会被误跳过。
            var header: [HEADER_SIZE]u8 = undefined;
            {
                var file = std.Io.Dir.openFileAbsolute(self.io, entry_path, .{}) catch continue;
                defer file.close(self.io); // 删除前必须先关闭（Windows 不允许删除打开中的文件）
                const n = file.readPositionalAll(self.io, &header, 0) catch continue;
                if (n < HEADER_SIZE) continue;
            }

            const expiry: u64 = endian.readU64Big(&header);
            if (expiry > 0 and now >= expiry) {
                std.Io.Dir.deleteFileAbsolute(self.io, entry_path) catch continue;
                cleaned += 1;
            }
        }

        return cleaned;
    }

    /// 将键编码为文件路径：`{dir_path}/{hex(key)}`
    fn keyPath(self: *Store, key: []const u8) ![]u8 {
        const hex_len = key.len * 2;
        const path_len = self.dir_path.len + 1 + hex_len; // dir + "/" + hex
        const path = try self.allocator.alloc(u8, path_len);
        errdefer self.allocator.free(path);

        @memcpy(path[0..self.dir_path.len], self.dir_path);
        path[self.dir_path.len] = '/';

        const hex_digits = "0123456789abcdef";
        for (key, 0..) |byte, i| {
            path[self.dir_path.len + 1 + i * 2] = hex_digits[byte >> 4];
            path[self.dir_path.len + 1 + i * 2 + 1] = hex_digits[byte & 0xf];
        }

        return path;
    }
};

/// 获取当前 Unix 时间戳（秒）。
fn nowSeconds() u64 {
    if (builtin.os.tag == .windows) {
        const EPOCH_OFFSET: u64 = 11644473600;
        var ft: u64 = 0;
        const kernel32 = struct {
            extern "kernel32" fn GetSystemTimeAsFileTime(filetime: *u64) callconv(.winapi) void;
        };
        kernel32.GetSystemTimeAsFileTime(&ft);
        return ft / 10_000_000 - EPOCH_OFFSET;
    }
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    return @intCast(ts.sec);
}

// ============================================================================
// 测试
// ============================================================================

const testing = std.testing;

/// 创建临时测试目录（绝对路径）。
/// 每次调用先清空同名目录再重建，保证测试从干净状态开始，
/// 且不在 .zig-cache/tmp 下逐次累积随机残留目录。
fn tmpDir(allocator: std.mem.Allocator, suffix: []const u8) ![]const u8 {
    const rel_dir = try std.fs.path.join(allocator, &.{
        ".zig-cache", "tmp", "zigfoundation-store-tests", suffix,
    });
    defer allocator.free(rel_dir);

    const cwd_dir = std.Io.Dir.cwd();
    cwd_dir.deleteTree(std.testing.io, rel_dir) catch {};
    cwd_dir.createDirPath(std.testing.io, rel_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    // 获取当前工作目录的绝对路径
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_ptr = std.c.getcwd(&cwd_buf, cwd_buf.len) orelse return error.GetCwdFailed;
    const cwd_path: []const u8 = std.mem.sliceTo(cwd_ptr, 0);

    return std.fs.path.join(allocator, &.{ cwd_path, rel_dir });
}

test "store: init and deinit" {
    const dir = try tmpDir(testing.allocator, "store_init");
    defer testing.allocator.free(dir);

    var s = try Store.init(testing.allocator, std.testing.io, dir);
    s.deinit();
}

test "store: get non-existent key returns null" {
    const dir = try tmpDir(testing.allocator, "store_get_miss");
    defer testing.allocator.free(dir);

    var s = try Store.init(testing.allocator, std.testing.io, dir);
    defer s.deinit();

    const result = try s.get("nonexistent");
    try testing.expect(result == null);
}

test "store: set and get round-trip" {
    const dir = try tmpDir(testing.allocator, "store_set_get");
    defer testing.allocator.free(dir);

    var s = try Store.init(testing.allocator, std.testing.io, dir);
    defer s.deinit();

    try s.set("hello", "world", 0);
    const result = try s.get("hello");
    try testing.expect(result != null);
    defer if (result) |r| testing.allocator.free(r);
    try testing.expectEqualStrings("world", result.?);
}

test "store: set overwrites existing key" {
    const dir = try tmpDir(testing.allocator, "store_overwrite");
    defer testing.allocator.free(dir);

    var s = try Store.init(testing.allocator, std.testing.io, dir);
    defer s.deinit();

    try s.set("key1", "value1", 0);
    try s.set("key1", "value2", 0);

    const result = try s.get("key1");
    defer if (result) |r| testing.allocator.free(r);
    try testing.expectEqualStrings("value2", result.?);
}

test "store: delete existing key" {
    const dir = try tmpDir(testing.allocator, "store_delete");
    defer testing.allocator.free(dir);

    var s = try Store.init(testing.allocator, std.testing.io, dir);
    defer s.deinit();

    try s.set("key_to_delete", "value", 0);
    try s.delete("key_to_delete");
    const result = try s.get("key_to_delete");
    try testing.expect(result == null);
}

test "store: delete non-existent key is no-op" {
    const dir = try tmpDir(testing.allocator, "store_del_miss");
    defer testing.allocator.free(dir);

    var s = try Store.init(testing.allocator, std.testing.io, dir);
    defer s.deinit();

    try s.delete("never_set");
}

test "store: expiry — get returns null after TTL" {
    const dir = try tmpDir(testing.allocator, "store_expiry");
    defer testing.allocator.free(dir);

    var s = try Store.init(testing.allocator, std.testing.io, dir);
    defer s.deinit();

    try s.set("ephemeral", "data", 1);
    // 注意 nsec 必须 < 1e9：曾写 1200ms 的纯 nsec (1.2e9) 触发 EINVAL 零睡眠，
    // 使本测试从未真正等到过期。1.3s > TTL 1s，秒级时间戳下必然过期。
    _ = std.c.nanosleep(&.{ .sec = 1, .nsec = 300 * std.time.ns_per_ms }, null);
    const result = try s.get("ephemeral");
    defer if (result) |r| testing.allocator.free(r);
    try testing.expect(result == null); // 曾缺失此核心断言
}

test "store: cleanExpired removes expired entries" {
    const dir = try tmpDir(testing.allocator, "store_clean");
    defer testing.allocator.free(dir);

    var s = try Store.init(testing.allocator, std.testing.io, dir);
    defer s.deinit();

    try s.set("expire_soon", "data", 1);
    try s.set("permanent", "forever", 0);

    _ = std.c.nanosleep(&.{ .sec = 1, .nsec = 300 * std.time.ns_per_ms }, null);

    const cleaned = try s.cleanExpired();
    try testing.expectEqual(@as(usize, 1), cleaned); // 曾写 `_ = cleaned` 无断言

    const gone = try s.get("expire_soon");
    defer if (gone) |r| testing.allocator.free(r);
    try testing.expect(gone == null);

    const perm = try s.get("permanent");
    defer if (perm) |r| testing.allocator.free(r);
    try testing.expect(perm != null);
}

test "store: cleanExpired handles empty directory" {
    const dir = try tmpDir(testing.allocator, "store_clean_empty");
    defer testing.allocator.free(dir);

    var s = try Store.init(testing.allocator, std.testing.io, dir);
    defer s.deinit();

    const cleaned = try s.cleanExpired();
    try testing.expectEqual(@as(usize, 0), cleaned);
}

test "store: cleanExpired skips tmp files" {
    const dir = try tmpDir(testing.allocator, "store_skip_tmp");
    defer testing.allocator.free(dir);

    var s = try Store.init(testing.allocator, std.testing.io, dir);
    defer s.deinit();

    try s.set("real_key", "value", 0);

    const cleaned = try s.cleanExpired();
    try testing.expectEqual(@as(usize, 0), cleaned);
}

test "store: binary key and value" {
    const dir = try tmpDir(testing.allocator, "store_binary");
    defer testing.allocator.free(dir);

    var s = try Store.init(testing.allocator, std.testing.io, dir);
    defer s.deinit();

    const key: [4]u8 = .{ 0x00, 0xff, 0xab, 0x42 };
    const value: [4]u8 = .{ 0xde, 0xad, 0xbe, 0xef };

    try s.set(&key, &value, 0);
    const result = try s.get(&key);
    defer if (result) |r| testing.allocator.free(r);
    try testing.expect(result != null);
    try testing.expectEqualSlices(u8, &value, result.?);
}

test "store: empty key returns error" {
    const dir = try tmpDir(testing.allocator, "store_empty_key");
    defer testing.allocator.free(dir);

    var s = try Store.init(testing.allocator, std.testing.io, dir);
    defer s.deinit();

    try testing.expectError(error.InvalidKey, s.set("", "value", 0));
    try testing.expectError(error.InvalidKey, s.get(""));
    try testing.expectError(error.InvalidKey, s.delete(""));
}

test "store: key at MAX_KEY_LEN works, over limit rejected (regression)" {
    // 回归：MAX_KEY_LEN 曾为 256，hex 文件名 512 字节超过文件系统 255 上限，
    // key ≥ 126 时 set() 必然失败 — 上限本身不可实现。
    const dir = try tmpDir(testing.allocator, "store_max_key");
    defer testing.allocator.free(dir);

    var s = try Store.init(testing.allocator, std.testing.io, dir);
    defer s.deinit();

    const max_key = [_]u8{'k'} ** MAX_KEY_LEN;
    try s.set(&max_key, "v", 0);
    const result = try s.get(&max_key);
    defer if (result) |r| testing.allocator.free(r);
    try testing.expectEqualStrings("v", result.?);

    const over_key = [_]u8{'k'} ** (MAX_KEY_LEN + 1);
    try testing.expectError(error.InvalidKey, s.set(&over_key, "v", 0));
    try testing.expectError(error.InvalidKey, s.get(&over_key));
    try testing.expectError(error.InvalidKey, s.delete(&over_key));
}

test "store: empty value round-trips, distinct from missing key" {
    const dir = try tmpDir(testing.allocator, "store_empty_value");
    defer testing.allocator.free(dir);

    var s = try Store.init(testing.allocator, std.testing.io, dir);
    defer s.deinit();

    try s.set("empty", "", 0);
    const result = try s.get("empty");
    try testing.expect(result != null); // 曾把空值当作"不存在"返回 null
    try testing.expectEqual(@as(usize, 0), result.?.len);
    testing.allocator.free(result.?);

    const missing = try s.get("never_set");
    try testing.expect(missing == null);
}
