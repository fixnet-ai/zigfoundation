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

### 全库代码审查 — 62 项确认发现 (2026-07-19)

方法：6 个并行审查 agent 逐行审查 13 模块 + 5 示例 + build.zig（共 5874 行，含测试代码），主会话逐项对抗验证（重读源码 + std 0.16 源码比对 + macOS SDK 头文件 + @sizeOf 探针 + queue 运行复现）。**全部发现核实成立，0 项误报**（5 项保留 [uncertain]）。

**为何 173 测试全绿 + 五平台 13/13 仍存在这些 bug：**
1. Zig 懒分析 — cli.zig 半数 pub API 零引用，从未被 Sema 编译（无 refAllDecls）
2. 示例 egress `catch { check(true) }` 把失败当 PASS — Linux/Android 的 egress 绿灯是假的
3. round-trip 测试对称掩盖（ip6ToInt/intToIp6 同错互抵）
4. 单元测试只在 macOS host 运行 — Darwin 专属 socket 常量恰好正确
5. 测试自身有 bug（nanosleep 越界 0 睡眠、断言缺失、恒真断言）

#### HIGH — 库代码 (12)

| # | 位置 | 问题 |
|---|------|------|
| H1 | egress.zig:38-54 | Darwin 常量硬编码为"全平台通用"：SOL_SOCKET=0xffff(Linux=1)、SO_REUSEADDR=4(Linux=2)、AF_INET6=30(Linux=10/Win=23)、IPV6_V6ONLY=27(Linux=26)。reuse_addr 默认 true → **Linux/Android 所有 Socket.init\* 必败**；Linux/Windows v6 socket 创建必败 |
| H2 | egress.zig:229-233 | macOS/iOS v6 socket 接口绑定：IPPROTO_IPV6 层用 25=IPV6_2292PKTOPTIONS，正确为 IPV6_BOUND_IF=125（SDK in6.h:401/506 实证） |
| H3 | queue.zig:108-112 | 溢出分支只推进 head 不推进 tail → 之后 pop+push 覆盖**最新**元素并重复投递已弹出旧值（运行复现：期望 {2,3,99,50} 实际 {2,3,50,1}） |
| H4 | net.zig:322-327 | broadcastAddr 对 /0：`@intCast(32-0)` → u5 溢出 panic（特判加错端：>=31 不需要、==0 需要） |
| H5 | net.zig:88-96 | ip6ToInt/intToIp6 用 @bitCast → 小端平台数值字节序颠倒（::1 → 1<<120），与 ip4ToInt 黄金值语义矛盾；round-trip 测试(516-521)对称掩盖 |
| H6 | cli.zig:54-69 | createRoot 把栈上 out_buf/in_buf 指针存入堆 Writer/Reader.buffer → 返回后悬垂，任何输出写野内存 |
| H7 | cli.zig:81-90 | stdoutDrain 不消费 buffer/不清 end/忽略 splat；defaultFlush=`while(end!=0) drain()`（Writer.zig:317-320 实证）→ **flush 死循环** |
| H8 | cli.zig:107-126 | stdinStream EOF 返回 0（契约要求 error.EndOfStream）→ 忙等死循环；`w.end=n` 覆写已缓冲数据 |
| H9 | cli.zig:174-369 | run/installExitHandlers(POSIX)/waitForSignal/daemonize 引用不存在的 std API（std.process.args、posix.empty_sigset/sigwait/fork、time.sleep、sigaction 返回 void 被 try）— grep std 源码实证；零引用+懒分析故测试绿，下游一用即编译失败 |
| H10 | platform.zig:75 | monoNanos Windows：`counter * ns_per_s` i64 中间溢出（QPC 10MHz 下开机 ~15 分钟后 panic / ReleaseFast 回绕） |
| H11 | yaml.zig:55-71 | 空文档/纯注释 parse 成功（libyaml 空流返回 1），root() @panic → **空配置文件使进程 abort**；测试 362-367 空转固化错误认知 + 泄漏 C 堆 |
| H12 | store.zig:28+207 | MAX_KEY_LEN=256 不可实现：hex 文件名=2×key.len(+".tmp") 超全平台 255 上限 → key≥126 set 必败、≥128 全操作必败 |

#### HIGH — 示例/测试 (4)

| # | 位置 | 问题 |
|---|------|------|
| H13 | android/test_runner.zig:192-195 | egress `check("egress", true)` 硬编码 PASS，零代码执行 |
| H14 | cli/android/ios main.zig | egress `catch { check(true) }` 把失败当 PASS，掩盖 H1（Linux/Android 100% 走 catch） |
| H15 | android/main.zig:150 | testLog 恢复 .warn（应 .info）→ JNI 路径后续全部 [PASS]+总结被过滤（已知 bug 3 处修 2 漏 1，见 MEMORY.md） |
| H16 | android/main.zig:184-188 | JNI store 相对路径 "tmp/..."（app cwd=/ → /tmp）：模拟器 app uid 不可写、真机无 /tmp → **APK 路径 store 必 FAIL**（adb shell 13/13 掩盖） |

#### MEDIUM — 库 (19)

