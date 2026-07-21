//! FdStream — libxev fd 系流适配器
//!
//! 将 libxev TCP / File / GenericStream 适配为统一的 Stream 接口，
//! 消除参数差异：
//! - libxev 回调回传 `s: Self` → 适配器丢弃
//! - libxev 使用 ReadBuffer / WriteBuffer → 适配器转换为 []u8
//! - libxev 错误类型各异 → 适配器统一为 n=0 (类 EOF)
//!
//! 适配后的接口与 memconn.MemStream、relay.Stream 兼容：
//!
//! - `read(loop, c, buf: []u8, Userdata, userdata, cb)` — 异步读
//! - `write(loop, c, buf: []const u8, Userdata, userdata, cb)` — 异步写
//! - `close(loop, c, Userdata, userdata, cb)` — 异步关闭
//!
//! ## 使用示例
//!
//! ```zig
//! const fdconn = @import("fdconn.zig");
//! const adapted = fdconn.FdStream(xev.TCP);
//! // adapted 现在满足 Stream 接口，可直接传给 relay.relay()
//! ```

const xev = @import("xev");

/// 将 libxev fd 系流类型适配为统一的 Stream 接口。
///
/// S 是 libxev 流类型（TCP / File / GenericStream 等），
/// 需提供 `.read` / `.write` / `.close` 方法。
///
/// 适配后的回调签名：
/// ```
/// read:  fn(ud, l, c, buf: []u8,         r: error{Closed}!usize) CallbackAction
/// write: fn(ud, l, c, buf: []const u8,   r: error{Closed}!usize) CallbackAction
/// close: fn(ud, l, c,                    r: void)              CallbackAction
/// ```
pub fn FdStream(comptime S: type) type {
    return struct {
        const Self = @This();

        inner: S,

        /// 异步读 — 适配 libxev `.read` 回调签名到 Stream 接口
        pub fn read(
            self: *Self,
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
            self.inner.read(loop, c, xev.ReadBuffer{ .slice = buf }, Userdata, userdata, (struct {
                fn wrap(
                    ud: ?*Userdata,
                    l: *xev.Loop,
                    co: *xev.Completion,
                    s: S,
                    rb: xev.ReadBuffer,
                    r: xev.ReadError!usize,
                ) xev.CallbackAction {
                    _ = s;
                    const n = r catch @as(usize, 0);
                    return @call(.auto, cb, .{ ud, l, co, rb.slice, n });
                }
            }).wrap);
        }

        /// 异步写 — 适配 libxev `.write` 回调签名到 Stream 接口
        pub fn write(
            self: *Self,
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
            self.inner.write(loop, c, xev.WriteBuffer{ .slice = buf }, Userdata, userdata, (struct {
                fn wrap(
                    ud: ?*Userdata,
                    l: *xev.Loop,
                    co: *xev.Completion,
                    s: S,
                    wb: xev.WriteBuffer,
                    r: xev.WriteError!usize,
                ) xev.CallbackAction {
                    _ = s;
                    const n = r catch @as(usize, 0);
                    return @call(.auto, cb, .{ ud, l, co, wb.slice, n });
                }
            }).wrap);
        }

        /// 异步关闭 — 适配 libxev `.close` 回调签名到 Stream 接口
        pub fn close(
            self: *Self,
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
            self.inner.close(loop, c, Userdata, userdata, (struct {
                fn wrap(
                    ud: ?*Userdata,
                    l: *xev.Loop,
                    co: *xev.Completion,
                    s: S,
                    r: xev.CloseError!void,
                ) xev.CallbackAction {
                    _ = s;
                    _ = r catch {};
                    return @call(.auto, cb, .{ ud, l, co, {} });
                }
            }).wrap);
        }
    };
}

// ============================================================================
// 测试
// ============================================================================

const testing = @import("std").testing;

test "fdconn: reference all pub decls (lazy-analysis guard)" {
    testing.refAllDecls(@This());
}

test "fdconn: FdStream wraps xev.Stream (compile-time verification)" {
    const F = FdStream(xev.Stream);
    testing.refAllDecls(F);
    try testing.expect(true);
}
