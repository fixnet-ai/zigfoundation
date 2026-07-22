# Zig 编码经验积累

从 zigtun / zigproxy / zproxy / zigbox 四个项目中提取的 Zig 0.16.0 通用语言与标准库经验。

> **适用范围**: 所有 fixnet 项目的 Zig 0.16.0 编码参考。
> 项目特定的构建/集成经验保留在各项目自身的 zig-codegen.md 中。

---

## 1. 核心语言特性

### 1.1 容器初始化

`.{}` 已废弃，必须使用 `.empty`（集合）或 `.init`（有状态类型）：

```zig
// ❌ 已废弃
var list: std.ArrayList(u32) = .{};
var gpa: std.heap.DebugAllocator(.{}) = .{};

// ✅ 正确
var list: std.ArrayList(u32) = .empty;
var gpa: std.heap.DebugAllocator(.{}) = .init;
```

### 1.2 数组字面量不再自动零填充

Zig 0.16.0 中，指定长度的数组字面量必须提供恰好 N 个元素：

```zig
// ❌ 错误: expected 16 array elements; found 1
const zero: [16]u8 = [16]u8{0};

// ✅ 正确: 使用 @splat
const zero: [16]u8 = @splat(0);
```

### 1.3 结构体字面量上不能链式调用方法

```zig
// ❌ 错误: expected ',' after argument
const result = IpAddr{ .v6 = addr }.isValid();

// ✅ 正确: 先赋值再调用
const ip = IpAddr{ .v6 = addr };
const result = ip.isValid();
```

### 1.4 `var` 局部变量必须被修改

Zig 0.16.0 强制要求：如果局部变量从未被重新赋值，必须声明为 `const`：

```zig
// ❌ 错误: local variable is never mutated
var result = SomeStruct{ .field1 = 1 };

// ✅ 正确
const result = SomeStruct{ .field1 = 1 };
```

### 1.5 `_ = param` 后不能再使用该参数

对参数做 `_ = param` 声明不使用后，再使用该参数会导致编译错误：

```zig
// ❌ 错误: pointless discard of function parameter
fn foo(allocator: std.mem.Allocator) void {
    _ = allocator;
    const x = allocator.alloc(u8, 10);  // 矛盾
}

// ✅ 正确: 直接使用，无需标记
fn foo(allocator: std.mem.Allocator) void {
    const x = allocator.alloc(u8, 10);
}
```

如需标记未使用参数，用 `_` 前缀命名：`fn handler(_ctx: *Context) void { ... }`。

### 1.6 函数参数不能 shadow 顶层声明

参数名与文件级 `pub fn` 同名会被拒绝：

```zig
// ❌ 错误: function parameter shadows declaration of 'allocator'
pub fn init(allocator: std.mem.Allocator) !*Self { ... }
pub fn allocator() std.mem.Allocator { ... }

// ✅ 正确: 参数名与顶层函数区分
pub fn init(alloc: std.mem.Allocator) !*Self { ... }
pub fn allocator() std.mem.Allocator { ... }
```

### 1.7 catch 捕获名不能 shadow 外层参数

```zig
// ❌ 错误: capture 'err' shadows function parameter
pub fn cb(arg: *T, err: anyerror) void {
    std.Thread.spawn(...) catch |err| { ... };
}

// ✅ 正确: 重命名内层捕获
pub fn cb(arg: *T, err: anyerror) void {
    std.Thread.spawn(...) catch |spawn_err| { ... };
}
```

### 1.8 void 函数中的 error union 必须处理

```zig
// ❌ 错误: error union is ignored
pub fn wait(self: *T) void {
    self.event.wait();
}

// ✅ 正确: 使用 catch 处理
pub fn wait(self: *T) void {
    self.event.wait() catch {};
}
```

### 1.9 shift 运算符要求 LHS 是固定宽度整数

```zig
// ❌ 错误: LHS of shift must be fixed-width
const shifted = 0xff << @as(u3, 4);  // 0xff 是 comptime_int

// ✅ 正确: 先 cast LHS
const shifted: u8 = @as(u8, 0xff) << @as(u3, 4);
```

shift amount 位宽必须匹配：`u8 << u3`、`u32 << u5`、`u64 << u6`。

### 1.10 `@import` 在编译期无条件解析

无论代码路径是否可达，所有 `@import` 都会被编译器解析：

```zig
// ❌ 错误: dead code 中的 @import 也会被解析
fn linuxOnly() void {
    const lmdbx = @import("lmdbx");  // 没有这个模块 → 编译失败
}

// ✅ 正确: 依赖必须在 build.zig 中无条件提供
```

### 1.11 comptime 闭包捕获外层变量

内部 struct 不能捕获运行时外层变量，必须用 `comptime` 参数或 struct 字段传递：

```zig
// ❌ 错误: 'value' not accessible from inner function
fn factory(value: []const u8) FnPtr {
    return struct {
        fn f() { _ = value; }
    }.f;
}

// ✅ 正确: 用 comptime 参数
fn factory(comptime value: []const u8) FnPtr {
    return struct {
        fn f() { _ = value; }
    }.f;
}
```

**变体：运行时可变指针传递** — 当值必须是运行时可变时，用 struct-level `var` 指针：

```zig
// ❌ 错误: mutable local not accessible from struct namespace
fn makeWriteFn(tw: *TestWriter) WriteFn {
    return struct {
        fn w(bytes: []const u8) !usize {
            return tw.write(bytes);  // 编译失败
        }
    }.w;
}

// ✅ 正确: struct-level var + 工厂函数设指针
fn makeWriteFn(tw: *TestWriter) WriteFn {
    const S = struct {
        var p: *TestWriter = undefined;
        fn w(bytes: []const u8) !usize {
            return p.write(bytes);
        }
    };
    S.p = tw;
    return S.w;
}
```

### 1.12 `@EnumLiteral()` — 替代 `@Type(.enum_literal)`

Zig 0.16.0 移除 `@Type`，`@EnumLiteral()` 是新的内置函数，用于声明编译期 enum literal 参数：

```zig
// ❌ 已移除
comptime scope: @Type(.enum_literal),

// ✅ 替代
comptime scope: @EnumLiteral(),
```

`std.log.logFn` 的签名在 0.16.0 中为：
```zig
logFn: fn (
    comptime message_level: log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void
```

