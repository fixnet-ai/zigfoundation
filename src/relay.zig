//! 异步双向数据中继 — 任意两个 Stream 之间的数据对拷
//!
//! ## 用途
//!
//! 在不修改两端代码的情况下，桥接任意两个异步字节流，实现双向数据转发。
//! 典型场景：TUN↔socket、TLS↔plain、MUX↔remote fd 等。
//!
//! ## Stream 概念
//!
//! 任何实现以下 Completion 方法的类型都可作为 relay 端点：
//!
//! - `read(loop, c, buf: []u8, Userdata, userdata, cb)` — 异步读
//! - `write(loop, c, buf: []const u8, Userdata, userdata, cb)` — 异步写
//! - `close(loop, c, Userdata, userdata, cb)` — 异步关闭
//!
//! 回调签名（与 memconn.MemStream 一致）：
//!
//! ```
//! read:  fn(ud, l, c, buf: []u8,         r: E!usize) CallbackAction  // 0=EOF
//! write: fn(ud, l, c, buf: []const u8,   r: E!usize) CallbackAction
//! close: fn(ud, l, c,                    r: void)   CallbackAction
//! ```
//!
//! - **memconn.MemStream** 原生满足此接口，无需适配。
//! - **libxev fd 系** (TCP/File/Stream) 通过 `fdconn.FdStream` 适配器包装。
//!
//! ## 架构
//!
//! ```
//! relay(loop, A, B)
//!   ├─ a_buf[8192]  — A→B 方向缓冲
//!   ├─ b_buf[8192]  — B→A 方向缓冲
//!   ├─ read A → write B → read A → ...  (Completion 链)
//!   └─ read B → write A → read B → ...  (Completion 链)
//!
//! 关闭序列:
//!   端 A EOF → close(B) → close(A) → on_done 回调
//! ```
//!
//! ## 使用示例
//!
//! ```zig
//! // memconn ↔ memconn relay
//! var pair_a = try memconn.createPair(4096, &loop, &loop, allocator);
//! var pair_b = try memconn.createPair(4096, &loop, &loop, allocator);
//!
//! try relay.relay(allocator, &loop, pair_a.remote, pair_b.local, .{}, void, null, (struct {
//!     fn cb(_: ?*void) void { std.debug.print("relay done\n", .{}); }
//! }).cb);
//! ```
//!
//! ## 线程安全
//!
//! - relay 在单个 Loop 内运行，两端 Completion 在同一事件循环调度
//! - relay 期间不可从外部操作 relay 持有的 stream 端点
//! - on_done 回调在 Loop 线程上下文中执行

const std = @import("std");
const xev = @import("xev");

// ============================================================================
// Relay 配置
// ============================================================================

pub const RelayConfig = struct {
    /// 每方向读缓冲区大小（字节）
    buf_size: usize = 8192,
};

// ============================================================================
// relay() — 启动双向数据中继
// ============================================================================

/// 启动双向 relay。立即返回，中继在 Completion 回调链中异步运行。
///
/// 当两端都关闭后，调用 on_done(userdata) 通知调用者。
/// relay 期间，a 和 b 的所有权转移给 relay 内部上下文（不可从外部操作）。
///
/// 约束：
/// - a 和 b 必须实现 Stream 接口（read/write/close）
/// - loop 必须由调用者驱动的同一事件循环
/// - buf_size 决定每方向读缓冲区块大小
pub fn relay(
    allocator: std.mem.Allocator,
    loop: *xev.Loop,
    a: anytype,
    b: anytype,
    comptime config: RelayConfig,
    comptime Userdata: type,
    userdata: ?*Userdata,
    comptime on_done: *const fn (?*Userdata) void,
) !void {
    const A = @TypeOf(a);
    const B = @TypeOf(b);

    // 分配缓冲区
    const a_buf = try allocator.alloc(u8, config.buf_size);
    errdefer allocator.free(a_buf);
    const b_buf = try allocator.alloc(u8, config.buf_size);
    errdefer allocator.free(b_buf);

    // 分配 Relay 上下文（堆分配，异步生命周期）
    const R = RelayCtx(A, B, Userdata, on_done);
    const ctx = try allocator.create(R);
    errdefer allocator.destroy(ctx);

    ctx.* = .{
        .allocator = allocator,
        .loop = loop,
        .a = a,
        .b = b,
        .a_buf = a_buf,
        .b_buf = b_buf,
        .userdata = userdata,
    };

    // 启动两个方向
    ctx.startReadA();
    ctx.startReadB();
}

// ============================================================================
// RelayCtx — relay 运行时上下文（堆分配，completion 嵌入其中）
// ============================================================================

