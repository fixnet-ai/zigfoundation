# zigfoundation API 参考

> **状态**: 14 模块全部实现，219 tests 全绿
>
> 版本: 0.1.0 | 目标平台: Windows / macOS / Linux / iOS / Android
>
> 依赖: Zig std + zli + libyaml C 库 + libxev | 构建: Zig 0.16.0

---

## 如何使用

在 `build.zig.zon` 中添加依赖：

```zig
.zigfoundation = .{
    .path = "../zigfoundation",
},
```

在 `build.zig` 中导入模块：

```zig
const foundation_dep = b.dependency("zigfoundation", .{
    .target = target,
    .optimize = optimize,
});
lib_module.addImport("foundation", foundation_dep.module("zigfoundation"));
```

在代码中使用：

```zig
const foundation = @import("foundation");

// 内存管理
const pool = try foundation.buffer.BufferPool.init(allocator, .{});
const buf = try foundation.ring.RingBuf(u8).init(slice);

// 网络工具
const cidr = try foundation.net.Cidr4.parse("192.168.1.0/24");

// 平台检测
if (foundation.platform.isLinux) { ... }

// 日志
const std_options = foundation.log.logOptions();
```

---

## 模块目录

### buffer.zig — 缓冲池

> **Phase 1** | std only | 来源: zigproxy/src/buffer.zig

固定大小缓冲区的 LIFO 复用池。所有连接共享单个缓冲池，避免每次连接单独分配内存。
`defaultConfig()` 初始块数为 0（零初始分配，完全按需扩展），按需扩展到上限，空闲时收缩。

#### 类型

```zig
pub const Buffer = struct {
    data: []u8,   // 从池中借出的数据切片
    index: u32,   // 内部块索引，归还时必须原样传回
};

pub const PoolConfig = struct {
    block_size: u32 = 8192,      // 单块大小（字节），必须为 2 的幂
    initial_blocks: u32 = 256,   // 结构体默认值（defaultConfig() 实际返回 0，按需扩展）
    max_blocks: u32 = 4096,      // 最大块数上限（4096 × 8KB = 32MB）
};
```

#### API

| 函数 | 签名 | 描述 |
|------|------|------|
| `defaultConfig` | `fn () PoolConfig` | 返回默认配置 |
| `BufferPool.init` | `fn (allocator, cfg: PoolConfig) !Self` | 创建缓冲池 |
| `BufferPool.deinit` | `fn (self: *Self) void` | 释放所有资源 |
| `BufferPool.acquire` | `fn (self: *Self) !?Buffer` | 借出一个块（无可用块时返回 null） |
| `BufferPool.release` | `fn (self: *Self, buf: Buffer) void` | 归还块到池中 |
| `BufferPool.blockSize` | `fn (self: *const Self) u32` | 查询块大小 |
| `BufferPool.shrink` | `fn (self: *Self, min_blocks: u32) u32` | 收缩到指定块数 |
| `BufferPool.shrinkToInitial` | `fn (self: *Self) u32` | 收缩回初始容量 |
| `BufferPool.totalMemory` | `fn (self: *const Self) usize` | 总分配内存（字节） |
| `BufferPool.freeBlocks` | `fn (self: *const Self) usize` | 空闲块数 |
| `BufferPool.usedBlocks` | `fn (self: *const Self) usize` | 已用块数 |
| `BufferPool.totalBlocks` | `fn (self: *const Self) u32` | 总块数 |

---

### ring.zig — 环缓冲区

> **Phase 1** | std only | 来源: zproxy/src/core/ringbuf.zig

泛型 SPSC（单生产者单消费者）无锁环缓冲区。固定容量，使用原子操作同步读写指针。
容量必须为 2 的幂（用于位掩码取模）。导出类型 `RingBuf`。

#### API

```zig
// 获取指定元素类型的 RingBuf 类型
pub fn RingBuf(comptime T: type) type
```

| 函数 | 签名 | 描述 |
|------|------|------|
| `init` | `fn (buf: []T) Self` | 用外部提供的缓冲区初始化 |
| `len` | `fn (self: *const Self) usize` | 当前已写入数量 |
| `capacity` | `fn (self: *const Self) usize` | 最大容量 |
| `availableWrite` | `fn (self: *const Self) usize` | 可写入剩余空间 |
| `availableRead` | `fn (self: *const Self) usize` | 可读取数量 |
| `isFull` | `fn (self: *const Self) bool` | 是否已满 |
| `isEmpty` | `fn (self: *const Self) bool` | 是否为空 |
| `push` | `fn (self: *Self, item: T) void` | 写入一个元素（调用者保证不满） |
| `pop` | `fn (self: *Self) T` | 读取一个元素（调用者保证不空） |
| `pushSlice` | `fn (self: *Self, items: []const T) usize` | 批量写入，返回实际写入数 |
| `popSlice` | `fn (self: *Self, dest: []T) usize` | 批量读取，返回实际读取数 |
| `tryPush` | `fn (self: *Self, item: T) bool` | 尝试写入，满时返回 false |
| `tryPop` | `fn (self: *Self) ?T` | 尝试读取，空时返回 null |

---

### endian.zig — 大小端转换

> **Phase 1** | std only | 新建

统一的大小端读写 API，消除各处散落的 `std.mem.readInt`/`writeInt` 样板代码。
命名惯例：`{read|write}{Type}{Endian}`。

#### API（全部 inline）

| 函数 | 签名 | 描述 |
|------|------|------|
| `readU16Big` | `fn (*const [2]u8) u16` | 大端读取 u16 |
| `readU16Little` | `fn (*const [2]u8) u16` | 小端读取 u16 |
| `readU32Big` | `fn (*const [4]u8) u32` | 大端读取 u32 |
| `readU32Little` | `fn (*const [4]u8) u32` | 小端读取 u32 |
| `readU64Big` | `fn (*const [8]u8) u64` | 大端读取 u64 |
| `readU64Little` | `fn (*const [8]u8) u64` | 小端读取 u64 |
| `writeU16Big` | `fn (*[2]u8, val: u16) void` | 大端写入 u16 |
| `writeU16Little` | `fn (*[2]u8, val: u16) void` | 小端写入 u16 |
| `writeU32Big` | `fn (*[4]u8, val: u32) void` | 大端写入 u32 |
| `writeU32Little` | `fn (*[4]u8, val: u32) void` | 小端写入 u32 |
| `writeU64Big` | `fn (*[8]u8, val: u64) void` | 大端写入 u64 |
| `writeU64Little` | `fn (*[8]u8, val: u64) void` | 小端写入 u64 |
| `readIntBig` | `fn (comptime T: type, bytes: []const u8) T` | 泛型大端读取 |
| `readIntLittle` | `fn (comptime T: type, bytes: []const u8) T` | 泛型小端读取 |
| `writeIntBig` | `fn (comptime T: type, bytes: []u8, val: T) void` | 泛型大端写入 |
| `writeIntLittle` | `fn (comptime T: type, bytes: []u8, val: T) void` | 泛型小端写入 |

---