### 1.13 `zig fetch` — 添加远程依赖

```bash
# 添加 GitHub 依赖（自动更新 build.zig.zon 的 .dependencies 和 .hash）
zig fetch --save=zli https://github.com/xcaeser/zli/archive/refs/heads/main.tar.gz
```

之后在 `build.zig` 中通过 `b.dependency()` 获取模块：
```zig
const zli_dep = b.dependency("zli", .{});
const zli_module = zli_dep.module("zli");
lib_module.addImport("zli", zli_module);
```

### 1.13 模块名 import vs 文件路径 import 歧义

当 `build.zig` 注册了模块名 `X` 指向 `src/X/mod.zig`，且 root module 中同时存在 `src/X/mod.zig`：

```zig
// ❌ 可能报 "file exists in modules 'root' and 'core'"
const x = @import("X");  // 模块名查找 vs 文件路径查找冲突

// ✅ 明确用文件路径形式
const x = @import("X/mod.zig");
```

### 1.14 `@hasField` 不支持指针类型

```zig
// ❌ 错误: type '*const T' does not support '@hasField'
if (@hasField(@TypeOf(dep_cfg), "tun")) { ... }

// ✅ 正确: 先用 Child 剥指针
const CfgT = std.meta.Child(@TypeOf(dep_cfg));
if (@hasField(CfgT, "tun")) { ... }
```

注意: `std.meta.Child` 只能用于 pointer/optional/array/vector，对 struct value 会报错。field access 通过指针会自动 deref，所以第二层起不要再包 `Child`。

### 1.15 `//!` 文档注释只能出现在文件头部

`//!` 是文件级文档注释，必须在所有声明之前。文件中间只能用 `///` 或 `//`。

---

## 2. 移除/废弃特性 (0.14→0.16)

### 2.1 `@Type` → 独立 builtin

```zig
// ❌ 已移除
const T = @Type(.{ .int = .{ .signedness = .unsigned, .bits = 10 } });

// ✅ 替代
const T = @Int(.unsigned, 10);
const E = @Enum(.{ .tag_type = u8, .fields = &.{...}, .decls = &.{...}, .is_exhaustive = true });
const S = @Struct(.{ .layout = .auto, .fields = &.{...}, .decls = &.{...}, .is_tuple = false });
const U = @Union(.{ .layout = .auto, .tag_mode = .enum, .fields = &.{...}, .decls = &.{...} });
const P = @Pointer(.{ .size = .One, .is_const = false, .child = u8 });
```

### 2.2 `usingnamespace` → 显式重新导出

```zig
// ❌ 已移除
pub usingnamespace @import("other.zig");

// ✅ 替代
const other = @import("other.zig");
pub const foo = other.foo;
```

### 2.3 `async`/`await` → 已移除

用 `std.Io.Threaded` / `std.Io.Evented` 并发模型替代。

### 2.4 `@cImport` → build.zig `addTranslateC`

```zig
// build.zig
const c_translate = b.addTranslateC(.{
    .root_source_file = b.path("src/c.h"),
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("c", c_translate.createModule());
```

### 2.5 `@intFromFloat` → `@floor`/`@ceil`/`@round`/`@trunc`

```zig
// ❌ 已废弃
const n: u8 = @intFromFloat(@floor(value));

// ✅ 替代: 这些函数直接返回整数
const n: u8 = @floor(value);
```

### 2.6 Vectors 不再支持运行时索引

```zig
// ❌ 编译错误
_ = vector[i];

// ✅ 替代: 先转数组
const array: [N]T = vector;
```

### 2.7 禁止返回局部变量地址

```zig
// ❌ 编译错误: returning address of expired local variable
fn getX() *i32 {
    var x: i32 = 5;
    return &x;
}
```

### 2.8 packed struct/union 不允许指针字段

```zig
// ❌ 编译错误
const S = packed struct { ptr: *u8 };

// ✅ 替代: 用 usize + @ptrFromInt/@intFromPtr
const S = packed struct { ptr: usize };
```

### 2.9 `@fence` → 已移除

使用更强的原子操作顺序（`.acquire`/`.release`/`.acq_rel`/`.seq_cst`）替代。

---

## 3. 标准库变更 (0.16.0)

### 3.1 Allocator 命名

```zig
// ❌ 旧名
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
defer _ = gpa.deinit();

// ✅ 新名
var debug_alloc = std.heap.DebugAllocator(.{}){};
defer _ = debug_alloc.deinit();
```

### 3.2 ArrayList 默认 Unmanaged

```zig
// ❌ 旧 API: 内部持有 allocator
var list = std.ArrayList(T).init(allocator);
try list.append(item);

// ✅ 新 API: 显式传 allocator
var list: std.ArrayList(T) = .empty;
errdefer list.deinit(allocator);
try list.append(allocator, item);
```

`toOwnedSlice(allocator)` 而非 `toOwned(allocator)`。

### 3.3 网络 API 迁移到 std.Io

```zig
// ❌ 已移除
const addr = std.net.Ip4Address.parse("127.0.0.1", 8080);
const file = std.fs.cwd().openFile("foo.txt", .{});

// ✅ 替代
const addr = std.Io.net.Ip4Address.parse("127.0.0.1", 8080);
// addr.bytes: [4]u8 (NBO)
const file = std.Io.Dir.cwd().openFile(io, "foo.txt", .{});
```

`std.net` 模块已移除，`std.fs` 迁移到 `std.Io`。

### 3.4 时间 API

```zig
// ❌ 已移除
const now = std.time.timestamp();
const ms = std.time.milliTimestamp();

// ✅ 替代 (POSIX)
fn monoMillis() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return ts.sec * 1000 + @divFloor(ts.nsec, std.time.ns_per_ms);
}

// ✅ Windows 替代
extern "c" fn _time64(timep: ?*anyopaque) c_longlong;
```

`std.time.ns_per_ms` / `ns_per_s` 等常量仍可用。

### 3.5 sleep 替代

```zig
// ❌ 已移除: std.time.sleep(50 * std.time.ns_per_ms);

// ✅ 替代
_ = std.c.nanosleep(&.{ .sec = 0, .nsec = 50 * std.time.ns_per_ms }, null);
```

