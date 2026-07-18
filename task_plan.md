# Task Plan: zigfoundation — fixnet 生态基础库实现

## Goal
从 zigproxy/zproxy/zigtun 提取公共组件，实现 13 个工业级基础模块（buffer/ring/endian/platform/net/strings/cli/log/yaml/store/event/queue/socket），100% 单元测试覆盖，五平台支持。

## Current Phase
Phase 2

## Phases

### Phase 0: 项目初始化
- [x] 创建项目骨架：build.zig、build.zig.zon、src/foundation.zig（barrel 模块 v0.1.0）
- [x] 创建 CLAUDE.md（中文，含项目概述/设计原则/模块架构/Zig 规则/提取规则）
- [x] 创建 API.md（模块目录框架）
- [x] 合并 zig-codegen.md（Zig 0.16.0 通用编码经验，来自 zigtun/zigproxy/zproxy）
- [x] 创建 .claude/skills/ 软链接（zig、utm-vm → ../../zigbox/.claude/skills/）
- [x] Git 基础环境：.gitignore（IDE/OS/构建产物）、.gitattributes（LF + binary）
- [x] Git 全局配置：user.name=fixnet-ai、user.email=28281228+fixnet-ai@users.noreply.github.com
- [x] git push → https://github.com/fixnet-ai/zigfoundation
- **Status:** complete

### Phase 1: 内存管理（std only）
- [x] `buffer.zig` — 从 zigproxy/src/buffer.zig (299行) 提取 BufferPool：LIFO 复用、shrink-to-initial 策略
- [x] `ring.zig` — 从 zigproxy/src/ringbuf.zig (199行) 提取 SPSC RingBuf：跨线程无锁环缓冲区。Zig 0.16.0 适配 `.init`
- [x] `endian.zig` — 新建薄封装：read/write U16/U32/U64 Big/Little + 通用泛型。16 个 round-trip 测试
- [x] foundation.zig 更新导出，挂接子模块测试
- [x] `zig build test` 28/28 全绿 + `zig fmt --check` 通过
- **Status:** complete

### Phase 2: 平台与网络（std only）
- [ ] `platform.zig` — 合并 zigproxy + zigtun 平台代码：时间获取、平台检测、系统资源探测（CPU 核数 / fd 上限 / 推荐线程池大小）、系统 DNS 探测
- [ ] `net.zig` — 从 zproxy/src/utils.zig 提取网络部分：IP 格式化/解析、完整 IPv4/v6 CIDR 接口（解析/匹配/包含/迭代/子网划分）、域名判断、parseHostPort。不含 checksum
- [ ] foundation.zig 更新导出
- [ ] `zig build test` 全绿
- **Status:** pending

### Phase 3: 应用框架（std + libyaml）
- [ ] `strings.zig` — 从 zproxy/src/utils.zig 提取字符串部分：切割、trim、大小写转换等
- [ ] `cli.zig` — 新建：命令行参数解析、跨平台信号处理 + 退出回调（SIGINT/SIGTERM/SIGHUP）、守护进程化
- [ ] `log.zig` — 新建：分级日志（trace/debug/info/warn/err）、多输出后端
- [ ] `yaml.zig` — 新建：libyaml C 库封装（build.zig 集成编译 + Zig API 接口），不提供任何业务配置结构
- [ ] foundation.zig 更新导出
- [ ] `zig build test` 全绿
- **Status:** pending

### Phase 4: 存储与并发（std + libxev）
- [ ] `store.zig` — 从 zigproxy 提取：持久化缓存，路径由调用者传入并初始化，文件读写/原子替换/过期清理。不绑定 DNS
- [ ] `event.zig` — 从 zproxy/src/core/event.zig (655行) 提取 ResetEvent：跨平台事件通知（Posix + Windows），基于 libxev
- [ ] `queue.zig` — 从 zproxy/src/core/queue.zig (348行) 提取 CommandQueue + MonitorQueue（MPSC），基于 libxev
- [ ] foundation.zig 更新导出
- [ ] `zig build test` 全绿
- **Status:** pending

### Phase 5: 网络出站（std + libxev）
- [ ] `socket.zig` — 网络出站 + 绕过路由绑定：跨平台 socket 接口绑定（`SO_BINDTODEVICE` / `IP_BOUND_IF` / `IP_UNICAST_IF`）、源地址绑定、出站路由策略
- [ ] foundation.zig 更新导出
- [ ] `zig build test` 全绿
- **Status:** pending

### Phase 6: 集成验证
- [ ] 全量测试 `zig build test` 100% 通过
- [ ] `zig fmt --check` 通过
- [ ] API.md 替换 TBD 占位为实际 API 文档
- [ ] 兄弟项目（zigtun/zigproxy）切换为依赖 zigfoundation，验证编译通过
- **Status:** pending

## Key Questions
1. ring.zig 选 zigproxy 简化版 (199行) 还是 zproxy 完整版 (602行)？后者含跨平台同步原语
2. endian 封装粒度：只封 readInt 还是连 writeInt 一起？
3. yaml.zig 的 libyaml 是系统库还是 vendor 捆绑？
4. socket.zig 的绕过路由绑定在 iOS/Android 上受限（无 SO_BINDTODEVICE），如何降级？

## Decisions Made
| Decision | Rationale |
|----------|-----------|
| 独立 Phase 编号（0-6） | zigfoundation 是独立项目 |
| 依赖分层：std only → std+libyaml → std+libxev | 明确各模块的外部依赖，按依赖递增编排阶段 |
| ring 而非 ringbuf | Zig 惯用短名（std.RingBuffer 前例），导出类型仍为 `RingBuf` |
| yaml 而非 config | 只封装 libyaml，不承载业务配置，名字诚实 |
| socket 而非 egress | 出站路由绑定本质是 socket 层操作，对开发者更直观 |
| store 路径由调用者传入 | 注入模式，模块不持有全局状态 |
| 不含 DNS | 应用层协议，不属于基础库 |
| 不含 checksum | 不提供 |
| 不含 protocol 首字节检测 | 协议层，属于 zigproxy |

## Errors Encountered
| Error | Attempt | Resolution |
|-------|---------|------------|

## Notes
- 参考代码路径见 CLAUDE.md「参考代码」章节
- Zig 0.16.0 编码经验见 `./zig-codegen.md`
- 测试与实现同文件（Zig 惯用模式）
- 提取规则：保持逻辑不变 → 移除原项目 import → 用 foundation 类型替代 → 原项目保留测试、foundation 新增测试