fn RelayCtx(
    comptime A: type,
    comptime B: type,
    comptime Userdata: type,
    comptime on_done: *const fn (?*Userdata) void,
) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        loop: *xev.Loop,
        a: A,
        b: B,
        a_buf: []u8,
        b_buf: []u8,
        userdata: ?*Userdata,

        // 每方向独立的 Completion（嵌入结构体，生命周期覆盖 relay 全程）
        a_read_c: xev.Completion = .{},
        a_write_c: xev.Completion = .{},
        a_close_c: xev.Completion = .{},
        b_read_c: xev.Completion = .{},
        b_write_c: xev.Completion = .{},
        b_close_c: xev.Completion = .{},

        // 关闭状态 — 防止重复关闭
        a_closing: bool = false,
        b_closing: bool = false,
        stopped: bool = false,

        // ---- A→B 方向: read A → write B → read A → ... ----

        fn startReadA(self: *Self) void {
            if (self.stopped) return;
            self.a.read(self.loop, &self.a_read_c, self.a_buf, Self, self, (struct {
                fn cb(ud: ?*Self, l: *xev.Loop, c: *xev.Completion, buf: []u8, r: error{Closed}!usize) xev.CallbackAction {
                    _ = l;
                    _ = c;
                    _ = buf;
                    const s = ud.?;
                    const n = r catch 0;
                    if (n == 0) {
                        s.onAeof();
                        return .disarm;
                    }
                    s.b.write(s.loop, &s.b_write_c, s.a_buf[0..n], Self, s, (struct {
                        fn cb2(ud2: ?*Self, l2: *xev.Loop, c2: *xev.Completion, b2: []const u8, r2: error{Closed}!usize) xev.CallbackAction {
                            _ = l2;
                            _ = c2;
                            _ = b2;
                            _ = r2 catch {};
                            ud2.?.startReadA();
                            return .disarm;
                        }
                    }).cb2);
                    return .disarm;
                }
            }).cb);
        }

        fn onAeof(self: *Self) void {
            if (self.b_closing) return;
            self.b_closing = true;
            self.b.close(self.loop, &self.b_close_c, Self, self, (struct {
                fn cb(ud: ?*Self, l: *xev.Loop, c: *xev.Completion, _: void) xev.CallbackAction {
                    _ = l;
                    _ = c;
                    ud.?.onBclosed();
                    return .disarm;
                }
            }).cb);
        }

        fn onBclosed(self: *Self) void {
            if (self.a_closing) {
                self.finish();
                return;
            }
            self.a_closing = true;
            self.a.close(self.loop, &self.a_close_c, Self, self, (struct {
                fn cb(ud: ?*Self, l: *xev.Loop, c: *xev.Completion, _: void) xev.CallbackAction {
                    _ = l;
                    _ = c;
                    ud.?.finish();
                    return .disarm;
                }
            }).cb);
        }

        // ---- B→A 方向: read B → write A → read B → ... ----

        fn startReadB(self: *Self) void {
            if (self.stopped) return;
            self.b.read(self.loop, &self.b_read_c, self.b_buf, Self, self, (struct {
                fn cb(ud: ?*Self, l: *xev.Loop, c: *xev.Completion, buf: []u8, r: error{Closed}!usize) xev.CallbackAction {
                    _ = l;
                    _ = c;
                    _ = buf;
                    const s = ud.?;
                    const n = r catch 0;
                    if (n == 0) {
                        s.onBeof();
                        return .disarm;
                    }
                    s.a.write(s.loop, &s.a_write_c, s.b_buf[0..n], Self, s, (struct {
                        fn cb2(ud2: ?*Self, l2: *xev.Loop, c2: *xev.Completion, b2: []const u8, r2: error{Closed}!usize) xev.CallbackAction {
                            _ = l2;
                            _ = c2;
                            _ = b2;
                            _ = r2 catch {};
                            ud2.?.startReadB();
                            return .disarm;
                        }
                    }).cb2);
                    return .disarm;
                }
            }).cb);
        }

        fn onBeof(self: *Self) void {
            if (self.a_closing) return;
            self.a_closing = true;
            self.a.close(self.loop, &self.a_close_c, Self, self, (struct {
                fn cb(ud: ?*Self, l: *xev.Loop, c: *xev.Completion, _: void) xev.CallbackAction {
                    _ = l;
                    _ = c;
                    ud.?.onAclosed();
                    return .disarm;
                }
            }).cb);
        }

        fn onAclosed(self: *Self) void {
            if (self.b_closing) {
                self.finish();
                return;
            }
            self.b_closing = true;
            self.b.close(self.loop, &self.b_close_c, Self, self, (struct {
                fn cb(ud: ?*Self, l: *xev.Loop, c: *xev.Completion, _: void) xev.CallbackAction {
                    _ = l;
                    _ = c;
                    ud.?.finish();
                    return .disarm;
                }
            }).cb);
        }

        fn finish(self: *Self) void {
            if (self.stopped) return;
            self.stopped = true;

            // 释放缓冲区
            self.allocator.free(self.a_buf);
            self.allocator.free(self.b_buf);

            // 通知调用者
            const ud = self.userdata;
            on_done(ud);

            // 注意：不在此处释放 RelayCtx。close 回调链导致 finish 可能在
            // close() 调用内部被触发，而 close() 在回调返回后仍会访问自身字段
            // （如 _close_releases）。此时释放 context 会导致 use-after-free。
            // 调用者应使用 ArenaAllocator 或等效机制管理 relay 内存。
        }
    };
}