### 3.6 POSIX 函数大量移除

`std.posix.socket/connect/ioctl/fcntl/accept/bind/listen/read/write` 全部移除。
必须 `extern "c"` 声明：

```zig
extern "c" fn socket(domain: c_uint, sock_type: c_uint, protocol: c_uint) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn recv(fd: c_int, buf: [*]u8, len: usize, flags: c_int) isize;
```

`posix.system.close(fd)` 返回 `c_int`，必须丢弃：

```zig
errdefer _ = posix.system.close(fd);
```

`std.posix.write` 也已移除。跨平台写 stderr/stdout 需自行处理：

```zig
// POSIX: 直接用 C write
const n = std.c.write(2, bytes.ptr, bytes.len);  // fd=2 → stderr

// Windows: kernel32 WriteFile
const STD_ERROR_HANDLE: u32 = @bitCast(@as(i32, -12));
const h = kernel32.GetStdHandle(STD_ERROR_HANDLE) orelse return error.WriteFailed;
var written: u32 = 0;
_ = kernel32.WriteFile(h, bytes.ptr, @intCast(bytes.len), &written, null);
```

### 3.6.1 `std.Io.getStdErr()` / `std.c.stderr` 已移除

Zig 0.16.0 移除了 `std.Io.getStdErr()`、`std.Io.getStdOut()` 和 `std.c.stderr`/`std.c.stdout` 常量。
不要使用这些 API，改用上方的 `std.c.write` 或 kernel32 模式。

### 3.6.2 `std.Io.Writer` 无 `.context` 字段

Zig 0.16.0 的 `Writer` 使用 vtable 模式（`vtable: *const VTable, buffer: []u8, end: usize`），
不再有 `.context`/`.writeFn` 字段。需要自定义输出后端时，推荐用回调函数模式：

```zig
pub const WriteFn = *const fn (bytes: []const u8) anyerror!usize;
```

### 3.6.3 `std.log.Level` 仅含四级

Zig 0.16.0 的 `std.log.Level` 仅包含 `err` / `warn` / `info` / `debug` 四个级别，
没有 `trace`、`emerg`、`alert`、`crit`、`notice`。

级别整数值：`debug(3) > info(2) > warn(1) > err(0)`，值越大越详细。
过滤逻辑：`if (@intFromEnum(msg_level) > @intFromEnum(threshold)) return;` —
设置 `.info` 时显示 err/warn/info，隐藏 debug。

### 3.7 errno 处理

`std.c.getErrno` 不存在，用 `std.c.errno(rc)`，需要传 syscall 返回值：

```zig
// ❌ 已移除
const en = std.c.getErrno();

// ✅ 替代: 显式传 rc
const fd = socket(domain, type, proto);
if (fd < 0) {
    const en = std.c.errno(fd);
    std.log.err("socket failed: {s}", .{@tagName(en)});
}
```

### 3.8 同步原语迁移

| 旧 (0.15) | 新 (0.16) |
|-----------|-----------|
| `std.Thread.ResetEvent` | `std.Io.Event` |
| `std.Thread.WaitGroup` | `std.Io.Group` |
| `std.Thread.Futex` | `std.Io.Futex` |
| `std.Thread.Mutex` | `std.Io.Mutex` |
| `std.Thread.Condition` | `std.Io.Condition` |
| `std.once` | 已移除 |

### 3.9 `std.atomic.Mutex` 只有 `tryLock` + `unlock`

没有阻塞版 `lock()`，必须自旋：

```zig
while (!mutex.tryLock()) {}
defer mutex.unlock();
```

### 3.10 `sockaddr_in` 命名空间

```zig
// ❌ 错误: struct 'c' has no member named 'sockaddr_in'
var addr: std.c.sockaddr_in = undefined;

// ✅ 正确
var addr: std.c.sockaddr.in = undefined;
```

### 3.11 `c_long` / `c_int` 是全局别名

不在 `std.c` 内：

```zig
// ❌ 错误: struct 'c' has no member named 'long'
const x: std.c.long = 0;

// ✅ 正确
const x: c_long = 0;
```

---

## 4. 构建系统 (build.zig)

### 4.1 module 创建模式

```zig
// ❌ 旧 API
const exe = b.addExecutable(.{
    .name = "app",
    .root_source_file = b.path("src/main.zig"),  // 已移除
    .target = target,
});

// ✅ 新 API
const exe = b.addExecutable(.{
    .name = "app",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    }),
});
```

### 4.2 模块导入

```zig
// ❌ 旧 API
exe.addModule("helper", helper_mod);
exe.addIncludePath(...);
exe.linkSystemLibrary("c");

// ✅ 新 API
exe.root_module.addImport("helper", helper_mod);
exe.root_module.addIncludePath(...);
exe.root_module.linkSystemLibrary("c", .{});
```

### 4.3 静态库编译

```zig
// ❌ 旧 API
const lib = b.addStaticLibrary(.{ .name = "foo", ... });

// ✅ 新 API
const lib = b.addLibrary(.{ .name = "foo", .linkage = .static, ... });
```

### 4.4 fingerprint 字段

`build.zig.zon` 必须有 `fingerprint` 字段，使用编译器建议的值：

```zon
.{
    .name = .myproject,
    .version = "0.1.0",
    .fingerprint = 0x...,
    .minimum_zig_version = "0.16.0",
}
```

### 4.5 `b.path()` 不能接受绝对路径

必须用相对路径或用 `b.dependency()` 走 vendor 模式。

### 4.6 C 源码不可跨模块重复编译

同一组 C 源文件在多个 module 中 `addCSourceFiles` 会导致 duplicate symbol：

```zig
// ❌ 错误: 两个 module 都编译同一组 C 源码
lib_mod.addCSourceFiles(.{ .files = &c_sources, ... });
cli_mod.addCSourceFiles(.{ .files = &c_sources, ... });  // 重复!

// ✅ 正确: C 源码只在一个 module 编译
lib_mod.addCSourceFiles(.{ .files = &c_sources, ... });
cli_mod.addImport("lib", lib_mod);  // 仅 Zig API 导入
```

### 4.7 测试不自动收集 transitive 文件的 test 块

`zig build test` 只运行 root source file 中的 `test` 块，不收集 `@import` 的 transitive 文件中的测试。每个有测试的文件需要独立 `addTest` step。

