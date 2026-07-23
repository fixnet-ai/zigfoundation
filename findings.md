# Findings & Decisions

## Requirements
- 从 zigproxy/zproxy/zigtun 提取公共组件到 zigfoundation
- 依赖：Zig std + zli (CLI 框架) + libxev（异步基础）+ libyaml C 库（yaml 模块），不再使用 zio
- 五平台支持：Windows / macOS / Linux / iOS / Android
- 100% 单元测试覆盖每个 pub fn
- 工业级稳定性：内存分配可审计、错误路径清晰、无 unsafe 透出
- 功能无关：不包含任何业务逻辑（代理、TUN、路由、DNS）

## Research Findings

### 项目现状 (2026-07-18)
- 仓库：https://github.com/fixnet-ai/zigfoundation（已推送）
- 构建系统：build.zig（静态库 + test/test-build 目标）、build.zig.zon
- 入口模块：src/mod.zig（barrel 模块，子模块 import 已预留）
- 文档：CLAUDE.md、API.md、zig-codegen.md（合并自 zigtun/zigproxy/zproxy）
- Git 环境：.gitignore、.gitattributes、user.name=fixnet-ai、user.email=noreply
- Skills：.claude/skills/zig（目录）、utm-vm（软链接 → ../../../utm-monitor/utm-vm）
- 提交历史：d22c375（骨架）→ 6310ac5（zig-codegen.md）→ 5d90ee4（git 基础环境）

### 依赖分层

