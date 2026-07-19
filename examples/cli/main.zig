//! zigfoundation 集成测试 CLI — 完整测试全部 14 个模块
//!
//! 构建: zig build example-cli
//! 运行: ./zig-out/bin/zigfoundation-example-cli
//!
//! 每个模块至少 1 个测试用例，断言关键行为，汇总输出 pass/fail。

const std = @import("std");
const foundation = @import("foundation");
const xev = @import("xev");

// 通过 log.zig 统一日志输出
pub const std_options: std.Options = foundation.log.logOptions();

var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
const allocator = arena.allocator();

var passed: usize = 0;
var failed: usize = 0;

fn check(module: []const u8, ok: bool) void {
    if (ok) {
        passed += 1;
        std.debug.print("[{s}PASS{s}] {s}\n", .{ "\x1b[32m", "\x1b[0m", module });
    } else {
        failed += 1;
        std.debug.print("[{s}FAIL{s}] {s}\n", .{ "\x1b[31m", "\x1b[0m", module });
    }
}

pub fn main() u8 {
    defer arena.deinit();

    std.debug.print("\n=== zigfoundation 集成测试 ({s}) ===\n\n", .{foundation.version_str});

    testBuffer();
    testRing();
    testRingZeroCopy();
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
    testMemconnDirect();

    std.debug.print("\n---\n{d} passed, {d} failed\n\n", .{ passed, failed });
    return if (failed > 0) @as(u8, 1) else @as(u8, 0);
}

// ============================================================================
// buffer.zig — BufferPool 共享内存池
// ============================================================================
fn testBuffer() void {
    const cfg = foundation.buffer.defaultConfig();
    var pool = foundation.buffer.BufferPool.init(allocator, cfg) catch {
        check("buffer", false);
        return;
    };
    defer pool.deinit();

    const buf = pool.acquire() catch null;
    const ok = buf != null;
    if (buf) |b| {
        pool.release(b);
    }
    _ = pool.shrinkToInitial();
    check("buffer", ok);
}

// ============================================================================
// ring.zig — SPSC 环缓冲区
// ============================================================================
fn testRing() void {
    var storage: [8]u32 = undefined;
    var rb = foundation.ring.RingBuf(u32).init(&storage);

    _ = rb.tryPush(42);
    _ = rb.tryPush(99);
    const v1 = rb.tryPop();
    const v2 = rb.tryPop();

    check("ring", v1 != null and v1.? == 42 and v2 != null and v2.? == 99 and rb.isEmpty());
}

// ============================================================================
// endian.zig — 大小端转换
// ============================================================================
fn testEndian() void {
    var buf: [4]u8 = undefined;
    foundation.endian.writeU32Big(&buf, 0x12345678);
    const val = foundation.endian.readU32Big(&buf);
    check("endian", val == 0x12345678);
}

// ============================================================================
// platform.zig — 平台抽象
// ============================================================================
fn testPlatform() void {
    const cpu = foundation.platform.getCpuCount();
    const t1 = foundation.platform.monoMillis();
    const t2 = foundation.platform.monoMillis();
    const pool_size = foundation.platform.getRecommendedPoolSize();

    var ok = cpu > 0;
    ok = ok and t2 >= t1;
    ok = ok and pool_size >= 16 and pool_size <= 32767;
    check("platform", ok);
}

// ============================================================================
// net.zig — 网络工具
// ============================================================================
fn testNet() void {
    // Cidr4 解析 + 包含测试
    const cidr = foundation.net.Cidr4.parse("10.0.0.0/8") catch {
        check("net", false);
        return;
    };
    const in_net = cidr.contains(@as(u32, 0x0a000001)); // 10.0.0.1
    const out_net = cidr.contains(@as(u32, 0xc0a80001)); // 192.168.0.1

    // parseHostPort
    const hp = foundation.net.parseHostPort("localhost:8080") catch {
        check("net", false);
        return;
    };

    // formatIpv4
    var ip_buf: [foundation.net.max_addr_buf]u8 = undefined;
    const ip_str = foundation.net.formatIpv4(&[_]u8{ 192, 168, 1, 1 }, &ip_buf);

    // isValidHost
    const valid_domain = foundation.net.isValidDomain("example.com");

    var ok = in_net and !out_net;
    ok = ok and std.mem.eql(u8, hp.host, "localhost") and hp.port == 8080;
    ok = ok and std.mem.eql(u8, ip_str, "192.168.1.1");
    ok = ok and valid_domain;
    check("net", ok);
}

