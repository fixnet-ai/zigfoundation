# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

**保持使用简体中文交流及编写文档**

## 项目概述

**zigfoundation** 是 fixnet 生态的基础库，提供与业务无关的工业级基础组件。

### 定位

```
fixnet/
  zigfoundation/  ← 基础库 (本项目) — Zig std + zli + libyaml + libxev
  libxev/         ← 异步 I/O 事件循环
  zigtun/         ← TUN 设备库 (依赖 zigfoundation + libxev)
  zigproxy/       ← 代理协议库 (依赖 zigfoundation + libxev)
  zigbox/         ← 编排层 (依赖 zigfoundation + zigtun + zigproxy)
```

zigfoundation 处于依赖图最底层（仅次于 libxev），为所有兄弟项目提供：
- 内存管理 (BufferPool、RingBuf)
- 大小端转换 (Endian)
- 平台抽象 (Platform)
- 网络工具 (Net、CIDR、Egress) — 含 IpAddr/IpPrefix/SocksAddr/Cidr/PortRange
- 信号处理 (Signal) — 跨平台 shutdown 检测
- 字符串常用处理 (Strings)
- 命令行框架 (CLI) — 基于 zli + 信号处理 + 守护进程化
- 日志框架 (Log) — 基于 std.log，跨平台输出 (Android logcat / Darwin syslog / 桌面 stderr)
- YAML 解析 (libyaml 封装)
- 存储框架 (Store)
- 并发原语 (Event、Queue)
- 内存网络连接 (MemStream、Registry)
- fd 流适配器 (FdStream)
- 双向数据中继 (Relay)

### 核心原则

1. **依赖分层** — std only 模块优先 → zli (cli) → libyaml → libxev，不引入 zio 或其他框架
2. **五平台支持** — Windows / macOS / Linux / iOS / Android
3. **100% 单元测试覆盖** — 每个公开 API 都有对应测试
4. **工业级稳定性** — 所有内存分配可审计、错误路径清晰、无 unsafe 透出
5. **功能无关** — 不包含任何业务逻辑（代理、TUN、路由、DNS），纯粹的基础组件

## 设计原则

### 模块独立性

每个 `src/<module>.zig` 是一个自包含模块：
- 公开 API 通过 `foundation.zig` barrel 模块统一导出
- 模块间依赖最小化（buffer/ring 零内部依赖，platform 零内部依赖）
- 每个模块独立可测试，不依赖其他模块的初始化

### 注入模式

遵循 fixnet 生态的统一惯例：
- 依赖外部传入，模块内部不创建全局状态
- Allocator 作为参数传入，不缓存
- 示例：`BufferPool.init(allocator, config)` 而非内部获取 allocator

### API 稳定性

- 公开 API 使用 `pub fn` 显式声明
- 内部实现标记为 non-pub 或使用 `_` 前缀
- 重大 API 变更在 `API.md` 中记录

## 构建命令

```bash
zig build                    # 构建静态库 libzigfoundation.a
zig build test               # 运行所有单元测试
zig build test-build         # 编译测试二进制（交叉编译用）
zig fetch --save=zli <url>   # 更新 zli 依赖版本（仅在升级 zli 时需要）
```

### 示例程序构建

```bash
# 桌面 CLI 集成测试 (macOS/Linux/Windows)
zig build example-cli
zig build example-cli -Dtarget=aarch64-linux-musl    # Linux ARM64
zig build example-cli -Dtarget=aarch64-windows-gnu   # Windows ARM64
./zig-out/bin/zigfoundation-example-cli

# iOS 静态库 (需 Xcode)
zig build example-ios -Dtarget=aarch64-ios-simulator -Dsysroot="$IOS_SDK_HOME_SIM"
zig build example-ios -Dtarget=aarch64-ios -Dsysroot="$IOS_SDK_HOME_DEVICE"
# → zig-out/lib/libzigfoundation-example-ios.a

# Android 动态库 (需 Android NDK)
zig build example-android -Dtarget=aarch64-linux-android \
    -Dsysroot="$ANDROID_NDK_HOME/.../sysroot" -Dlibc-file=<libc.conf>
# → zig-out/lib/libzigfoundation-example-android.so
```