```
std only (8 modules):
  buffer  ring  endian
  platform  net
  strings  log  egress

std + zli (1 module):
  cli

std + libyaml C (1 module):
  yaml

std + libxev (4 modules):
  store  event  queue  memconn
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
| egress 而非 socket | 强调"出站路由绑定"语义，与普通 socket 创建区分 |
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

## Phase 8 — memconn.zig Completion 模型重写 (2026-07-19)

### Completion 生命周期约束（关键发现）

**核心事实**: 内核（kqueue/epoll/IOCP）的 kevent `udata` 存储的是 `*xev.Completion` 指针。
Completion 在回调触发前释放 = use-after-free。

**zigproxy 生产模式**（`src/server.zig`）:
- Completion 嵌入堆分配的 Session 结构体（5 个字段：client_c/connect_c/client_close_c 等）
- 单 Loop 实例，事件循环线程独占 loop.run()
- `xev.Async` 完全不用，跨线程通信用原子自旋锁

**测试中发现的问题**:
- 栈 Completion + spawn 线程提前退出 → 野指针
- 单 Loop 跨线程：线程 B 栈 Completion → 线程退出 → kevent udata 失效 → 线程 A 的 loop 处理 kevent 时崩溃
- 双 Loop 是 workaround（注册线程=运行线程→栈存活），不是设计模式

**正确姿势**:
- Completion 必须堆分配（嵌入连接上下文结构体）
- 单 Loop + notify() 跨线程通知（线程安全）
- 生命周期：Context 创建→Completions 嵌入→read/write 注册→loop.run()→回调→Context 销毁

### macOS kqueue + xev.Async 内部机制

**`xev.Async` Mach port**（`libxev/src/watcher/async.zig`）:
- `mpl_qlimit = 1`（Mach port 队列深度 1）
- `wait()`: 设置 Completion → `loop.add(c)` → 实际 kevent 注册在 `tick()` 中
- `drain()`: 在回调 wrapper 中调用，用 `MACH_RCV_MSG | MACH_RCV_TIMEOUT, MACH_MSG_TIMEOUT_NONE` 消费所有 pending 消息
- `notify()`: 发送空 Mach 消息 `MACH_SEND_MSG` + `MACH_SEND_TIMEOUT` + `COPY_SEND` 标志

**kqueue tick 循环**（`libxev/src/backend/kqueue.zig`）:
- `ev.udata = @intFromPtr(self)` → `*Completion`
- `c.perform()` → `c.callback()` → `.disarm`（EV_DELETE）或 `.rearm`（保持活跃）

### `zig build test` hang 问题

**原因**: `b.addRunArtifact(lib_tests)` 使用 `--listen=-` 模式（二进制协议 stdin/stdout）。
该协议与 libxev 事件循环 / 跨线程测试冲突 → 测试二进制 hang → 构建系统收不到响应。

**修复**: 改用 `b.addSystemCommand` 直接运行已安装的二进制（terminal 模式），避开了协议冲突。

### 双向传输死锁

**原始设计**: 每端点 2 个 Async（读/写共享一个通知器）。

**问题**: 写通知唤醒的是同一 Async 上的读等待 → 读回调处理完数据后通知对端写 → 如果两端同时写满 buffer，
都在等待对端读走数据，但通知被自己的读消费掉了 → 死锁。

**修复**: 4 个 Async（每端点独立的读/写通知器）。写 notify → 对端读 Async 被唤醒；读 notify → 对端写 Async 被唤醒。读写不互相干扰。

### 幂等 close + Registry refcount

**问题**: 两个不同 MemConn（conn 和 accepted_conn）共享同一 `closed` 标志。第一个 close() 在 CloseOp 回调中释放 refcount，第二个 close() 命中幂等路径直接返回 → refcount 未释放 → 内存泄漏。

**修复**: 幂等路径中，若 `_close_releases = true`（Registry 模式），也调用 `shared_release` 释放引用。

### 文档矛盾点修复 (2026-07-20)

审查中发现 6 处文档/注释与代码不符，逐一修复：

| # | 位置 | 矛盾 | 修复 |
|---|------|------|------|
| 1 | memconn.zig:499 | destroy() 注释"可安全多次调用"，实际 refcount 2→0 后 use-after-free | 注释改为"不可多次调用" |
| 2 | foundation.zig:32-44 | Phase 3 标 std only(cli 用 zli)、Phase 4 标 libyaml+libxev(store/event/queue 都不用)、Phase 5 标 std+libxev(egress 纯 std) | Phase 3: std+zli, Phase 4: std+libyaml, Phase 5: std only |
| 3 | buffer.zig | API.md/struct 注释 initial_blocks=256(2MB)，defaultConfig() 实际返回 0 | API.md 改为说明初始为 0，按需扩展 |
| 4 | store.zig | API.md 写"sync 后 rename"，代码注释"不显式 fsync" | 保持现状，信任 OS |
| 5 | log.zig | API.md/CLAUDE.md 写 Android __android_log_write + iOS/macOS syslog，实际全 stderr | Android: __android_log_write, iOS: syslog, macOS: 保持 stderr |
| 6 | README.md | CLAUDE.md 引用为必读文件但不存在 | 创建简洁 GitHub README |

### log.zig 平台增强 (2026-07-20)

**Android**: 添加 `extern "c" fn __android_log_write(prio: c_int, tag: [*:0]const u8, text: [*:0]const u8) c_int`，优先级映射: err→ANDROID_LOG_ERROR(6), warn→ANDROID_LOG_WARN(5), info→ANDROID_LOG_INFO(4), debug→ANDROID_LOG_DEBUG(3)，tag="zigfoundation"。

**iOS/tvOS/watchOS/visionOS**: 添加 `extern "c" fn syslog(priority: c_int, format: [*:0]const u8, ...) void`，优先级映射: err→LOG_ERR(3), warn→LOG_WARNING(4), info→LOG_INFO(6), debug→LOG_DEBUG(7)。

**macOS**: 保持 stderr+ANSI 颜色。syslog 在 macOS 已 deprecated，CLI 开发者需要终端输出。

**非目标平台安全**: extern 声明放在 const struct 内部，Zig 惰性分析避免非目标平台链接报错。验证: `zig build test` 219/219 ✅（macOS host）。

**Android 交叉编译修复**: 
- `comptime_int` 常量需显式 `: c_int` 类型标注（编译期 int 在 runtime switch 中无法确定类型）
- `linkSystemLibrary("log", .{})` — NDK 中 `paths_first` 策略搜索路径为空且 `addLibraryPath` 会 double-prefix sysroot
- 解决: `addObjectFile(.{ .cwd_relative = "<sysroot>/usr/lib/aarch64-linux-android/liblog.so" })` 直接链接 + `ln -sf 36/liblog.so` symlink
- Android 构建验证: `aarch64-linux-android` ELF pie executable 6.4MB ✅

**原始问题**: `aarch64-windows-gnu` 测试二进制 5 个编译错误。

**已修复**: Phase 9 中通过全局分析修复了三组类型问题（pthread void / nanosleep / zli remaining）。
**2026-07-20 重新验证**: `zig build test-build -Dtarget=aarch64-windows-gnu` → PE32+ AArch64 可执行文件 ✅，`zig build example-cli -Dtarget=aarch64-windows-gnu` → 同样成功 ✅。之前 5 个错误均已消除。

**全局分析**（不逐行修补）:

| 类别 | 错误原因 | 修复策略 | 影响文件 |
|------|---------|---------|---------|
| pthread 类型 = `void` | Windows 无 pthread, `std.c.pthread_mutex_t`/`pthread_cond_t` 是 `void`, `= .{}` 对 void 无效 | `= undefined`（`init()` 显式初始化，安全） | event.zig:48-49 |
| `std.c.nanosleep` = `void` | Windows 无 POSIX nanosleep | `platform.zig` 新增 `sleepNs()` — Windows: `kernel32 Sleep(ms)`, POSIX: `nanosleep` | event.zig:313, queue.zig:249, store.zig:357,373 |
| `Args.Iterator.Windows.remaining` 已移除 | Zig 0.16.0 Windows Args Iterator 不再有 `remaining` 字段 | zli `parseArgs()` 预收集所有参数到 ArrayList, 索引迭代替代 `remaining` 访问 | zli.zig:843,869,916,971 |

**关键发现**:
- Zig 0.16.0 `std.ArrayList` 是 unmanaged 类型（旧 `ArrayListUnmanaged`），API 变为 `.empty` + 方法传 `allocator`。zli 已适配此模式，仅新加的预收集代码用了旧 API。
- `comptime-known if`（`builtin.os.tag == .windows`）能正确剪枝 POSIX 代码，但 `_ =` 抛弃检查发生在剪枝前。不加 `_ =` 直接 `return false;` 即可。

验证: `zig build test-build -Dtarget=aarch64-windows-gnu` → PE32+ AArch64 4.0MB ✅

### fdconn.zig 独立模块 — 循环依赖预防 (2026-07-20)

**问题**: `FdStream` 适配 libxev fd 系流类型为统一 Stream 接口，relay.zig 和 memconn.zig 等多模块均需引用。若留于 relay.zig 内，任何需适配 fd 流的代码都需 import relay，形成不必要的依赖链。

**决策**: 将 `FdStream` 提取到独立 `src/fdconn.zig` 模块。fdconn 仅依赖 `xev`，不依赖任何 zigfoundation 内部模块，位于依赖图最底端。relay.zig 改为 `const fdconn = @import("fdconn.zig")` 引用。

**影响**:
- 新增 `src/fdconn.zig`（~130 行，含 2 tests）
- foundation.zig 新增 `pub const fdconn` 导出
- 模块数: 15 → 16，测试数: 237 → 239
- API.md 新增 fdconn.zig 完整文档章节

### tunconn.zig TUN vtable 接口提取 — 组件解耦 (2026-07-21)

**问题**: zigproxy 编译期依赖 zigtun（`zigproxy_module.addImport("zigtun", ...)`），但实际只使用 6 个纯 vtable 接口类型（零实现逻辑）。组件库之间不应有直接依赖，应由 zigbox 统筹编排。

**决策**: 将 6 个 vtable 类型从 zigtun 提取到 zigfoundation 作为共享接口层（新建 `src/tunconn.zig`）。zigtun 和 zigproxy 均改为 `@import("zigfoundation").tunconn`，zigbox 在运行时注入实现。

**目标架构**:
```
zigfoundation.tunconn  ← 共享 vtable 接口
    ↑                    ↑