// ============================================================================
// strings.zig — 字符串工具
// ============================================================================
fn testStrings() void {
    // toUpper (alloc)
    const upper = foundation.strings.toUpper(allocator, "hello") catch {
        check("strings", false);
        return;
    };
    defer allocator.free(upper);
    const ok1 = std.mem.eql(u8, upper, "HELLO");

    // contains
    const ok2 = foundation.strings.contains("hello world", "world");

    // join
    const parts = &[_][]const u8{ "a", "b", "c" };
    const joined = foundation.strings.join(allocator, parts, ",") catch {
        check("strings", false);
        return;
    };
    defer allocator.free(joined);
    const ok3 = std.mem.eql(u8, joined, "a,b,c");

    // startsWithIgnoreCase
    const ok4 = foundation.strings.startsWithIgnoreCase("HelloWorld", "hello");

    // splitTrim
    var iter = foundation.strings.splitTrim(" one , two , three ", ',');
    const part1 = iter.next();
    const part2 = iter.next();
    const ok5 = std.mem.eql(u8, part1.?, "one") and std.mem.eql(u8, part2.?, "two");

    check("strings", ok1 and ok2 and ok3 and ok4 and ok5);
}

// ============================================================================
// cli.zig — CLI 框架（zli 封装 + 信号处理 + 守护进程）
// ============================================================================
fn testCli() void {
    const root = foundation.cli.createRoot(allocator, .{
        .name = "zigfoundation-test",
        .description = "integration test",
    }) catch {
        check("cli", false);
        return;
    };
    defer root.deinit();

    // registerExitCallback
    var cb_called = false;
    const Callback = struct {
        var flag: *bool = undefined;
        fn handler() void {
            flag.* = true;
        }
    };
    Callback.flag = &cb_called;
    foundation.cli.registerExitCallback(Callback.handler);

    // check that exitRequested returns false (no signal sent)
    const not_exited = !foundation.cli.exitRequested();

    check("cli", not_exited);
}

// ============================================================================
// log.zig — 跨平台日志
// ============================================================================
fn testLog() void {
    foundation.log.init(.debug);
    const lvl = foundation.log.getLevel();
    const ok1 = lvl == .debug;

    foundation.log.setLevel(.err);
    const lvl2 = foundation.log.getLevel();
    const ok2 = lvl2 == .err;

    // 恢复默认级别
    foundation.log.setLevel(.warn);

    // 实际写一条日志（验证不崩溃）
    std.log.info("zigfoundation integration test log", .{});

    check("log", ok1 and ok2);
}

// ============================================================================
// yaml.zig — YAML 解析
// ============================================================================
fn testYaml() void {
    const yaml_str =
        \\server:
        \\  host: localhost
        \\  port: 8080
        \\  debug: true
        \\tags:
        \\  - web
        \\  - api
    ;

    var doc = foundation.yaml.Document.parse(yaml_str) catch {
        check("yaml", false);
        return;
    };
    defer doc.deinit();

    const root = doc.root();

    // 访问 mapping
    const server = root.mappingGet("server") orelse {
        check("yaml", false);
        return;
    };
    const host = server.mappingGet("host") orelse {
        check("yaml", false);
        return;
    };
    const port = server.mappingGet("port") orelse {
        check("yaml", false);
        return;
    };
    const debug = server.mappingGet("debug") orelse {
        check("yaml", false);
        return;
    };

    const host_ok = std.mem.eql(u8, host.asString().?, "localhost");
    const port_ok = port.asInt(u16).? == 8080;
    const debug_ok = debug.asBool().? == true;

    // 访问 sequence
    const tags = root.mappingGet("tags") orelse {
        check("yaml", false);
        return;
    };
    const tag0 = tags.seqGet(0) orelse {
        check("yaml", false);
        return;
    };

    const tags_ok = std.mem.eql(u8, tag0.asString().?, "web") and tags.seqLen() == 2;

    check("yaml", host_ok and port_ok and debug_ok and tags_ok);
}

// ============================================================================
// store.zig — 持久化 KV 存储
// ============================================================================
fn testStore() void {
    const tmp_path = "zig-out/tmp/example-store-test";

    // 创建 Io 实例（用于文件系统操作）
    var io_instance = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer io_instance.deinit();
    const io = io_instance.io();

    // 确保 tmp 目录存在
    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, tmp_path) catch {
        check("store", false);
        return;
    };

    const abs_path = cwd.realPathFileAlloc(io, tmp_path, allocator) catch {
        check("store", false);
        return;
    };
    defer allocator.free(abs_path);

    var store = foundation.store.Store.init(
        allocator,
        io,
        abs_path,
    ) catch {
        check("store", false);
        return;
    };
    defer store.deinit();

    // set + get
    store.set("hello", "world", 0) catch {
        check("store", false);
        return;
    };
    const val = store.get("hello") catch {
        check("store", false);
        return;
    };
    const ok1 = val != null and std.mem.eql(u8, val.?, "world");

    // delete + get → null
    store.delete("hello") catch {
        check("store", false);
        return;
    };
    const val2 = store.get("hello") catch {
        check("store", false);
        return;
    };
    const ok2 = val2 == null;

    // cleanup
    _ = cwd.deleteTree(io, tmp_path) catch {};

    check("store", ok1 and ok2);
}