### platform.zig — 平台抽象

> **Phase 2** | std only | 来源: zigproxy + zigtun + zproxy

跨平台检测、时间获取、系统资源探测、DNS 探测。
各平台 `#ifdef` 集中在本模块，其他模块通过本模块间接适配。

#### 编译期常量

| 常量 | 类型 | 描述 |
|------|------|------|
| `isDarwin` | `bool` | macOS / iOS / tvOS / watchOS / visionOS |
| `isLinux` | `bool` | Linux |
| `isWindows` | `bool` | Windows |
| `isMobile` | `bool` | iOS / tvOS / watchOS / visionOS / Android |

#### API

| 函数 | 签名 | 描述 |
|------|------|------|
| `monoMillis` | `fn () i64` | 单调时钟毫秒，不受系统时间调整影响 |
| `monoMicros` | `fn () i64` | 单调时钟微秒 |
| `monoNanos` | `fn () i64` | 单调时钟纳秒 |
| `absoluteMillis` | `fn () i64` | 绝对（墙上）时钟毫秒，可能受 NTP 影响 |
| `getCpuCount` | `fn () usize` | 在线 CPU 核数，失败时回退到 2 |
| `getMaxFds` | `fn () usize` | 最大 fd 数（预留 4 给 stdin/stdout/stderr/server） |
| `raiseMaxFds` | `fn () void` | 如 fd 软限制低于 2048 则提升（非 Windows） |
| `getRecommendedPoolSize` | `fn () usize` | 推荐会话池大小：maxFds / 2 - 4，截断到 [16, 32767] |
| `detectSystemDns` | `fn (allocator) []const u8` | 从系统配置探测 DNS 地址，回退到 "8.8.8.8" |
| `sleepNs` | `fn (ns: u64) void` | 跨平台纳秒睡眠（Windows Sleep / POSIX nanosleep） |

---

### net.zig — 网络工具

> **Phase 2** | std only | 来源: zproxy/src/utils.zig + ip_cidr.zig + ip_cidr6.zig

IP 地址格式化/解析、完整 IPv4/v6 CIDR 接口、域名合法性判断、host:port 解析。
不含 checksum。

#### 类型

```zig
pub const Ip4Addr = [4]u8;   // IPv4 地址（网络字节序，大端）
pub const Ip6Addr = [16]u8;  // IPv6 地址（网络字节序，大端）
```

#### 常量

| 常量 | 值 | 描述 |
|------|-----|------|
| `max_addr_buf` | 64 | IPv4 格式化字符串最大缓冲 |
| `max_host_port_len` | 128 | "host:port" 字符串最大长度 |

#### IP 格式化/解析

| 函数 | 签名 | 描述 |
|------|------|------|
| `formatIpv4` | `fn (bytes: []const u8, buf: *[max_addr_buf]u8) []const u8` | IPv4 字节 → 点分十进制 |
| `formatIpv6` | `fn (bytes: []const u8, buf: *[max_ipv6_buf]u8) []const u8` | IPv6 字节 → 冒号十六进制 |
| `ip4ToInt` | `fn (bytes: []const u8) u32` | IPv4 字节 → 主机序 u32 |
| `intToIp4` | `fn (val: u32) Ip4Addr` | 主机序 u32 → IPv4 字节 |
| `ip6ToInt` | `fn (bytes: []const u8) u128` | IPv6 字节 → 主机序 u128 |
| `intToIp6` | `fn (val: u128) Ip6Addr` | 主机序 u128 → IPv6 字节 |
| `parseIpv4` | `fn (str: []const u8) !Ip4Addr` | 点分十进制 → IPv4 字节 |
| `parseIpv6` | `fn (str: []const u8) !Ip6Addr` | 冒号十六进制 → IPv6 字节 |

#### 地址判断

| 函数 | 签名 | 描述 |
|------|------|------|
| `isIpv4` | `fn (addr: []const u8) bool` | 是否为 IPv4 字节串 (4 字节) |
| `isIpv6` | `fn (addr: []const u8) bool` | 是否为 IPv6 字节串 (16 字节) |
| `isDomain` | `fn (addr: []const u8) bool` | 是否为域名（非 4/16 字节 = 域名） |
| `isValidPort` | `fn (port: u16) bool` | 端口是否有效 (1-65535) |
| `isValidIpv4String` | `fn (str: []const u8) bool` | 是否有效 IPv4 字符串 |
| `isValidIpv6String` | `fn (str: []const u8) bool` | 是否有效 IPv6 字符串 |
| `isValidDomain` | `fn (domain: []const u8) bool` | 是否有效域名 |
| `isValidHost` | `fn (host: []const u8) bool` | 是否有效主机（IP 或域名） |

#### Host:Port 解析

| 函数 | 签名 | 描述 |
|------|------|------|
| `parseHostPort` | `fn (host_port: []const u8) !struct { host: []const u8, port: u16 }` | 解析 "host:port" 字符串 |
| `buildHostPort` | `fn (host: []const u8, port: u16, buf: *[max_host_port_len]u8) ![]const u8` | 构造 "host:port" 字符串 |

#### Cidr4 — IPv4 CIDR

```zig
pub const Cidr4 = struct {
    network: u32,    // 网络地址（主机序）
    mask_bits: u8,   // 前缀长度 (0-32)
};
```

| 方法 | 签名 | 描述 |
|------|------|------|
| `parse` | `fn (s: []const u8) !Cidr4` | 解析 "192.168.1.0/24" |
| `contains` | `fn (self, ip_host: u32) bool` | 主机序 IP 是否在范围内 |
| `containsIp4` | `fn (self, ip: Ip4Addr) bool` | 网络序 IP 是否在范围内 |
| `networkAddr` | `fn (self) u32` | 网络地址（主机序） |
| `networkBytes` | `fn (self) Ip4Addr` | 网络地址（网络序字节） |
| `broadcastAddr` | `fn (self) u32` | 广播地址（主机序） |
| `broadcastBytes` | `fn (self) Ip4Addr` | 广播地址（网络序字节） |
| `netmask` | `fn (self) u32` | 子网掩码（主机序） |
| `prefixLen` | `fn (self) u8` | 前缀长度 |
| `format` | `fn (self, buf: *[max_addr_buf]u8) ![]const u8` | 格式化为 "a.b.c.d/n" |

#### Cidr6 — IPv6 CIDR

```zig
pub const Cidr6 = struct {
    base: Ip6Addr,    // 基础地址（网络序）
    mask_bits: u8,    // 前缀长度 (0-128)
};
```

| 方法 | 签名 | 描述 |
|------|------|------|
| `parse` | `fn (s: []const u8) !Cidr6` | 解析 "2001:db8::/32" |
| `contains` | `fn (self, ip: Ip6Addr) bool` | IP 是否在范围内 |
| `network` | `fn (self) Ip6Addr` | 网络地址 |
| `prefixLen` | `fn (self) u8` | 前缀长度 |
| `next` | `fn (self) Ip6Addr` | 下一个子网起始地址 |
| `format` | `fn (self, buf: *[max_ipv6_buf]u8) ![]const u8` | 格式化为标准 CIDR 表示 |

