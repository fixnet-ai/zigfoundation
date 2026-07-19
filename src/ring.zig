//! 环形缓冲区 — 通用 SPSC (Single Producer, Single Consumer)
//!
//! 固定容量、无锁设计，使用原子操作同步读写指针。
//! 容量必须为 2 的幂，以便用位掩码代替取模运算。
//!
//! 提取自 zigproxy/src/ringbuf.zig，适配 Zig 0.16.0。

const std = @import("std");
const assert = std.debug.assert;

/// 泛型 SPSC 环形缓冲区，容量 capacity 必须是 2 的幂。
/// 导出类型 `RingBuf(T)` — 底层元素类型参数化。
pub fn RingBuf(comptime T: type) type {
    return struct {
        const Self = @This();

        buf: []T,
        mask: usize,
        head: std.atomic.Value(usize) align(std.atomic.cache_line),
        tail: std.atomic.Value(usize) align(std.atomic.cache_line),

        /// 初始化环形缓冲区。buf.len 必须是 2 的幂。
        pub fn init(buf: []T) Self {
            assert(std.math.isPowerOfTwo(buf.len));
            return .{
                .buf = buf,
                .mask = buf.len - 1,
                .head = std.atomic.Value(usize).init(0),
                .tail = std.atomic.Value(usize).init(0),
            };
        }

        /// 当前已写入的元素数量。
        pub fn len(self: *const Self) usize {
            const h = self.head.load(.acquire);
            const t = self.tail.load(.acquire);
            return t - h;
        }

        /// 容量（最多可容纳元素数）。
        pub fn capacity(self: *const Self) usize {
            return self.buf.len;
        }

        /// 可写入空间。
        pub fn availableWrite(self: *const Self) usize {
            return self.capacity() - self.len();
        }

        /// 可读元素数量（等价于 len）。
        pub fn availableRead(self: *const Self) usize {
            return self.len();
        }

        /// 缓冲区是否已满。
        pub fn isFull(self: *const Self) bool {
            return self.len() == self.capacity();
        }

        /// 缓冲区是否为空。
        pub fn isEmpty(self: *const Self) bool {
            return self.len() == 0;
        }

        /// 写入单个元素。调用者保证有空间（isFull() == false）。
        pub fn push(self: *Self, item: T) void {
            const t = self.tail.load(.acquire);
            const idx = t & self.mask;
            self.buf[idx] = item;
            self.tail.store(t + 1, .release);
        }

        /// 读取单个元素。调用者保证有数据（isEmpty() == false）。
        pub fn pop(self: *Self) T {
            const h = self.head.load(.acquire);
            const idx = h & self.mask;
            const item = self.buf[idx];
            self.head.store(h + 1, .release);
            return item;
        }

        /// 批量写入，返回实际写入数量。
        /// 返回值为实际写入的元素数量（<= items.len）。
        pub fn pushSlice(self: *Self, items: []const T) usize {
            const avail = self.availableWrite();
            const n = @min(items.len, avail);
            var i: usize = 0;
            const t = self.tail.load(.acquire);
            while (i < n) : (i += 1) {
                const idx = (t + i) & self.mask;
                self.buf[idx] = items[i];
            }
            self.tail.store(t + n, .release);
            return n;
        }

        /// 批量读取，返回实际读取数量。
        /// 读取的数据直接写入 dest，返回实际读取数量。
        pub fn popSlice(self: *Self, dest: []T) usize {
            const avail = self.availableRead();
            const n = @min(dest.len, avail);
            var i: usize = 0;
            const h = self.head.load(.acquire);
            while (i < n) : (i += 1) {
                const idx = (h + i) & self.mask;
                dest[i] = self.buf[idx];
            }
            self.head.store(h + n, .release);
            return n;
        }

        /// 尝试写入单个元素，满时返回 false。
        pub fn tryPush(self: *Self, item: T) bool {
            if (self.isFull()) return false;
            self.push(item);
            return true;
        }

        /// 尝试读取单个元素，空时返回 null。
        pub fn tryPop(self: *Self) ?T {
            if (self.isEmpty()) return null;
            return self.pop();
        }
    };
}

// ============================================================
// 测试
// ============================================================

const testing = std.testing;

test "ring: reference all pub decls (lazy-analysis guard)" {
    testing.refAllDecls(@This());
}

test "ring: basic push/pop" {
    var buf: [4]u32 = undefined;
    var rb = RingBuf(u32).init(&buf);

    try testing.expect(rb.isEmpty());
    try testing.expect(!rb.isFull());

    rb.push(10);
    rb.push(20);
    try testing.expectEqual(@as(usize, 2), rb.len());

    try testing.expectEqual(@as(u32, 10), rb.pop());
    try testing.expectEqual(@as(u32, 20), rb.pop());
    try testing.expect(rb.isEmpty());
}

test "ring: tryPush/tryPop" {
    var buf: [2]u32 = undefined;
    var rb = RingBuf(u32).init(&buf);

    try testing.expect(rb.tryPush(1));
    try testing.expect(rb.tryPush(2));
    try testing.expect(!rb.tryPush(3)); // full

    try testing.expectEqual(@as(u32, 1), rb.tryPop().?);
    try testing.expectEqual(@as(u32, 2), rb.tryPop().?);
    try testing.expectEqual(@as(?u32, null), rb.tryPop()); // empty
}

test "ring: wrap-around" {
    var buf: [4]u32 = undefined;
    var rb = RingBuf(u32).init(&buf);

    // fill, drain, fill again — tests wrap-around
    rb.push(1);
    rb.push(2);
    try testing.expectEqual(@as(u32, 1), rb.pop());
    rb.push(3);
    rb.push(4);
    rb.push(5);
    try testing.expectEqual(@as(u32, 2), rb.pop());
    try testing.expectEqual(@as(u32, 3), rb.pop());
    try testing.expectEqual(@as(u32, 4), rb.pop());
    try testing.expectEqual(@as(u32, 5), rb.pop());
    try testing.expect(rb.isEmpty());
}

test "ring: pushSlice/popSlice" {
    var buf: [8]u32 = undefined;
    var rb = RingBuf(u32).init(&buf);

    const src = [_]u32{ 1, 2, 3, 4, 5 };
    const n = rb.pushSlice(&src);
    try testing.expectEqual(@as(usize, 5), n);

    var dest: [8]u32 = [_]u32{0} ** 8;
    const m = rb.popSlice(&dest);
    try testing.expectEqual(@as(usize, 5), m);
    try testing.expectEqualSlices(u32, &[_]u32{ 1, 2, 3, 4, 5 }, dest[0..5]);
}

test "ring: partial pushSlice when full" {
    var buf: [4]u32 = undefined;
    var rb = RingBuf(u32).init(&buf);

    const src = [_]u32{ 1, 2, 3, 4, 5, 6 };
    const n = rb.pushSlice(&src);
    try testing.expectEqual(@as(usize, 4), n);

    var dest: [8]u32 = [_]u32{0} ** 8;
    const m = rb.popSlice(&dest);
    try testing.expectEqual(@as(usize, 4), m);
    try testing.expectEqualSlices(u32, &[_]u32{ 1, 2, 3, 4 }, dest[0..4]);
}