// ============================================================================
// 测试
// ============================================================================

const testing = std.testing;
const memconn = @import("memconn.zig");
const fdconn = @import("fdconn.zig");

test "relay: reference all pub decls (lazy-analysis guard)" {
    testing.refAllDecls(@This());
}

test "relay: basic memstream ↔ memstream" {
    // 使用 ArenaAllocator 管理 relay 内存（relay context 在 finish 中不释放自身，
    // 以避免 close 回调链中的 use-after-free；由 arena 统一释放）
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var loop = try xev.Loop.init(.{});
    defer loop.deinit();

    // 创建两对 memconn（memconn 需要独立 allocator，其生命周期短于 arena）
    var pair_a = try memconn.createPair(256, &loop, &loop, testing.allocator);
    defer pair_a.destroy();
    var pair_b = try memconn.createPair(256, &loop, &loop, testing.allocator);
    defer pair_b.destroy();

    // 向 pair_a.local 写入数据（模拟外部输入）
    var wc: xev.Completion = .{};
    var write_done = false;
    pair_a.local.write(&loop, &wc, "hello", bool, &write_done, (struct {
        fn cb(ud: ?*bool, l: *xev.Loop, c: *xev.Completion, b: []const u8, r: error{Closed}!usize) xev.CallbackAction {
            _ = l;
            _ = c;
            _ = b;
            _ = r catch {};
            ud.?.* = true;
            return .disarm;
        }
    }).cb);

    // 启动 relay: pair_a.remote ↔ pair_b.local
    var relay_done = false;
    try relay(allocator, &loop, pair_a.remote, pair_b.local, .{ .buf_size = 64 }, bool, &relay_done, (struct {
        fn cb(ud: ?*bool) void {
            ud.?.* = true;
        }
    }).cb);

    // 注册对 pair_b.remote 的读（等待 relay 转发的数据）
    var read_buf: [64]u8 = undefined;
    var read_n: usize = 0;
    var rc: xev.Completion = .{};
    pair_b.remote.read(&loop, &rc, &read_buf, usize, &read_n, (struct {
        fn cb(ud: ?*usize, l: *xev.Loop, c: *xev.Completion, b: []u8, r: error{Closed}!usize) xev.CallbackAction {
            _ = l;
            _ = c;
            _ = b;
            ud.?.* = r catch 0;
            return .disarm;
        }
    }).cb);

    // 关闭 pair_a.local 以触发 relay 关闭序列（否则 relay 保持活跃 completion）
    var cc: xev.Completion = .{};
    pair_a.local.close(&loop, &cc, void, null, (struct {
        fn cb(_: ?*void, _: *xev.Loop, _: *xev.Completion, _: void) xev.CallbackAction {
            return .disarm;
        }
    }).cb);

    try loop.run(.until_done);

    try testing.expect(write_done);
    try testing.expectEqual(@as(usize, 5), read_n);
    try testing.expectEqualStrings("hello", read_buf[0..read_n]);
    try testing.expect(relay_done);
}

test "relay: memstream ↔ memstream EOF propagation" {
    // 使用 ArenaAllocator 管理 relay 内存（避免 close 回调链中释放 RelayCtx 导致 use-after-free）
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var loop = try xev.Loop.init(.{});
    defer loop.deinit();

    var pair_a = try memconn.createPair(256, &loop, &loop, testing.allocator);
    defer pair_a.destroy();
    var pair_b = try memconn.createPair(256, &loop, &loop, testing.allocator);
    defer pair_b.destroy();

    // 启动 relay
    var relay_done = false;
    try relay(allocator, &loop, pair_a.remote, pair_b.local, .{ .buf_size = 64 }, bool, &relay_done, (struct {
        fn cb(ud: ?*bool) void {
            ud.?.* = true;
        }
    }).cb);

    // 关闭 pair_a.local → pair_a.remote 读到 EOF → relay 传播关闭
    var cc: xev.Completion = .{};
    pair_a.local.close(&loop, &cc, void, null, (struct {
        fn cb(_: ?*void, _: *xev.Loop, _: *xev.Completion, _: void) xev.CallbackAction {
            return .disarm;
        }
    }).cb);

    try loop.run(.until_done);

    try testing.expect(relay_done);
    try testing.expect(pair_b.remote.isClosed());
}