---

## 5. 字节序与内存

### 5.1 `@bitCast` 与 IP 地址陷阱

`@bitCast` 将 `[4]u8` 按本机字节序转为 `u32`，不保证网络字节序语义：

```zig
// ❌ 错误: 在 LE 机器上字节序反转
const ip_int: u32 = @bitCast(ip_bytes);

// ✅ 正确: 统一使用 readInt/writeInt 明确字节序
const ip_int: u32 = std.mem.readInt(u32, &ip_bytes, .big);
std.mem.writeInt(u32, &out, ip_int, .big);
```

### 5.2 `sockaddr.in.addr` 直接赋 NBO 整数

`extern struct` 的 `.addr` 字段存 NBO 整数时，内存字节自动是 NBO 顺序，**不要**再调 `bigToNative`：

```zig
// ❌ 错误: 双重转换
sa.sin_addr = .{ .s_addr = std.mem.bigToNative(u32, nbo_ip) };

// ✅ 正确: 直接 store NBO 整数
sa.sin_addr = .{ .s_addr = nbo_ip };
```

### 5.3 `writeInt` 与 `nativeToBig` 重复转换

`std.mem.writeInt(u32, buf, val, .big)` 已经把 host 值转为 big-endian 字节，不要先 `nativeToBig` 再 `writeInt`：

```zig
// ❌ 错误: 重复转换
std.mem.writeInt(u32, out[12..16], std.mem.nativeToBig(u32, src_ip), .big);
// nativeToBig 把 host→big, writeInt .big 又做一次 → 双重反转

// ✅ 正确: 直接传 host 值 + .big
std.mem.writeInt(u32, out[12..16], src_ip, .big);
```

### 5.4 `extern struct` vs `struct` 字段顺序

`struct` 不保证字段顺序（Zig 可能为对齐重新排序），`extern struct` 锁定 C ABI 顺序：

```zig
// ❌ 需要固定顺序时用普通 struct
pub const Slot = struct {
    data: [2048]u8,              // 期望 offset 0
    len: u16,
    seq: std.atomic.Value(u64),  // align 8 → Zig 可能提到最前
};
// → @offsetOf(data) 可能不是 0

// ✅ 用 extern struct + 显式 padding
pub const Slot = extern struct {
    data: [2048]u8,              // offset 0（锁定）
    len: u16,                     // offset 2048
    _pad: u32 = 0,               // offset 2052，显式对齐 seq
    seq: std.atomic.Value(u64) = .init(0),  // offset 2056
};
```

判断标准：struct 内存布局是否对外可见（C FFI、mmap、wire format、持久化） → 必须 `extern`。

### 5.5 跨线程传递指针用 `usize`

```zig
// ❌ 不可靠: 裸指针跨线程
const evt = Event{ .pcb = @intFromPtr(pcb) };  // *opaque → usize

// 消费端
const pcb: *Pcb = @ptrFromInt(evt.pcb);  // usize → *opaque
```

---

## 6. defer 块作用域语义

**关键规则**: Zig `defer` 是**块作用域**（block-scoped），不是函数作用域。

| 行为 | Zig defer | Go defer |
|------|-----------|----------|
| 作用域 | 块作用域 | 函数作用域 |
| 触发时机 | 当前块结束 | 函数返回 |
| if 块内 defer | if 块结束即触发 | 函数返回才触发 |
| 循环内 defer | 每次迭代触发 | 函数返回触发 |

```zig
// ❌ 陷阱: defer 在 if 块结束时就触发
if (cfg.tun_enabled) {
    initTun();
    defer deinitTun();  // ← if 块结束就执行！
    // ... 后续代码 ...
}  // ← deinitTun() 在这里执行

// ✅ 正确: defer 放在函数作用域 + 标志变量
var tun_enabled = false;
if (cfg.tun_enabled) {
    initTun();
    tun_enabled = true;
}
defer if (tun_enabled) deinitTun();  // 函数返回才执行
```

---

## 7. 平台与 ABI

### 7.1 Android 是 ABI 不是 OS Tag

```zig
// ❌ 错误: Target.Os.Tag 没有 .android
switch (builtin.os.tag) {
    .android => ...,
    else => ...,
}

// ✅ 正确
if (comptime builtin.abi.isAndroid()) {
    // Android
} else switch (builtin.os.tag) {
    .linux => ...,
    .macos => ...,
    else => ...,
}
```

### 7.2 Go build tags → Zig comptime

| Go | Zig |
|----|-----|
| `//go:build darwin` | `if (builtin.os.tag == .macos) { ... }` |
| `//go:build linux` | `if (builtin.os.tag == .linux) { ... }` |
| `//go:build windows` | `if (builtin.os.tag == .windows) { ... }` |

### 7.3 Windows `clock_gettime` 不存在

`std.c.clockid_t` 在 Windows target 是 `void`，`clock_gettime` 编译失败：

```zig
fn monoMillis() i64 {
    if (builtin.os.tag == .windows) return 0;  // 提前 gate
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return ts.sec * 1000 + @divFloor(ts.nsec, std.time.ns_per_ms);
}
```

---

## 8. C FFI 常见坑

### 8.1 信号处理 handler 签名跨平台差异

macOS/BSD 用 `fn(std.c.SIG) callconv(.c) void`，Linux 用 `fn(c_int) callconv(.c) void`。统一写法：

```zig
fn posixSignalHandler(sig: std.c.SIG) callconv(.c) void {
    const num: c_int = @intCast(@intFromEnum(sig));
    // 只做 async-signal-safe 操作
}
```

### 8.1.1 跨平台日志 FFI

Android 用 `__android_log_write`（logcat），iOS/macOS 用 `syslog`：

```zig
// Android — logcat 输出
extern fn __android_log_write(prio: c_int, tag: [*]const u8, text: [*]const u8) c_int;

// 优先级映射：err→3(ERROR), warn→4(WARN), info→5(INFO), debug→6(DEBUG)

// iOS / macOS — syslog 输出
extern fn syslog(priority: c_int, format: [*]const u8, ...) void;

// 优先级映射：err→3(LOG_ERR), warn→4(LOG_WARNING), info→6(LOG_INFO), debug→7(LOG_DEBUG)
```

