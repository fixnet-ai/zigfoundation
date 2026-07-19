//! 进程内异步内存连接 — 基于 libxev Completion 模型。
//!
//! ## 用途
//!
//! 同一进程内多个网络模块（TUN、Proxy、Outbound）通过 socket-like 异步接口进行
//! 跨线程数据交换，不走内核网络栈。基于 `RingBuf` + `xev.Async` 纯内存实现，
//! 完全融入 libxev 事件循环。
//!
//! ## 核心约束：Completion 生命周期
//!
//! **Completion 必须存活到回调触发之后。** 内核（kqueue/epoll/IOCP）的 kevent
//! `udata` 存储的是 `*xev.Completion` 指针，如果在回调触发前 Completion 内存被释放，
//! 会导致 use-after-free。
//!
//! **生产代码的正确模式**（参照 zigproxy）：
//! - Completion 嵌入堆分配的连接结构体，生命周期覆盖整个连接
//! - **单个** xev.Loop 实例，由事件循环线程独占执行 loop.run()
//! - 跨线程通信仅用 notify()（线程安全），无需多个 Loop
//!
//! 本模块测试中使用双 Loop 是因为测试用栈变量做 Completion 且线程提前退出——
//! 这是测试的权宜之计，不是设计模式。不要在生产代码中模仿。
//!
//! ## 架构
//!
//! ```
//! SharedState(buf_size)           — 堆分配，引用计数管理
//!   ├─ RingBuf(u8) ×2             — 每方向一个无锁环形缓冲 (SPSC)
//!   ├─ xev.Async ×4               — 每端点独立的读/写通知器
//!   └─ atomic(bool)               — 关闭标志
//!
//! MemStream                         — 轻量句柄（指针语义，无所有权）
//!   ├─ read/write/close           — Completion 回调接口
//!   └─ 可选 refcounted 清理       — createPair / Registry 用
//! ```
//!
//! ## 使用方式（生产代码示例）
//!
//! 1. **createPair — 单 Loop，堆分配 Completion**：
//!    ```zig
//!    const ConnCtx = struct {
//!        conn: memconn.MemStream,
//!        read_c: xev.Completion,   // Completion 嵌入连接结构体（堆分配）
//!        write_c: xev.Completion,
//!        buf: [4096]u8,
//!    };
//!
//!    var ctx = try allocator.create(ConnCtx);
//!    ctx.conn = pair.local;
//!    // 注册读/写（Completion 存活到回调或 deinit）
//!    ctx.conn.read(loop, &ctx.read_c, &ctx.buf, ConnCtx, ctx, readCb);
//!    // 循环在单独线程运行 loop.run(.until_done)
//!    ```
//!
//! 2. **跨线程通知**（无需第二个 Loop）：
//!    ```zig
//!    // 线程 A：事件循环线程
//!    ctx.conn.read(loop, &ctx.read_c, &ctx.buf, ConnCtx, ctx, readCb);
//!    loop.run(.until_done);  // 阻塞，等待回调
//!
//!    // 线程 B：业务线程，写入数据触发对端回调
//!    peer_conn.write(loop, &ctx.write_c, data, ConnCtx, ctx, writeCb);
//!    // write 内部调用 peer_read_async.notify() 唤醒线程 A 的 loop
//!    ```
//!
//! 3. **命名连接** — 通过 Registry 按名称发现：
//!    ```zig
//!    var reg = try memconn.Registry.init(allocator);
//!    defer reg.deinit();
//!    _ = try reg.listen("tun");
//!    // 在不同线程:
//!    var conn = try reg.dial(4096, "tun");
//!    ```
//!
//! ## 线程安全
//!
//! - 每方向 SPSC（单生产者单消费者）：一个线程写，对端线程读
//! - 同一 MemStream 不可从多线程并发 read/write
//! - close() 可从任意线程安全调用
//! - Registry 由 Mutex 保护，线程安全
//! - 不同操作必须使用不同的 Completion（read/write/close 各用各的）
//! - xev.Async.notify() 线程安全：可在任意线程调用以唤醒事件循环
//! - COMPLETION 生命周期约束：必须存活到回调触发之后（堆分配，勿栈分配跨线程）

const std = @import("std");
const builtin = @import("builtin");
const ring_mod = @import("ring.zig");
const xev = @import("xev");

const RingBuf = ring_mod.RingBuf;

// ============================================================================
// 错误集
// ============================================================================

pub const MemStreamError = error{
    Closed,
    NameNotFound,
    NameInUse,
    NotInitialized,
    OutOfMemory,
};

// ============================================================================
// SharedState — 堆分配管道的引用计数包装
// ============================================================================

fn SharedState(comptime buf_size: usize) type {
    if (!std.math.isPowerOfTwo(buf_size)) {
        @compileError("memconn: buf_size must be a power of 2, got " ++
            std.fmt.comptimePrint("{d}", .{buf_size}));
    }

    return struct {
        const Self = @This();

        a_to_b_buf: [buf_size]u8 = undefined,
        b_to_a_buf: [buf_size]u8 = undefined,
        a_to_b_ring: RingBuf(u8) = undefined,
        b_to_a_ring: RingBuf(u8) = undefined,
        closed: std.atomic.Value(bool) = .init(false),
        refcount: std.atomic.Value(u32) = .init(2),
        allocator: std.mem.Allocator,
        a_read_async: xev.Async,
        a_write_async: xev.Async,
        b_read_async: xev.Async,
        b_write_async: xev.Async,

        fn init(allocator: std.mem.Allocator) !*Self {
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);

            self.* = .{
                .allocator = allocator,
                .a_read_async = try xev.Async.init(),
                .a_write_async = try xev.Async.init(),
                .b_read_async = try xev.Async.init(),
                .b_write_async = try xev.Async.init(),
            };
            errdefer {
                self.a_read_async.deinit();
                self.a_write_async.deinit();
                self.b_read_async.deinit();
                self.b_write_async.deinit();
            }
            self.a_to_b_ring = RingBuf(u8).init(&self.a_to_b_buf);
            self.b_to_a_ring = RingBuf(u8).init(&self.b_to_a_buf);
            self.closed.store(false, .release);
            return self;
        }

        fn deinit(self: *Self) void {
            self.a_read_async.deinit();
            self.a_write_async.deinit();
            self.b_read_async.deinit();
            self.b_write_async.deinit();
            self.allocator.destroy(self);
        }

        fn release(ptr: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            if (self.refcount.fetchSub(1, .release) == 1) {
                self.deinit();
            }
        }
    };
}

// ============================================================================
// MemStream — 异步 Completion 句柄
// ============================================================================

