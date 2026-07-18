# zigfoundation API 参考

> **状态**: 框架已建立，API 文档随模块实现逐步填充。
>
> 版本: 0.1.0 | 目标平台: Windows / macOS / Linux / iOS / Android
>
> 零外部依赖，仅使用 Zig 标准库。

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

> **Phase 8b** | 来源: zigproxy/src/buffer.zig

固定大小缓冲区的 LIFO 复用池，采用 shrink-to-initial 策略。

```
[TBD — 提取后填写]
```

### ringbuf.zig — 环缓冲区

> **Phase 8b** | 来源: zproxy/src/core/ringbuf.zig

SPSC (单生产者单消费者) 无锁环缓冲区，支持跨线程通信。

```
[TBD — 提取后填写]
```

### endian.zig — 大小端转换

> **Phase 8b** | 新建

统一的大小端读写 API，消除各处散落的 `std.mem.readInt`/`writeInt` 样板代码。

```
[TBD — 实现后填写]
```

### platform.zig — 平台抽象

> **Phase 8c** | 来源: zigproxy + zigtun

跨平台时间获取、平台类型检测、系统 DNS 探测。

```
[TBD — 合并后填写]
```

### net.zig — 网络工具

> **Phase 8c** | 来源: zproxy/src/utils.zig

IP 地址格式化/解析、域名合法性判断、校验和计算、host:port 解析。

```
[TBD — 提取后填写]
```

### strings.zig — 字符串处理

> **Phase 8d** | 来源: zproxy/src/utils.zig

字符串切割、trim、大小写转换、hex 编解码等常用操作。

```
[TBD — 提取后填写]
```

### cli.zig — 命令行框架

> **Phase 8d** | 新建

信号处理抽象、命令行参数解析、守护进程化、Windows 控制台事件。

```
[TBD — 实现后填写]
```

### log.zig — 日志框架

> **Phase 8d** | 新建

分级日志系统 (trace/debug/info/warn/err)，支持多输出后端（文件、控制台、syslog）。

```
[TBD — 实现后填写]
```

### store.zig — 存储框架

> **Phase 8e** | 来源: zigproxy

持久化缓存存储，支持原子替换、过期清理。

```
[TBD — 提取后填写]
```

### event.zig — 事件通知

> **Phase 8e** | 来源: zproxy/src/core/event.zig

跨平台 ResetEvent (Posix eventfd/pipe + Windows Event Object)，用于线程间信号通知。

```
[TBD — 提取后填写]
```

### queue.zig — 并发队列

> **Phase 8e** | 来源: zproxy/src/core/queue.zig

CommandQueue + MonitorQueue (MPSC 模式)，支持背压和批量出队。

```
[TBD — 提取后填写]
```

---

## 变更日志

| 版本 | 日期 | 变更 |
|------|------|------|
| 0.1.0 | 2026-07-18 | 项目骨架初始化，API 框架建立 |
