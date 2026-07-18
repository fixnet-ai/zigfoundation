# Findings & Decisions

## Requirements
- 从 zigproxy/zproxy/zigtun 提取公共组件到 zigfoundation
- 依赖：Zig std + libxev（异步基础）+ libyaml C 库（yaml 模块），不再使用 zio
- 五平台支持：Windows / macOS / Linux / iOS / Android
- 100% 单元测试覆盖每个 pub fn
- 工业级稳定性：内存分配可审计、错误路径清晰、无 unsafe 透出
- 功能无关：不包含任何业务逻辑（代理、TUN、路由、DNS）

## Research Findings

### 项目现状 (2026-07-18)
- 仓库：https://github.com/fixnet-ai/zigfoundation（已推送）
- 构建系统：build.zig（静态库 + test/test-build 目标）、build.zig.zon
- 入口模块：src/foundation.zig（barrel 模块，版本 0.1.0，子模块 import 已预留）
- 文档：CLAUDE.md、API.md、zig-codegen.md（合并自 zigtun/zigproxy/zproxy）
- Git 环境：.gitignore、.gitattributes、user.name=fixnet-ai、user.email=noreply
- Skills：.claude/skills/zig、utm-vm（软链接 → ../../zigbox/.claude/skills/）
- 提交历史：d22c375（骨架）→ 6310ac5（zig-codegen.md）→ 5d90ee4（git 基础环境）

### 依赖分层

```
std only (8 modules):
  buffer  ring  endian
  platform  net
  strings  cli  log

std + libyaml C (1 module):
  yaml

std + libxev (4 modules):
  store  event  queue  socket
```

### 提取源代码审计

| 源文件 | 行数 | 提取目标 | Phase | 依赖清理难度 |
|--------|------|---------|-------|-------------|
| zigproxy/src/buffer.zig | 299 | buffer.zig | 1 | 低 — 仅依赖 std |
| zproxy/src/core/ringbuf.zig | 602 | ring.zig | 1 | 中 — 跨平台原子操作 |
| zigproxy/src/ringbuf.zig | 199 | ring.zig 简化备选 | 1 | 低 — 功能更少 |
| — | — | endian.zig | 1 | 无 — 新建 |
| zigproxy/src/platform.zig | 118 | platform.zig | 2 | 低 — 纯平台检测 |
| zproxy/src/platform/system.zig | 269 | platform.zig 系统探测 | 2 | 中 — 信号处理 + 资源 |
| zproxy/src/platform/time.zig | 176 | platform.zig 时间 | 2 | 低 |
| zproxy/src/utils.zig | 897 | net.zig + strings.zig | 2/3 | 中 — 含 zproxy 特有 import |
| zproxy/src/core/ip_cidr6.zig | 128 | net.zig CIDR | 2 | 低 — 纯逻辑 |
| — | — | cli.zig | 3 | 无 — 新建 |
| — | — | log.zig | 3 | 无 — 新建 |
| — | — | yaml.zig | 3 | 低 — libyaml C FFI |
| zigproxy | ? | store.zig | 4 | 待确认 |
| zproxy/src/core/event.zig | 655 | event.zig | 4 | 中 — Posix + Windows 分支 |
| zproxy/src/core/queue.zig | 348 | queue.zig | 4 | 中 — 依赖 event.zig |
| — | — | socket.zig | 5 | 中 — 五平台 socket 差异大 |

### 明确排除

| 功能 | 原因 |
|------|------|
| DNS 协议/解析/缓存 | 应用层协议，不属于基础库 |
| checksum（IP/TCP/UDP/ICMP） | 不提供 |
| protocol 首字节检测 | 协议层，属于 zigproxy |
| 业务配置结构/模板 | yaml.zig 只封装 libyaml，不含业务 schema |

### iOS 模拟器自动运行日志问题 — 已解决 (2026-07-19)

- **问题**：`.app` 路径（build-and-run.sh）用 `simctl launch` 启动后 stdout/stderr 不回流脚本终端，只能截图 + 手动 `log stream` —— 无法自动断言测试结果
- **方案**：`examples/ios/test_runner.zig` + build.zig `ios-test-runner` step —— 纯 CLI 可执行文件，`xcrun simctl spawn booted` 直接运行，stdout/stderr 直连终端（与 Android adb shell 方案同构）
- **上一会话未跑通的根因**：Zig 0.16.0 交叉链接 iOS exe/dylib 时不在 sysroot `usr/lib` 下查找 `libSystem.tbd`（静态库不链接故 Phase 6a 未暴露）→ 已修复：build.zig `addLibraryPath(.{ .cwd_relative = "/usr/lib" })` + ReleaseSmall
- **验证**：iPhone 17 / iOS 26.5 模拟器 `simctl spawn` → 13/13 PASS，退出码 0，[PASS] 逐行实时输出
- **运行命令**：`zig build ios-test-runner -Dtarget=aarch64-ios-simulator -Doptimize=ReleaseSmall -Dsysroot="$IOS_SDK_HOME_SIM"` → `xcrun simctl spawn booted zig-out/bin/zigfoundation-ios-test`