pub const MemStream = struct {
    tx_ring: *RingBuf(u8),
    rx_ring: *RingBuf(u8),
    self_read_async: *xev.Async,
    self_write_async: *xev.Async,
    peer_read_async: *xev.Async,
    peer_write_async: *xev.Async,
    closed: *std.atomic.Value(bool),
    _shared: ?*anyopaque = null,
    _shared_release: ?*const fn (*anyopaque) void = null,
    /// 当 true 时，close() 回调会释放 _shared 引用（Registry 模式）。
    /// 当 false 时，引用计数由 PairHandle.destroy() 管理。
    _close_releases: bool = false,
    allocator: std.mem.Allocator,

    /// 注册异步读操作。
    ///
    /// 回调触发时机：rx_ring 中有数据，或对端已关闭。
    /// 返回 0 且 isClosed() 为 true 表示 EOF。
    ///
    /// cb: fn (?*Userdata, *xev.Loop, *xev.Completion, []u8, error{Closed}!usize) xev.CallbackAction
    pub fn read(
        self: *const MemStream,
        loop: *xev.Loop,
        c: *xev.Completion,
        buf: []u8,
        comptime Userdata: type,
        userdata: ?*Userdata,
        comptime cb: *const fn (
            ud: ?*Userdata,
            l: *xev.Loop,
            c_inner: *xev.Completion,
            b: []u8,
            r: error{Closed}!usize,
        ) xev.CallbackAction,
    ) void {
        const S = ReadOp(Userdata, cb);
        const op = self.allocator.create(S) catch {
            // OOM: 立即回调错误
            _ = cb(userdata, loop, c, buf, 0);
            return;
        };
        op.* = .{
            .allocator = self.allocator,
            .memconn = self.*,
            .buf = buf,
            .userdata = userdata,
        };

        // 已有数据或已关闭 → 立即通知 self_read_async
        if (!self.rx_ring.isEmpty() or self.closed.load(.acquire)) {
            self.self_read_async.notify() catch {};
        }

        self.self_read_async.wait(loop, c, S, op, S.internalCb);
    }

    /// 注册异步写操作。
    ///
    /// 尽力写入 RingBuf 中的所有数据。缓冲区满时等待对端消费后继续。
    /// 回调返回实际写入的字节数。
    ///
    /// cb: fn (?*Userdata, *xev.Loop, *xev.Completion, []const u8, error{Closed}!usize) xev.CallbackAction
    pub fn write(
        self: *const MemStream,
        loop: *xev.Loop,
        c: *xev.Completion,
        buf: []const u8,
        comptime Userdata: type,
        userdata: ?*Userdata,
        comptime cb: *const fn (
            ud: ?*Userdata,
            l: *xev.Loop,
            c_inner: *xev.Completion,
            b: []const u8,
            r: error{Closed}!usize,
        ) xev.CallbackAction,
    ) void {
        if (buf.len == 0) {
            // 空写立即完成
            self.self_write_async.notify() catch {};
            const S = WriteOp(Userdata, cb);
            const op = self.allocator.create(S) catch {
                _ = cb(userdata, loop, c, buf, 0);
                return;
            };
            op.* = .{
                .allocator = self.allocator,
                .memconn = self.*,
                .buf = buf,
                .written = 0,
                .userdata = userdata,
            };
            self.self_write_async.wait(loop, c, S, op, S.internalCb);
            return;
        }

        // 尝试立即写入
        const n = self.tx_ring.pushSlice(buf);
        if (n > 0) {
            // 通知对端的读 async（数据已就绪）
            self.peer_read_async.notify() catch {};
        }

        if (self.closed.load(.acquire)) {
            _ = cb(userdata, loop, c, buf, error.Closed);
            return;
        }

        const S = WriteOp(Userdata, cb);
        const op = self.allocator.create(S) catch {
            _ = cb(userdata, loop, c, buf, n);
            return;
        };
        op.* = .{
            .allocator = self.allocator,
            .memconn = self.*,
            .buf = buf,
            .written = n,
            .userdata = userdata,
        };

        if (n >= buf.len) {
            // 全部写入 — 立即回调
            self.self_write_async.notify() catch {};
        }

        self.self_write_async.wait(loop, c, S, op, S.internalCb);
    }

    /// 异步关闭端点。
    ///
    /// 设置关闭标志，通知对端。完成时回调 cb。
    /// cb: fn (?*Userdata, *xev.Loop, *xev.Completion, void) xev.CallbackAction
    pub fn close(
        self: *const MemStream,
        loop: *xev.Loop,
        c: *xev.Completion,
        comptime Userdata: type,
        userdata: ?*Userdata,
        comptime cb: *const fn (
            ud: ?*Userdata,
            l: *xev.Loop,
            c_inner: *xev.Completion,
            r: void,
        ) xev.CallbackAction,
    ) void {
        // 幂等关闭：若已关闭则同步完成，避免在同一 Async 上注册多个 Completion。
        // Registry 模式下，不同 MemStream 共享同一 closed 标志，因此后关闭的
        // 连接在此处释放其引用计数（先关闭的连接在 CloseOp.internalCb 中释放）。
        if (self.closed.load(.acquire)) {
            _ = cb(userdata, loop, c, {});
            if (self._close_releases) {
                if (self._shared_release) |rfn| {
                    if (self._shared) |ptr| {
                        rfn(ptr);
                    }
                }
            }
            return;
        }
        self.closed.store(true, .release);

        // 通知对端的读和写 async（唤醒 pending read/write）
        self.peer_read_async.notify() catch {};
        self.peer_write_async.notify() catch {};

        const S = CloseOp(Userdata, cb);
        const op = self.allocator.create(S) catch {
            // OOM 时直接回调
            _ = cb(userdata, loop, c, {});
            return;
        };
        op.* = .{
            .allocator = self.allocator,
            .memconn = self.*,
            .userdata = userdata,
        };

        self.self_read_async.notify() catch {};
        self.self_read_async.wait(loop, c, S, op, S.internalCb);
    }

    pub fn isClosed(self: *const MemStream) bool {
        return self.closed.load(.acquire);
    }

    // ---- 零拷贝接口 ----

    /// 注册零拷贝异步读操作。
    ///
    /// 回调接收的 `[]const u8` 直接指向底层 RingBuf 内存——无 @memcpy。
    /// 切片仅在回调期间有效；回调返回后数据自动提交（推进 head）。
    /// 返回 0 且 isClosed() == true 表示 EOF。
    ///
    /// 注意：受环形缓冲区绕回限制，一次性可读的数据可能少于全部数据。
    /// 若需读取剩余数据，在回调中重新调用 readDirect() 即可。
    ///
    /// cb: fn (?*Userdata, *xev.Loop, *xev.Completion, []const u8, error{Closed}!usize) xev.CallbackAction
    pub fn readDirect(
        self: *const MemStream,
        loop: *xev.Loop,
        c: *xev.Completion,
        comptime Userdata: type,
        userdata: ?*Userdata,
        comptime cb: *const fn (
            ud: ?*Userdata,
            l: *xev.Loop,
            c_inner: *xev.Completion,
            b: []const u8,
            r: error{Closed}!usize,
        ) xev.CallbackAction,
    ) void {
        const S = ReadDirectOp(Userdata, cb);
        const op = self.allocator.create(S) catch {
            _ = cb(userdata, loop, c, &.{}, 0);
            return;
        };
        op.* = .{
            .allocator = self.allocator,
            .memconn = self.*,
            .userdata = userdata,
        };

        if (!self.rx_ring.isEmpty() or self.closed.load(.acquire)) {
            self.self_read_async.notify() catch {};
        }

        self.self_read_async.wait(loop, c, S, op, S.internalCb);
    }

    /// 注册零拷贝异步写操作。
    ///
    /// 写入 `n` 字节。回调接收直接指向 tx_ring 的 `[]u8` 可写切片
    /// （长度等于 n），调用者将数据写入切片后返回。切片仅在回调期间有效；
    /// 回调返回后自动提交（推进 tail）并通知对端。
    ///
    /// 若 RingBuf 空间不足，自动等待（re-arm）直到对端消费后空间释放。
    ///
    /// cb: fn (?*Userdata, *xev.Loop, *xev.Completion, []u8, error{Closed}!usize) xev.CallbackAction
    pub fn writeDirect(
        self: *const MemStream,
        loop: *xev.Loop,
        c: *xev.Completion,
        n: usize,
        comptime Userdata: type,
        userdata: ?*Userdata,
        comptime cb: *const fn (
            ud: ?*Userdata,
            l: *xev.Loop,
            c_inner: *xev.Completion,
            b: []u8,
            r: error{Closed}!usize,
        ) xev.CallbackAction,
    ) void {
        if (n == 0) {
            _ = cb(userdata, loop, c, &.{}, @as(usize, 0));
            return;
        }
        if (self.closed.load(.acquire)) {
            _ = cb(userdata, loop, c, &.{}, error.Closed);
            return;
        }

        const S = WriteDirectOp(Userdata, cb);
        const op = self.allocator.create(S) catch {
            _ = cb(userdata, loop, c, &.{}, error.Closed);
            return;
        };
        op.* = .{
            .allocator = self.allocator,
            .memconn = self.*,
            .n = n,
            .userdata = userdata,
        };

        self.self_write_async.notify() catch {};
        self.self_write_async.wait(loop, c, S, op, S.internalCb);
    }
};

// ============================================================================
// 操作状态（堆分配，在回调中释放）
// ============================================================================

fn ReadOp(comptime Userdata: type, comptime cb: anytype) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        memconn: MemStream,
        buf: []u8,
        userdata: ?*Userdata,

        fn internalCb(
            ud: ?*Self,
            loop: *xev.Loop,
            c: *xev.Completion,
            r: xev.Async.WaitError!void,
        ) xev.CallbackAction {
            const self = ud.?;
            _ = r catch {};

            if (self.memconn.closed.load(.acquire) and self.memconn.rx_ring.isEmpty()) {
                const action = cb(self.userdata, loop, c, self.buf, @as(usize, 0));
                self.allocator.destroy(self);
                return action;
            }

            if (!self.memconn.rx_ring.isEmpty()) {
                const n = self.memconn.rx_ring.popSlice(self.buf);
                // 通知对端的 write async：空间已释放，可继续写
                self.memconn.peer_write_async.notify() catch {};
                const action = cb(self.userdata, loop, c, self.buf, n);
                self.allocator.destroy(self);
                return action;
            }

            // 假唤醒：re-arm 等待下一次通知
            return .rearm;
        }
    };
}

fn WriteOp(comptime Userdata: type, comptime cb: anytype) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        memconn: MemStream,
        buf: []const u8,
        written: usize,
        userdata: ?*Userdata,

        fn internalCb(
            ud: ?*Self,
            loop: *xev.Loop,
            c: *xev.Completion,
            r: xev.Async.WaitError!void,
        ) xev.CallbackAction {
            const self = ud.?;
            _ = r catch {};

            if (self.memconn.closed.load(.acquire)) {
                const action = cb(self.userdata, loop, c, self.buf, error.Closed);
                self.allocator.destroy(self);
                return action;
            }

            // 尝试继续写
            const remaining = self.buf[self.written..];
            const n = self.memconn.tx_ring.pushSlice(remaining);
            if (n > 0) {
                // 通知对端的 read async：数据已就绪
                self.memconn.peer_read_async.notify() catch {};
            }
            self.written += n;

            if (self.written >= self.buf.len) {
                const action = cb(self.userdata, loop, c, self.buf, self.written);
                self.allocator.destroy(self);
                return action;
            }

            // 缓冲区满，等待对端消费
            return .rearm;
        }
    };
}

fn CloseOp(comptime Userdata: type, comptime cb: anytype) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        memconn: MemStream,
        userdata: ?*Userdata,

        fn internalCb(
            ud: ?*Self,
            loop: *xev.Loop,
            c: *xev.Completion,
            r: xev.Async.WaitError!void,
        ) xev.CallbackAction {
            const self = ud.?;
            _ = r catch {};

            const action = cb(self.userdata, loop, c, {});
            // 先捕获释放所需字段，再释放 self (CloseOp)
            const close_releases = self.memconn._close_releases;
            const release_fn = self.memconn._shared_release;
            const shared = self.memconn._shared;
            self.allocator.destroy(self);

            // 仅在 Registry 模式（_close_releases=true）下释放 shared state
            // PairHandle.destroy() 负责统一释放
            if (close_releases) {
                if (release_fn) |rfn| {
                    if (shared) |ptr| {
                        rfn(ptr);
                    }
                }
            }

            return action;
        }
    };
}