---

### strings.zig — 字符串处理

> **Phase 3** | std only | 新建

常用字符串处理：大小写转换、子串搜索、前后缀匹配、拼接、切分。
遵循注入模式：Allocator 作为参数传入。

#### 类型

```zig
pub const SplitTrimIterator = struct { ... };
// 迭代器，next() 返回下一个去空白段或 null
```

#### API

| 函数 | 签名 | 描述 |
|------|------|------|
| `toLower` | `fn (allocator, s: []const u8) ![]u8` | 转小写（分配新内存） |
| `toUpper` | `fn (allocator, s: []const u8) ![]u8` | 转大写（分配新内存） |
| `toLowerInPlace` | `fn (s: []u8) void` | 原地转小写 |
| `toUpperInPlace` | `fn (s: []u8) void` | 原地转大写 |
| `contains` | `fn (haystack: []const u8, needle: []const u8) bool` | 子串搜索 |
| `containsIgnoreCase` | `fn (haystack: []const u8, needle: []const u8) bool` | 大小写不敏感子串搜索 |
| `startsWithIgnoreCase` | `fn (haystack: []const u8, needle: []const u8) bool` | 忽略大小写前缀匹配 |
| `endsWithIgnoreCase` | `fn (haystack: []const u8, needle: []const u8) bool` | 忽略大小写后缀匹配 |
| `join` | `fn (allocator, parts: []const []const u8, separator: []const u8) ![]u8` | 拼接字符串数组 |
| `splitLines` | `fn (s: []const u8) std.mem.SplitIterator(u8, .scalar)` | 按行切分 |
| `splitTrim` | `fn (s: []const u8, delimiter: u8) SplitTrimIterator` | 按分隔符切分并去空白 |

---

### cli.zig — 命令行框架

> **Phase 3** | std + zli v5.1.2 | 新建

基于 zli v5.1.2 的薄封装。提供 CLI 脚手架 + 跨平台信号处理 + 守护进程化。

#### 重新导出（zli 原生类型）

```zig
pub const zli = @import("zli");      // zli 完整模块
pub const Command = zli.Command;
pub const CommandContext = zli.CommandContext;
pub const CommandOptions = zli.CommandOptions;
pub const Flag = zli.Flag;
pub const FlagType = zli.FlagType;
pub const FlagValue = zli.FlagValue;
pub const PositionalArg = zli.PositionalArg;
pub const InitOptions = zli.InitOptions;
pub const CommandErrors = zli.CommandErrors;
```

#### 信号类型

```zig
pub const Signal = enum {
    interrupt,   // SIGINT / Ctrl+C
    terminate,   // SIGTERM
    hangup,      // SIGHUP
};

pub const ExitCallback = *const fn () void;
```

#### API

| 函数 | 签名 | 描述 |
|------|------|------|
| `createRoot` | `fn (allocator, opts: CommandOptions) !*Command` | 创建根命令（自动设 stdout/stderr） |
| `run` | `fn (root: *Command, args: std.process.Args) noreturn` | 运行根命令并退出进程 |
| `noopAction` | `fn (_: CommandContext) anyerror!void` | 无操作 action（父命令默认值） |
| `registerExitCallback` | `fn (cb: ExitCallback) void` | 注册退出回调（最多 16 个，LIFO 调用） |
| `installExitHandlers` | `fn (signals: []const Signal) !void` | 安装信号处理器 |
| `waitForSignal` | `fn () Signal` | 阻塞等待注册的信号 |
| `exitRequested` | `fn () bool` | 非阻塞检查是否收到退出信号 |
| `daemonize` | `fn () !void` | 守护进程化（POSIX double-fork，Windows 返回 Unsupported） |

---

### log.zig — 日志框架

> **Phase 3** | std only | 新建

基于 `std.log` 的跨平台日志。覆盖全局 `std_options.logFn` 路由到平台适配输出。

- Android → `__android_log_write` (logcat)，带优先级和 tag
- iOS / tvOS / watchOS / visionOS → `syslog`，集成系统日志
- macOS / Linux / Windows → stderr + ANSI 颜色

#### 类型

```zig
pub const Level = std.log.Level;   // .err | .warn | .info | .debug
```

#### API

| 函数 | 签名 | 描述 |
|------|------|------|
| `init` | `fn (level: Level) void` | 初始化日志级别 |
| `setLevel` | `fn (level: Level) void` | 运行时动态切换级别 |
| `getLevel` | `fn () Level` | 获取当前级别 |
| `logOptions` | `fn () std.Options` | 返回带自定义 logFn 的 std.Options |

**使用方式** — 在应用根文件中：

```zig
pub const std_options: std.Options = foundation.log.logOptions();
```

---

### yaml.zig — YAML 解析

> **Phase 4** | std + libyaml C | 新建

libyaml C 库封装（build.zig `addTranslateC` + `addCSourceFiles` 编译）。
提供 `Document` 类型，封装 `yaml_document_t` 并给出 Zig 友好的节点导航 API。
不包含任何业务配置结构。

#### 错误

```zig
pub const Error = error{
    ParseFailed,
    OutOfMemory,
    InvalidNodeType,
    EmptyDocument,
};
```

#### 类型

```zig
pub const Document.Node.Kind = enum { scalar, sequence, mapping };

pub const Document.MappingEntry = struct {
    key: Node,
    value: Node,
};
```

#### Document API

| 方法 | 签名 | 描述 |
|------|------|------|
| `parse` | `fn (content: []const u8) !Document` | 从 YAML 字符串解析文档 |
| `deinit` | `fn (self: *Document) void` | 释放文档资源 |
| `root` | `fn (self: *Document) Node` | 获取根节点 |

#### Node API

| 方法 | 签名 | 描述 |
|------|------|------|
| `kind` | `fn (self) Kind` | 节点类型 |
| `asString` | `fn (self) ?[]const u8` | 标量 → 字符串（非标量返回 null） |
| `asInt` | `fn (self, comptime T: type) ?T` | 标量 → 整数（非整数返回 null） |
| `asBool` | `fn (self) ?bool` | 标量 → 布尔（true/yes/false/no） |
| `seqLen` | `fn (self) usize` | 序列长度（非序列返回 0） |
| `seqGet` | `fn (self, index: usize) ?Node` | 序列子节点（越界返回 null） |
| `seqIter` | `fn (self) SeqIterator` | 序列迭代器 |
| `mappingGet` | `fn (self, key: []const u8) ?Node` | 按键查映射值（不存在返回 null） |
| `mappingIter` | `fn (self) MappingIterator` | 映射迭代器 |

#### 迭代器 API

| 方法 | 签名 | 描述 |
|------|------|------|
| `SeqIterator.next` | `fn (self: *SeqIterator) ?Node` | 下一个序列元素 |
| `MappingIterator.next` | `fn (self: *MappingIterator) ?MappingEntry` | 下一个键值对 |

#### 示例

