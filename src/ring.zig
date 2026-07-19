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
        /// 批量写入。处理环形缓冲区绕回：先写 end 到 buf 末尾，再写剩余到 buf 开头。
        /// 使用 @memcpy 一次性拷贝连续区间，LLVM 自动向量化。
        pub fn pushSlice(self: *Self, items: []const T) usize {
            const avail = self.availableWrite();
            const n = @min(items.len, avail);
            if (n == 0) return 0;
            const t = self.tail.load(.acquire);
            const start = t & self.mask;
            const first = @min(n, self.buf.len - start);
            @memcpy(self.buf[start .. start + first], items[0..first]);
            if (first < n) {
                const second = n - first;
                @memcpy(self.buf[0..second], items[first..n]);
            }
            self.tail.store(t + n, .release);
            return n;
        }

        /// 批量读取。处理环形缓冲区绕回：先从 head 读至 buf 末尾，再从 buf 开头读剩余。
        /// 使用 @memcpy 一次性拷贝连续区间，LLVM 自动向量化。
        pub fn popSlice(self: *Self, dest: []T) usize {
            const avail = self.availableRead();
            const n = @min(dest.len, avail);
            if (n == 0) return 0;
            const h = self.head.load(.acquire);
            const start = h & self.mask;
            const first = @min(n, self.buf.len - start);
            @memcpy(dest[0..first], self.buf[start .. start + first]);
            if (first < n) {
                const second = n - first;
                @memcpy(dest[first..n], self.buf[0..second]);
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

        // ---- 零拷贝接口 ----

        /// 获取可写入的连续区间。最多返回 max_n 字节，受环形缓冲区绕回边界
        /// 限制可能更少。调用者直接写入返回的切片，然后调用 commitWrite(n)。
        pub fn writeSpan(self: *Self, max_n: usize) []T {
            const avail = self.availableWrite();
            const n = @min(max_n, avail);
            if (n == 0) return &.{};
            const t = self.tail.load(.acquire);
            const start = t & self.mask;
            const contiguous = @min(n, self.buf.len - start);
            return self.buf[start .. start + contiguous];
        }

        /// 提交写入 n 字节，推进 tail。必须先调用 writeSpan() 获取可写区间。
        pub fn commitWrite(self: *Self, n: usize) void {
            assert(n > 0);
            const t = self.tail.load(.acquire);
            self.tail.store(t + n, .release);
        }

        /// 获取可读取的连续区间（零拷贝读取）。返回的切片指向内部缓冲区，
        /// 受绕回边界限制可能少于全部可读数据。调用者处理后调用 commitRead(n)。
        pub fn readSpan(self: *Self) []const T {
            const avail = self.availableRead();
            if (avail == 0) return &.{};
            const h = self.head.load(.acquire);
            const start = h & self.mask;
            const contiguous = @min(avail, self.buf.len - start);
            return self.buf[start .. start + contiguous];
        }

        /// 提交读取 n 字节，推进 head。必须先调用 readSpan() 获取可读区间。
        pub fn commitRead(self: *Self, n: usize) void {
            assert(n > 0);
            const h = self.head.load(.acquire);
            self.head.store(h + n, .release);
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

// ---- 零拷贝接口测试 ----

test "ring: writeSpan/commitWrite round-trip" {
    var buf: [8]u32 = undefined;
    var rb = RingBuf(u32).init(&buf);

    const span = rb.writeSpan(5);
    try testing.expect(span.len >= 5);
    span[0] = 10;
    span[1] = 20;
    span[2] = 30;
    span[3] = 40;
    span[4] = 50;
    rb.commitWrite(5);
    try testing.expectEqual(@as(usize, 5), rb.len());

    var dest: [8]u32 = [_]u32{0} ** 8;
    const m = rb.popSlice(&dest);
    try testing.expectEqual(@as(usize, 5), m);
    try testing.expectEqualSlices(u32, &[_]u32{ 10, 20, 30, 40, 50 }, dest[0..5]);
}

test "ring: readSpan/commitRead round-trip" {
    var buf: [8]u32 = undefined;
    var rb = RingBuf(u32).init(&buf);

    const src = [_]u32{ 100, 200, 300 };
    _ = rb.pushSlice(&src);

    const span = rb.readSpan();
    try testing.expectEqual(@as(usize, 3), span.len);
    try testing.expectEqual(@as(u32, 100), span[0]);
    try testing.expectEqual(@as(u32, 200), span[1]);
    try testing.expectEqual(@as(u32, 300), span[2]);
    rb.commitRead(3);
    try testing.expect(rb.isEmpty());
}

test "ring: zero-copy span truncated at wraparound" {
    var buf: [4]u32 = undefined;
    var rb = RingBuf(u32).init(&buf);

    // 写入 2 个，读走 2 个 → head=2, tail=2
    rb.push(1);
    rb.push(2);
    _ = rb.pop();
    _ = rb.pop();

    // 写入 3 个 — 绕回：buf[2], buf[3], buf[0]
    rb.push(3);
    rb.push(4);
    rb.push(5);

    // 总共 3 个可读，但 readSpan 只能返回连续的 2 个（buf[2..4]）
    const span = rb.readSpan();
    try testing.expectEqual(@as(usize, 2), span.len);
    try testing.expectEqual(@as(u32, 3), span[0]);
    try testing.expectEqual(@as(u32, 4), span[1]);

    // 提交读取 2 个后，剩余的 buf[0] 变为连续可读
    rb.commitRead(2);
    const span2 = rb.readSpan();
    try testing.expectEqual(@as(usize, 1), span2.len);
    try testing.expectEqual(@as(u32, 5), span2[0]);
    rb.commitRead(1);
    try testing.expect(rb.isEmpty());
}

test "ring: writeSpan wraparound limit" {
    var buf: [4]u32 = undefined;
    var rb = RingBuf(u32).init(&buf);

    // 写入 1 个，读走 1 个 → head=1, tail=1
    rb.push(99);
    _ = rb.pop();

    // 写入 3 个 → tail=4, 可写空间 = 4 - 3 = 1
    rb.push(1);
    rb.push(2);
    rb.push(3);

    // writeSpan 可写 1 个，但受绕回边界限制
    // tail=4, mask=3, start=0, buf.len=4 → contiguous = min(1, 4) = 1
    const span = rb.writeSpan(10);
    try testing.expectEqual(@as(usize, 1), span.len);
    span[0] = 42;
    rb.commitWrite(1);

    // 读走所有数据，验证 42 在正确位置
    var dest: [4]u32 = [_]u32{0} ** 4;
    _ = rb.popSlice(&dest);
    try testing.expectEqual(@as(u32, 1), dest[0]);
    try testing.expectEqual(@as(u32, 2), dest[1]);
    try testing.expectEqual(@as(u32, 3), dest[2]);
    try testing.expectEqual(@as(u32, 42), dest[3]);
}

test "ring: writeSpan on full buffer returns empty" {
    var buf: [4]u32 = undefined;
    var rb = RingBuf(u32).init(&buf);
    _ = rb.pushSlice(&[_]u32{ 1, 2, 3, 4 });

    const span = rb.writeSpan(10);
    try testing.expectEqual(@as(usize, 0), span.len);
}

test "ring: readSpan on empty buffer returns empty" {
    var buf: [4]u32 = undefined;
    var rb = RingBuf(u32).init(&buf);

    const span = rb.readSpan();
    try testing.expectEqual(@as(usize, 0), span.len);
}