// ---- 零拷贝操作状态 ----

fn ReadDirectOp(comptime Userdata: type, comptime cb: anytype) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        memconn: MemStream,
        userdata: ?*Userdata,

        fn internalCb(
            ud: ?*Self,
            loop: *xev.Loop,
            c: *xev.Completion,
            r: xev.Async.WaitError!void,
        ) xev.CallbackAction {
            const self = ud.?;
            _ = r catch {};

            if (self.memconn.closed.load(.acquire) and self.memconn.rx_ring.isEmpty()) {
                const action = cb(self.userdata, loop, c, &.{}, @as(usize, 0));
                self.allocator.destroy(self);
                return action;
            }

            const span = self.memconn.rx_ring.readSpan();
            if (span.len > 0) {
                const action = cb(self.userdata, loop, c, span, span.len);
                self.memconn.rx_ring.commitRead(span.len);
                self.memconn.peer_write_async.notify() catch {};
                self.allocator.destroy(self);
                return action;
            }

            return .rearm;
        }
    };
}

fn WriteDirectOp(comptime Userdata: type, comptime cb: anytype) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        memconn: MemStream,
        n: usize,
        userdata: ?*Userdata,

        fn internalCb(
            ud: ?*Self,
            loop: *xev.Loop,
            c: *xev.Completion,
            r: xev.Async.WaitError!void,
        ) xev.CallbackAction {
            const self = ud.?;
            _ = r catch {};

            if (self.memconn.closed.load(.acquire)) {
                const action = cb(self.userdata, loop, c, &.{}, error.Closed);
                self.allocator.destroy(self);
                return action;
            }

            const span = self.memconn.tx_ring.writeSpan(self.n);
            if (span.len < self.n) {
                // 空间不足，等待对端消费
                return .rearm;
            }

            const exact_span = span[0..self.n];
            const action = cb(self.userdata, loop, c, exact_span, self.n);
            self.memconn.tx_ring.commitWrite(self.n);
            self.memconn.peer_read_async.notify() catch {};
            self.allocator.destroy(self);
            return action;
        }
    };
}

// ============================================================================
// createPair / PairHandle
// ============================================================================

pub const PairHandle = struct {
    local: MemStream,
    remote: MemStream,

    /// 释放共享状态（同步，调用前确保无 pending completions）。
    ///
    /// 设置关闭标志、通知对端 pending 操作，然后释放两个引用计数。
    /// 不可多次调用 — 引用计数 2→0 后 SharedState 被释放，重复调用导致 use-after-free。
    pub fn destroy(self: *PairHandle) void {
        self.local.closed.store(true, .release);
        self.local.peer_read_async.notify() catch {};
        self.local.peer_write_async.notify() catch {};
        self.remote.closed.store(true, .release);
        self.remote.peer_read_async.notify() catch {};
        self.remote.peer_write_async.notify() catch {};

        const release_fn = self.local._shared_release orelse return;
        const shared = self.local._shared orelse return;
        release_fn(shared);
        release_fn(shared);
    }
};

pub fn createPair(
    comptime buf_size: usize,
    loop_a: *xev.Loop,
    loop_b: *xev.Loop,
    allocator: std.mem.Allocator,
) !PairHandle {
    _ = loop_a;
    _ = loop_b;

    const S = SharedState(buf_size);
    const shared = try S.init(allocator);

    const local = MemStream{
        .tx_ring = &shared.a_to_b_ring,
        .rx_ring = &shared.b_to_a_ring,
        .self_read_async = &shared.a_read_async,
        .self_write_async = &shared.a_write_async,
        .peer_read_async = &shared.b_read_async,
        .peer_write_async = &shared.b_write_async,
        .closed = &shared.closed,
        ._shared = @ptrCast(shared),
        ._shared_release = S.release,
        .allocator = allocator,
    };

    const remote = MemStream{
        .tx_ring = &shared.b_to_a_ring,
        .rx_ring = &shared.a_to_b_ring,
        .self_read_async = &shared.b_read_async,
        .self_write_async = &shared.b_write_async,
        .peer_read_async = &shared.a_read_async,
        .peer_write_async = &shared.a_write_async,
        .closed = &shared.closed,
        ._shared = @ptrCast(shared),
        ._shared_release = S.release,
        .allocator = allocator,
    };

    return PairHandle{
        .local = local,
        .remote = remote,
    };
}

// ============================================================================
// 跨平台 Mutex
// ============================================================================

const Mutex = if (builtin.os.tag == .windows) struct {
    locked: bool = false,

    fn lock(self: *@This()) void {
        while (@atomicRmw(bool, &self.locked, .Xchg, true, .acquire)) {
            std.atomic.spinLoopHint();
        }
    }

    fn unlock(self: *@This()) void {
        @atomicStore(bool, &self.locked, false, .release);
    }
} else struct {
    inner: std.c.pthread_mutex_t = .{},

    fn lock(self: *@This()) void {
        const pthread_mutex_lock_fn = struct {
            extern "c" fn pthread_mutex_lock(mutex: *std.c.pthread_mutex_t) std.c.E;
        }.pthread_mutex_lock;
        _ = pthread_mutex_lock_fn(&self.inner);
    }

    fn unlock(self: *@This()) void {
        const pthread_mutex_unlock_fn = struct {
            extern "c" fn pthread_mutex_unlock(mutex: *std.c.pthread_mutex_t) std.c.E;
        }.pthread_mutex_unlock;
        _ = pthread_mutex_unlock_fn(&self.inner);
    }
};

// ============================================================================
// MemListener — 命名连接异步接受器
// ============================================================================

pub const MemListener = struct {
    _name: []const u8,
    _allocator: std.mem.Allocator,
    _queue_mutex: Mutex = .{},
    _notify: xev.Async,
    _queue_buf: [16]MemStream = undefined,
    _queue_head: usize = 0,
    _queue_tail: usize = 0,
    _queue_count: usize = 0,
    _closed: std.atomic.Value(bool) = .init(false),
    _deinited: bool = false,

    fn init(listen_name: []const u8, allocator: std.mem.Allocator) !MemListener {
        return MemListener{
            ._name = listen_name,
            ._allocator = allocator,
            ._notify = try xev.Async.init(),
        };
    }

    fn deinit(self: *MemListener) void {
        if (self._deinited) return;
        self._deinited = true;

        // 清理 accept 队列中未取走的连接
        while (self._queue_count > 0) {
            self._queue_buf[self._queue_head].closed.store(true, .release);
            self._queue_head = (self._queue_head + 1) % self._queue_buf.len;
            self._queue_count -= 1;
        }
        self._notify.deinit();
    }

    /// 推入新连接到 accept 队列。满时覆盖最旧连接（关闭旧连接触发清理）。
    fn pushConn(self: *MemListener, conn: MemStream) void {
        self._queue_mutex.lock();
        defer self._queue_mutex.unlock();

        if (self._queue_count == self._queue_buf.len) {
            const old = self._queue_buf[self._queue_head];
            old.closed.store(true, .release);
            old.peer_read_async.notify() catch {};
            old.peer_write_async.notify() catch {};
            self._queue_head = (self._queue_head + 1) % self._queue_buf.len;
            self._queue_count -= 1;
        }

        self._queue_buf[self._queue_tail] = conn;
        self._queue_tail = (self._queue_tail + 1) % self._queue_buf.len;
        self._queue_count += 1;
        self._notify.notify() catch {};
    }

    /// 取出一个连接。空时返回 null。
    fn popConn(self: *MemListener) ?MemStream {
        self._queue_mutex.lock();
        defer self._queue_mutex.unlock();

        if (self._queue_count == 0) return null;

        const conn = self._queue_buf[self._queue_head];
        self._queue_buf[self._queue_head] = .{
            .tx_ring = undefined,
            .rx_ring = undefined,
            .self_read_async = undefined,
            .self_write_async = undefined,
            .peer_read_async = undefined,
            .peer_write_async = undefined,
            .closed = undefined,
            .allocator = undefined,
        };
        self._queue_head = (self._queue_head + 1) % self._queue_buf.len;
        self._queue_count -= 1;
        return conn;
    }

    /// 注册异步接受操作。
    ///
    /// cb: fn (?*Userdata, *xev.Loop, *xev.Completion, ?MemStream) xev.CallbackAction
    /// 返回 null 且 listener 已关闭表示 listener 已终止。
    pub fn accept(
        self: *MemListener,
        loop: *xev.Loop,
        c: *xev.Completion,
        comptime Userdata: type,
        userdata: ?*Userdata,
        comptime cb: *const fn (
            ud: ?*Userdata,
            l: *xev.Loop,
            c_inner: *xev.Completion,
            conn: ?MemStream,
        ) xev.CallbackAction,
    ) void {
        const S = AcceptOp(Userdata, cb);
        const op = self._allocator.create(S) catch {
            _ = cb(userdata, loop, c, null);
            return;
        };
        op.* = .{
            .allocator = self._allocator,
            .listener = self,
            .userdata = userdata,
        };

        self._notify.wait(loop, c, S, op, S.internalCb);
    }

    fn isClosed(self: *const MemListener) bool {
        return self._closed.load(.acquire);
    }

    /// 同步关闭 listener，唤醒所有阻塞的 accept 调用者。
    pub fn close(self: *MemListener) void {
        self._closed.store(true, .release);
        self._notify.notify() catch {};
    }

    /// 返回 listener 注册名称。
    pub fn name(self: *const MemListener) []const u8 {
        return self._name;
    }
};

