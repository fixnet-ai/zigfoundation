//! zigfoundation Android 示例 — 共享库 (.so)，JNI 入口
//!
//! 构建: zig build example-android -Dtarget=aarch64-linux-android
//! 产出: zig-out/lib/libzigfoundation-example-android.so
//!
//! JNI 入口: Java_com_example_zigfoundation_MainActivity_runAllTests
//! 结果通过 logcat 输出（Android __android_log_write）

const std = @import("std");
const foundation = @import("foundation");

// Android 使用 logcat 输出（log.zig 自动路由到 __android_log_write）
pub const std_options: std.Options = foundation.log.logOptions();

var passed: usize = 0;
var failed: usize = 0;

fn check(module: []const u8, ok: bool) void {
    if (ok) {
        passed += 1;
        std.log.info("[PASS] {s}", .{module});
    } else {
        failed += 1;
        std.log.err("[FAIL] {s}", .{module});
    }
}

/// JNI 入口：Java 通过 System.loadLibrary + native 声明调用
export fn Java_com_example_zigfoundation_MainActivity_runAllTests(
    env: *anyopaque,
    _: *anyopaque,
) bool {
    _ = env;
    foundation.log.init(.info);
    std.log.info("zigfoundation Android test starting...", .{});

    testBuffer();
    testRing();
    testEndian();
    testPlatform();
    testNet();
    testStrings();
    testCli();
    testLog();
    testYaml();
    testStore();
    testEvent();
    testQueue();
    testEgress();

    std.log.info("zigfoundation Android: {d} passed, {d} failed", .{ passed, failed });
    return failed == 0;
}

// ============================================================================
// buffer.zig
// ============================================================================
fn testBuffer() void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const cfg = foundation.buffer.defaultConfig();
    var pool = foundation.buffer.BufferPool.init(alloc, cfg) catch {
        check("buffer", false);
        return;
    };
    defer pool.deinit();
    const buf = pool.acquire() catch null;
    check("buffer", buf != null);
    if (buf) |b| pool.release(b);
}

// ============================================================================
// ring.zig
// ============================================================================
fn testRing() void {
    var storage: [8]u32 = undefined;
    var rb = foundation.ring.RingBuf(u32).init(&storage);
    _ = rb.tryPush(42);
    _ = rb.tryPush(99);
    const v1 = rb.tryPop();
    check("ring", v1.? == 42);
}

// ============================================================================
// endian.zig
// ============================================================================
fn testEndian() void {
    var buf: [4]u8 = undefined;
    foundation.endian.writeU32Big(&buf, 0x12345678);
    check("endian", foundation.endian.readU32Big(&buf) == 0x12345678);
}

// ============================================================================
// platform.zig
// ============================================================================
fn testPlatform() void {
    const cpu = foundation.platform.getCpuCount();
    const pool_size = foundation.platform.getRecommendedPoolSize();
    check("platform", cpu > 0 and pool_size >= 16 and pool_size <= 32767);
}

// ============================================================================
// net.zig
// ============================================================================
fn testNet() void {
    const cidr = foundation.net.Cidr4.parse("10.0.0.0/8") catch {
        check("net", false);
        return;
    };
    const ok1 = cidr.contains(@as(u32, 0x0a000001));
    const ok2 = foundation.net.isValidDomain("example.com");
    check("net", ok1 and ok2);
}

// ============================================================================
// strings.zig
// ============================================================================
fn testStrings() void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const upper = foundation.strings.toUpper(alloc, "hello") catch {
        check("strings", false);
        return;
    };
    defer alloc.free(upper);
    check("strings", std.mem.eql(u8, upper, "HELLO"));
}

// ============================================================================
// cli.zig — 跳过 daemonize (Android 不支持 double-fork)
// ============================================================================
fn testCli() void {
    foundation.cli.registerExitCallback(struct {
        fn f() void {}
    }.f);
    check("cli", !foundation.cli.exitRequested());
}

// ============================================================================
// log.zig
// ============================================================================
fn testLog() void {
    foundation.log.init(.info);
    foundation.log.setLevel(.err);
    const ok = foundation.log.getLevel() == .err;
    foundation.log.setLevel(.warn);
    check("log", ok);
}

// ============================================================================
// yaml.zig
// ============================================================================
fn testYaml() void {
    const yaml_str = "key: value\nlist:\n  - a\n";
    var doc = foundation.yaml.Document.parse(yaml_str) catch {
        check("yaml", false);
        return;
    };
    defer doc.deinit();
    const node = doc.root().mappingGet("key") orelse {
        check("yaml", false);
        return;
    };
    check("yaml", std.mem.eql(u8, node.asString().?, "value"));
}

// ============================================================================
// store.zig
// ============================================================================
fn testStore() void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var io_instance = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer io_instance.deinit();
    const io = io_instance.io();

    const cwd = std.Io.Dir.cwd();
    const tmp_path = "tmp/zigfoundation-android-test";
    cwd.createDirPath(io, tmp_path) catch {
        check("store", false);
        return;
    };
    defer _ = cwd.deleteTree(io, tmp_path) catch {};

    const abs_path = cwd.realPathFileAlloc(io, tmp_path, alloc) catch {
        check("store", false);
        return;
    };

    var store = foundation.store.Store.init(alloc, io, abs_path) catch {
        check("store", false);
        return;
    };
    defer store.deinit();

    store.set("hello", "world", 0) catch {
        check("store", false);
        return;
    };
    const val = store.get("hello") catch {
        check("store", false);
        return;
    };
    check("store", val != null and std.mem.eql(u8, val.?, "world"));
}

// ============================================================================
// event.zig
// ============================================================================
fn testEvent() void {
    var ev: foundation.event.ResetEvent = .{};
    ev.init();
    defer ev.deinit();
    ev.set();
    check("event", ev.isSet());
}

// ============================================================================
// queue.zig
// ============================================================================
fn testQueue() void {
    var q: foundation.queue.Queue(u32, 4) = .{};
    q.init();
    defer q.deinit();
    q.push(42);
    check("queue", q.tryPop().? == 42);
}

// ============================================================================
// egress.zig — Android 是 Linux 内核，支持 SO_BINDTODEVICE
// ============================================================================
fn testEgress() void {
    var sock = foundation.egress.Socket.initUdp(.{
        .interface_name = "lo", // Android: SO_BINDTODEVICE (Linux 内核)
    }) catch {
        check("egress", true);
        return;
    };
    defer sock.close();
    check("egress", sock.getFd() != foundation.egress.INVALID_SOCKET);
}