test "relay: bidirectional memstream ↔ memstream" {
    // 使用 ArenaAllocator 管理 relay 内存
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var loop = try xev.Loop.init(.{});
    defer loop.deinit();

    var pair_a = try memconn.createPair(256, &loop, &loop, testing.allocator);
    defer pair_a.destroy();
    var pair_b = try memconn.createPair(256, &loop, &loop, testing.allocator);
    defer pair_b.destroy();

    const BidirCtx = struct {
        a_to_b_data: [5]u8 = .{0} ** 5,
        a_to_b_n: usize = 0,
        b_to_a_data: [5]u8 = .{0} ** 5,
        b_to_a_n: usize = 0,
    };
    var bidir_ctx = BidirCtx{};

    // 向 pair_a.local 写入 "ping"（A→B 方向）
    var wc1: xev.Completion = .{};
    pair_a.local.write(&loop, &wc1, "ping", void, null, (struct {
        fn cb(_: ?*void, _: *xev.Loop, _: *xev.Completion, _: []const u8, _: error{Closed}!usize) xev.CallbackAction {
            return .disarm;
        }
    }).cb);

    // 向 pair_b.remote 写入 "pong"（B→A 方向）
    var wc2: xev.Completion = .{};
    pair_b.remote.write(&loop, &wc2, "pong", void, null, (struct {
        fn cb(_: ?*void, _: *xev.Loop, _: *xev.Completion, _: []const u8, _: error{Closed}!usize) xev.CallbackAction {
            return .disarm;
        }
    }).cb);

    // 启动 relay
    var relay_done = false;
    try relay(allocator, &loop, pair_a.remote, pair_b.local, .{ .buf_size = 64 }, bool, &relay_done, (struct {
        fn cb(ud: ?*bool) void {
            ud.?.* = true;
        }
    }).cb);

    // 从 pair_b.remote 读（应该收到 "ping"）
    var rc1: xev.Completion = .{};
    pair_b.remote.read(&loop, &rc1, &bidir_ctx.a_to_b_data, BidirCtx, &bidir_ctx, (struct {
        fn cb(ud: ?*BidirCtx, l: *xev.Loop, c: *xev.Completion, _: []u8, r: error{Closed}!usize) xev.CallbackAction {
            _ = l;
            _ = c;
            ud.?.a_to_b_n = r catch 0;
            return .disarm;
        }
    }).cb);

    // 从 pair_a.local 读（应该收到 "pong"）
    var rc2: xev.Completion = .{};
    pair_a.local.read(&loop, &rc2, &bidir_ctx.b_to_a_data, BidirCtx, &bidir_ctx, (struct {
        fn cb(ud: ?*BidirCtx, l: *xev.Loop, c: *xev.Completion, _: []u8, r: error{Closed}!usize) xev.CallbackAction {
            _ = l;
            _ = c;
            ud.?.b_to_a_n = r catch 0;
            return .disarm;
        }
    }).cb);

    // 关闭 pair_a.local 触发 relay 关闭序列（否则活跃 completion 阻止 loop 退出）
    var cc: xev.Completion = .{};
    pair_a.local.close(&loop, &cc, void, null, (struct {
        fn cb(_: ?*void, _: *xev.Loop, _: *xev.Completion, _: void) xev.CallbackAction {
            return .disarm;
        }
    }).cb);

    try loop.run(.until_done);

    try testing.expectEqual(@as(usize, 4), bidir_ctx.a_to_b_n);
    try testing.expectEqualStrings("ping", bidir_ctx.a_to_b_data[0..bidir_ctx.a_to_b_n]);
    try testing.expectEqual(@as(usize, 4), bidir_ctx.b_to_a_n);
    try testing.expectEqualStrings("pong", bidir_ctx.b_to_a_data[0..bidir_ctx.b_to_a_n]);
}

test "relay: fdconn.FdStream wraps xev.Stream (compile-time verification)" {
    // 验证 fdconn.FdStream(xev.Stream) 类型构造和所有公开声明均可正常通过编译
    const F = fdconn.FdStream(xev.Stream);
    testing.refAllDecls(F);
    try testing.expect(true);
}