fn AcceptOp(comptime Userdata: type, comptime cb: anytype) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        listener: *MemListener,
        userdata: ?*Userdata,

        fn internalCb(
            ud: ?*Self,
            loop: *xev.Loop,
            c: *xev.Completion,
            r: xev.Async.WaitError!void,
        ) xev.CallbackAction {
            const self = ud.?;
            _ = r catch {};

            if (self.listener.popConn()) |c2| {
                const action = cb(self.userdata, loop, c, c2);
                self.allocator.destroy(self);
                return action;
            }

            if (self.listener._closed.load(.acquire)) {
                const action = cb(self.userdata, loop, c, null);
                self.allocator.destroy(self);
                return action;
            }

            // 假唤醒，re-arm
            return .rearm;
        }
    };
}

// ============================================================================
// Registry — 命名连接注册表
// ============================================================================

pub const Registry = struct {
    _mutex: Mutex = .{},
    _map: std.StringHashMap(*MemListener),
    _allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !Registry {
        return Registry{
            ._map = std.StringHashMap(*MemListener).init(allocator),
            ._allocator = allocator,
        };
    }

    pub fn deinit(self: *Registry) void {
        self._mutex.lock();
        defer self._mutex.unlock();

        var it = self._map.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.close();
            entry.value_ptr.*.deinit();
            self._allocator.free(entry.key_ptr.*);
            self._allocator.destroy(entry.value_ptr.*);
        }
        self._map.deinit();
    }

    pub fn listen(self: *Registry, name: []const u8) !*MemListener {
        self._mutex.lock();
        defer self._mutex.unlock();

        if (self._map.contains(name)) {
            return error.NameInUse;
        }

        const name_copy = try self._allocator.dupe(u8, name);
        errdefer self._allocator.free(name_copy);

        const listener = try self._allocator.create(MemListener);
        errdefer self._allocator.destroy(listener);

        listener.* = try MemListener.init(name_copy, self._allocator);
        try self._map.put(name_copy, listener);
        return listener;
    }

    pub fn dial(self: *Registry, comptime buf_size: usize, name: []const u8) !MemStream {
        self._mutex.lock();
        defer self._mutex.unlock();

        const listener = self._map.get(name) orelse return error.NameNotFound;

        const S = SharedState(buf_size);
        const shared = try S.init(self._allocator);

        // local → 返回给 dial 调用者
        // remote → 推入 accept 队列
        const local = MemStream{
            .tx_ring = &shared.a_to_b_ring,
            .rx_ring = &shared.b_to_a_ring,
            .self_read_async = &shared.a_read_async,
            .self_write_async = &shared.a_write_async,
            .peer_read_async = &shared.b_read_async,
            .peer_write_async = &shared.b_write_async,
            .closed = &shared.closed,
            ._shared = @ptrCast(shared),
            ._shared_release = S.release,
            ._close_releases = true,
            .allocator = self._allocator,
        };
        const remote = MemStream{
            .tx_ring = &shared.b_to_a_ring,
            .rx_ring = &shared.a_to_b_ring,
            .self_read_async = &shared.b_read_async,
            .self_write_async = &shared.b_write_async,
            .peer_read_async = &shared.a_read_async,
            .peer_write_async = &shared.a_write_async,
            .closed = &shared.closed,
            ._shared = @ptrCast(shared),
            ._shared_release = S.release,
            ._close_releases = true,
            .allocator = self._allocator,
        };

        listener.pushConn(remote);
        return local;
    }

    pub fn unlisten(self: *Registry, name: []const u8) void {
        self._mutex.lock();
        defer self._mutex.unlock();

        if (self._map.fetchRemove(name)) |kv| {
            kv.value.close();
            kv.value.deinit();
            self._allocator.free(kv.key);
            self._allocator.destroy(kv.value);
        }
    }
};

// ============================================================================
// 全局便捷函数
// ============================================================================

var global_registry: ?*Registry = null;
var global_mutex: Mutex = .{};

pub fn initGlobal(allocator: std.mem.Allocator) !void {
    global_mutex.lock();
    defer global_mutex.unlock();

    if (global_registry != null) return;

    const reg = try allocator.create(Registry);
    errdefer allocator.destroy(reg);
    reg.* = try Registry.init(allocator);
    global_registry = reg;
}

pub fn deinitGlobal() void {
    global_mutex.lock();
    defer global_mutex.unlock();

    if (global_registry) |reg| {
        reg.deinit();
        const allocator = reg._allocator;
        allocator.destroy(reg);
        global_registry = null;
    }
}

pub fn listen(name: []const u8) !*MemListener {
    global_mutex.lock();
    const reg = global_registry orelse {
        global_mutex.unlock();
        return error.NotInitialized;
    };
    const allocator = reg._allocator;
    const name_copy = try allocator.dupe(u8, name);
    global_mutex.unlock();
    defer allocator.free(name_copy);
    return reg.listen(name_copy);
}

pub fn dial(comptime buf_size: usize, name: []const u8) !MemStream {
    global_mutex.lock();
    const reg = global_registry orelse {
        global_mutex.unlock();
        return error.NotInitialized;
    };
    const allocator = reg._allocator;
    const name_copy = try allocator.dupe(u8, name);
    global_mutex.unlock();
    defer allocator.free(name_copy);
    return reg.dial(buf_size, name_copy);
}

// ============================================================================
// 测试
// ============================================================================

const testing = std.testing;

test "memconn: reference all pub decls (lazy-analysis guard)" {
    testing.refAllDecls(@This());
}

// ---- createPair 基本读写 (事件循环驱动) ----

test "createPair: basic write/read single byte" {
    var loop = try xev.Loop.init(.{});
    defer loop.deinit();

    var pair = try createPair(256, &loop, &loop, testing.allocator);
    defer pair.destroy();

    var write_done = false;
    var read_buf: [1]u8 = undefined;
    var read_n: usize = 0;

    var wc: xev.Completion = .{};
    pair.local.write(&loop, &wc, &.{0x42}, bool, &write_done, (struct {
        fn cb(ud: ?*bool, l: *xev.Loop, c: *xev.Completion, b: []const u8, r: error{Closed}!usize) xev.CallbackAction {
            _ = l;
            _ = c;
            _ = b;
            ud.?.* = true;
            _ = r catch unreachable;
            return .disarm;
        }
    }).cb);

    var rc: xev.Completion = .{};
    pair.remote.read(&loop, &rc, &read_buf, usize, &read_n, (struct {
        fn cb(ud: ?*usize, l: *xev.Loop, c: *xev.Completion, b: []u8, r: error{Closed}!usize) xev.CallbackAction {
            _ = l;
            _ = c;
            _ = b;
            ud.?.* = r catch unreachable;
            return .disarm;
        }
    }).cb);

    try loop.run(.until_done);
    try testing.expect(write_done);
    try testing.expectEqual(@as(usize, 1), read_n);
    try testing.expectEqual(@as(u8, 0x42), read_buf[0]);
}

test "createPair: write/read multiple bytes" {
    var loop = try xev.Loop.init(.{});
    defer loop.deinit();

    var pair = try createPair(256, &loop, &loop, testing.allocator);
    defer pair.destroy();

    var write_done = false;
    var read_buf: [64]u8 = undefined;
    var read_n: usize = 0;

    var wc: xev.Completion = .{};
    pair.local.write(&loop, &wc, "hello", bool, &write_done, (struct {
        fn cb(ud: ?*bool, l: *xev.Loop, c: *xev.Completion, b: []const u8, r: error{Closed}!usize) xev.CallbackAction {
            _ = l;
            _ = c;
            _ = b;
            ud.?.* = true;
            _ = r catch unreachable;
            return .disarm;
        }
    }).cb);

    var rc: xev.Completion = .{};
    pair.remote.read(&loop, &rc, &read_buf, usize, &read_n, (struct {
        fn cb(ud: ?*usize, l: *xev.Loop, c: *xev.Completion, b: []u8, r: error{Closed}!usize) xev.CallbackAction {
            _ = l;
            _ = c;
            _ = b;
            ud.?.* = r catch unreachable;
            return .disarm;
        }
    }).cb);

    try loop.run(.until_done);
    try testing.expect(write_done);
    try testing.expectEqualStrings("hello", read_buf[0..read_n]);
}

test "createPair: bidirectional" {
    var loop = try xev.Loop.init(.{});
    defer loop.deinit();

    var pair = try createPair(256, &loop, &loop, testing.allocator);
    defer pair.destroy();

    var local_read_n: usize = 0;
    var remote_read_n: usize = 0;
    var local_buf: [64]u8 = undefined;
    var remote_buf: [64]u8 = undefined;

    var wc1: xev.Completion = .{};
    pair.local.write(&loop, &wc1, "ping", void, null, (struct {
        fn cb(_: ?*void, _: *xev.Loop, _: *xev.Completion, _: []const u8, r: error{Closed}!usize) xev.CallbackAction {
            _ = r catch unreachable;
            return .disarm;
        }
    }).cb);

    var wc2: xev.Completion = .{};
    pair.remote.write(&loop, &wc2, "pong", void, null, (struct {
        fn cb(_: ?*void, _: *xev.Loop, _: *xev.Completion, _: []const u8, r: error{Closed}!usize) xev.CallbackAction {
            _ = r catch unreachable;
            return .disarm;
        }
    }).cb);

    var rc1: xev.Completion = .{};
    pair.remote.read(&loop, &rc1, &remote_buf, usize, &remote_read_n, (struct {
        fn cb(ud: ?*usize, l: *xev.Loop, c: *xev.Completion, b: []u8, r: error{Closed}!usize) xev.CallbackAction {
            _ = l;
            _ = c;
            _ = b;
            ud.?.* = r catch unreachable;
            return .disarm;
        }
    }).cb);

    var rc2: xev.Completion = .{};
    pair.local.read(&loop, &rc2, &local_buf, usize, &local_read_n, (struct {
        fn cb(ud: ?*usize, l: *xev.Loop, c: *xev.Completion, b: []u8, r: error{Closed}!usize) xev.CallbackAction {
            _ = l;
            _ = c;
            _ = b;
            ud.?.* = r catch unreachable;
            return .disarm;
        }
    }).cb);

    try loop.run(.until_done);
    try testing.expectEqualStrings("ping", remote_buf[0..remote_read_n]);
    try testing.expectEqualStrings("pong", local_buf[0..local_read_n]);
}

