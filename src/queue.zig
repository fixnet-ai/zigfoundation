//! 跨线程有界队列 — 基于环形缓冲区 + mutex + ResetEvent
//!
//! 从 zproxy/src/core/queue.zig 提取，泛型化以支持任意元素类型。
//!
//! ## 设计
//!
//! - **Queue(T, capacity)**: 固定容量的环形缓冲区，由 `pthread_mutex_t` 和 `ResetEvent` 保护。
//!   生产者调用 `push()`，消费者调用 `tryPop()` 或 `drain()`。
//!   每次 `push()` 时设置 `event`，队列排空时重置，消费者可在批次之间阻塞于 `wait()`。
//!
//! - 原 zproxy 中的 `CommandQueue`（含 Command 联合体）和 `MonitorQueue`（含 NetworkEvent）
//!   均为此泛型 `Queue(T)` 的特化。
//!
//! ## 溢出行为
//!
//! 当 `push()` 时所有槽已满，**最旧**的条目被丢弃（在 head 指针处覆盖）。
//! 这以丢失最旧的排队条目为代价，保护消费者不被大量低优先级事件淹没。
//!
//! ## 线程安全
//!
//! - 生产和消费可跨线程并发
//! - `len()` 仅返回快照值，调用后可能立即变化

const std = @import("std");
const builtin = @import("builtin");
const event_mod = @import("event.zig");

/// 跨平台互斥锁 — POSIX 使用 pthread_mutex_t，Windows 使用原子自旋锁。
const Mutex = if (builtin.os.tag == .windows)
    struct {
        locked: bool = false,

        fn lock(self: *@This()) void {
            while (@atomicRmw(bool, &self.locked, .Xchg, true, .acquire)) {
                std.atomic.spinLoopHint();
            }
        }

        fn unlock(self: *@This()) void {
            @atomicStore(bool, &self.locked, false, .release);
        }
    }
else
    std.c.pthread_mutex_t;

/// 返回固定容量环形缓冲区队列的类型。
///
/// `T` 是元素类型，`capacity` 是编译期固定的容量（默认 16）。
/// 生产者-消费者模式：一个生产者线程 + 一个消费者线程。
pub fn Queue(comptime T: type, comptime capacity: usize) type {
    return struct {
        mutex: Mutex = .{},
        event: event_mod.ResetEvent = .{},
        buffer: [capacity]T = undefined,
        head: usize = 0,
        tail: usize = 0,
        count: usize = 0,

        const Self = @This();

        /// Zig 0.16.0 不在 std.c 中导出 pthread_mutex_init / pthread_mutex_destroy（仅 POSIX 需要）。
        extern "c" fn pthread_mutex_init(
            mutex: *std.c.pthread_mutex_t,
            attr: ?*const anyopaque,
        ) std.c.E;
        extern "c" fn pthread_mutex_destroy(mutex: *std.c.pthread_mutex_t) std.c.E;

        /// 初始化 mutex 和 event。首次使用前必须调用。
        pub fn init(self: *Self) void {
            if (builtin.os.tag != .windows) {
                _ = pthread_mutex_init(&self.mutex, null);
            }
            self.event.init();
        }

        /// 销毁 mutex 和 event。在 `init()` 之后仅调用一次。
        pub fn deinit(self: *Self) void {
            self.event.deinit();
            if (builtin.os.tag != .windows) {
                _ = pthread_mutex_destroy(&self.mutex);
            }
        }

        fn lockMutex(self: *Self) void {
            if (builtin.os.tag == .windows) {
                self.mutex.lock();
            } else {
                _ = std.c.pthread_mutex_lock(&self.mutex);
            }
        }

        fn unlockMutex(self: *Self) void {
            if (builtin.os.tag == .windows) {
                self.mutex.unlock();
            } else {
                _ = std.c.pthread_mutex_unlock(&self.mutex);
            }
        }

        /// 入队 `item`。如果队列已满，最旧的条目被覆盖（丢弃）。
        /// 始终通过 `event.set()` 唤醒消费者。
        pub fn push(self: *Self, item: T) void {
            self.lockMutex();
            if (self.count < capacity) {
                self.buffer[self.tail] = item;
                self.tail = (self.tail + 1) % capacity;
                self.count += 1;
            } else {
                // 溢出：覆盖最旧的条目（在 head），推进 head。
                self.buffer[self.head] = item;
                self.head = (self.head + 1) % capacity;
            }
            self.unlockMutex();
            self.event.set();
        }

        /// FIFO 出队。队列空时返回 `null`。
        /// 队列排空时重置 event，使下一次 `wait()` 阻塞直到下一次 `push()`。
        pub fn tryPop(self: *Self) ?T {
            self.lockMutex();
            defer self.unlockMutex();
            if (self.count == 0) return null;
            const item = self.buffer[self.head];
            self.head = (self.head + 1) % capacity;
            self.count -= 1;
            if (self.count == 0) self.event.reset();
            return item;
        }

        /// 批量出队最多 `out.len` 个条目到 `out`，保持 FIFO 顺序。
        /// 返回实际出队的条目数。队列空时提前停止。
        /// 队列排空时重置 event。
        pub fn drain(self: *Self, out: []T) usize {
            if (out.len == 0) return 0;
            self.lockMutex();
            defer self.unlockMutex();
            const n = @min(self.count, out.len);
            for (out[0..n]) |*slot| {
                slot.* = self.buffer[self.head];
                self.head = (self.head + 1) % capacity;
            }
            self.count -= n;
            if (self.count == 0) self.event.reset();
            return n;
        }

        /// 阻塞直到至少调用一次 `push()`。多个等待者同时唤醒（广播风格）。
        /// 结构体在等待期间必须保持地址稳定。
        pub fn wait(self: *Self) void {
            self.event.wait();
        }

        /// 当前排队的条目数。仅快照值，调用后可能立即变化。
        pub fn len(self: *const Self) usize {
            return self.count;
        }
    };
}

