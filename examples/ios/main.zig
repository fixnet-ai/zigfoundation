//! zigfoundation iOS 示例 — 静态库，测试所有兼容模块
//!
//! 构建: zig build example-ios -Dtarget=aarch64-ios-simulator
//! 产出: zig-out/lib/libzigfoundation-example-ios.a
//!
//! 入口: export fn runAllTests() → 返回 true/false，通过 syslog 输出详情

const std = @import("std");
const foundation = @import("foundation");

// iOS 使用 syslog 输出（log.zig 自动路由到 darwinLog → syslog）
pub const std_options: std.Options = foundation.log.logOptions();

var passed: usize = 0;
var failed: usize = 0;

// 测试结果缓冲区，供 Swift 端通过 os.Logger 输出
var result_buffer: [4096]u8 = [_]u8{0} ** 4096;
var result_len: usize = 0;

fn appendResult(text: []const u8) void {
    if (result_len + text.len < result_buffer.len) {
        @memcpy(result_buffer[result_len..][0..text.len], text);
        result_len += text.len;
    }
}

fn check(module: []const u8, ok: bool) void {
    if (ok) {
        passed += 1;
        std.log.info("[PASS] {s}", .{module});
    } else {
        failed += 1;
        std.log.err("[FAIL] {s}", .{module});
    }
}

/// C-ABI 入口：Swift 调用此函数运行所有测试
export fn runAllTests() bool {
    result_len = 0;
    foundation.log.init(.info);
    std.log.info("zigfoundation iOS test starting...", .{});

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

    // 格式化结果到缓冲区（Swift 端通过 os.Logger 输出到统一日志）
    const summary = std.fmt.bufPrint(
        result_buffer[result_len..],
        "{d} passed, {d} failed, {d} total\n",
        .{ passed, failed, passed + failed },
    ) catch "result buffer full\n";
    result_len += summary.len;

    std.log.info("zigfoundation iOS: {d} passed, {d} failed", .{ passed, failed });
    return failed == 0;
}

/// 获取详细结果字符串（null-terminated，供 Swift 端 os.Logger 输出）
export fn getResultsBuf() [*:0]const u8 {
    if (result_len < result_buffer.len) {
        result_buffer[result_len] = 0;
        return @ptrCast(&result_buffer);
    }
    result_buffer[result_buffer.len - 1] = 0;
    return @ptrCast(&result_buffer);
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
// cli.zig — 跳过 daemonize (iOS 不支持)
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
    foundation.log.setLevel(.info); // 恢复级别，否则后续 PASS 不显示
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

    // iOS: use /tmp (system tmp directory, sandbox-accessible)
    const abs_path = "/tmp/zigfoundation-ios-test-store";
    std.Io.Dir.cwd().createDirPath(io, abs_path) catch {
        check("store", false);
        return;
    };
    defer _ = std.Io.Dir.cwd().deleteTree(io, abs_path) catch {};

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
// egress.zig — iOS 使用 interface_index (IP_BOUND_IF)
// ============================================================================
fn testEgress() void {
    var sock = foundation.egress.Socket.initUdp(.{
        .interface_index = 1, // iOS: IP_BOUND_IF
    }) catch {
        check("egress", false);
        return;
    };
    defer sock.close();
    check("egress", sock.getFd() != foundation.egress.INVALID_SOCKET);
}