test "createPair: large data transfer" {
    var loop = try xev.Loop.init(.{});
    defer loop.deinit();

    var pair = try createPair(4096, &loop, &loop, testing.allocator);
    defer pair.destroy();

    const msg = [_]u8{'A'} ** 4000;
    var read_buf: [4000]u8 = undefined;
    var write_done = false;
    var read_n: usize = 0;

    var wc: xev.Completion = .{};
    pair.local.write(&loop, &wc, &msg, bool, &write_done, (struct {
        fn cb(ud: ?*bool, l: *xev.Loop, c: *xev.Completion, b: []const u8, r: error{Closed}!usize) xev.CallbackAction {
            _ = l;
            _ = c;
            _ = b;
            ud.?.* = true;
            _ = r catch unreachable;
            return .disarm;
        }
    }).cb);

    var rc: xev.Completion = .{};
    pair.remote.read(&loop, &rc, &read_buf, usize, &read_n, (struct {
        fn cb(ud: ?*usize, l: *xev.Loop, c: *xev.Completion, b: []u8, r: error{Closed}!usize) xev.CallbackAction {
            _ = l;
            _ = c;
            _ = b;
            ud.?.* = r catch unreachable;
            return .disarm;
        }
    }).cb);

    try loop.run(.until_done);
    try testing.expect(write_done);
    try testing.expectEqual(@as(usize, 4000), read_n);
    try testing.expectEqualSlices(u8, &msg, read_buf[0..read_n]);
}

// ---- close 行为 ----

test "createPair: read returns 0 on peer close (EOF)" {
    var loop = try xev.Loop.init(.{});
    defer loop.deinit();

    var pair = try createPair(256, &loop, &loop, testing.allocator);
    defer pair.destroy();

    var read_n: isize = -1;
    var read_buf: [64]u8 = undefined;

    var close_c: xev.Completion = .{};
    pair.local.close(&loop, &close_c, void, null, (struct {
        fn cb(_: ?*void, _: *xev.Loop, _: *xev.Completion, _: void) xev.CallbackAction {
            return .disarm;
        }
    }).cb);

    var rc: xev.Completion = .{};
    pair.remote.read(&loop, &rc, &read_buf, isize, &read_n, (struct {
        fn cb(ud: ?*isize, l: *xev.Loop, c: *xev.Completion, b: []u8, r: error{Closed}!usize) xev.CallbackAction {
            _ = l;
            _ = c;
            _ = b;
            ud.?.* = @intCast(r catch {
                return .disarm;
            });
            return .disarm;
        }
    }).cb);

    try loop.run(.until_done);
    try testing.expectEqual(@as(isize, 0), read_n);
}

test "createPair: write returns error.Closed after close" {
    var loop = try xev.Loop.init(.{});
    defer loop.deinit();

    var pair = try createPair(256, &loop, &loop, testing.allocator);
    defer pair.destroy();

    var write_closed = false;

    var close_c: xev.Completion = .{};
    pair.remote.close(&loop, &close_c, void, null, (struct {
        fn cb(_: ?*void, _: *xev.Loop, _: *xev.Completion, _: void) xev.CallbackAction {
            return .disarm;
        }
    }).cb);

    var wc: xev.Completion = .{};
    pair.local.write(&loop, &wc, "hello", bool, &write_closed, (struct {
        fn cb(ud: ?*bool, l: *xev.Loop, c: *xev.Completion, b: []const u8, r: error{Closed}!usize) xev.CallbackAction {
            _ = l;
            _ = c;
            _ = b;
            _ = r catch {
                ud.?.* = true;
                return .disarm;
            };
            return .disarm;
        }
    }).cb);

    try loop.run(.until_done);
    try testing.expect(write_closed);
}

test "createPair: isClosed before and after close" {
    var loop = try xev.Loop.init(.{});
    defer loop.deinit();

    var pair = try createPair(256, &loop, &loop, testing.allocator);
    defer pair.destroy();

    try testing.expect(!pair.local.isClosed());

    var close_done = false;
    var cc: xev.Completion = .{};
    pair.local.close(&loop, &cc, bool, &close_done, (struct {
        fn cb(ud: ?*bool, l: *xev.Loop, c: *xev.Completion, _: void) xev.CallbackAction {
            _ = l;
            _ = c;
            ud.?.* = true;
            return .disarm;
        }
    }).cb);

    try loop.run(.until_done);
    try testing.expect(close_done);
    try testing.expect(pair.local.isClosed());
}

test "createPair: close is idempotent" {
    var loop = try xev.Loop.init(.{});
    defer loop.deinit();

    var pair = try createPair(256, &loop, &loop, testing.allocator);
    defer pair.destroy();

    var c1: xev.Completion = .{};
    pair.local.close(&loop, &c1, void, null, (struct {
        fn cb(_: ?*void, _: *xev.Loop, _: *xev.Completion, _: void) xev.CallbackAction {
            return .disarm;
        }
    }).cb);

    var c2: xev.Completion = .{};
    pair.local.close(&loop, &c2, void, null, (struct {
        fn cb(_: ?*void, _: *xev.Loop, _: *xev.Completion, _: void) xev.CallbackAction {
            return .disarm;
        }
    }).cb);

    try loop.run(.until_done);
    try testing.expect(pair.local.isClosed());
}

// ---- 空操作 ----

test "createPair: zero-length write" {
    var loop = try xev.Loop.init(.{});
    defer loop.deinit();

    var pair = try createPair(256, &loop, &loop, testing.allocator);
    defer pair.destroy();

    var written: usize = 1; // 非零初始化，确保回调修改了它
    var wc: xev.Completion = .{};
    pair.local.write(&loop, &wc, &.{}, usize, &written, (struct {
        fn cb(ud: ?*usize, l: *xev.Loop, c: *xev.Completion, b: []const u8, r: error{Closed}!usize) xev.CallbackAction {
            _ = l;
            _ = c;
            _ = b;
            ud.?.* = r catch unreachable;
            return .disarm;
        }
    }).cb);

    try loop.run(.until_done);
    try testing.expectEqual(@as(usize, 0), written);
}

// ---- 跨线程 ----
//
// **重要：这些测试使用双 Loop 模式的原因。**
//
// 测试中 Completion 是**栈变量**，线程退出后栈被回收，但 kernel kevent 的
// udata 仍持有指向已释放 Completion 的指针 → use-after-free。
//
// 双 Loop 保证注册 Completion 的线程也运行 loop.run()（阻塞），因此
// Completion 在回调触发前一直存活。
//
// **这不是 memconn 的设计要求，而是栈 Completion + 跨线程的测试模式产物。**
//
// 生产代码的正确模式（参照 zigproxy）：
// - Completion 嵌入堆分配的连接结构体，生命周期覆盖整个连接
// - 单 Loop 实例，事件循环线程独占运行 loop.run()
// - 跨线程通信仅用 xev.Async.notify()（线程安全），无需多个 Loop

test "createPair: cross-thread write/read" {
    const Ctx = struct {
        loop: *xev.Loop,
        remote: *MemStream,
        done: std.atomic.Value(bool) = .init(false),
        read_buf: [64]u8 = undefined,
        read_n: usize = 0,
    };

    var loop_a = try xev.Loop.init(.{});
    defer loop_a.deinit();
    var loop_b = try xev.Loop.init(.{});
    defer loop_b.deinit();

    var pair = try createPair(256, &loop_a, &loop_b, testing.allocator);
    defer pair.destroy();

    var ctx = Ctx{ .loop = &loop_b, .remote = &pair.remote };

    // 线程 B：注册读并运行 loop_b
    const t = try std.Thread.spawn(.{}, (struct {
        fn run(c: *Ctx) void {
            var rc: xev.Completion = .{};
            c.remote.read(c.loop, &rc, &c.read_buf, Ctx, c, (struct {
                fn cb(ud: ?*Ctx, l: *xev.Loop, ci: *xev.Completion, b: []u8, r: error{Closed}!usize) xev.CallbackAction {
                    _ = l;
                    _ = ci;
                    _ = b;
                    ud.?.read_n = r catch unreachable;
                    ud.?.done.store(true, .release);
                    return .disarm;
                }
            }).cb);
            c.loop.run(.until_done) catch {};
        }
    }).run, .{&ctx});

    // 线程 A：写数据
    var wc: xev.Completion = .{};
    pair.local.write(&loop_a, &wc, "hello", void, null, (struct {
        fn cb(_: ?*void, _: *xev.Loop, _: *xev.Completion, _: []const u8, r: error{Closed}!usize) xev.CallbackAction {
            _ = r catch unreachable;
            return .disarm;
        }
    }).cb);
    try loop_a.run(.until_done);

    t.join();
    try testing.expect(ctx.done.load(.acquire));
    try testing.expectEqualStrings("hello", ctx.read_buf[0..ctx.read_n]);
}

