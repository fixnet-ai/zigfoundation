# CLAUDE.md

> **通用规则（日志规范、Zig 0.16.0、唯一实现源、行为准则、代码编写规范等）**
> 已在用户级 `~/.claude/CLAUDE.md` 中统一定义，本项目不再重复。
> 本文件仅包含 zigfoundation 项目特有信息。

## 项目概述

**zigfoundation** 是 fixnet 生态的基础库，提供与业务无关的工业级基础组件。

### 定位

```
fixnet/
  zigfoundation/  ← 基础库 (本项目) — Zig std + zli + libyaml + libxev
  libxev/         ← 异步 I/O 事件循环
  zigtun/         ← TUN 设备库
  zigproxy/       ← 代理协议库
  zigdns/         ← DNS 组件库
  zigbox/         ← 编排层
```

zigfoundation 处于依赖图最底层（仅次于 libxev），提供：
- 内存管理 (BufferPool、RingBuf)
- 大小端转换 (Endian)
- 平台抽象 (Platform)
- 网络工具 (Net、CIDR、Egress) — 含 IpAddr/IpPrefix/SocksAddr/Cidr/PortRange
- 信号处理 (Signal)
- 字符串常用处理 (Strings)
- 命令行框架 (CLI) — 基于 zli
- 日志框架 (Log)
- YAML 解析 (libyaml 封装)
- 存储框架 (Store)、并发原语 (Event、Queue)
- 内存网络连接 (MemStream、Registry)、fd 流适配器 (FdStream)
- 双向数据中继 (Relay)

### 核心原则

1. **依赖分层** — std only 模块优先 → zli (cli) → libyaml → libxev
2. **五平台支持** — Windows / macOS / Linux / iOS / Android
3. **工业级稳定性** — 所有内存分配可审计、错误路径清晰
4. **功能无关** — 不包含任何业务逻辑（代理、TUN、路由、DNS）

### 注入模式

- 依赖外部传入，模块内部不创建全局状态
- Allocator 作为参数传入，不缓存
- 示例：`BufferPool.init(allocator, config)` 而非内部获取 allocator

## 模块架构

```
std only (9):     buffer  ring  endian  platform  net  strings  log  egress  signal
std + zli (1):    cli
std + libyaml (1): yaml
std + libxev (6):  store  event  queue  memconn  fdconn  relay
```

| 模块 | 描述 |
|------|------|
| `buffer.zig` | BufferPool: LIFO 复用、shrink-to-initial 策略 |
| `ring.zig` | SPSC RingBuf: 跨线程无锁环缓冲区 |
| `endian.zig` | 大小端读写统一 API |
| `platform.zig` | 时间获取、平台检测、跨平台睡眠、系统 DNS 探测 |
| `net.zig` | IP 格式化/解析、CIDR、PortRange、IpAddr、SocksAddr、isNonPublic |
| `strings.zig` | 大小写转换、子串搜索、前后缀匹配 |
| `cli.zig` | zli v5.1.2 薄封装 + 跨平台信号处理 + 守护进程化 |
| `log.zig` | 跨平台日志：Android logcat / Darwin syslog / stderr + ANSI |
| `signal.zig` | 独立跨平台信号处理 (Posix/Windows) |
| `yaml.zig` | libyaml C 库封装 |
| `store.zig` | 持久化缓存 (路径注入) |
| `event.zig` | ResetEvent: 跨平台事件通知 |
| `queue.zig` | MPSC 队列 |
| `egress.zig` | 网络出站 + 绕过路由绑定 |
| `memconn.zig` | 进程内异步 socket-like 接口 |
| `fdconn.zig` | fd 流适配器 |
| `relay.zig` | 通用异步双向数据中继 |

## 构建命令

```bash
zig build                    # 构建静态库 libzigfoundation.a
zig build test               # 运行所有单元测试
zig build test-build         # 编译测试二进制（交叉编译用）
```

### 示例程序

```bash
zig build example-cli
zig build example-cli -Dtarget=aarch64-linux-musl

# iOS 静态库 (需 Xcode)
zig build example-ios -Dtarget=aarch64-ios-simulator -Dsysroot="$IOS_SDK_HOME_SIM"

# Android 动态库 (需 Android NDK)
zig build example-android -Dtarget=aarch64-linux-android -Dsysroot="$ANDROID_NDK_HOME/.../sysroot" -Dlibc-file=<libc.conf>
```

### Vendored C 库模式

每个 vendored C 库放在 `vendor/<name>/` 下，有自己的 `build.zig` + `build.zig.zon`：
- 使用 `b.addModule("name", opts)`（公开）而非 `b.createModule(opts)`
- translate-c 使用 `b.resolveTargetQuery(.{})`（native target）
- **禁止**在根 build.zig 中直接写 C 编译代码

## 依赖规则

- std only 模块 (9个)：不依赖 libxev 或 zli
- std + zli (1个)：cli
- std + libyaml (1个)：yaml
- std + libxev (6个)：可依赖 std + libxev
- 禁止引入 zio 或任何其他第三方框架（zli 除外）

## 组件标识

| 标识 | 模块 |
|------|------|
| `[buffer]` | BufferPool |
| `[ring]` | RingBuf |
| `[net]` | 网络工具 |
| `[signal]` | 信号处理 |
| `[egress]` | 网络出站 |
| `[platform]` | 平台抽象 |
| `[relay]` | 数据中继 |

## 参考代码

- `../zproxy/src/core/event.zig` — ResetEvent 跨平台事件
- `../zproxy/src/core/ringbuf.zig` — SPSC 环缓冲区
- `../zproxy/src/core/queue.zig` — MPSC 队列
- `../zproxy/src/utils.zig` — 网络工具 + 字符串处理
- `../zproxy/src/platform/system.zig` — 系统资源探测 + 信号处理
- `../zproxy/src/platform/time.zig` — 跨平台单调时钟
- `../zigproxy/src/buffer.zig` — BufferPool 实现
- `../zigproxy/src/ringbuf.zig` — 简化 RingBuf
- `./zig-codegen.md` — Zig 0.16.0 编码经验

## 代码编写

- 100% 测试覆盖：每个 `pub fn` 必须至少有一个对应测试
- 提取现有代码时：保持原有逻辑不变、移除原项目特有 import、用 zigfoundation 类型替代散落实现