### 交叉编译环境变量

在 `~/.bash_profile` 中设置：

```bash
export IOS_SDK_HOME_SIM=$(xcrun --sdk iphonesimulator --show-sdk-path 2>/dev/null)
export IOS_SDK_HOME_DEVICE=$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null)
export ANDROID_HOME="$HOME/Library/Android/sdk"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export ANDROID_NDK_HOME="$ANDROID_HOME/ndk/30.0.15729638"
```

build.zig 通过 `-Dsysroot=<path>` 和 `-Dlibc-file=<path>` 选项接收这些路径：
- `-Dsysroot` — 设置 `b.sysroot`（linker 用）+ `addSystemIncludePath`（C 编译器用）+ 架构特定头文件路径
- `-Dlibc-file` — Android 专属，指向 NDK Bionic libc 配置文件（格式：key=value，字段见 std/zig/LibCInstallation.zig）

### Vendored C 库模式

本项目内嵌的 C 库（如 libyaml）遵循 Zig 包管理器惯例：

**每个 vendored C 库是独立的 Zig 包**，放在 `vendor/<name>/` 目录下，有自己的 `build.zig` + `build.zig.zon`：

```
vendor/yaml/
  build.zig           # translate-c + addCSourceFiles + addModule("yaml_c", ...)
  build.zig.zon       # .name = .yaml, .fingerprint = ...
  yaml_c.zig          # 重新导出 translate-c 绑定（依赖方 import 的入口）
  src/                # C 源码
  include/            # C 头文件
```

根项目 `build.zig.zon` 通过 `.yaml = .{ .path = "vendor/yaml" }` 声明依赖，
根项目 `build.zig` 通过 `b.dependency("yaml", .{}).module("yaml_c")` 获取模块。

**关键规则：**
- 使用 `b.addModule("name", opts)`（公开）而非 `b.createModule(opts)`（私有），否则依赖方 `dep.module()` 找不到
- translate-c 使用 `b.resolveTargetQuery(.{})`（native target），避免交叉编译时缺少目标平台 libc 头文件
- 新增 C 库时按此模式创建 `vendor/<name>/` 包，**禁止**在根 build.zig 中直接写 C 编译代码

## 模块架构

### 依赖分层

```
std only (9):     buffer  ring  endian  platform  net  strings  log  egress  signal
std + zli (1):    cli
std + libyaml (1): yaml
std + libxev (6):  store  event  queue  memconn  fdconn  relay
```

### Phase 1 — 内存管理（std only）

| 模块 | 来源 | 描述 |
|------|------|------|
| `buffer.zig` | 从 zigproxy 提取 | BufferPool: LIFO 复用、shrink-to-initial 策略 |
| `ring.zig` | 从 zigproxy 提取 | SPSC RingBuf: 跨线程无锁环缓冲区 |
| `endian.zig` | 新建薄封装 | 大小端读写统一 API (消除各处散落的 std.mem.readInt) |

### Phase 2 — 平台与网络（std only）

| 模块 | 来源 | 描述 |
|------|------|------|
| `platform.zig` | 合并 zigproxy + zproxy | 时间获取、平台检测、系统资源探测 (CPU/fd/线程池)、跨平台睡眠、系统 DNS 探测 |
| `net.zig` | 从 zproxy/utils.zig 提取 | IP 格式化/解析、完整 IPv4/v6 CIDR 接口、域名判断、parseHostPort。不含 checksum。**2026-07 增强：新增 IpAddr/IpPrefix/SocksAddr/Uint32Range/Cidr(PortRange)/isNonPublicV4/V6，从 zigtun/zigbox 统一收归** |

### Phase 3 — 应用框架（std only + zli）

