# Task Plan: zigfoundation — fixnet 生态基础库实现

## Goal
从 zigproxy/zproxy/zigtun 提取公共组件，实现 13 个工业级基础模块（buffer/ring/endian/platform/net/strings/cli/log/yaml/store/event/queue/egress），100% 单元测试覆盖，五平台支持。

## Current Phase
Phase 6 (集成验证)

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
- [x] `platform.zig` — 合并 zigproxy + zigtun 平台代码：时间获取、平台检测、系统资源探测（CPU 核数 / fd 上限 / 推荐线程池大小）、系统 DNS 探测。9 tests
- [x] `net.zig` — 从 zproxy/src/utils.zig 提取网络部分：IP 格式化/解析、完整 IPv4/v6 CIDR 接口（解析/匹配/包含/网络/广播/前缀长度）、域名判断、parseHostPort。不含 checksum。49 tests
- [x] foundation.zig 更新导出
- [x] `zig build test` 全绿 (86/86)
- **Status:** complete

### Phase 3: 应用框架（std only）
- [x] `strings.zig` — 新建原创模块：大小写转换（toLower/toUpper/toLowerInPlace/toUpperInPlace）、子串搜索（contains/containsIgnoreCase）、前后缀匹配（startsWithIgnoreCase/endsWithIgnoreCase）、拼接（join）、切分（splitLines/splitTrim）。20 tests
- [x] `cli.zig` — 新建：CliArgs 命令行参数解析（--flag/-f/--key=value/positional）、跨平台信号处理 + 退出回调（SIGINT/SIGTERM/SIGHUP）、守护进程化。~23 tests
- [x] `log.zig` — 新建：分级日志 Logger（trace/debug/info/warn/err）、WriteFn 回调输出后端、跨平台 stderr/stdout（POSIX write + Windows kernel32）、ANSI 颜色、动态切换级别/后端。10 tests
- [x] foundation.zig 更新导出
- [x] `zig build test` 全绿 (134/134)
- **Status:** complete（yaml.zig 需要 libyaml，移至 Phase 4）

### Phase 4: 存储、配置与并发（std + libyaml + libxev）
- [x] `yaml.zig` — 新建：libyaml C 库封装（build.zig addTranslateC + addCSourceFiles 编译 yaml_document_t API + Zig 友好 Node 导航接口）。12 tests
- [x] `store.zig` — 从 zigproxy 提取：持久化缓存，路径由调用者传入并初始化，文件读写/原子替换/过期清理。不绑定 DNS。Zig 0.16.0 Io.Dir API 适配。12 tests
- [x] `event.zig` — 从 zproxy/src/core/event.zig (655行) 提取 ResetEvent：跨平台事件通知（POSIX pthread + Windows SRWLOCK），不含 MainEvent。7 tests
- [x] `queue.zig` — 从 zproxy/src/core/queue.zig (348行) 提取并泛化为 Queue(T, comptime capacity)：MPSC 环形缓冲区 + mutex + ResetEvent。7 tests
- [x] foundation.zig 更新导出（yaml/store/event/queue）
- [x] `zig build test` 161/161 全绿
- **Status:** complete

### Phase 5: 网络出站（std + libxev）
- [x] `egress.zig` — 网络出站 + 绕过路由绑定：跨平台 socket 接口绑定（`SO_BINDTODEVICE` / `IP_BOUND_IF` / `IP_UNICAST_IF`）、源地址绑定、出站路由策略。12 tests
- [x] foundation.zig 更新导出（egress）
- [x] `zig build test` 173/173 全绿
- **Status:** complete