- platform.zig:91 — absoluteMillis Windows 返回 1601 纪元（未减 11644473600000），与 POSIX 1970 不一致（store.zig:234 已正确减，证明意图）
- platform.zig:174-178 — resolv.conf 用 splitAny：连续空白 → 空 token → `catch continue` 丢整行合法 nameserver；detectSystemDns 实收 IPv6 违反"返回 IPv4"文档（测试 len>=7 在 IPv6-first 机器失败）
- net.zig:404-412 — Cidr6.next() `while (i > 0)` 不含 byte[0]，进位丢失
- net.zig:196-221 — isValidIpv6String：前导单冒号误收（":1:2:…:7"）、合法 8 冒号压缩形式误拒（"1:2:3:4:5:6:7::"）
- net.zig:292/311/373 — Cidr4/6.parse 不归一化 → networkAddr/format 对 "10.1.2.3/8" 返回主机地址
- endian.zig:71-88 — 泛型用 @sizeOf(T)（实测 u24=4/u48=8 ≠ bits/8）→ u24/u40/u48/u56 实例化即错（现仅 u16/u32/u64 调用故未爆）
- buffer.zig:133-135 — release() 零防护：double-release → 同一内存双发 / usedBlocks usize 下溢 panic / 环覆盖丢块
- event.zig:140-141+207-208 — timedWait 无虚假唤醒重试循环（POSIX+Windows 同病）→ 提前谎报超时
- event.zig:88+97-99 — setFromSignal 置位后，后续 set() 因 swap 早退跳过 broadcast → 已阻塞 waiter 无界延迟
- queue.zig:122 — tryPop 空路径不 reset event（drain 有）→ 排空与延迟 set 竞态后 wait+tryPop 忙转
- strings.zig:147 — splitTrim trim 集 " \t\r" 缺 '\n'
- log.zig:58-62 — logOptions 未设 .log_level → release 构建 debug 日志被 comptime 剔除，setLevel(.debug) 失效
- log.zig:95-99 — prefix OOM 兜底 "(?) " 静态串被 page_allocator.free → panic/UB
- cli.zig:242-250 — 信号 handler 直接执行任意用户回调（非 async-signal-safe）；count 无同步
- cli.zig:58-71 — createRoot 3 个 create 无 errdefer；成功路径 3 块堆内存无法释放
- egress.zig:235-237 — Windows IP_UNICAST_IF(v4) 要求网络序索引，传主机序
- store.zig:104-105 — set(k,"") 成功但 get 返回 null（空值≡不存在）
- store.zig:8/114 — 文档承诺 "sync 后 rename"，实现无 fsync（崩溃持久性缺失）
- yaml.zig:13 — 文档示例 `parse(allocator,…)` 与签名不符 + asString 生命周期未说明

#### MEDIUM — 测试/示例 (7)

- store.zig:346/361 — nanosleep nsec=1.2e9 越界 EINVAL **0 睡眠**；347-348/363-364 无核心断言 → TTL/清理路径零有效覆盖
- store.zig:249-250 — tmpDir helper `defer tmp.cleanup()` 返回前删目录（靠 Store.init 重建侥幸过）+ 测试产物残留
- yaml.zig:362-367 — 空文档测试空转 + 每次运行泄漏（见 H11）
- 五示例 cli 恒真断言 `!exitRequested()`（未装 handler 不可能 true）；cli/main.zig 回调 flag 指向栈帧永不注销
- android/ios main.zig — runAllTests 不重置 passed/failed（Android 旋转屏幕 → 计数累加/永久 ❌）
- android/main.zig:6-7 — 声称 logcat(__android_log_write) 实为 stderr，APK 进程默认丢弃 → JNI 路径零可见输出
- ios/main.zig:210 + android/test_runner:147 — store /tmp 相对路径真机必败（模拟器侥幸）

#### LOW (~20)

ring 非环绕算术(32位理论溢出)；endian 泛型短输入 panic 无 checked 变体；buffer FIFO 实现 vs "LIFO" 声明 + 线程契约未文档化[uncertain]；net isValidIpv4String 末段不查长度、parseHostPort "[::1:8080" 垃圾 host、ip4/ip6ToInt 无长度防护、/31 broadcastAddr 语义不一致(测试固化)、isValidDomain 255 vs 253[uncertain]；platform RLIM_INFINITY maxInt(u64) Darwin 不匹配[uncertain]；event/queue 测试硬编码 PosixResetEvent+nanosleep → Windows test-build 编不过、WindowsResetEvent 零覆盖；egress 测试固定端口 23456 flaky、sa_bytes 对齐[uncertain]；queue.len() 形式 data race；log 级别非原子、ANSI 无条件、stderr 短写、logOptions 测试恒真；cli Windows 忽略信号集、writeStdout @intCast+短写、noopAction/trigger 测试恒真；store TTL 加法溢出、孤儿 .tmp 永不回收、skips-tmp 测试没建 tmp 文件；yaml asBool 半个 YAML1.1；examples/cli testLog 假验证 + store 清理非 defer；ios appendResult 死代码；build.zig libc-file 未挂 lib_tests、/usr/lib 无 target 守卫。

#### 修复优先级建议

1. **P0（真实环境必炸）**：H1/H2（egress 常量按 os.tag 分派）、H11（空 YAML）、H4（/0 broadcast）、H3（queue tail）、H12（MAX_KEY_LEN）
2. **P1（下游一用即炸）**：H6-H9（cli.zig I/O 层 + 死代码 API，建议加 refAllDeclsRecursive 测试）、H5（ip6ToInt）、H10（Windows monoNanos）
3. **P2（示例假 PASS 治理）**：H13-H16 + egress catch-as-pass 改真实 FAIL
4. **P3**：MEDIUM 逐项、测试补断言/修 nanosleep

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