桌面端（Linux/Windows）直接用 `std.c.write(2, ...)` 写 stderr 或 kernel32 `WriteFile`。

注意：`std.heap.page_allocator` 非线程安全，在日志路径中仅用于临时格式化（用完即 free），不适合高频并发场景。

### 8.1.2 `std_options.logFn` 覆盖全局日志

在根文件中设置 `pub const std_options` 可覆盖 `std.log` 的全部默认行为：

```zig
// main.zig
pub const std_options: std.Options = .{
    .logFn = myLogImpl,
};

fn myLogImpl(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime fmt: []const u8,
    args: anytype,
) void {
    // 自定义输出逻辑
}
```

`std_options` 是编译期全局常量，每个二进制只能设置一次。

### 8.2 `SA_SIGINFO` 不能与 1-arg handler 共用

`SA.SIGINFO` 请求 3-arg handler，单 arg handler 只需要 `SA.RESTART`。

### 8.3 macOS `socket()` 不接受 `SOCK_NONBLOCK`

macOS 的 `socket()` 拒绝任何含 `SOCK_NONBLOCK` 标志的调用（errno=43）。正确做法：

```zig
// 1. 创建 blocking socket
const fd = socket(AF_INET, SOCK_STREAM, 0);

// 2. fcntl 设为非阻塞
const flags = fcntl(fd, F_GETFL, @as(i32, 0));
_ = fcntl(fd, F_SETFL, flags | @as(i32, 0x04));  // macOS O_NONBLOCK = 0x04
```

### 8.4 `pthread_cond_timedwait` 返回 `E`（enum）不是 `c_int`

```zig
// ❌ 错误
const rc = std.c.pthread_cond_timedwait(&cond, &mutex, &ts);
if (rc == 0) ...  // rc 是 enum，不是 int

// ✅ 正确
const rc = std.c.pthread_cond_timedwait(&cond, &mutex, &ts);
if (rc == .SUCCESS) ...
```

### 8.5 `pthread_cond_timedwait` 需要绝对时间

`timespec` 是绝对截止时间（CLOCK_REALTIME），不是相对时长：

```zig
// ❌ 错误: 相对时长当作绝对时间
var ts: std.c.timespec = .{ .sec = timeout_sec, .nsec = 0 };
std.c.pthread_cond_timedwait(&cond, &mutex, &ts);

// ✅ 正确: 从 CLOCK_REALTIME 获取当前时间再加 timeout
var deadline: std.c.timespec = undefined;
_ = std.c.clock_gettime(.REALTIME, &deadline);
deadline.sec += @as(@TypeOf(deadline.sec), @intCast(timeout_sec));
```

### 8.6 `pthread_mutex_init/destroy` 不导出

Zig 0.16 不暴露 `pthread_mutex_init` / `pthread_mutex_destroy`，需自行声明：

```zig
extern "c" fn pthread_mutex_init(mutex: *std.c.pthread_mutex_t, attr: ?*const anyopaque) std.c.E;
extern "c" fn pthread_mutex_destroy(mutex: *std.c.pthread_mutex_t) std.c.E;
```

零初始化的 mutex（`= .{}`）在所有 POSIX 平台上等同于 `PTHREAD_MUTEX_INITIALIZER`，可免 init/destroy。

### 8.7 extern union tag 字段必须是首个字节

extern union 的 tag 读取 union 内存的首个 u8。所有 struct variant 的首字段必须是 tag：

```zig
pub const Event = extern union {
    tag: EventTag,
    udp_event: extern struct {
        tag: EventTag = .udp,  // 必须是第一个字段
        port: u16,
    },
    tcp_event: extern struct {
        tag: EventTag = .tcp,  // 必须是第一个字段
        pcb: usize,
    },
};
```

### 8.8 C callback 参数保守用 `?*const T`

```zig
// ❌ 可能报 cast 错误
const UdpRecvFn = *const fn (arg: ?*anyopaque, pcb: *Pcb, p: *Pbuf, addr: *const IpAddr, port: u16) void;

// ✅ 保守写法: addr 用 optional
const UdpRecvFn = *const fn (arg: ?*anyopaque, pcb: *Pcb, p: *Pbuf, addr: ?*const IpAddr, port: u16) void;
```

---

## 9. 测试

### 9.1 `zig build test` 不收集 transitive 文件的 test 块

