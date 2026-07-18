//! zigfoundation iOS Simulator 测试 — 纯 CLI 可执行文件
//!
//! 构建: zig build ios-test-runner -Dtarget=aarch64-ios-simulator -Dsysroot=...
//! 运行: xcrun simctl spawn booted zig-out/bin/zigfoundation-ios-test
//!
//! 不依赖 Swift / Xcode / .app bundle — 直接通过 simctl spawn 运行

const std = @import("std");
const foundation = @import("foundation");

var passed: usize = 0;
var failed: usize = 0;

fn check(name: []const u8, ok: bool) void {
    if (ok) {
        passed += 1;
        std.debug.print("[PASS] {s}\n", .{name});
    } else {
        failed += 1;
        std.debug.print("[FAIL] {s}\n", .{name});
    }
}

pub fn main() u8 {
    std.debug.print("\n=== zigfoundation iOS Simulator Test ===\n\n", .{});

    // ---- buffer ----
    buff: {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const cfg = foundation.buffer.defaultConfig();
        var pool = foundation.buffer.BufferPool.init(arena.allocator(), cfg) catch {
            check("buffer", false);
            break :buff;
        };
        defer pool.deinit();
        const buf = pool.acquire() catch null;
        check("buffer", buf != null);
        if (buf) |b| pool.release(b);
    }

    // ---- ring ----
    {
        var storage: [8]u32 = undefined;
        var rb = foundation.ring.RingBuf(u32).init(&storage);
        _ = rb.tryPush(42);
        _ = rb.tryPush(99);
        check("ring", rb.tryPop().? == 42);
    }

    // ---- endian ----
    {
        var buf: [4]u8 = undefined;
        foundation.endian.writeU32Big(&buf, 0x12345678);
        check("endian", foundation.endian.readU32Big(&buf) == 0x12345678);
    }

    // ---- platform ----
    {
        const cpu = foundation.platform.getCpuCount();
        const pool_size = foundation.platform.getRecommendedPoolSize();
        check("platform", cpu > 0 and pool_size >= 16 and pool_size <= 32767);
    }

    // ---- net ----
    net_blk: {
        const c = foundation.net.Cidr4.parse("10.0.0.0/8") catch {
            check("net", false);
            break :net_blk;
        };
        const ok1 = c.contains(@as(u32, 0x0a000001));
        const ok2 = foundation.net.isValidDomain("example.com");
        check("net", ok1 and ok2);
    }

    // ---- strings ----
    str_blk: {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const upper = foundation.strings.toUpper(arena.allocator(), "hello") catch {
            check("strings", false);
            break :str_blk;
        };
        check("strings", std.mem.eql(u8, upper, "HELLO"));
    }

    // ---- cli (跳过 daemonize) ----
    {
        foundation.cli.registerExitCallback(struct {
            fn f() void {}
        }.f);
        check("cli", !foundation.cli.exitRequested());
    }

    // ---- log ----
    {
        foundation.log.init(.info);
        foundation.log.setLevel(.err);
        const ok = foundation.log.getLevel() == .err;
        foundation.log.setLevel(.warn);
        check("log", ok);
    }

    // ---- yaml ----
    yaml_blk: {
        const yaml_str = "key: value\nlist:\n  - a\n";
        var doc = foundation.yaml.Document.parse(yaml_str) catch {
            check("yaml", false);
            break :yaml_blk;
        };
        defer doc.deinit();
        const node = doc.root().mappingGet("key") orelse {
            check("yaml", false);
            break :yaml_blk;
        };
        check("yaml", std.mem.eql(u8, node.asString().?, "value"));
    }

    // ---- store ----
    store_blk: {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        var io_instance = std.Io.Threaded.init(std.heap.page_allocator, .{});
        defer io_instance.deinit();
        const io = io_instance.io();

        const cwd = std.Io.Dir.cwd();
        const tmp_path = "tmp/zigfoundation-ios-cli-test";
        cwd.createDirPath(io, tmp_path) catch {
            check("store", false);
            break :store_blk;
        };
        defer _ = cwd.deleteTree(io, tmp_path) catch {};

        const abs_path = cwd.realPathFileAlloc(io, tmp_path, alloc) catch {
            check("store", false);
            break :store_blk;
        };

        var store = foundation.store.Store.init(alloc, io, abs_path) catch {
            check("store", false);
            break :store_blk;
        };
        defer store.deinit();

        store.set("hello", "world", 0) catch {
            check("store", false);
            break :store_blk;
        };

        const val = store.get("hello") catch null;
        check("store", val != null and std.mem.eql(u8, val.?, "world"));
    }

    // ---- event ----
    {
        var ev: foundation.event.ResetEvent = .{};
        ev.init();
        defer ev.deinit();
        ev.set();
        check("event", ev.isSet());
    }

    // ---- queue ----
    {
        var q: foundation.queue.Queue(u32, 4) = .{};
        q.init();
        defer q.deinit();
        q.push(42);
        check("queue", q.tryPop().? == 42);
    }

    // ---- egress (iOS: interface_index) ----
    {
        if (foundation.egress.Socket.initUdp(.{ .interface_index = 1 })) |sock_val| {
            var sock = sock_val;
            sock.close();
            check("egress", true);
        } else |_| {
            check("egress", false);
        }
    }

    std.debug.print("\n---\n{d} passed, {d} failed\n", .{ passed, failed });
    return if (failed > 0) @as(u8, 1) else @as(u8, 0);
}