```zig
var doc = try foundation.yaml.Document.parse(
    \\server:
    \\  port: 8080
    \\  hosts:
    \\    - example.com
    \\    - test.com
);
defer doc.deinit();

const root = doc.root();
const port = root.mappingGet("server").?.mappingGet("port").?.asInt(u16).?;
```

---

### store.zig — 存储框架

> **Phase 4** | std only | 来源: zigproxy

文件系统持久化 KV 存储。每个键存储为独立文件 `{dir}/{hex(key)}`。
文件格式：8 字节到期时间戳 (u64 大端，0 = 永不过期) + 值字节。
原子写入：先写 `.tmp`，再 rename（不显式 fsync，依赖 OS 回写）。

#### 常量

| 常量 | 值 | 描述 |
|------|-----|------|
| `MAX_KEY_LEN` | 125 | 键最大字节长度 |
| `MAX_VALUE_LEN` | 16 MB | 值最大字节长度 |

#### API

| 方法 | 签名 | 描述 |
|------|------|------|
| `Store.init` | `fn (allocator, io: std.Io, dir_path: []const u8) !Store` | 创建实例（自动创建目录，解析绝对路径） |
| `Store.deinit` | `fn (self: *Store) void` | 释放资源（目录和文件保留在磁盘） |
| `Store.get` | `fn (self: *Store, key: []const u8) !?[]const u8` | 按键查询，未找到或过期返回 null |
| `Store.set` | `fn (self: *Store, key: []const u8, value: []const u8, ttl_seconds: u64) !void` | 写入键值（原子写入，ttl=0 永不过期） |
| `Store.delete` | `fn (self: *Store, key: []const u8) !void` | 删除键（不存在时静默忽略） |
| `Store.cleanExpired` | `fn (self: *Store) !usize` | 清理过期条目，返回清理数 |

---

### event.zig — 事件通知

> **Phase 4** | std only | 来源: zproxy/src/core/event.zig

跨线程手动重置事件（manual-reset event）。`set()` 唤醒所有等待者并保持置位，直到 `reset()`。
根据 OS 分派：POSIX 实现 (pthread) / Windows 实现 (SRWLOCK)。

#### 类型

```zig
// 公开类型别名 — 根据 OS 自动选择实现
pub const ResetEvent = if (builtin.os.tag == .windows) WindowsResetEvent else PosixResetEvent;
```

#### ResetEvent API

| 方法 | 签名 | 描述 |
|------|------|------|
| `init` | `fn (self: *ResetEvent) void` | 初始化事件（POSIX 初始化 mutex/cond） |
| `deinit` | `fn (self: *ResetEvent) void` | 销毁事件（POSIX 销毁 mutex/cond） |
| `set` | `fn (self: *ResetEvent) void` | 置位事件，唤醒所有等待者（线程安全） |
| `setFromSignal` | `fn (self: *ResetEvent) void` | 异步信号安全 set（仅原子存储） |
| `wait` | `fn (self: *ResetEvent) void` | 阻塞等待直到 set() |
| `timedWait` | `fn (self: *ResetEvent, timeout_ms: u32) bool` | 超时等待，true=已置位，false=超时 |
| `reset` | `fn (self: *ResetEvent) void` | 清除事件信号 |
| `isSet` | `fn (self: *const ResetEvent) bool` | 非阻塞检查状态 |

> **注意**: 结构体实例不可重定位（含 pthread mutex/cond 内部指针），保持地址稳定。

---

### queue.zig — 并发队列

> **Phase 4** | std only | 来源: zproxy/src/core/queue.zig

跨线程有界 MPSC 队列。泛型 `Queue(T, capacity)` 返回固定容量环形缓冲区类型，
由 pthread mutex + ResetEvent 保护。

#### 类型

```zig
// 获取指定元素类型和容量的 Queue 类型
pub fn Queue(comptime T: type, comptime capacity: usize) type
```

满时 `push()` 覆盖最旧条目（保护消费者不被淹没）。

#### API

| 方法 | 签名 | 描述 |
|------|------|------|
| `init` | `fn (self: *Self) void` | 初始化 mutex 和 event |
| `deinit` | `fn (self: *Self) void` | 销毁 mutex 和 event |
| `push` | `fn (self: *Self, item: T) void` | 入队（满时覆盖最旧，唤醒消费者） |
| `tryPop` | `fn (self: *Self) ?T` | 出队一个元素（空时返回 null） |
| `drain` | `fn (self: *Self, out: []T) usize` | 批量出队（FIFO），返回实际出队数 |
| `wait` | `fn (self: *Self) void` | 阻塞等待 push() 发生 |
| `len` | `fn (self: *const Self) usize` | 当前队列长度（快照值，调用后可能立变） |

---

### egress.zig — 网络出站

> **Phase 5** | std only | 新建

跨平台网络出站 socket 创建 + 绕过路由绑定。

#### 平台支持矩阵

| 功能 | Linux | macOS | iOS | Windows | Android |
|------|-------|-------|-----|---------|---------|
| 接口名绑定 | SO_BINDTODEVICE | ❌ | ❌ | ❌ | SO_BINDTODEVICE |
| 接口索引绑定 | ❌ | IP_BOUND_IF | IP_BOUND_IF | IP_UNICAST_IF | ❌ |
| 源地址绑定 | bind() | bind() | bind() | bind() | bind() |

#### 类型

```zig
pub const BindOpts = struct {
    interface_name: ?[]const u8 = null,   // Linux/Android: SO_BINDTODEVICE
    interface_index: ?u32 = null,         // macOS/iOS: IP_BOUND_IF, Windows: IP_UNICAST_IF
    source_addr: ?[]const u8 = null,      // 源地址 "ip:port"（如 "127.0.0.1:0"）
    reuse_addr: bool = true,             // SO_REUSEADDR
};
```

#### Socket API

| 方法 | 签名 | 描述 |
|------|------|------|
| `initTcp` | `fn (opts: BindOpts) !Socket` | 创建 TCP socket + 应用绑定选项 |
| `initUdp` | `fn (opts: BindOpts) !Socket` | 创建 UDP socket + 应用绑定选项 |
| `initTcp6` | `fn (opts: BindOpts) !Socket` | 创建 IPv6 双栈 TCP socket |
| `initUdp6` | `fn (opts: BindOpts) !Socket` | 创建 IPv6 双栈 UDP socket |
| `close` | `fn (self: *Socket) void` | 关闭 socket |
| `getFd` | `fn (self: *const Socket) std.posix.socket_t` | 获取原始 fd（供 libxev 等异步 I/O） |

```zig
// 示例：创建绑定到指定接口的 TCP socket
const sock = try foundation.egress.Socket.initTcp(.{
    .interface_name = "eth0",
    .source_addr = "10.0.0.1:0",
});
defer sock.close();
```

### memconn.zig — 内存网络连接

> **Phase 8** | std + libxev | 新建

进程内异步 socket-like 接口，通过 `RingBuf` + `xev.Async` 纯内存实现，完全融入 libxev Completion 模型。零 fd 开销，适合同一进程内多个网络模块（TUN → Proxy → Outbound）的跨线程数据交换。