| 模块 | 来源 | 描述 |
|------|------|------|
| `strings.zig` | 新建原创 | 大小写转换、子串搜索、前后缀匹配、字符串拼接、切分 |
| `cli.zig` | 新建 — zli v5.1.2 薄封装 | 重新导出 zli CLI 框架 (Command/Flag/CommandContext 等) + 跨平台信号处理 (POSIX sigaction / Windows SetConsoleCtrlHandler) + 守护进程化 (POSIX double-fork)。createRoot() 便捷构造器封装 InitOptions |
| `log.zig` | 新建 | 基于 std.log 的跨平台日志：Android `__android_log_write`(logcat) / iOS+macOS `syslog` / 桌面 `std.c.write` stderr + ANSI 颜色。通过 `std_options.logFn` 覆盖全局日志，支持运行时动态切换级别 (err/warn/info/debug) |

### Phase 3b — 信号处理（std only）

| 模块 | 来源 | 描述 |
|------|------|------|
| `signal.zig` | 从 cli.zig 拆分 | 独立跨平台信号处理模块。Posix `sigaction` (SIGINT/SIGTERM) / Windows `SetConsoleCtrlHandler` (5 类控制事件)。`SignalContext { init, install, uninstall }` + `isShuttingDown()` 全局标志。不依赖 zli CLI 框架，可独立使用 |

### Phase 4 — 存储、配置与并发（std + libyaml + libxev）

| 模块 | 来源 | 描述 |
|------|------|------|
| `yaml.zig` | 新建 | libyaml C 库封装 (build.zig 集成编译 + API)，不提供业务配置结构 |
| `store.zig` | 从 zigproxy 提取 | 持久化缓存 (路径由调用者注入，文件读写、原子替换、过期清理)，不绑定 DNS |
| `event.zig` | 从 zproxy/core/event.zig 提取 | ResetEvent: 跨平台事件通知 (Posix + Windows)，基于 libxev |
| `queue.zig` | 从 zproxy/core/queue.zig 提取 | CommandQueue + MonitorQueue (MPSC 模式)，基于 libxev |

### Phase 5 — 网络出站（std + libxev）

| 模块 | 来源 | 描述 |
|------|------|------|
| `egress.zig` | 新建 | 网络出站 + 绕过路由绑定: SO_BINDTODEVICE / IP_BOUND_IF / IP_UNICAST_IF、源地址绑定、出站路由策略 |

### Phase 8 — 内存网络连接 + fd 流适配器（std + libxev）

| 模块 | 来源 | 描述 |
|------|------|------|
| `memconn.zig` | 新建 | MemStream: 进程内异步 socket-like 接口，基于 RingBuf + xev.Async + Completion 回调模型；Registry 命名连接解耦；createPair 直接创建 |
| `fdconn.zig` | 新建 | FdStream: 泛型适配器工厂，将 libxev fd 系流类型 (TCP/File/Stream) 适配为统一 Stream 接口 |

### Phase 9 — 数据中继（std + libxev）

| 模块 | 来源 | 描述 |
|------|------|------|
| `relay.zig` | 新建 | 通用异步双向数据中继，Completion 链驱动，任意两个 Stream 端点间的零额外线程数据对拷 |

## 参考代码

- `../zproxy/src/core/event.zig` — ResetEvent 跨平台事件 (655 行)
- `../zproxy/src/core/ringbuf.zig` — SPSC 环缓冲区 (602 行)
- `../zproxy/src/core/queue.zig` — MPSC 队列 (348 行)
- `../zproxy/src/core/ip_cidr6.zig` — IPv6 CIDR (128 行)
- `../zproxy/src/utils.zig` — 网络工具 + 字符串处理 (897 行，生产验证)
- `../zproxy/src/platform/system.zig` — 系统资源探测 + 信号处理 (269 行)
- `../zproxy/src/platform/time.zig` — 跨平台单调时钟 (176 行)
- `../zigproxy/src/buffer.zig` — BufferPool 实现 (299 行)
- `../zigproxy/src/ringbuf.zig` — 简化 RingBuf (199 行)
- `../zigproxy/src/platform.zig` — 平台工具 (118 行)
- `./zig-codegen.md` — Zig 0.16.0 编码经验