参见 [4.7](#47-测试不自动收集-transitive-文件的-test-块)。

### 9.2 测试中修改全局状态必须 defer 还原

```zig
const saved = global_state.value;
global_state.value = &test_value;
defer global_state.value = saved;
```

### 9.3 `zig build test` 单进程顺序执行

依赖此行为的测试（如共享全局状态）可以安全使用 `defer` 还原，但建议避免全局状态。

---

## 10. vtable 模式（Go interface → Zig）

```zig
pub const Handler = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        prepareFn: *const fn (ptr: *anyopaque, ...) anyerror!Result,
        closeFn: *const fn (ptr: *anyopaque) void,
    };

    pub fn prepare(self: Handler, ...) anyerror!Result {
        return self.vtable.prepareFn(self.ptr, ...);
    }
};

// 测试中的实现
const test_impl = struct {
    fn myPrepare(ptr: *anyopaque, ...) anyerror!Result {
        const self: *const MyType = @ptrCast(@alignCast(ptr));
        _ = self;
        // ...
    }
};

const vtable = Handler.VTable{
    .prepareFn = test_impl.myPrepare,
    .closeFn = test_impl.myClose,
};
const handler = Handler{ .ptr = @ptrCast(&instance), .vtable = &vtable };
```

---

## 11. 校验和（IP/TCP/UDP Checksum）

### 11.1 IP Checksum 验证

```zig
const cksum = ipChecksum(&header);  // 计算 checksum 字段值
std.mem.writeInt(u16, header[10..12], cksum, .big);  // 填入
const verify = ipChecksum(&header);  // 验证：期望 0
try std.testing.expectEqual(@as(u16, 0), verify);
```

原理: sum(S) + checksum(~S) = 0xFFFF, ~0xFFFF = 0。

---

## 12. 代码风格与最佳实践

### 12.1 命名冲突避免

- 函数参数用简短别名（`alloc` 而非 `allocator`）避免与顶层访问器冲突
- catch 捕获名用具体化名称（`spawn_err`、`bind_err`）避免 shadow

### 12.2 const 优先

- 声明后不修改的变量一律 `const`
- 需要取地址的变量用 `var`，其余用 `const`

### 12.3 错误处理模式

- void 函数中处理 error union：`func() catch {};` 或 `func() catch return;`
- 需要日志但继续执行：用 `if/else |err|` 而非 `catch |err|`（避免类型兼容性问题）
- `std.Thread.spawn` 返回 error union，必须处理

### 12.4 build cache 清理

改 stdlib API 或跨版本升级后，先 `rm -rf .zig-cache zig-out`，避免 stale cache 误导错误定位。

### 12.5 128-bit 整数增量要注意进位链

```zig
// ❌ 错误: 单次 +%= 处理不了跨字节进位
while (i > 0) {
    i -= 1;
    result[i] +%= 1;
    if (result[i] != 0) break;  // 0xff + 1 = 0x00, 但下一字节未进位
}

// ✅ 正确: 用 u16 检查进位
while (i > 0) {
    i -= 1;
    const sum = @as(u16, result[i]) + 1;
    result[i] = @intCast(sum & 0xff);
    if (sum <= 0xff) break;  // 无进位
}
```

---

## 快速诊断表

| 错误信息 | 根因 | 修复 |
|---------|------|------|
| `use of undefined value` | 算术运算用了 undefined | 显式初始化所有值 |
| `type 'f32' cannot represent integer` | 整数字面量赋给浮点 | 用 `123.0` 而非 `123` |
| `no field 'root_source_file'` | 使用了旧 build API | 改用 `root_module = b.createModule(...)` |
| `expected type '*Io', found 'Io'` | `threaded.io()` 返回值 | `var io = ...; const io_ptr = &io;` |
| `struct 'std' has no member named 'net'` | 旧 API | 改用 `std.Io.net.*` |
| `local variable is never mutated` | `var` 应该用 `const` | 改为 `const` |
| `pointless discard of function parameter` | `_ = p` 后又用 `p` | 删除 `_ = p` |
| `capture 'err' shadows function parameter` | 内外层同名 | 重命名内层捕获 |
| `error union is discarded` | `_ = func()` 不处理错误 | 加 `catch` |
| `import of file outside module path` | `@import("../x.zig")` | 用 build.zig 的 module+import |
| `invalid builtin function: '@Type'` | 旧 `@Type(.enum_literal)` | 改用 `@EnumLiteral()` |
| `enum 'log.Level' has no member named 'trace'` | 使用了 0.16 不存在的级别 | 仅用 err/warn/info/debug |
| `mutable local not accessible from struct namespace` | comptime 闭包不能捕获运行时可变指针 | 用 struct-level `var` + 工厂函数 |
| `union 'CallingConvention' has no member named 'C'` | callconv(.C) 已废弃 | export fn 默认为 C convention，移除 callconv |
| `unable to provide libc for target 'aarch64-linux-android'` | Zig 不捆绑 Bionic libc | 创建 libc 配置文件 + `setLibCFile` |
| `sub_path is expected to be relative to the build root` | b.path() 不接受绝对路径 | 用 `.{ .cwd_relative = path }` |
| `@ptrCast increases pointer alignment` | 指针转换时对齐增加 | 添加 `@alignCast` |
| `expected type '[*]const u8', found '[]u8'` | extern C 函数需要指针 | 用 `.ptr` 取切片指针 |
| `'asm/types.h' file not found` (Android) | 缺少架构特定 include | 添加 NDK arch 目录 to addSystemIncludePath |
| `unable to find libSystem system library` (iOS) | Zig 不在 sysroot usr/lib 查找 .tbd | `addLibraryPath(.{ .cwd_relative = "/usr/lib" })` 由 linker 加 sysroot 前缀 |
| `undefined symbol: __dyld_get_image_header_containing_address` | iOS Debug 构建 std.debug 引用不存在符号 | iOS 目标用 `-Doptimize=ReleaseSmall` |

---

---

## 13. 交叉编译 (Cross-Compilation)

### 13.1 `CallingConvention` — `.C` 不存在 → `export fn` 默认为 C

Zig 0.16.0 中 `CallingConvention` 是 tagged union，没有 `.C` 成员。
`export fn` 默认使用目标平台的 C calling convention，无需显式声明：

```zig
// ❌ 错误: union 'builtin.CallingConvention' has no member named 'C'
export fn runAllTests() callconv(.C) bool;

// ✅ 正确: export fn 默认为 C calling convention
export fn runAllTests() bool;
```

`CallingConvention.c` 是 `pub const`（编译期求值为当前目标的 C 调用约定），不是 tagged union 字段，不能作为 `.c` 枚举字面量使用。

### 13.2 `b.sysroot` — 交叉编译 sysroot 传递

Zig 0.16.0 中 `Build.sysroot` 可设置，Compile 步骤会自动透传 `--sysroot` 给 zig build-lib（用于链接器）。
C 头文件搜索需要额外 `addSystemIncludePath`：

```zig
// build.zig
const sysroot = b.option([]const u8, "sysroot", "sysroot 路径 (iOS SDK / Android NDK)");
if (sysroot) |s| {
    b.sysroot = s;  // 设置给 linker
    // C 编译器头文件搜索需要显式添加
    const usr_include = b.pathJoin(&.{ s, "usr", "include" });
    lib_module.addSystemIncludePath(.{ .cwd_relative = usr_include });
}
```

注意：`Build.Step.Compile` 没有 `setSysroot` 方法，只能通过 `b.sysroot` 全局设置。

### 13.3 Android NDK 架构特定头文件

Android Bionic 的 `asm/types.h` 等文件不在 `usr/include` 下，而在架构特定目录：

```zig
// Android NDK 添加架构特定 include path
const ndk_arch: []const u8 = switch (target.result.cpu.arch) {
    .aarch64 => "aarch64-linux-android",
    .x86_64 => "x86_64-linux-android",
    .x86 => "i686-linux-android",
    .arm, .armeb, .thumb, .thumbeb => "arm-linux-androideabi",
    .riscv64 => "riscv64-linux-android",
    else => "aarch64-linux-android",
};
const arch_include = b.pathJoin(&.{ s, "usr", "include", ndk_arch });
lib_module.addSystemIncludePath(.{ .cwd_relative = arch_include });
```

### 13.4 `--libc` 文件 — Zig 不捆绑 Bionic 时的方案

Zig 0.16.0 不捆绑 Android Bionic libc。需创建 libc 配置文件并通过 `setLibCFile` 传递：

```zig
// build.zig
const libc_file = b.option([]const u8, "libc-file", "libc 配置文件路径 (Android)");
if (libc_file) |lf| {
    example_android.setLibCFile(.{ .cwd_relative = lf });
}
```

libc 配置文件格式（key=value，每行一对）：
```
include_dir=/path/to/ndk/sysroot/usr/include
sys_include_dir=/path/to/ndk/sysroot/usr/include
crt_dir=/path/to/ndk/sysroot/usr/lib/aarch64-linux-android/35
msvc_lib_dir=
kernel32_lib_dir=
gcc_dir=
```

- 空值 `=` 表示 null（字段可选时不强制）
- `include_dir` / `sys_include_dir` / `crt_dir` 为必须字段（非 Darwin 目标）
- 参考 `std/zig/LibCInstallation.zig` 的 `parse()` 了解完整字段

### 13.5 `b.path()` 不能接受绝对路径 → `LazyPath.cwd_relative`

```zig
// ❌ 错误: panics on absolute path
example.setLibCFile(b.path("/absolute/path/to/libc.conf"));

// ✅ 正确: 用 LazyPath.cwd_relative
example.setLibCFile(.{ .cwd_relative = "/absolute/path/to/libc.conf" });
```

### 13.6 `@ptrCast` 需要 `@alignCast` 当对齐增加时

```zig
// ❌ 错误: @ptrCast increases pointer alignment (alignment 1 → 2)
const rc = std.c.bind(fd, @ptrCast(&sa_bytes), @intCast(sa_len));

// ✅ 正确: 添加 @alignCast
const rc = std.c.bind(fd, @ptrCast(@alignCast(&sa_bytes)), @intCast(sa_len));
```

这常出现在 Linux/Android 目标上，因为 `std.c.bind` 的 sockaddr 参数对齐要求高于 `[28]u8`。

### 13.7 `[]u8` → `[*]const u8` for extern C functions

```zig
// ❌ 错误: expected type '[*]const u8', found '[]u8'
_ = __android_log_write(priority, "tag", c_str);

// ✅ 正确: 用 .ptr 获取指针
_ = __android_log_write(priority, "tag", c_str.ptr);
```

切片 `[]u8` 的 `.ptr` 返回 `[*]u8`，可隐式 coerce 为 `[*]const u8`。

### 13.8 Windows socket: `@intCast` 溢出 — 必须先检查负数再转无符号

`std.c.socket()` 返回 `c_int`（i32）。Windows 上 `std.posix.socket_t` 是 `*anyopaque`（指针），
需要 `@ptrFromInt(@as(usize, @intCast(raw)))` 转换。但失败时 `raw = -1`，不能直接 cast 到 `usize`：

```zig
// ❌ 致命错误: socket 失败时 raw = -1，@intCast(-1) → usize panic
const raw = std.c.socket(domain, sock_type, protocol);
const fd: std.posix.socket_t = @ptrFromInt(@as(usize, @intCast(raw)));

// ✅ 正确: 先检查负数再转换
const raw = std.c.socket(domain, sock_type, protocol);
if (builtin.os.tag == .windows) {
    if (raw < 0) return error.SocketCreateFailed;
    return @ptrFromInt(@as(usize, @intCast(raw)));
} else {
    if (raw == INVALID_SOCKET) return error.SocketCreateFailed;
    return raw;
}
```

### 13.9 Windows `std.posix.setsockopt` → compileError

Zig 0.16.0 在 Windows 上 `std.posix.setsockopt` 的函数体直接是 `@compileError("use std.Io instead")`。
必须使用跨平台 wrapper 调用 winsock：

```zig
const winSock = struct {
    const SOCKET = usize;
    extern "ws2_32" fn setsockopt(
        s: SOCKET, level: c_int, optname: c_int, optval: [*]const u8, optlen: c_int,
    ) callconv(.winapi) c_int;
    extern "ws2_32" fn closesocket(s: SOCKET) callconv(.winapi) c_int;
};

fn sockSetOpt(fd: std.posix.socket_t, level: i32, optname: u32, opt: []const u8) !void {
    if (builtin.os.tag == .windows) {
        const sock: winSock.SOCKET = @intFromPtr(fd);
        const rc = winSock.setsockopt(sock, level, @intCast(optname), opt.ptr, @intCast(opt.len));
        if (rc != 0) return error.SetSockOptFailed;
    } else {
        try std.posix.setsockopt(fd, level, optname, opt);
    }
}
```

### 13.10 Windows Mutex: atomic spinlock 替代 pthread

Zig 0.16.0 `std.Thread.Mutex` 不存在。Windows 没有 `pthread_mutex_t`（`std.c.pthread_mutex_t = void`）。

```zig
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
```

### 13.11 Windows I/O: kernel32 本地声明

Zig 0.16.0 `std.os.windows.kernel32` 几乎无声明，必须本地 `extern "kernel32"`：

```zig
const win = struct {
    const HANDLE = *anyopaque;
    const DWORD = u32;
    const BOOL = i32;
    const LPVOID = *anyopaque;
    extern "kernel32" fn GetStdHandle(nStdHandle: DWORD) callconv(.winapi) HANDLE;
    extern "kernel32" fn WriteFile(hFile: HANDLE, lpBuffer: [*]const u8,
        nNumberOfBytesToWrite: DWORD, lpNumberOfBytesWritten: ?*DWORD,
        lpOverlapped: ?LPVOID) callconv(.winapi) BOOL;
    extern "kernel32" fn ReadFile(hFile: HANDLE, lpBuffer: [*]u8,
        nNumberOfBytesToRead: DWORD, lpNumberOfBytesRead: ?*DWORD,
        lpOverlapped: ?LPVOID) callconv(.winapi) BOOL;
};
```

**关键规则：**
- `callconv(.winapi)` 不是 `callconv(.C)`（后者已移除）
- `?*DWORD` 而非 `?LPDWORD`：`LPDWORD = ?*DWORD`，用在函数参数中产生 `??*DWORD`，Win64 calling convention 不接受双重 optional

### 13.12 iOS 交叉链接 exe/dylib: `unable to find libSystem system library`

Zig 0.16.0 交叉链接 iOS/模拟器**可执行文件或 dylib** 时，即使传了 `--sysroot`，
也不会自动在 `<sysroot>/usr/lib` 下查找 `libSystem.tbd`。静态库 `.a` 不经过链接，
所以此问题在构建静态库时不会暴露：

```zig
// build.zig — 修复：显式 -L/usr/lib，MachO linker 自动加 sysroot 前缀
if (sysroot) |s| {
    mod.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ s, "usr", "include" }) });
    mod.addLibraryPath(.{ .cwd_relative = "/usr/lib" }); // → <sysroot>/usr/lib
}
```

**关键点：**
- `-L` 传绝对 SDK 路径会被 sysroot **二次前缀**（`<SDK><SDK>/usr/lib` → FileNotFound 警告），
  必须用 `/usr/lib` 相对形式，由 linker 拼接 sysroot
- 替代方案：`--libc` conf（`crt_dir=<SDK>/usr/lib`）同样有效，但需要额外文件
- Debug 模式链接 iOS 会报 `undefined symbol: __dyld_get_image_header_containing_address`
  （std.debug.SelfInfo 引用，iOS 无此符号）→ iOS 目标固定用 `-Doptimize=ReleaseSmall`

### 13.13 iOS 模拟器自动化测试: simctl spawn 直连终端

`.app` bundle + `simctl launch` 的 stdout/stderr 不回流终端，无法自动断言。
正解与 Android adb shell 同构 —— 构建纯 CLI 可执行文件直接 spawn：

```bash
zig build ios-test-runner -Dtarget=aarch64-ios-simulator \
    -Doptimize=ReleaseSmall -Dsysroot="$(xcrun --sdk iphonesimulator --show-sdk-path)"
xcrun simctl spawn booted zig-out/bin/zigfoundation-ios-test
# stdout/stderr 直连当前终端，退出码可断言
```

---

## 14. TUN 回包写入（UDP/TCP 包头重写）

TUN 模式下 DNS 劫持等场景需要解析原始 IP 包、修改后写回 TUN。
以下是三个极易犯错的关键点。

### 14.1 校验和重算三步：清零 → 计算 → 写入

重算 UDP/TCP 校验和时，必须先把校验和字段清零，再用 `rawChecksum()` 计算。
旧校验和值会污染 one's complement 累加结果。

```zig
// ❌ 错误: 缓存头中的旧校验和污染 rawChecksum()
ip_hdr.setTotalLength(total_len);
udp.setLength(udp_len);
const ph = pseudoHeaderChecksum(IP_PROTO_UDP, &ip_hdr.src_addr, &ip_hdr.dst_addr, udp_len);
const csum = internetChecksum(data, rawChecksum(udp_bytes, ph));  // udp_bytes 含旧 csum!
udp.setChecksum(csum);

// ✅ 正确: 先清零再计算
udp.setLength(udp_len);
udp.setChecksum(0);  // ← 必须在 rawChecksum 之前清零
const ph = pseudoHeaderChecksum(IP_PROTO_UDP, &ip_hdr.src_addr, &ip_hdr.dst_addr, udp_len);
const csum = internetChecksum(data, rawChecksum(udp_bytes, ph));
udp.setChecksum(csum);
```

**同一文件中 TCP 和 UDP 路径必须一致。** TCP 路径正确清零而 UDP 路径未清零，
这种不一致本身就是代码坏味道。

### 14.2 缓存头回写：所有可变字段必须更新

从入站包缓存的 IP+UDP/TCP 头在写回时，必须更新**全部**可变字段：

| 字段 | 必须更新 | 原因 |
|------|---------|------|
| 源/目标 IP | ✅ | NAT 交换 |
| 源/目标端口 | ✅ | NAT 交换 |
| IP total_length | ✅ | 响应长度 ≠ 查询长度 |
| UDP/TCP length | ✅ | 响应长度 ≠ 查询长度 |
| UDP/TCP checksum | ✅ | 旧值无效 |
| IP checksum | ✅ | IP 头字段变更后重算 |

```zig
// ❌ 错误: 漏了 setLength — 查询 42 字节、响应 118 字节，UDP length 仍是 50
udp.setSrcPort(self.destination.port);
udp.setDstPort(self.source.port);
// 缺少 udp.setLength(@intCast(UDP_MIN_SIZE + data.len));

// ✅ 正确: 逐字段更新
udp.setSrcPort(self.destination.port);
udp.setDstPort(self.source.port);
udp.setLength(@intCast(UDP_MIN_SIZE + data.len));  // 响应长度
```

**检查方法：** 代码审查时，搜索所有缓存包头写回路径，逐一核对上表中的字段是否全部更新。
`setLength` 方法存在但从未被调用 → 漏掉了。

### 14.3 tcpdump 看到包 ≠ 内核接受包

UDP 校验和错误或长度字段错误时，macOS 内核**静默丢弃**数据包：
- 无 ICMP 错误回传
- 无内核日志
- tcpdump 在 TUN 接口层面仍能看到包（tcpdump 抓在协议栈处理之前）

这意味着 `tcpdump -i utun5` 看到响应包发出但 `dig` 收不到，
不能排除包头字段错误。排查时必须验证校验和与长度字段。

### 14.4 TUN 写路径禁止 `catch {}` 静默丢错

```zig
// ❌ 危险: 静默丢弃 TUN 写入错误，出问题时无可调试
_ = self.tun_device.write(buf) catch {};

// ✅ 正确: 至少 warn 级别日志
_ = self.tun_device.write(buf) catch |err| {
    std.log.warn("[stack] tun write failed: {}", .{err});
};
```

TUN 写入失败是严重但难以察觉的问题（应用层无反馈），`catch {}` 使排查极其困难。

---
*最后更新: 2026-07-22*
*来源: 从 zigtun/zigproxy/zproxy/zigbox 的 zig-codegen.md 提取合并*
*本次新增: 第 14 章 — TUN 回包写入（校验和清零、缓存头字段更新、tcpdump 可见性陷阱、catch {} 禁止）*