#### 架构

```
SharedState(buf_size)           — 堆分配，引用计数管理
  ├─ RingBuf(u8) ×2             — 每方向一个无锁环形缓冲 (SPSC)
  ├─ xev.Async ×4               — 每端点独立的读/写通知器
  └─ atomic(bool)               — 关闭标志

MemConn                         — 轻量句柄（指针语义，无所有权）
  ├─ read/write/close           — Completion 回调接口
  └─ 可选 refcounted 清理       — createPair / Registry 用
```

#### 类型

```zig
pub const MemConnError = error{
    Closed,
    NameNotFound,
    NameInUse,
    NotInitialized,
    OutOfMemory,
};

pub const MemConn = struct {
    // 注册异步读操作。回调触发时机：rx_ring 有数据或对端关闭（返回 0 = EOF）。
    // cb: fn (?*Userdata, *xev.Loop, *xev.Completion, []u8, error{Closed}!usize) xev.CallbackAction
    pub fn read(self, loop, c, buf, comptime Userdata, userdata, comptime cb) void;

    // 注册异步写操作。尽力写入全部数据，缓冲区满时自动等待并 re-arm。
    // cb: fn (?*Userdata, *xev.Loop, *xev.Completion, []const u8, error{Closed}!usize) xev.CallbackAction
    pub fn write(self, loop, c, buf, comptime Userdata, userdata, comptime cb) void;

    // 异步关闭。设置原子标志，通知对端。幂等（已关闭则立即回调）。
    // cb: fn (?*Userdata, *xev.Loop, *xev.Completion, void) xev.CallbackAction
    pub fn close(self, loop, c, comptime Userdata, userdata, comptime cb) void;

    pub fn isClosed(self) bool;
};

pub const PairHandle = struct {
    local: MemConn,
    remote: MemConn,
    // 同步销毁：设置关闭标志、通知对端、释放 2 个引用计数。
    // 调用前确保无 pending completions。
    pub fn destroy(self: *PairHandle) void;
};

pub const MemListener = struct {
    // 注册异步接受。回调返回 conn（非空 = 新连接）或 null（listener 已关闭）。
    // cb: fn (?*Userdata, *xev.Loop, *xev.Completion, ?MemConn) xev.CallbackAction
    pub fn accept(self, loop, c, comptime Userdata, userdata, comptime cb) void;

    pub fn close(self) void;       // 同步关闭 listener
    pub fn name(self) []const u8;  // listener 注册名
};

pub const Registry = struct {
    pub fn init(allocator: std.mem.Allocator) !Registry;
    pub fn deinit(self: *Registry) void;
    pub fn listen(self: *Registry, name: []const u8) !*MemListener;
    pub fn dial(self: *Registry, comptime buf_size: usize, name: []const u8) !MemConn;  // 同步
    pub fn unlisten(self: *Registry, name: []const u8) void;
};
```

#### 获取连接的三种方式

| 方式 | 函数 | 场景 |
|------|------|------|
| 直接创建 | `createPair(buf_size, loop_a, loop_b, allocator)` | 同一初始化路径中直接拿到 local + remote |
| 命名注册 | `Registry.listen/dial` | 跨模块，按名称解耦发现；dial 同步返回，accept 异步获取 |
| 全局便捷 | `initGlobal(allocator)` / `listen(name)` / `dial(buf_size, name)` | 全局单例，免去传递 Registry 实例 |

#### 核心 API

| 方法 | 签名 | 描述 |
|------|------|------|
| `createPair` | `fn (comptime buf_size: usize, loop_a, loop_b, allocator) !PairHandle` | 创建一对已连接的 MemConn |
| `read` | `fn (self, loop, c, buf, Userdata, userdata, cb) void` | 异步读 — rx_ring 有数据或对端关闭时回调（返回 0 = EOF） |
| `write` | `fn (self, loop, c, buf, Userdata, userdata, cb) void` | 异步写 — 尽力写入全部数据，中间满时自动 re-arm 等待 |
| `close` | `fn (self, loop, c, Userdata, userdata, cb) void` | 异步关闭 — 设置关闭标志，通知对端。幂等（可安全多次调用） |
| `isClosed` | `fn (self) bool` | 非阻塞检查关闭状态 |

---

#### 使用模式

##### 模式 1：createPair — 最基本读写

```zig
var loop = try xev.Loop.init(.{});
defer loop.deinit();

var pair = try memconn.createPair(256, &loop, &loop, allocator);
defer pair.destroy();

var write_done = false;
var read_buf: [64]u8 = undefined;
var read_n: usize = 0;

// 一端写
var wc: xev.Completion = .{};
pair.local.write(&loop, &wc, "hello", bool, &write_done, (struct {
    fn cb(ud: ?*bool, l: *xev.Loop, c: *xev.Completion, b: []const u8, r: error{Closed}!usize) xev.CallbackAction {
        _ = l; _ = c; _ = b;
        ud.?.* = true;
        _ = r catch unreachable;
        return .disarm;
    }
}).cb);

// 另一端读
var rc: xev.Completion = .{};
pair.remote.read(&loop, &rc, &read_buf, usize, &read_n, (struct {
    fn cb(ud: ?*usize, l: *xev.Loop, c: *xev.Completion, b: []u8, r: error{Closed}!usize) xev.CallbackAction {
        _ = l; _ = c; _ = b;
        ud.?.* = r catch unreachable;
        return .disarm;
    }
}).cb);

try loop.run(.until_done);
// write_done == true, read_n == 5, read_buf[0..5] == "hello"
```

##### 模式 2：双向同时通信

`pair.local` 和 `pair.remote` 完全对称，可同时在两个方向收发：

```zig
// 两个方向同时写
pair.local.write(&loop, &wc1, "ping", void, null, writeCb);
pair.remote.write(&loop, &wc2, "pong", void, null, writeCb);

// 两个方向同时读
pair.remote.read(&loop, &rc1, &remote_buf, usize, &remote_n, readCb1);
pair.local.read(&loop, &rc2, &local_buf, usize, &local_n, readCb2);

try loop.run(.until_done);
// remote_buf == "ping", local_buf == "pong"
```

##### 模式 3：关闭与 EOF 检测

```zig
// 一端关闭
var cc: xev.Completion = .{};
pair.local.close(&loop, &cc, void, null, (struct {
    fn cb(_: ?*void, _: *xev.Loop, _: *xev.Completion, _: void) xev.CallbackAction {
        return .disarm;
    }
}).cb);

// 对端 read 返回 0（EOF）
var read_n: isize = -1;
var rc: xev.Completion = .{};
pair.remote.read(&loop, &rc, &read_buf, isize, &read_n, (struct {
    fn cb(ud: ?*isize, l: *xev.Loop, c: *xev.Completion, b: []u8, r: error{Closed}!usize) xev.CallbackAction {
        _ = l; _ = c; _ = b;
        ud.?.* = @intCast(r catch unreachable);  // 0 = EOF
        return .disarm;
    }
}).cb);

try loop.run(.until_done);
// read_n == 0 且 pair.remote.isClosed() == true
```