// ============================================================================
// 测试
// ============================================================================

const testing = std.testing;

// 为测试定义具体类型
const TestQueue = Queue(u32, 16);
const SmallQueue = Queue(u32, 4);

test "queue: push/pop FIFO order" {
    var q: TestQueue = .{};
    q.init();
    defer q.deinit();
    try testing.expectEqual(@as(usize, 0), q.len());
    q.push(42);
    try testing.expectEqual(@as(usize, 1), q.len());
    const got = q.tryPop();
    try testing.expect(got != null);
    try testing.expectEqual(@as(u32, 42), got.?);
    try testing.expectEqual(@as(usize, 0), q.len());
    try testing.expect(q.tryPop() == null);
}

test "queue: overflow overwrites oldest" {
    var q: SmallQueue = .{};
    q.init();
    defer q.deinit();
    // 填满 4 个槽
    for (0..4) |i| q.push(@intCast(i));
    try testing.expectEqual(@as(usize, 4), q.len());

    // 第 5 次 push 覆盖最旧的。计数保持 4，head 前进经过被覆盖的槽。
    q.push(99);
    try testing.expectEqual(@as(usize, 4), q.len());

    // 排空全部 4 个。前 3 个应是被覆盖槽之后的下一个最旧条目。
    // 最后一个应是被覆盖槽（在缓冲区环绕后到达）。
    const first = q.tryPop();
    try testing.expect(first != null);
    try testing.expectEqual(@as(u32, 1), first.?);

    for (0..2) |_| _ = q.tryPop();

    const last = q.tryPop();
    try testing.expect(last != null);
    try testing.expectEqual(@as(u32, 99), last.?);

    try testing.expect(q.tryPop() == null);
}

test "queue: cross-thread push/tryPop" {
    var q: TestQueue = .{};
    q.init();
    defer q.deinit();

    const Ctx = struct { q: *TestQueue };
    var ctx = Ctx{ .q = &q };
    const Worker = struct {
        fn run(c: *Ctx) void {
            _ = std.c.nanosleep(&.{ .sec = 0, .nsec = 50 * std.time.ns_per_ms }, null);
            c.q.push(77);
        }
    };
    const handle = try std.Thread.spawn(.{}, Worker.run, .{&ctx});
    q.wait();
    const got = q.tryPop();
    try testing.expect(got != null);
    try testing.expectEqual(@as(u32, 77), got.?);
    handle.join();
}

test "queue: drain empties" {
    var q: TestQueue = .{};
    q.init();
    defer q.deinit();
    q.push(10);
    q.push(20);
    q.push(30);

    var buf: [4]u32 = undefined;
    const n = q.drain(&buf);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqual(@as(u32, 10), buf[0]);
    try testing.expectEqual(@as(u32, 20), buf[1]);
    try testing.expectEqual(@as(u32, 30), buf[2]);
    try testing.expect(q.tryPop() == null);
}

test "queue: drain respects out buffer size" {
    var q: TestQueue = .{};
    q.init();
    defer q.deinit();
    q.push(1);
    q.push(2);
    q.push(3);

    var buf: [2]u32 = undefined;
    const n = q.drain(&buf);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(@as(usize, 1), q.len());
}

test "queue: drain on empty queue returns zero" {
    var q: TestQueue = .{};
    q.init();
    defer q.deinit();

    var buf: [4]u32 = undefined;
    const n = q.drain(&buf);
    try testing.expectEqual(@as(usize, 0), n);
}

test "queue: custom capacity queue" {
    // 使用自定义容量的队列
    const TinyQueue = Queue(u8, 2);
    var q: TinyQueue = .{};
    q.init();
    defer q.deinit();
    q.push(1);
    q.push(2);
    try testing.expectEqual(@as(usize, 2), q.len());
    q.push(3); // 覆盖最旧的
    try testing.expectEqual(@as(usize, 2), q.len());
    const got = q.tryPop();
    try testing.expect(got != null);
    try testing.expectEqual(@as(u8, 2), got.?);
}