// ============================================================================
// event.zig — 跨线程事件通知 (ResetEvent)
// ============================================================================
fn testEvent() void {
    var ev: foundation.event.ResetEvent = .{};
    ev.init();
    defer ev.deinit();

    const ok1 = !ev.isSet();

    ev.set();
    const ok2 = ev.isSet();

    // wait 应该立即返回（已 set）
    ev.wait();

    ev.reset();
    const ok3 = !ev.isSet();

    // timedWait 不 set → 超时返回 false
    const ok4 = !ev.timedWait(10);

    check("event", ok1 and ok2 and ok3 and ok4);
}

// ============================================================================
// queue.zig — 有界 MPSC 队列
// ============================================================================
fn testQueue() void {
    var q: foundation.queue.Queue(u32, 4) = .{};
    q.init();
    defer q.deinit();

    q.push(10);
    q.push(20);
    q.push(30);

    const ok1 = q.len() == 3;

    const v1 = q.tryPop();
    const v2 = q.tryPop();
    const v3 = q.tryPop();
    const v_empty = q.tryPop();

    const ok2 = v1.? == 10 and v2.? == 20 and v3.? == 30 and v_empty == null;
    const ok3 = q.len() == 0;

    // 溢出测试：push 5 项到容量 4 的队列
    q.push(1);
    q.push(2);
    q.push(3);
    q.push(4);
    q.push(5); // 覆盖 1
    const first = q.tryPop();
    const ok4 = first.? == 2; // 最老的 (1) 被覆盖

    check("queue", ok1 and ok2 and ok3 and ok4);
}

// ============================================================================
// egress.zig — 网络出站 (socket 创建 + 接口绑定)
// ============================================================================
fn testEgress() void {
    var sock = foundation.egress.Socket.initTcp(.{ .reuse_addr = true }) catch {
        check("egress", false);
        return;
    };
    defer sock.close();

    const fd = sock.getFd();
    const ok1 = fd != foundation.egress.INVALID_SOCKET;

    // 创建 UDP socket 验证
    var sock2 = foundation.egress.Socket.initUdp(.{}) catch {
        check("egress", ok1);
        return;
    };
    defer sock2.close();

    check("egress", ok1 and sock2.getFd() != foundation.egress.INVALID_SOCKET);
}

// ============================================================================
// ring.zig — 零拷贝 span API
// ============================================================================
fn testRingZeroCopy() void {
    var storage: [8]u8 = undefined;
    var rb = foundation.ring.RingBuf(u8).init(&storage);

    // writeSpan + commitWrite — 零拷贝写入
    const span = rb.writeSpan(5);
    @memcpy(span[0..5], "hello");
    rb.commitWrite(5);

    // readSpan + commitRead — 零拷贝读取
    const rspan = rb.readSpan();
    const ok = rspan.len == 5 and std.mem.eql(u8, rspan[0..5], "hello");
    rb.commitRead(5);

    check("ring-zero-copy", ok and rb.isEmpty());
}

// ============================================================================
// memconn.zig — 零拷贝 readDirect / writeDirect
// ============================================================================
fn testMemconnDirect() void {
    var loop = xev.Loop.init(.{}) catch {
        check("memconn-direct", false);
        return;
    };
    defer loop.deinit();

    var pair = foundation.memconn.createPair(256, &loop, &loop, allocator) catch {
        check("memconn-direct", false);
        return;
    };
    defer pair.destroy();

    const DirectCtx = struct {
        write_done: bool = false,
        read_data: [5]u8 = .{0} ** 5,
        read_n: usize = 0,
    };
    var ctx = DirectCtx{};

    // writeDirect — 回调直接拿到 RingBuf 可写切片（零拷贝写）
    var wc: xev.Completion = .{};
    pair.local.writeDirect(&loop, &wc, 5, DirectCtx, &ctx, (struct {
        fn cb(ud: ?*DirectCtx, l: *xev.Loop, c: *xev.Completion, span: []u8, r: error{Closed}!usize) xev.CallbackAction {
            _ = l;
            _ = c;
            _ = r catch unreachable;
            @memcpy(span[0..5], "hello");
            ud.?.*.write_done = true;
            return .disarm;
        }
    }).cb);

    // readDirect — 回调直接收到 RingBuf 内部数据切片（零拷贝读）
    var rc: xev.Completion = .{};
    pair.remote.readDirect(&loop, &rc, DirectCtx, &ctx, (struct {
        fn cb(ud: ?*DirectCtx, l: *xev.Loop, c: *xev.Completion, data: []const u8, r: error{Closed}!usize) xev.CallbackAction {
            _ = l;
            _ = c;
            const n = r catch unreachable;
            @memcpy(ud.?.*.read_data[0..data.len], data);
            ud.?.*.read_n = n;
            return .disarm;
        }
    }).cb);

    loop.run(.until_done) catch {
        check("memconn-direct", false);
        return;
    };

    check("memconn-direct", ctx.write_done and ctx.read_n == 5 and std.mem.eql(u8, &ctx.read_data, "hello"));
}