zigtun (重导出)    zigproxy (直接使用)
    ↑                    ↑
zigbox (编排层，连接两者)
```

**实施**:
- 新建 `src/tunconn.zig`（274 行，含 22 tests）
- zigtun/tun.zig: 6 个 `pub const Xxx = zf_conn.Xxx` 重导出
- zigproxy 3 文件: `@import("zigfoundation").tunconn`
- zigbox 2 文件: `zf.tunconn.Xxx`
- zigproxy/build.zig: 删除 zigtun_module 和 addImport
- zigbox/build.zig: 删除 `zigproxy_module.addImport("zigtun", ...)`

**命名决策**: `conn.zig` → `tunconn.zig`，因为其中的类型（TcpConn/UdpConn/Handler/DirectRoute*）都是 TUN 连接层特化的，与 `fdconn`（fd 适配器）和 `memconn`（内存实现）语义区分。

**验证**: zigfoundation 272/272 ✅、zigbox 55/55 ✅，zigproxy 不再依赖 zigtun

## fdconn.zig kqueue 兼容修复 (2026-07-21)

**问题**: macOS kqueue 后端 `xev.TCP` 类型中不存在 `ReadError`/`WriteError`/`CloseError` 类型成员。
编译 `zigbox` 时报错 `S.ReadError` not found。

**根因**: libxev 的 kqueue 后端 TCP watcher 使用模块级错误类型（`xev.ReadError`/`xev.WriteError`/`xev.CloseError`），
而 epoll/IOCP 后端使用类型特定错误类型（`S.ReadError`/`S.WriteError`/`S.CloseError`）。

**修复**: `fdconn.zig` 中三处回调签名从 `S.ReadError`/`S.WriteError`/`S.CloseError` 改为
`xev.ReadError`/`xev.WriteError`/`xev.CloseError`。这些是跨平台的模块级类型，所有后端通用。

**验证**: zigfoundation 287 tests ✅、zigbox 全量测试 ✅

## buffer.zig 分级缓冲池 + 空闲收缩 (2026-07-21)

**需求**: zigbox relay 迁移需要三级池（2K UDP 数据报 / 4K 握手 / 16K TCP relay），
替代 relay struct 中嵌入的栈/堆数组。

**新增**:
- `pool2K()` / `pool4K()` 工厂函数（已有 `defaultConfig()` 16K）
- `idle_since_ms` 字段：`acquire` 清除，`release` 时全部空闲则记录时间戳
- `checkShrink(now_ms, idle_timeout_ms) u32`：外部定时器周期性调用，空闲超时后收缩到初始容量

**验证**: zigfoundation 287 tests ✅（buffer 测试 8→14 项）

## Zig 0.16.0 IpAddress.parse 冒号陷阱 (2026-07-21)

**问题**: `std.Io.net.IpAddress.parse("10.0.0.1:53", 53)` 返回 `ParseFailed`。

**根因**: `Ip4Address.parse` 逐字符解析，`:` 触发 `error.InvalidCharacter`。
`IpAddress.parse` 在 IPv4 失败后尝试 IPv6，`"10.0.0.1:53"` 不是有效 IPv6 格式 → 最终 `ParseFailed`。

**设计本意**: Zig std lib 的 `parse(text, port)` 期望 `text` 不含端口（端口通过第二个参数传入）。
`format()` 输出 `"1.2.3.4:port"` 格式，但 `parse()` **不**支持相同格式的输入。

**方案**: zigfoundation `net.parseHostPortAddr`：
1. 方括号 `[ipv6]:port` → parseHostPort 拆分 → IPv6 解析
2. 多个 `:` → 纯 IPv6 字面量 → 直接解析 + default_port
3. 单个 `:` → parseHostPort 拆分 host:port → 先 IPv4 后 IPv6
4. 零 `:` → 纯 IP + default_port

**影响范围**: zigdns `DnsServer.init` 已迁移至 `zf.net.parseHostPortAddr`。
任何调用 `std.Io.net.IpAddress.parse(host_port_str, default_port)` 的地方都可能受影响。

**验证**: zigfoundation 293 tests ✅

## saveAllSystemDns 与 execCaptureOutput 空 envp (2026-07-23)

### saveAllSystemDns 设计

`saveSystemDnsDarwin` 通过 `isNonPublicV4` 跳过公网 DNS 服务 — zigbox 正常模式下这是期望行为（只替换内网 DNS 为公网 223.5.5.5）。但 --full-proxy 模式需要替换 ALL 服务的 DNS（包括 Wi-Fi 的公网 223.5.5.5 → TUN 198.18.0.2），因此需要 `saveAllSystemDnsDarwin` 不区分公/私有保存全部服务。

### execCaptureOutput null-termination 问题 ✅ 已修复 (2026-07-23)

**根因**：`execve` 需要 `[*:0]const u8`（null-terminated 字符串），但原始代码对 slice 做 `@ptrCast` 绕过类型检查。运行时分配的字符串（如 `networksetup` 输出）不保证 null-terminated，`execve` 读到未分配内存。

**修复**：子进程中用 `dupeZ` 为 cmd 和所有 args 分配 null-terminated 副本。`execve` + `c.environ` 继承父进程环境。

**修复前两个问题**：
1. 空 `envp: .{null}` → 改为 `c.environ`（继承父环境）
2. 未 null-terminated 的 args → 改为 `dupeZ` 分配

**验证**：`networksetup -getdnsservers Wi-Fi` 确认 223.5.5.5 → 198.18.0.2，--full-proxy TUN 模式正常上网。