test "createPair: cross-thread close wakes reader" {
    const Ctx = struct {
        loop: *xev.Loop,
        remote: *MemStream,
        done: std.atomic.Value(bool) = .init(false),
        read_n: isize = -1,
    };

    var loop_a = try xev.Loop.init(.{});
    defer loop_a.deinit();
    var loop_b = try xev.Loop.init(.{});
    defer loop_b.deinit();

    var pair = try createPair(256, &loop_a, &loop_b, testing.allocator);
    defer pair.destroy();

    var ctx = Ctx{ .loop = &loop_b, .remote = &pair.remote };

    // 线程 B：注册读并运行 loop_b
    const t = try std.Thread.spawn(.{}, (struct {
        fn run(c: *Ctx) void {
            var read_buf: [64]u8 = undefined;
            var rc: xev.Completion = .{};
            c.remote.read(c.loop, &rc, &read_buf, Ctx, c, (struct {
                fn cb(ud: ?*Ctx, l: *xev.Loop, ci: *xev.Completion, b: []u8, r: error{Closed}!usize) xev.CallbackAction {
                    _ = l;
                    _ = ci;
                    _ = b;
                    ud.?.read_n = @intCast(r catch unreachable);
                    ud.?.done.store(true, .release);
                    return .disarm;
                }
            }).cb);
            c.loop.run(.until_done) catch {};
        }
    }).run, .{&ctx});

    // 线程 A：关闭 local → 远程读应返回 0 (EOF)
    var cc: xev.Completion = .{};
    pair.local.close(&loop_a, &cc, void, null, (struct {
        fn cb(_: ?*void, _: *xev.Loop, _: *xev.Completion, _: void) xev.CallbackAction {
            return .disarm;
        }
    }).cb);
    try loop_a.run(.until_done);

    t.join();
    try testing.expect(ctx.done.load(.acquire));
    try testing.expectEqual(@as(isize, 0), ctx.read_n);
}

// ---- Registry ----

test "Registry: init/deinit" {
    var reg = try Registry.init(testing.allocator);
    defer reg.deinit();
}

test "Registry: listen then dial and accept" {
    var loop = try xev.Loop.init(.{});
    defer loop.deinit();

    var reg = try Registry.init(testing.allocator);
    defer reg.deinit();

    const listener = try reg.listen("test1");

    var conn = try reg.dial(256, "test1");

    // 写数据
    var wc: xev.Completion = .{};
    conn.write(&loop, &wc, "hello", void, null, (struct {
        fn cb(_: ?*void, _: *xev.Loop, _: *xev.Completion, _: []const u8, r: error{Closed}!usize) xev.CallbackAction {
            _ = r catch unreachable;
            return .disarm;
        }
    }).cb);

    // accept
    var accepted_conn: ?MemStream = null;
    var ac: xev.Completion = .{};
    listener.accept(&loop, &ac, ?MemStream, &accepted_conn, (struct {
        fn cb(ud: ?*?MemStream, l: *xev.Loop, c: *xev.Completion, c2: ?MemStream) xev.CallbackAction {
            _ = l;
            _ = c;
            ud.?.* = c2;
            return .disarm;
        }
    }).cb);

    try loop.run(.until_done);
    try testing.expect(accepted_conn != null);

    // 读接受端
    var read_buf: [64]u8 = undefined;
    var read_n: usize = 0;
    var rc: xev.Completion = .{};
    accepted_conn.?.read(&loop, &rc, &read_buf, usize, &read_n, (struct {
        fn cb(ud: ?*usize, l: *xev.Loop, c: *xev.Completion, b: []u8, r: error{Closed}!usize) xev.CallbackAction {
            _ = l;
            _ = c;
            _ = b;
            ud.?.* = r catch unreachable;
            return .disarm;
        }
    }).cb);

    try loop.run(.until_done);
    try testing.expectEqualStrings("hello", read_buf[0..read_n]);

    // 正确关闭两端以释放 SharedState（Registry 模式 _close_releases=true）
    var c1: xev.Completion = .{};
    conn.close(&loop, &c1, void, null, (struct {
        fn cb(_: ?*void, _: *xev.Loop, _: *xev.Completion, _: void) xev.CallbackAction {
            return .disarm;
        }
    }).cb);
    var c2: xev.Completion = .{};
    accepted_conn.?.close(&loop, &c2, void, null, (struct {
        fn cb(_: ?*void, _: *xev.Loop, _: *xev.Completion, _: void) xev.CallbackAction {
            return .disarm;
        }
    }).cb);
    try loop.run(.until_done);
}

test "Registry: dial unknown name returns NameNotFound" {
    var reg = try Registry.init(testing.allocator);
    defer reg.deinit();

    const result = reg.dial(256, "nonexistent");
    try testing.expectError(error.NameNotFound, result);
}

test "Registry: listen duplicate name returns NameInUse" {
    var reg = try Registry.init(testing.allocator);
    defer reg.deinit();

    const l1 = try reg.listen("dup");
    defer {
        l1.close();
        l1.deinit();
    }

    const result = reg.listen("dup");
    try testing.expectError(error.NameInUse, result);
}

test "Registry: unlisten removes listener" {
    var reg = try Registry.init(testing.allocator);
    defer reg.deinit();

    _ = try reg.listen("temp");
    reg.unlisten("temp");

    const result = reg.dial(256, "temp");
    try testing.expectError(error.NameNotFound, result);
}

test "Registry: listener close wakes accept with null" {
    var loop = try xev.Loop.init(.{});
    defer loop.deinit();

    var reg = try Registry.init(testing.allocator);
    defer reg.deinit();

    var listener = try reg.listen("close_test");

    var accepted: ?MemStream = null;
    var ac: xev.Completion = .{};
    listener.accept(&loop, &ac, ?MemStream, &accepted, (struct {
        fn cb(ud: ?*?MemStream, l: *xev.Loop, c: *xev.Completion, c2: ?MemStream) xev.CallbackAction {
            _ = l;
            _ = c;
            ud.?.* = c2;
            return .disarm;
        }
    }).cb);

    // 关闭 listener
    listener.close();

    try loop.run(.until_done);
    try testing.expectEqual(@as(?MemStream, null), accepted);
}

test "Registry: multiple listeners" {
    var loop = try xev.Loop.init(.{});
    defer loop.deinit();

    var reg = try Registry.init(testing.allocator);
    defer reg.deinit();

    const l1 = try reg.listen("a");
    defer {
        l1.close();
        l1.deinit();
    }
    const l2 = try reg.listen("b");
    defer {
        l2.close();
        l2.deinit();
    }

    var conn_a = try reg.dial(256, "a");
    var conn_b = try reg.dial(256, "b");

    // 写 + accept a
    var wc_a: xev.Completion = .{};
    conn_a.write(&loop, &wc_a, "to-a", void, null, (struct {
        fn cb(_: ?*void, _: *xev.Loop, _: *xev.Completion, _: []const u8, r: error{Closed}!usize) xev.CallbackAction {
            _ = r catch unreachable;
            return .disarm;
        }
    }).cb);

    // 写 + accept b
    var wc_b: xev.Completion = .{};
    conn_b.write(&loop, &wc_b, "to-b", void, null, (struct {
        fn cb(_: ?*void, _: *xev.Loop, _: *xev.Completion, _: []const u8, r: error{Closed}!usize) xev.CallbackAction {
            _ = r catch unreachable;
            return .disarm;
        }
    }).cb);

    var acc_a: ?MemStream = null;
    var acc_b: ?MemStream = null;
    var ac_a: xev.Completion = .{};
    var ac_b: xev.Completion = .{};

    l1.accept(&loop, &ac_a, ?MemStream, &acc_a, (struct {
        fn cb(ud: ?*?MemStream, l: *xev.Loop, c: *xev.Completion, conn: ?MemStream) xev.CallbackAction {
            _ = l;
            _ = c;
            ud.?.* = conn;
            return .disarm;
        }
    }).cb);

    l2.accept(&loop, &ac_b, ?MemStream, &acc_b, (struct {
        fn cb(ud: ?*?MemStream, l: *xev.Loop, c: *xev.Completion, conn: ?MemStream) xev.CallbackAction {
            _ = l;
            _ = c;
            ud.?.* = conn;
            return .disarm;
        }
    }).cb);

    try loop.run(.until_done);
    try testing.expect(acc_a != null);
    try testing.expect(acc_b != null);

    // 读验证
    var buf: [64]u8 = undefined;
    var n: usize = 0;
    var rc: xev.Completion = .{};

    var rc2: xev.Completion = .{};
    var buf2: [64]u8 = undefined;
    var n2: usize = 0;
    acc_a.?.read(&loop, &rc, &buf, usize, &n, (struct {
        fn cb(ud: ?*usize, l: *xev.Loop, c: *xev.Completion, b: []u8, r: error{Closed}!usize) xev.CallbackAction {
            _ = l;
            _ = c;
            _ = b;
            ud.?.* = r catch unreachable;
            return .disarm;
        }
    }).cb);

    acc_b.?.read(&loop, &rc2, &buf2, usize, &n2, (struct {
        fn cb(ud: ?*usize, l: *xev.Loop, c: *xev.Completion, b: []u8, r: error{Closed}!usize) xev.CallbackAction {
            _ = l;
            _ = c;
            _ = b;
            ud.?.* = r catch unreachable;
            return .disarm;
        }
    }).cb);

    try loop.run(.until_done);
    try testing.expectEqualStrings("to-a", buf[0..n]);
    try testing.expectEqualStrings("to-b", buf2[0..n2]);

    // 正确关闭所有连接以释放 SharedState
    var ca1: xev.Completion = .{};
    conn_a.close(&loop, &ca1, void, null, (struct {
        fn cb(_: ?*void, _: *xev.Loop, _: *xev.Completion, _: void) xev.CallbackAction {
            return .disarm;
        }
    }).cb);
    var ca2: xev.Completion = .{};
    acc_a.?.close(&loop, &ca2, void, null, (struct {
        fn cb(_: ?*void, _: *xev.Loop, _: *xev.Completion, _: void) xev.CallbackAction {
            return .disarm;
        }
    }).cb);
    var cb1: xev.Completion = .{};
    conn_b.close(&loop, &cb1, void, null, (struct {
        fn cb(_: ?*void, _: *xev.Loop, _: *xev.Completion, _: void) xev.CallbackAction {
            return .disarm;
        }
    }).cb);
    var cb2: xev.Completion = .{};
    acc_b.?.close(&loop, &cb2, void, null, (struct {
        fn cb(_: ?*void, _: *xev.Loop, _: *xev.Completion, _: void) xev.CallbackAction {
            return .disarm;
        }
    }).cb);
    try loop.run(.until_done);
}