**close() 是幂等的** — 多次调用安全，第二次及以后调用立即同步回调，不会重复注册 Completion。

##### 模式 4：生产代码 — 堆分配 Completion + re-arm 持续读

这是 zigproxy 等生产项目的推荐模式。Completion 嵌入堆分配的连接结构体，生命周期覆盖整个连接。在读回调中 re-arm 同一个 Completion 实现持续监听：

```zig
const Connection = struct {
    conn: memconn.MemConn,
    read_c: xev.Completion = .{},   // Completion 嵌入结构体（堆分配）
    buf: [4096]u8 = undefined,
    total: usize = 0,

    fn start(self: *Connection, loop: *xev.Loop) void {
        self.conn.read(loop, &self.read_c, &self.buf, Connection, self, onData);
    }

    fn onData(ud: ?*Connection, loop: *xev.Loop, c: *xev.Completion,
              buf: []u8, r: error{Closed}!usize) xev.CallbackAction {
        const self = ud.?;
        const n = r catch return .disarm;
        if (n == 0) return .disarm;  // EOF

        // 处理 buf[0..n] ...

        // re-arm：继续读（复用同一个 Completion c）
        self.conn.read(loop, c, &self.buf, Connection, self, onData);
        return .disarm;
    }
};

// 使用
var ctx = try allocator.create(Connection);
ctx.conn = pair.remote;
ctx.start(loop);

// 对端多次写
pair.local.write(&loop, &wc1, "ab", ...);
pair.local.write(&loop, &wc2, "cd", ...);
try loop.run(.until_done);
// ctx.total == 4
```

##### 模式 5：Registry — 命名连接跨模块解耦

```zig
var reg = try memconn.Registry.init(allocator);
defer reg.deinit();

// === 服务端 ===
var listener = try reg.listen("tun.device0");
defer { listener.close(); listener.deinit(); }

// 异步 accept
var accepted: ?memconn.MemConn = null;
var ac: xev.Completion = .{};
listener.accept(&loop, &ac, ?memconn.MemConn, &accepted, (struct {
    fn cb(ud: ?*?memconn.MemConn, l: *xev.Loop, c: *xev.Completion, conn: ?memconn.MemConn) xev.CallbackAction {
        _ = l; _ = c;
        ud.?.* = conn;  // conn == null 表示 listener 已关闭
        return .disarm;
    }
}).cb);

// === 客户端（不同线程/模块）===
var conn = try reg.dial(4096, "tun.device0");  // 同步，立即返回
conn.write(&loop, &wc, "hello", ...);

// 服务端 accept 回调触发，拿到 conn
try loop.run(.until_done);
// accepted != null，可进行 read/write

// 重要：Registry 模式下两端都必须 close() 以释放 SharedState 引用计数
var c1: xev.Completion = .{};
conn.close(&loop, &c1, void, null, closeCb);
var c2: xev.Completion = .{};
accepted.?.close(&loop, &c2, void, null, closeCb);
try loop.run(.until_done);
```

##### 模式 6：跨线程通信

跨线程通知通过 `xev.Async.notify()`（线程安全）实现，无需多个事件循环：

```zig
// 线程 A — 事件循环线程（注册读，阻塞在 loop.run()）
const t = try std.Thread.spawn(.{}, (struct {
    fn run(c: *Ctx) void {
        var rc: xev.Completion = .{};
        c.remote.read(c.loop, &rc, &c.read_buf, Ctx, c, onData);
        c.loop.run(.until_done) catch {};
    }
}).run, .{&ctx});

// 线程 B — 写数据（内部调用 peer_read_async.notify() 唤醒线程 A）
var wc: xev.Completion = .{};
pair.local.write(&loop_a, &wc, "ping", void, null, writeCb);
try loop_a.run(.until_done);

t.join();
// ctx.read_buf == "ping"
```

**原理**：write() 将数据推入 `tx_ring`（lock-free SPSC），然后 `peer_read_async.notify()` 跨线程唤醒对端事件循环。全程仅原子操作 + 环形缓冲区，零系统调用（notify 除外）。

> **注意**：以上跨线程示例使用双 Loop 是因为测试中 Completion 是栈变量且线程会提前退出。
> 生产代码中推荐**单 Loop** + 堆分配 Completion，仅用 `notify()` 跨线程唤醒。

---

#### 回调签名速查

所有回调必须返回 `xev.CallbackAction`（`.disarm` 或 `.rearm`），且必须通过**内联 struct 的 `.cb` 字段**传入（comptime 约束，不可传函数变量）：

| 操作 | 回调签名 | `r` 含义 |
|------|---------|----------|
| `read` | `fn (?*Userdata, *xev.Loop, *xev.Completion, []u8, error{Closed}!usize) xev.CallbackAction` | `0` = EOF（对端关闭），`>0` = 读到的字节数 |
| `write` | `fn (?*Userdata, *xev.Loop, *xev.Completion, []const u8, error{Closed}!usize) xev.CallbackAction` | 实际写入字节数；调用者应确保一次回调中完全写入 |
| `close` | `fn (?*Userdata, *xev.Loop, *xev.Completion, void) xev.CallbackAction` | 无错误传递 |
| `accept` | `fn (?*Userdata, *xev.Loop, *xev.Completion, ?MemConn) xev.CallbackAction` | `null` = listener 已关闭 |

---

#### 注意事项

1. **回调必须是 comptime 函数**：`read/write/close/accept` 的 `cb` 参数是 `comptime` 的。不能传函数指针变量，必须用内联 struct 模式：

   ```zig
   // ❌ 错误：函数指针变量不是 comptime 已知的
   const myCb = someStruct.someFn;
   conn.read(&loop, &c, &buf, void, null, myCb);

   // ✅ 正确：内联 struct 的 .cb 字段是 comptime 已知的
   conn.read(&loop, &c, &buf, void, null, (struct {
       fn cb(ud: ?*void, l: *xev.Loop, c: *xev.Completion, b: []u8, r: error{Closed}!usize) xev.CallbackAction {
           _ = l; _ = c; _ = b;
           // 处理数据...
           return .disarm;
       }
   }).cb);
   ```

2. **Completion 必须存活到回调触发后**：内核（kqueue/epoll/IOCP）的 kevent `udata` 存储的是 `*xev.Completion` 指针。如果在回调触发前 Completion 被释放，导致 **use-after-free**。解决方案：
   - 生产代码：Completion 嵌入堆分配的结构体，生命周期覆盖整个连接
   - 测试代码：栈 Completion + `loop.run(.until_done)` 阻塞保证生命周期
   - 绝不：栈 Completion 跨线程（线程返回后栈被回收，kevent 仍持有悬垂指针）

3. **不同操作使用不同 Completion**：`read`、`write`、`close` 各需要独立的 `xev.Completion`。不可复用同一个 Completion 同时注册多个操作。

