# zigfoundation API 参考

> **状态**: 框架已建立，API 文档随模块实现逐步填充。
>
> 版本: 0.1.0 | 目标平台: Windows / macOS / Linux / iOS / Android
>
> 依赖: Zig std + libxev (异步基础) + libyaml C 库 (yaml 模块)

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
const buf = try foundation.buffer.BufferPool.init(allocator, .{});
```

---

## 模块目录

### buffer.zig — 缓冲池

> **Phase 1** | std only | 来源: zigproxy/src/buffer.zig

固定大小缓冲区的 LIFO 复用池，采用 shrink-to-initial 策略。

```
[TBD — 提取后填写]
```

### ring.zig — 环缓冲区

> **Phase 1** | std only | 来源: zproxy/src/core/ringbuf.zig

SPSC (单生产者单消费者) 无锁环缓冲区，支持跨线程通信。导出类型 `RingBuf`。

```
[TBD — 提取后填写]
```

### endian.zig — 大小端转换

> **Phase 1** | std only | 新建

统一的大小端读写 API，消除各处散落的 `std.mem.readInt`/`writeInt` 样板代码。

```
[TBD — 实现后填写]
```

### platform.zig — 平台抽象

> **Phase 2** | std only | 来源: zigproxy + zigtun + zproxy

跨平台时间获取、平台类型检测、系统资源探测 (CPU 核数 / fd 上限 / 推荐线程池大小)、系统 DNS 探测。

```
[TBD — 合并后填写]
```

### net.zig — 网络工具

> **Phase 2** | std only | 来源: zproxy/src/utils.zig

IP 地址格式化/解析、完整 IPv4/v6 CIDR 接口 (解析/匹配/包含/迭代/子网划分)、域名合法性判断、host:port 解析。不含 checksum。

```
[TBD — 提取后填写]
```

### strings.zig — 字符串处理

> **Phase 3** | std only | 来源: zproxy/src/utils.zig

字符串切割、trim、大小写转换、hex 编解码等常用操作。

```
[TBD — 提取后填写]
```

### cli.zig — 命令行框架

> **Phase 3** | std only | 新建

命令行参数解析、跨平台信号处理 + 退出回调 (SIGINT/SIGTERM/SIGHUP)、守护进程化。

```
[TBD — 实现后填写]
```

### log.zig — 日志框架

> **Phase 3** | std only | 新建

分级日志系统 (trace/debug/info/warn/err)，支持多输出后端（文件、控制台、syslog）。

```
[TBD — 实现后填写]
```

### yaml.zig — YAML 解析

> **Phase 3** | std + libyaml C | 新建

libyaml C 库封装 (build.zig 集成编译 + Zig API 接口)。仅提供 YAML 解析/序列化能力，不提供任何业务配置结构或模板。

```
[TBD — 实现后填写]
```

### store.zig — 存储框架

> **Phase 4** | std + libxev | 来源: zigproxy

持久化缓存存储，路径由调用者传入并初始化。支持文件读写、原子替换、过期清理。不绑定 DNS。

```
[TBD — 提取后填写]
```

### event.zig — 事件通知

> **Phase 4** | std + libxev | 来源: zproxy/src/core/event.zig

跨平台 ResetEvent (Posix eventfd/pipe + Windows Event Object)，基于 libxev。用于线程间信号通知。

```
[TBD — 提取后填写]
```

### queue.zig — 并发队列

> **Phase 4** | std + libxev | 来源: zproxy/src/core/queue.zig

CommandQueue + MonitorQueue (MPSC 模式)，基于 libxev。支持背压和批量出队。

```
[TBD — 提取后填写]
```

### socket.zig — 网络出站

> **Phase 5** | std + libxev | 新建

网络出站 + 绕过路由绑定。跨平台 socket 接口：SO_BINDTODEVICE / IP_BOUND_IF / IP_UNICAST_IF、源地址绑定、出站路由策略。

```
[TBD — 实现后填写]
```

---

## 变更日志

| 版本 | 日期 | 变更 |
|------|------|------|
| 0.1.0 | 2026-07-18 | 项目骨架初始化，API 框架建立（13 模块，5 Phase） |