// ---- 全局便捷函数 ----

test "global registry: initGlobal/deinitGlobal lifecycle" {
    try initGlobal(testing.allocator);
    defer deinitGlobal();
}

test "global registry: listen/dial round-trip" {
    var loop = try xev.Loop.init(.{});
    defer loop.deinit();

    try initGlobal(testing.allocator);
    defer deinitGlobal();

    const listener = try listen("global1");
    defer {
        listener.close();
        listener.deinit();
    }

    var conn = try dial(256, "global1");

    // 写
    var wc: xev.Completion = .{};
    conn.write(&loop, &wc, "global", void, null, (struct {
        fn cb(_: ?*void, _: *xev.Loop, _: *xev.Completion, _: []const u8, r: error{Closed}!usize) xev.CallbackAction {
            _ = r catch unreachable;
            return .disarm;
        }
    }).cb);

    // accept
    var accepted: ?MemStream = null;
    var ac: xev.Completion = .{};
    listener.accept(&loop, &ac, ?MemStream, &accepted, (struct {
        fn cb(ud: ?*?MemStream, l: *xev.Loop, c: *xev.Completion, c2: ?MemStream) xev.CallbackAction {
            _ = l;
            _ = c;
            ud.?.* = c2;
            return .disarm;
        }
    }).cb);

    try loop.run(.until_done);
    try testing.expect(accepted != null);

    var buf: [64]u8 = undefined;
    var n: usize = 0;
    var rc: xev.Completion = .{};
    accepted.?.read(&loop, &rc, &buf, usize, &n, (struct {
        fn cb(ud: ?*usize, l: *xev.Loop, c: *xev.Completion, b: []u8, r: error{Closed}!usize) xev.CallbackAction {
            _ = l;
            _ = c;
            _ = b;
            ud.?.* = r catch unreachable;
            return .disarm;
        }
    }).cb);

    try loop.run(.until_done);
    try testing.expectEqualStrings("global", buf[0..n]);

    // 正确关闭两端以释放 SharedState
    var c1: xev.Completion = .{};
    conn.close(&loop, &c1, void, null, (struct {
        fn cb(_: ?*void, _: *xev.Loop, _: *xev.Completion, _: void) xev.CallbackAction {
            return .disarm;
        }
    }).cb);
    var c2: xev.Completion = .{};
    accepted.?.close(&loop, &c2, void, null, (struct {
        fn cb(_: ?*void, _: *xev.Loop, _: *xev.Completion, _: void) xev.CallbackAction {
            return .disarm;
        }
    }).cb);
    try loop.run(.until_done);
}

// ---- 分片写入 ----

test "createPair: partial write (buffer full, rearm)" {
    var loop = try xev.Loop.init(.{});
    defer loop.deinit();

    var pair = try createPair(256, &loop, &loop, testing.allocator);
    defer pair.destroy();

    // 写一个大消息（超过 buffer 容量），需要分片写入
    const msg = [_]u8{0x41} ** 400;
    var written: usize = 0;
    var read_buf: [400]u8 = undefined;
    var read_total: usize = 0;

    var wc: xev.Completion = .{};
    pair.local.write(&loop, &wc, &msg, usize, &written, (struct {
        fn cb(ud: ?*usize, l: *xev.Loop, c: *xev.Completion, b: []const u8, r: error{Closed}!usize) xev.CallbackAction {
            _ = l;
            _ = c;
            _ = b;
            ud.?.* = r catch unreachable;
            return .disarm;
        }
    }).cb);

    // 读者边读边累积
    var rc: xev.Completion = .{};
    pair.remote.read(&loop, &rc, &read_buf, usize, &read_total, (struct {
        fn cb(ud: ?*usize, l: *xev.Loop, c: *xev.Completion, b: []u8, r: error{Closed}!usize) xev.CallbackAction {
            _ = l;
            _ = c;
            _ = b;
            ud.?.* = r catch unreachable;
            return .disarm;
        }
    }).cb);

    try loop.run(.until_done);
    try testing.expectEqual(@as(usize, 400), written);
    try testing.expect(read_total > 0);
}

// ---- 跨线程 Registry ----

test "Registry: cross-thread dial and accept" {
    var loop_a = try xev.Loop.init(.{});
    defer loop_a.deinit();
    var loop_b = try xev.Loop.init(.{});
    defer loop_b.deinit();

    var reg = try Registry.init(testing.allocator);
    defer reg.deinit();

    const listener = try reg.listen("cross");
    defer {
        listener.close();
        listener.deinit();
    }

    const Ctx = struct {
        loop: *xev.Loop,
        listener: *MemListener,
        conn: ?MemStream = null,
        done: std.atomic.Value(bool) = .init(false),
        buf: [64]u8 = undefined,
        n: usize = 0,
    };
    var ctx = Ctx{ .loop = &loop_b, .listener = listener };

    // 服务端线程：accept → 运行 loop_b
    const t = try std.Thread.spawn(.{}, (struct {
        fn run(c: *Ctx) void {
            var ac: xev.Completion = .{};
            c.listener.accept(c.loop, &ac, ?MemStream, &c.conn, (struct {
                fn cb(ud: ?*?MemStream, l: *xev.Loop, ci: *xev.Completion, c2: ?MemStream) xev.CallbackAction {
                    _ = l;
                    _ = ci;
                    ud.?.* = c2;
                    return .disarm;
                }
            }).cb);
            c.loop.run(.until_done) catch {};
        }
    }).run, .{&ctx});

    // 客户端拨号 + 写
    var conn = try reg.dial(256, "cross");

    var wc: xev.Completion = .{};
    conn.write(&loop_a, &wc, "ping", void, null, (struct {
        fn cb(_: ?*void, _: *xev.Loop, _: *xev.Completion, _: []const u8, r: error{Closed}!usize) xev.CallbackAction {
            _ = r catch unreachable;
            return .disarm;
        }
    }).cb);
    try loop_a.run(.until_done);

    t.join();
    try testing.expect(ctx.conn != null);

    // 关闭两端以释放 SharedState
    var c1: xev.Completion = .{};
    conn.close(&loop_a, &c1, void, null, (struct {
        fn cb(_: ?*void, _: *xev.Loop, _: *xev.Completion, _: void) xev.CallbackAction {
            return .disarm;
        }
    }).cb);
    try loop_a.run(.until_done);

    var c2: xev.Completion = .{};
    ctx.conn.?.close(&loop_b, &c2, void, null, (struct {
        fn cb(_: ?*void, _: *xev.Loop, _: *xev.Completion, _: void) xev.CallbackAction {
            return .disarm;
        }
    }).cb);
    try loop_b.run(.until_done);
}

// ---- 零拷贝接口测试 ----

test "createPair: readDirect zero-copy" {
    var loop = try xev.Loop.init(.{});
    defer loop.deinit();

    var pair = try createPair(256, &loop, &loop, testing.allocator);
    defer pair.destroy();

    var write_done = false;

    const ReadCtx = struct {
        data: [64]u8 = undefined,
        n: usize = 0,
    };
    var read_ctx = ReadCtx{};

    // 写入数据
    var wc: xev.Completion = .{};
    pair.local.write(&loop, &wc, "hello", bool, &write_done, (struct {
        fn cb(ud: ?*bool, l: *xev.Loop, c: *xev.Completion, b: []const u8, r: error{Closed}!usize) xev.CallbackAction {
            _ = l;
            _ = c;
            _ = b;
            ud.?.* = true;
            _ = r catch unreachable;
            return .disarm;
        }
    }).cb);

    // 零拷贝读取 — 回调中的 span 直接指向 RingBuf 内存
    var rc: xev.Completion = .{};
    pair.remote.readDirect(&loop, &rc, ReadCtx, &read_ctx, (struct {
        fn cb(ud: ?*ReadCtx, l: *xev.Loop, c: *xev.Completion, b: []const u8, r: error{Closed}!usize) xev.CallbackAction {
            _ = l;
            _ = c;
            const n = r catch unreachable;
            // b 直接指向 RingBuf，零拷贝
            @memcpy(ud.?.data[0..n], b[0..n]);
            ud.?.n = n;
            return .disarm;
        }
    }).cb);

    try loop.run(.until_done);
    try testing.expect(write_done);
    try testing.expectEqual(@as(usize, 5), read_ctx.n);
    try testing.expectEqualStrings("hello", read_ctx.data[0..read_ctx.n]);
}