4. **`buf_size` 必须是 2 的幂**：编译期 `@compileError` 校验。`RingBuf` 使用位掩码取模，非 2 的幂会导致数据损坏。

5. **SPSC 契约**：每方向 RingBuf 是单生产者单消费者。同一端点的 `write`（或 `read`）不能从多线程并发调用。需要多生产者场景应在上层加队列或锁。

6. **Registry 模式下 close() 释放引用计数**：`Registry.dial()` 创建的连接，SharedState 引用计数由 `close()` 回调管理。两端都 close 后 SharedState 自动释放。反之，`createPair` 创建的连接由 `PairHandle.destroy()` 统一释放，close 不释放引用计数。

7. **`createPair` 的 `loop_a` / `loop_b` 参数**：目前仅为 API 预留（标记两端各自归属的事件循环），实际存储不依赖这两个参数。Async 的 init/notify/wait 不绑定特定 Loop 实例。可传同一个 Loop 两次。

8. **大消息自动分片**：当写入数据超过 RingBuf 可用空间时，write 先写入部分，剩余的通过回调中 `re-arm` 等待对端消费后继续。调用者无需处理部分写入——回调返回的 `written` 一定等于 `buf.len`（除非对端关闭）。

#### 线程安全模型

| 操作 | 安全约束 |
|------|---------|
| `read()` (端点A) + `write()` (端点B) | ✅ 并发安全（SPSC 每方向） |
| 两线程同时 `write()` 同一端点 | ❌ UB（破坏 SPSC 契约） |
| 两线程同时 `read()` 同一端点 | ❌ UB |
| `close()` 任意线程 | ✅ 安全（原子标志 + Async 通知） |
| `Registry.listen()` / `dial()` / `unlisten()` | ✅ Mutex 保护 |

---

## 移动端开发环境搭建

> 从裸机（macOS 开发主机）起步，构建可在 iOS 模拟器和 Android 模拟器上运行的 zigfoundation 示例程序并验证全部 13 个模块通过。

### 前置要求

| 工具 | 版本 | 用途 |
|------|------|------|
| Zig | 0.16.0 | 编译器 + 构建系统 |
| Xcode | 16.0+ | iOS SDK + 模拟器运行时 |
| Android Studio | 2024.2+ | Android SDK + NDK + AVD 管理器 |
| macOS | 14.0+ | 仅支持 macOS 作为交叉编译主机 |

### 1. Zig 安装

```bash
# 推荐使用 brew（从最新 Zig 发布版安装）
brew install zig

# 或手动下载二进制包解压到 ~/bin
# https://ziglang.org/download/

zig version  # 验证: 0.16.0
```

### 2. iOS 编译环境

#### 2.1 安装 Xcode 和 Command Line Tools

```bash
# 从 App Store 安装 Xcode，然后安装 Command Line Tools
xcode-select --install

# 验证 SDK 可用
xcrun --sdk iphonesimulator --show-sdk-path
# → /Applications/Xcode.app/.../iPhoneSimulator26.5.sdk
xcrun --sdk iphoneos --show-sdk-path
# → /Applications/Xcode.app/.../iPhoneOS26.5.sdk
```

#### 2.2 环境变量配置

在 `~/.bash_profile`（或 `~/.zshrc`）中添加：

```bash
export IOS_SDK_HOME_SIM=$(xcrun --sdk iphonesimulator --show-sdk-path 2>/dev/null)
export IOS_SDK_HOME_DEVICE=$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null)
```

#### 2.3 iOS 模拟器管理

```bash
# 查看可用运行时
xcrun simctl list runtimes

# 查看可用设备类型
xcrun simctl list devicetypes | grep iPhone

# 创建模拟器（如不存在）
xcrun simctl create "iPhone17Test" "iPhone 17" "com.apple.CoreSimulator.SimRuntime.iOS-26-5"

# 启动模拟器
xcrun simctl boot "iPhone17Test"
# 或
open -a Simulator

# 查看已启动设备
xcrun simctl list devices | grep Booted
```

#### 2.4 构建与运行

```bash
# 构建 iOS 模拟器可执行程序
zig build example-ios -Dtarget=aarch64-ios-simulator \
    -Doptimize=ReleaseSmall \
    -Dsysroot="$IOS_SDK_HOME_SIM"

# 直接在启动的模拟器中运行（无需 .app bundle）
xcrun simctl spawn booted ./zig-out/bin/zigfoundation-ios-test

# 期望输出
# [LOG] zigfoundation ios-test: 13/13 passed
```

#### 2.5 iOS 关键约束

| 约束 | 说明 |
|------|------|
| **必须 ReleaseSmall** | Debug 模式交叉链接 dyld 时缺少 `__dyld_get_image_header_containing_address` 符号 |
| **`/usr/lib` 路径** | MachO linker 自动在 sysroot 前缀查找 `libSystem.tbd`，`build.zig` 中需 `addLibraryPath(.{.cwd_relative = "/usr/lib"})` |
| **simctl spawn 直连终端** | stdout/stderr 直接输出到终端，无需截图、log stream 或 .app 打包 |
| **仅静态库** | 静态库编译不需要 `libSystem` 动态链接，可直接产出 `.a` |

### 3. Android 编译环境

#### 3.1 安装 Android Studio 和 NDK

```bash
# 方法一：从 Android Studio GUI 安装
# Preferences → Languages & Frameworks → Android SDK → SDK Tools → NDK (Side by side)

# 方法二：命令行安装
brew install android-studio
# 首次启动 Android Studio 完成 SDK 初始化向导

# 方法三：仅 sdkmanager 命令行
# 从 https://developer.android.com/studio#command-line-tools-only 下载
# 解压到 ~/Library/Android/sdk/cmdline-tools/latest/
```

安装以下组件：

```bash
sdkmanager --install \
    "platform-tools" \
    "platforms;android-36" \
    "ndk;30.0.15729638" \
    "system-images;android-36;aosp_arm64;phone" \
    "emulator"
```

#### 3.2 环境变量配置

在 `~/.bash_profile` 中添加：

```bash
export ANDROID_HOME="$HOME/Library/Android/sdk"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export ANDROID_NDK_HOME="$ANDROID_HOME/ndk/30.0.15729638"
export PATH="$ANDROID_HOME/platform-tools:$PATH"
```

#### 3.3 NDK libc 配置文件

Zig 交叉编译 Android 需要 libc 配置文件。创建 `ndk-libc.conf`：

```ini
# 文件位置：项目根目录或任意路径，构建时通过 -Dlibc-file 指定
# 格式：key=value

include_dir=$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/darwin-x86_64/sysroot/usr/include
sys_include_dir=$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/darwin-x86_64/sysroot/usr/include/aarch64-linux-android
crt_dir=$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/darwin-x86_64/sysroot/usr/lib/aarch64-linux-android/36
msvc_lib_dir=
kernel32_lib_dir=
gcc_dir=
```

**字段说明：**