## Technical Decisions
| Decision | Rationale |
|----------|-----------|
| 依赖分层（std → libyaml → libxev） | 明确外部依赖边界，Phase 按依赖递增编排 |
| ring 而非 ringbuf | Zig 惯用短名，std.RingBuffer 前例 |
| yaml 而非 config | 只封装 libyaml 解析/序列化，不承载业务配置，名字诚实 |
| socket 而非 egress | 出站路由绑定本质是 socket 层操作，对开发者更直观 |
| store 路径注入 | 注入模式，调用者传入路径并初始化，模块不持有全局状态 |
| 不含 DNS | 应用层，属于 zproxy/zigproxy |
| 不含 checksum | 不提供 |
| Vendored C 库独立 Zig package | 每个内嵌 C 库有独立 build.zig + build.zig.zon，防止根 build.zig 臃肿；`b.addModule("name", opts)` 公开模块供依赖方 `dep.module()` 获取 |
| `b.addModule` vs `b.createModule` | addModule = 公开（注册到 b.modules，可被依赖方访问）；createModule = 私有（内部使用）。vendor package 必须用 addModule |
| NDK arch include 使用预设列表 | `target.result.zigTriple()` 在 dependency 中返回宿主 triple，无法动态计算目标 triple |
| Android 动态链接（.linkage = .dynamic） | NDK 30 的 `libc.a` 包含 Rust std 代码需 libunwind，无法静态链接；Zig 动态链接自动设置 `/system/bin/linker64` + PIE |
| Android 日志：stderr 自动到 logcat | 移除 `__android_log_write` + liblog 依赖，Android 原生程序 stderr 输出自动路由到 logcat |
| `testLog()` 必须恢复日志级别 | 全局 `log_level` 状态污染的副作用：testLog 最后一行必须 `setLevel(.info)`，否则后续 PASS 不可见 |

## Issues Encountered
| Issue | Resolution |
|-------|------------|
| CLAUDE.md 跨项目引用路径错误（../zigtun/ 已不存在） | 修正为 ./ 本地路径引用 |
| 原计划 11 模块 → 13 模块 | socket.zig（出站路由绑定）、yaml.zig（libyaml 封装）新增；平台/网络/signal/resource 明确划入对应模块 |
| vendor/yaml 重构后 iOS/Android 交叉编译失败 | vendor/yaml/build.zig 添加 sysroot include paths（`usr/include` + NDK 架构特定目录） |
| `b.sysroot` 全局设置不传播到 dependency C 编译 include path | 需在 dependency build.zig 中手动 `addSystemIncludePath` |
| Dependency 中 `b.standardTargetOptions` 无法获取交叉编译目标 triple | 返回宿主 triple，需用预设列表替代动态目录扫描 |
| Zig 0.16.0 libc conf 要求全部 6 字段 | msvc_lib_dir / kernel32_lib_dir / gcc_dir 即使 Android 不需要也必须声明（空值） |
| NDK 库文件在版本化子目录 linker 找不到 | 创建 symlink 从 `<triple>/` → `<triple>/36/`（libc/libm/libdl .so + .a） |
| `linkSystemLibrary("log")` Zig 构建系统无法定位 | Android log.zig 改为 stderr 输出，移除 liblog 依赖 |
| GitHub MCP 插件需 `GITHUB_PERSONAL_ACCESS_TOKEN` | 从 `gh auth token` 获取 → `~/.bash_profile` export |

## Resources
- zproxy 参考：`../zproxy/src/utils.zig`、`core/event.zig`、`core/ringbuf.zig`、`core/queue.zig`、`platform/`
- zigproxy 参考：`../zigproxy/src/buffer.zig`、`ringbuf.zig`、`platform.zig`
- zigtun 参考：`../zigtun/src/checksum.zig`、`signal.zig`、平台适配代码
- Zig 0.16.0 手册：https://ziglang.org/documentation/0.16.0/
- 编码经验：`./zig-codegen.md`

## Visual/Browser Findings
-

---
*每 2 次查看/浏览器/搜索操作后更新此文件*
*防止视觉信息丢失*
