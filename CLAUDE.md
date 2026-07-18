# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

**保持使用简体中文交流及编写文档**

## 项目概述

**zigfoundation** 是 fixnet 生态的基础库，提供与业务无关的工业级基础组件。

### 定位

```
fixnet/
  zigfoundation/  ← 基础库 (本项目) — 零外部依赖，std only
  libxev/         ← 异步 I/O 事件循环
  zigtun/         ← TUN 设备库 (依赖 zigfoundation + libxev)
  zigproxy/       ← 代理协议库 (依赖 zigfoundation + libxev)
  zigbox/         ← 编排层 (依赖 zigfoundation + zigtun + zigproxy)
```

zigfoundation 处于依赖图最底层（仅次于 libxev），为所有兄弟项目提供：
- 内存管理 (BufferPool、RingBuf)
- 大小端转换 (Endian)
- 字符串常用处理 (Strings)
- 命令行程序框架 (CLI)
- 日志框架 (Log)
- 存储框架 (Store)
- 平台抽象 (Platform)
- 网络工具 (Net)
- 并发原语 (Event、Queue)

### 核心原则

1. **零外部依赖** — 仅使用 Zig 标准库，不依赖 libxev 或任何第三方库
2. **五平台支持** — Windows / macOS / Linux / iOS / Android
3. **100% 单元测试覆盖** — 每个公开 API 都有对应测试
4. **工业级稳定性** — 所有内存分配可审计、错误路径清晰、无 unsafe 透出
5. **功能无关** — 不包含任何业务逻辑（代理、TUN、路由），纯粹的基础组件

## 设计原则

### 模块独立性

每个 `src/<module>.zig` 是一个自包含模块：
- 公开 API 通过 `foundation.zig` barrel 模块统一导出
- 模块间依赖最小化（buffer/ringbuf 零内部依赖，platform 零内部依赖）
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
```

## 模块架构

### Phase 8b — 内存管理基础

| 模块 | 来源 | 描述 |
|------|------|------|
| `buffer.zig` | 从 zigproxy 提取 | BufferPool: LIFO 复用、shrink-to-initial 策略 |
| `ringbuf.zig` | 从 zproxy 提取 | SPSC RingBuf: 跨线程无锁环缓冲区 |
| `endian.zig` | 新建薄封装 | 大小端读写统一 API (消除各处散落的 std.mem.readInt) |

### Phase 8c — 平台与网络

| 模块 | 来源 | 描述 |
|------|------|------|
| `platform.zig` | 合并 zigproxy + zigtun | 时间获取、平台检测、系统 DNS 探测 |
| `net.zig` | 从 zproxy/utils.zig 提取 | IP 格式化/解析、域名判断、checksum、parseHostPort |

### Phase 8d — 应用框架

| 模块 | 来源 | 描述 |
|------|------|------|
| `strings.zig` | 从 zproxy/utils.zig 提取 | 字符串切割、trim、大小写转换等常用操作 |
| `cli.zig` | 新建 | 命令行参数解析、信号处理抽象、守护进程化 |
| `log.zig` | 新建 | 分级日志 (trace/debug/info/warn/err)、多输出后端 |

### Phase 8e — 存储与并发

| 模块 | 来源 | 描述 |
|------|------|------|
| `store.zig` | 从 zigproxy 提取 | 持久化缓存 (文件读写、原子替换、过期清理) |
| `event.zig` | 从 zproxy/core/event.zig 提取 | ResetEvent: 跨平台事件通知 (Posix + Windows) |
| `queue.zig` | 从 zproxy/core/queue.zig 提取 | CommandQueue + MonitorQueue (MPSC 模式) |

## 参考代码

- `../zproxy/src/utils.zig` — 网络工具 + 字符串处理 (897 行，生产验证)
- `../zproxy/src/core/event.zig` — ResetEvent 跨平台事件 (655 行)
- `../zproxy/src/core/ringbuf.zig` — SPSC 环缓冲区 (602 行)
- `../zproxy/src/core/queue.zig` — MPSC 队列 (348 行)
- `../zigproxy/src/buffer.zig` — BufferPool 实现 (299 行)
- `../zigproxy/src/ringbuf.zig` — 简化 RingBuf (199 行)
- `../zigproxy/src/platform.zig` — 平台工具 (118 行)
- `../zigtun/zig-codegen.md` — Zig 0.16.0 编码经验

## 重要规则

### Zig 0.16.0

- 使用 `zig build test` 运行测试
- 遇到编译错误时参考 `../zigtun/zig-codegen.md` 的编码经验
- 从 [Zig 0.16.0 语言手册](https://ziglang.org/documentation/0.16.0/) 查找正确用法
- `@Type` 已移除 → 使用 `@Int`/`@Enum`/`@Struct`/`@Union`/`@Pointer`/`@Fn`
- `usingnamespace` 已移除 → 显式重新导出
- 容器初始化：`.empty`（空集合）、`.init`（有状态类型），禁止 `.{}`
- build.zig: `root_source_file` → `root_module = b.createModule(...)`

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

## 行为准则

**先思考再编码。不要假设。简单优先。精准变更。目标驱动执行。**

详见 `../zigtun/CLAUDE.md` 行为准则章节。