### Phase 6: 集成验证 — 三平台示例程序
- [x] 全量测试 `zig build test` 173/173 100% 通过
- [x] `zig fmt --check` 通过
- [x] API.md 替换 TBD 占位为实际 API 文档（13 模块完整 API 参考）
- [x] 创建 `examples/cli/main.zig` — 桌面 CLI 集成测试，13 模块全量验证（macOS/Linux/Windows）
- [x] 创建 `examples/ios/` — iOS 模拟器静态库 + Swift App (main.zig / AppDelegate.swift / Info.plist / build.sh)
- [x] 创建 `examples/android/` — Android 模拟器 .so + JNI Activity (main.zig / MainActivity.java / AndroidManifest.xml / build.sh)
- [x] 修改 `build.zig` — 添加 example-cli / example-ios / example-android 三个 build step
- [x] 修改 `src/log.zig` — 修复 `.android` os.tag → `builtin.abi.isAndroid()`；`std.cstr.addNullByte` → 手动分配
- [x] 修改 `src/cli.zig` — 重写 `createRoot()` 适配 Zig 0.16.0 Io API（std.io.getStdOut/getStdIn 已移除）
- [x] 修改 `src/egress.zig` — INVALID_SOCKET 改为 pub
- [x] CLI 示例在 macOS 上构建并运行通过（13 passed, 0 failed）
- [ ] 兄弟项目（zigtun/zigproxy）切换为依赖 zigfoundation，验证编译通过（延后 — 兄弟项目尚未适配 Zig 0.16.0）
- **Status:** complete

### Phase 6a: 交叉编译验证 — iOS + Android 实际编译
- [x] 查找本机 iOS SDK + Android NDK 路径
- [x] 配置 `~/.bash_profile` 环境变量（IOS_SDK_HOME / ANDROID_HOME / ANDROID_SDK_ROOT / ANDROID_NDK_HOME）
- [x] 修改 `build.zig`：`-Dsysroot` + `-Dlibc-file` 选项、NDK 架构特定 include
- [x] 修改 `src/log.zig`：androidLog 分支 `std.cstr.addNullByte` 修复 + `[*]const u8` 适配
- [x] 修改 `src/egress.zig`：`@alignCast` 修复 Linux/Android 对齐
- [x] 修改 `examples/ios/main.zig` + `examples/android/main.zig`：移除 `callconv(.C)`（Zig 0.16.0 已移除）
- [x] 更新 `examples/ios/build.sh` + `examples/android/build.sh`：使用 env vars
- [x] iOS 编译成功：`libzigfoundation-example-ios.a` (5.5MB, aarch64-ios-simulator)
- [x] Android 编译成功：`libzigfoundation-example-android.so` (6.4MB, aarch64-linux-android)
- [x] 更新 `zig-codegen.md`（第 13 章交叉编译 + 8 条诊断）
- [x] 更新 `CLAUDE.md`（构建命令 + 环境变量）
- [x] 全量验证：`zig build test` 173/173 ✓, `zig fmt --check` ✓
- **Status:** complete

### Phase 6b: 交叉编译 CLI + 三平台 VM 测试 + Windows egress 修复
- [x] 修复 `src/egress.zig` `createSocket()` — Windows `@intCast(-1)` → `usize` panic（socket 失败时 `-1` 无法转无符号类型）
- [x] 交叉编译 CLI 到 Windows aarch64 (907KB) / Linux aarch64 (4.8MB) / macOS aarch64 (569KB)
- [x] 跨平台代码适配：cli.zig (Windows kernel32 I/O)、log.zig (Windows stderr)、queue.zig (atomic spinlock)、egress.zig (winsock)
- [x] Linux VM 测试：13/13 passed ✅
- [x] macOS VM 测试：13/13 passed ✅
- [x] Windows VM 测试：13/13 passed ✅（egress 崩溃已修复）
- **Status:** complete

## Key Questions
1. ring.zig 选 zigproxy 简化版 (199行) 还是 zproxy 完整版 (602行)？后者含跨平台同步原语
2. endian 封装粒度：只封 readInt 还是连 writeInt 一起？
3. yaml.zig 的 libyaml 是系统库还是 vendor 捆绑？
4. egress.zig 的绕过路由绑定在 iOS/Android 上受限（无 SO_BINDTODEVICE），如何降级？

## Decisions Made
| Decision | Rationale |
|----------|-----------|
| 独立 Phase 编号（0-6） | zigfoundation 是独立项目 |
| 依赖分层：std only → std+libyaml → std+libxev | 明确各模块的外部依赖，按依赖递增编排阶段 |
| ring 而非 ringbuf | Zig 惯用短名（std.RingBuffer 前例），导出类型仍为 `RingBuf` |
| yaml 而非 config | 只封装 libyaml，不承载业务配置，名字诚实 |
| egress 而非 socket | 出站路由绑定本质是网络出站层操作，egress 更准确表达意图 |
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