| 字段 | 说明 |
|------|------|
| `include_dir` | C 标准头文件路径（`stdlib.h`、`string.h` 等） |
| `sys_include_dir` | 架构特定系统头文件路径（`asm/types.h`、`bits/` 等内核头文件） |
| `crt_dir` | CRT 目标文件路径（`crtbegin_dynamic.o`、`libc.so` 等），必须指定 API 级别子目录 |
| `msvc_lib_dir` | Windows cross 用，留空 |
| `kernel32_lib_dir` | Windows cross 用，留空 |
| `gcc_dir` | GCC 特定，留空 |

> **注意**：`crt_dir` 的 API 级别子目录（如 `36`）必须与实际安装的 NDK 版本中的目录名一致。

#### 3.4 NDK 库文件 Symlink 修复

NDK 30 中 `.so`/`.a` 文件存放在 `<triple>/<api>/` 子目录下，Zig 编译期在 `<triple>/` 父目录查找。需要创建符号链接：

```bash
cd "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/darwin-x86_64/sysroot/usr/lib/aarch64-linux-android"

# 将 API 子目录下的库文件链接到父目录
for f in 36/*.so 36/*.a; do
    [ -f "$f" ] && ln -sf "$f" "$(basename "$f")"
done

# 验证
ls -la libc.so libm.so libdl.so
# → 应指向 36/libc.so 等
```

#### 3.5 Android 模拟器管理

```bash
# 创建 AVD（仅首次）
avdmanager create avd -n "Pixel9_ARM64" \
    -k "system-images;android-36;aosp_arm64;phone" \
    -d "pixel_9"

# 列出已有 AVD
avdmanager list avd

# 启动模拟器（带 GUI）
emulator -avd Pixel9_ARM64 &

# 验证设备已连接
adb devices
# → List of devices attached
# → emulator-5554  device

# 等待设备完全启动
adb wait-for-device
```

#### 3.6 构建与运行

```bash
# 构建 Android ARM64 可执行测试程序
zig build android-test -Dtarget=aarch64-linux-android \
    -Doptimize=ReleaseSmall \
    -Dsysroot="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/darwin-x86_64/sysroot" \
    -Dlibc-file="$(pwd)/ndk-libc.conf"

# 推送可执行程序到模拟器
adb push ./zig-out/bin/zigfoundation-android-test /data/local/tmp/

# 运行测试
adb shell /data/local/tmp/zigfoundation-android-test

# 期望输出
# [LOG] zigfoundation android-test: 13/13 passed
```

#### 3.7 Android 关键约束

| 约束 | 说明 |
|------|------|
| **必须动态链接** | NDK 30 `libc.a` 包含 Rust std 对象文件，需要 `_Unwind_*` 符号 → 使用 `.linkage = .dynamic` |
| **adb shell CWD** | `adb shell` 工作目录为 `/data/local/tmp`（可写），JNI 应用的 CWD 为 `/`（不可写） |
| **Store 路径必须绝对路径** | 移动端无相对路径概念，`Store.init` 需传入 `/data/local/tmp/...` 或 `/tmp/...` 等绝对路径 |
| **log.zig Android 用 `__android_log_write`** | 直接调用 Bionic liblog，构建时通过 `addObjectFile` 链接 NDK 中的 `liblog.so` |
| **模拟器 GUI 可选** | `-no-window` 可无头运行，默认带窗口更便于调试 |

### 4. 构建命令速查

```bash
# ---- iOS ----
# 模拟器
zig build example-ios -Dtarget=aarch64-ios-simulator -Doptimize=ReleaseSmall -Dsysroot="$IOS_SDK_HOME_SIM"
xcrun simctl spawn booted ./zig-out/bin/zigfoundation-ios-test

# 真机（需 Apple Developer 签名）
zig build example-ios -Dtarget=aarch64-ios -Doptimize=ReleaseSmall -Dsysroot="$IOS_SDK_HOME_DEVICE"

# ---- Android ----
# 模拟器/真机（共享库）
zig build example-android -Dtarget=aarch64-linux-android -Doptimize=ReleaseSmall \
    -Dsysroot="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/darwin-x86_64/sysroot" \
    -Dlibc-file="$(pwd)/ndk-libc.conf"

# 模拟器/真机（可执行测试，直接 adb shell 运行）
zig build android-test -Dtarget=aarch64-linux-android -Doptimize=ReleaseSmall \
    -Dsysroot="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/darwin-x86_64/sysroot" \
    -Dlibc-file="$(pwd)/ndk-libc.conf"
adb push ./zig-out/bin/zigfoundation-android-test /data/local/tmp/
adb shell /data/local/tmp/zigfoundation-android-test
```

### 5. 常见问题排查

| 症状 | 可能原因 | 解决 |
|------|---------|------|
| `error: unable to find C compiler` | Xcode Command Line Tools 未安装 | `xcode-select --install` |
| `dyld: symbol '__dyld_get_image_header_containing_address' not found` | iOS Debug 模式链接问题 | 添加 `-Doptimize=ReleaseSmall` |
| `undefined reference to '_Unwind_*'` | Android 静态链接 NDK 30 libc.a | 使用 `.linkage = .dynamic` |
| `cannot find -llog` | Android `linkSystemLibrary("log")` 在 NDK 路径搜索为空 | 使用 `addObjectFile` 直接链接 NDK 中的 `liblog.so` |
| `fatal error: 'stdlib.h' file not found` | sysroot 未传播到 vendored C 库 | 检查 `-Dsysroot` 和 vendor/yaml 架构 include |
| `adb: no devices/emulators found` | 模拟器未启动 | `emulator -avd <name> &` 等待 `adb wait-for-device` |
| `Store.init` 失败 (PermissionDenied) | 移动端使用相对路径 | 改为绝对路径：iOS `/tmp/`，Android `/data/local/tmp/` |

---

## 变更日志

| 版本 | 日期 | 变更 |
|------|------|------|
| 0.1.5 | 2026-07-20 | log.zig 平台日志增强：Android 改用 `__android_log_write`(logcat)、iOS 改用 `syslog`；build.zig 新增 `android-test` 步骤；Android liblog 通过 `addObjectFile` 链接 |
| 0.1.4 | 2026-07-19 | memconn API 文档重写：6 种使用模式 + 回调签名速查 + 8 条注意事项（comptime 回调约束、Completion 生命周期、SPSC 契约、引用计数管理等） |
| 0.1.3 | 2026-07-19 | Phase 8 async rewrite: memconn.zig 从同步阻塞重写为 libxev Completion 模型（SharedState 含 4 个 xev.Async、双 loop 跨线程、219 tests 全绿） |
| 0.1.2 | 2026-07-19 | Phase 8: memconn.zig 内存网络连接模块（MemPipe/MemConn/PairHandle/MemListener/Registry），37 tests，233 total tests 全绿，zero memory leaks |
| 0.1.1 | 2026-07-19 | P0-P3 bug 修复 26 项（event/cli/platform/egress/strings/log/store），196 tests，三平台交叉编译 + iOS/Android 模拟器真机验证通过，移动端开发环境文档 |
| 0.1.0 | 2026-07-18 | 13 模块全部实现，173 tests 全绿，API 文档完成 |