## 重要规则

### 计划和任务管理

使用 **`planning-with-files:plan-zh`** skill 规划和跟进全部开发工作，必须及时更新。上下文压缩后，必须重新载入此 skill。

开始任何工作前，必须阅读以下文件（若存在），然后使用 **'/superpowers'** 插件进行开发工作：
- `./CLAUDE.md`
- `./README.md`
- `./zig-codegen.md`

### Zig 0.16.0 语言特性

- 遇到编译错误时，**必须**读取 `zig-codegen.md` 学习理解，避免重复犯错
- 从 [Zig 0.16.0 语言手册](https://ziglang.org/documentation/0.16.0/) 查找正确用法，不要乱猜语法
- 每次解决编译问题后，**把经验追加到 `zig-codegen.md`**，持续积累编码经验
- 开始编写代码前，先启用 zig skill 了解语言标准和特性
- 使用 `zig build test` 运行测试
- `@Type` 已移除 → 使用 `@Int`/`@Enum`/`@Struct`/`@Union`/`@Pointer`/`@Fn`/`@EnumLiteral`
- `usingnamespace` 已移除 → 显式重新导出
- 容器初始化：`.empty`（空集合）、`.init`（有状态类型），禁止 `.{}`
- build.zig: `root_source_file` → `root_module = b.createModule(...)`

### 日志规范

所有代码必须遵循统一的日志格式。zigfoundation 的 `log.zig` 是日志基础设施的**唯一实现源**。

**强制要求：所有日志输出必须通过 `log.zig` 基础设施，严禁绕过。**

| ✅ 允许 | ❌ 禁止 |
|--------|--------|
| `std.log.info("[buffer] ...")` — 通过 `log.logOptions()` 设置 `std_options` 后使用 | 裸 `std.debug.print(...)` |
| `std.log.err("[net] ...")` — 同上 | 直接 `std.log.info(...)` 而不设置 `log.logOptions()` |
| | `std.io.getStdErr().writeAll(...)` 或其他任何绕过方式 |

**级别定义：**

| 级别 | 用途 | 语义 |
|------|------|------|
| `err` | 致命错误、不可恢复 | 初始化失败、资源耗尽、系统调用错误 |
| `warn` | 可恢复异常、降级行为 | 超时、重试、非预期但可处理 |
| `info` | 关键生命周期事件 | 启动/关闭、连接建立/关闭 |
| `debug` | 调测细节 | 内部状态追踪、数据流详情 |

**消息格式：** `[component] action: key=value key2=value2`

- `[component]` — 模块短标识，方括号包裹
- `action` — 英文小写动词短语
- `key=value` — 结构化字段，空格分隔

**示例：**
```
[buffer] pool created: capacity=64 buf_size=8192
[ring] write blocked: available=0 capacity=1024
[net] cidr parsed: input=10.0.0.0/8 version=v4
[signal] shutdown requested: signal=SIGTERM
[egress] bind failed: interface=eth0 error=NoSuchDevice
[warn] [relay] idle timeout: src=10.0.0.1:44321 duration_ms=300000
[err] [platform] clock init failed: error=Unexpected
[debug] [buffer] shrink check: used=3 initial=16 threshold=8
```

**初始化（仅应用层）：**

```zig
// 应用程序根文件 — 库项目不设此
pub const std_options = foundation.log.logOptions();

pub fn main() !void {
    foundation.log.init(.info);
    // ...
}
```

库项目不调用 `log.init()`，由上层应用统一初始化。库代码直接使用 `std.log.info` 等接口。

**禁止事项：**

| # | 规则 | 原因 |
|---|------|------|
| 1 | 禁止在热路径打印 | `read`/`write` 循环内不得有日志 |
| 2 | 禁止打印敏感数据 | 密码/token 绝不出现 |
| 3 | 禁止裸 `std.debug.print` | 必须走 `std.log.err/warn/info/debug` |
| 4 | 禁止无 `[component]` 前缀 | 每条日志必须以 `[module]` 开头 |
| 5 | 禁止 `info` 级别高频事件 | 细粒度调测用 `debug`

### CLI 规范

- CLI 基于 zli v5.1.2 框架（`https://github.com/xcaeser/zli`）
- 使用 `cli.createRoot(allocator, opts)` 创建根命令
- Flag 用 zli 原生 `Flag` struct（`.name`/`.type`/`.default_value` 字段）
- 信号处理和守护进程化通过 `cli.registerExitCallback` / `cli.installExitHandlers` / `cli.daemonize` 使用
- zli 依赖通过 `zig fetch --save=zli <url>` 管理，build.zig 中通过 `b.dependency("zli", .{}).module("zli")` 获取

### 依赖规则

- std only 模块 (9个)：buffer、ring、endian、platform、net、strings、log、egress、signal — 不依赖 libxev 或 zli
- std + zli (1个)：cli — 依赖 zli v5.1.2 CLI 框架
- std + libyaml (1个)：yaml — 仅依赖 std + libyaml C 库
- std + libxev (6个)：store、event、queue、memconn、fdconn、relay — 可依赖 std + libxev
- 禁止引入 zio 或任何其他第三方框架（zli 除外，已纳入标准依赖）

### 代码编写

- 100% 测试覆盖：每个 `pub fn` 必须至少有一个对应测试
- 精准变更：只改必须改的，不"改进"无关代码
- 简单优先：解决问题的最少代码
- 发现错误注释及时更正
- 测试与实现同文件（Zig 惯用模式）
- 各平台 #ifdef 集中在 `platform.zig`，其他模块通过 platform 间接适配

### 提取现有代码时的规则

从 zigproxy/zproxy/zigtun 提取代码到 zigfoundation 时：
1. 保持原有逻辑不变（仅格式化由 zig fmt 处理）
2. 移除原项目特有的 import（如 libxev、zigtun 内部类型）
3. 用 zigfoundation 的类型替代（如 `endian.readIntBig` 替代各处散落的 `std.mem.readInt`）
4. 原项目改为 `const foundation = @import("zigfoundation");` 并更新调用点
5. 提取后原项目的测试保留（验证行为不变），zigfoundation 新增独立测试

### 唯一实现源原则（核心架构约束）

**zigfoundation 是所有底层算法和基础类型的唯一实现源。** 此原则适用于：

| 类别 | 模块 | 禁止在其他项目中重复实现 |
|------|------|------------------------|
| 信号处理 | `signal.zig` | `sigaction`/`SetConsoleCtrlHandler`/`waitForSignal`/`exitRequested` |
| 字节序 | `endian.zig` | `std.mem.readInt`/`writeInt` 的包装函数 |
| 平台抽象 | `platform.zig` | `monoMillis`/`monoMicros`/平台检测/`sleepMs` |
| 网络类型 | `net.zig` | `Cidr`/`Cidr4`/`Cidr6`/`PortRange`/`IpAddr`/`IpPrefix`/`SocksAddr`/`isNonPublicV4`/`isNonPublicV6` |
| 内存管理 | `buffer.zig`/`ring.zig` | `BufferPool`/`RingBuf` |
| 日志 | `log.zig` | `logOptions`/日志格式化/跨平台输出 |

**规则：**
- 如果功能已在 zigfoundation 中存在，其他项目**必须**通过 `@import("zigfoundation")` 使用，**严禁**重新实现
- 如需新增基础功能，先评估是否应放入 zigfoundation，而非在消费项目中局部添加
- cli.zig 的信号处理已委托到 signal.zig（2026-07 重构），不得反向复制

## 行为准则

**先思考再编码。不要假设。简单优先。精准变更。目标驱动执行。**

详见 `./CLAUDE.md` 行为准则章节。