test "createPair: writeDirect zero-copy" {
    var loop = try xev.Loop.init(.{});
    defer loop.deinit();

    var pair = try createPair(256, &loop, &loop, testing.allocator);
    defer pair.destroy();

    var written = false;
    var read_buf: [64]u8 = undefined;
    var read_n: usize = 0;

    // 零拷贝写入 — 回调中的 span 直接指向 tx_ring 内存
    var wc: xev.Completion = .{};
    pair.local.writeDirect(&loop, &wc, 5, bool, &written, (struct {
        fn cb(ud: ?*bool, l: *xev.Loop, c: *xev.Completion, b: []u8, r: error{Closed}!usize) xev.CallbackAction {
            _ = l;
            _ = c;
            _ = r catch unreachable;
            // b 直接指向 tx_ring，零拷贝写入
            b[0] = 'w';
            b[1] = 'o';
            b[2] = 'r';
            b[3] = 'l';
            b[4] = 'd';
            ud.?.* = true;
            return .disarm;
        }
    }).cb);

    // 对端读取
    var rc: xev.Completion = .{};
    pair.remote.read(&loop, &rc, &read_buf, usize, &read_n, (struct {
        fn cb(ud: ?*usize, l: *xev.Loop, c: *xev.Completion, b: []u8, r: error{Closed}!usize) xev.CallbackAction {
            _ = l;
            _ = c;
            _ = b;
            ud.?.* = r catch unreachable;
            return .disarm;
        }
    }).cb);

    try loop.run(.until_done);
    try testing.expect(written);
    try testing.expectEqualStrings("world", read_buf[0..read_n]);
}

test "createPair: readDirect returns 0 on peer close (EOF)" {
    var loop = try xev.Loop.init(.{});
    defer loop.deinit();

    var pair = try createPair(256, &loop, &loop, testing.allocator);
    defer pair.destroy();

    var read_n: isize = -1;

    // 关闭一端
    var cc: xev.Completion = .{};
    pair.local.close(&loop, &cc, void, null, (struct {
        fn cb(_: ?*void, _: *xev.Loop, _: *xev.Completion, _: void) xev.CallbackAction {
            return .disarm;
        }
    }).cb);

    // 对端零拷贝读取 → EOF
    var rc: xev.Completion = .{};
    pair.remote.readDirect(&loop, &rc, isize, &read_n, (struct {
        fn cb(ud: ?*isize, l: *xev.Loop, c: *xev.Completion, b: []const u8, r: error{Closed}!usize) xev.CallbackAction {
            _ = l;
            _ = c;
            _ = b;
            ud.?.* = @intCast(r catch unreachable);
            return .disarm;
        }
    }).cb);

    try loop.run(.until_done);
    try testing.expectEqual(@as(isize, 0), read_n);
}

test "createPair: writeDirect returns error.Closed after close" {
    var loop = try xev.Loop.init(.{});
    defer loop.deinit();

    var pair = try createPair(256, &loop, &loop, testing.allocator);
    defer pair.destroy();

    var write_closed = false;

    // 先关闭对端
    var cc: xev.Completion = .{};
    pair.remote.close(&loop, &cc, void, null, (struct {
        fn cb(_: ?*void, _: *xev.Loop, _: *xev.Completion, _: void) xev.CallbackAction {
            return .disarm;
        }
    }).cb);

    // 尝试零拷贝写入 → error.Closed
    var wc: xev.Completion = .{};
    pair.local.writeDirect(&loop, &wc, 10, bool, &write_closed, (struct {
        fn cb(ud: ?*bool, l: *xev.Loop, c: *xev.Completion, b: []u8, r: error{Closed}!usize) xev.CallbackAction {
            _ = l;
            _ = c;
            _ = b;
            _ = r catch {
                ud.?.* = true;
                return .disarm;
            };
            return .disarm;
        }
    }).cb);

    try loop.run(.until_done);
    try testing.expect(write_closed);
}

test "createPair: readDirect bidirectional zero-copy" {
    var loop = try xev.Loop.init(.{});
    defer loop.deinit();

    var pair = try createPair(256, &loop, &loop, testing.allocator);
    defer pair.destroy();

    const ReadCtx = struct {
        data: [64]u8 = undefined,
        n: usize = 0,
    };
    var local_ctx = ReadCtx{};
    var remote_ctx = ReadCtx{};

    // 写入 "ping" 用普通 write
    var wc1: xev.Completion = .{};
    pair.local.write(&loop, &wc1, "ping", void, null, (struct {
        fn cb(_: ?*void, _: *xev.Loop, _: *xev.Completion, _: []const u8, r: error{Closed}!usize) xev.CallbackAction {
            _ = r catch unreachable;
            return .disarm;
        }
    }).cb);

    // 写入 "pong" 用零拷贝 writeDirect
    var wc2: xev.Completion = .{};
    pair.remote.writeDirect(&loop, &wc2, 4, void, null, (struct {
        fn cb(_: ?*void, l: *xev.Loop, c: *xev.Completion, b: []u8, r: error{Closed}!usize) xev.CallbackAction {
            _ = l;
            _ = c;
            _ = r catch unreachable;
            b[0] = 'p';
            b[1] = 'o';
            b[2] = 'n';
            b[3] = 'g';
            return .disarm;
        }
    }).cb);

    // 零拷贝读取 remote 方向
    var rc1: xev.Completion = .{};
    pair.remote.readDirect(&loop, &rc1, ReadCtx, &remote_ctx, (struct {
        fn cb(ud: ?*ReadCtx, l: *xev.Loop, c: *xev.Completion, b: []const u8, r: error{Closed}!usize) xev.CallbackAction {
            _ = l;
            _ = c;
            const n = r catch unreachable;
            @memcpy(ud.?.data[0..n], b[0..n]);
            ud.?.n = n;
            return .disarm;
        }
    }).cb);

    // 零拷贝读取 local 方向
    var rc2: xev.Completion = .{};
    pair.local.readDirect(&loop, &rc2, ReadCtx, &local_ctx, (struct {
        fn cb(ud: ?*ReadCtx, l: *xev.Loop, c: *xev.Completion, b: []const u8, r: error{Closed}!usize) xev.CallbackAction {
            _ = l;
            _ = c;
            const n = r catch unreachable;
            @memcpy(ud.?.data[0..n], b[0..n]);
            ud.?.n = n;
            return .disarm;
        }
    }).cb);

    try loop.run(.until_done);
    try testing.expectEqualStrings("ping", remote_ctx.data[0..remote_ctx.n]);
    try testing.expectEqualStrings("pong", local_ctx.data[0..local_ctx.n]);
}

test "createPair: readDirect large data" {
    var loop = try xev.Loop.init(.{});
    defer loop.deinit();

    var pair = try createPair(4096, &loop, &loop, testing.allocator);
    defer pair.destroy();

    const msg = [_]u8{'B'} ** 4000;
    var write_done = false;

    const ReadCtx = struct {
        buf: [4000]u8 = undefined,
        total: usize = 0,
    };
    var read_ctx = ReadCtx{};

    var wc: xev.Completion = .{};
    pair.local.write(&loop, &wc, &msg, bool, &write_done, (struct {
        fn cb(ud: ?*bool, l: *xev.Loop, c: *xev.Completion, b: []const u8, r: error{Closed}!usize) xev.CallbackAction {
            _ = l;
            _ = c;
            _ = b;
            ud.?.* = true;
            _ = r catch unreachable;
            return .disarm;
        }
    }).cb);

    // 零拷贝读取 — 缓冲区 4096 足够容纳 4000 字节，无绕回，一次读取完成
    var rc: xev.Completion = .{};
    pair.remote.readDirect(&loop, &rc, ReadCtx, &read_ctx, (struct {
        fn cb(ud: ?*ReadCtx, l: *xev.Loop, c: *xev.Completion, b: []const u8, r: error{Closed}!usize) xev.CallbackAction {
            _ = l;
            _ = c;
            const n = r catch unreachable;
            @memcpy(ud.?.buf[0..n], b[0..n]);
            ud.?.total = n;
            return .disarm;
        }
    }).cb);

    try loop.run(.until_done);
    try testing.expect(write_done);
    try testing.expectEqual(@as(usize, 4000), read_ctx.total);
    try testing.expectEqualSlices(u8, &msg, read_ctx.buf[0..read_ctx.total]);
}

test "createPair: writeDirect full buffer rearm" {
    var loop = try xev.Loop.init(.{});
    defer loop.deinit();

    // 小缓冲区：仅 4 字节，强制绕回/满等待
    var pair = try createPair(4, &loop, &loop, testing.allocator);
    defer pair.destroy();

    var written = false;
    var read_buf: [8]u8 = undefined;
    var read_n: usize = 0;

    // 零拷贝写入 4 字节（填满缓冲区）
    var wc: xev.Completion = .{};
    pair.local.writeDirect(&loop, &wc, 4, bool, &written, (struct {
        fn cb(ud: ?*bool, l: *xev.Loop, c: *xev.Completion, b: []u8, r: error{Closed}!usize) xev.CallbackAction {
            _ = l;
            _ = c;
            _ = r catch unreachable;
            @memcpy(b[0..4], "abcd");
            ud.?.* = true;
            return .disarm;
        }
    }).cb);

    // 对端读取
    var rc: xev.Completion = .{};
    pair.remote.read(&loop, &rc, &read_buf, usize, &read_n, (struct {
        fn cb(ud: ?*usize, l: *xev.Loop, c: *xev.Completion, b: []u8, r: error{Closed}!usize) xev.CallbackAction {
            _ = l;
            _ = c;
            _ = b;
            ud.?.* = r catch unreachable;
            return .disarm;
        }
    }).cb);

    try loop.run(.until_done);
    try testing.expect(written);
    try testing.expectEqual(@as(usize, 4), read_n);
    try testing.expectEqualStrings("abcd", read_buf[0..read_n]);
}
