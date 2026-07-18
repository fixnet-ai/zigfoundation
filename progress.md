# Progress Log

### Phase 4: 存储、配置与并发（std + libyaml + libxev）
- **Status:** complete
- Actions taken:
  - 从 zproxy 复制 `vendor/yaml/` (8 C 源文件 + headers)，复用已验证的交叉编译 libyaml 源码
  - 修改 `build.zig`：addTranslateC(yaml.h) → yaml_h.createModule() → lib_module.addImport("yaml_c", ...); lib_module.addCSourceFiles 编译 8 个 C 文件；添加 include paths
  - 创建 `yaml.zig` — libyaml C 库封装。Document.parse() → doc.root() → Node (kind/asString/asInt/asBool/seqLen/seqGet/seqIter/mappingGet/mappingIter)。debug translateC struct 布局差异（items/pairs 嵌套、pointer subtraction → usize）。12 tests
  - 创建 `store.zig` — 文件系统 KV 存储。Hex-encoded 文件名、8字节 header (u64 big-endian 到期时间)、原子写入 (tmp+rename)、过期清理。Zig 0.16.0 Io.Dir API (writeFile/readFileAlloc/renameAbsolute/deleteFileAbsolute/createDirPath)、Io.Limit.limited()、getcwd → sliceTo。12 tests
  - 创建 `event.zig` — 从 zproxy 提取 ResetEvent。POSIX (pthread_mutex + pthread_cond + atomic state) / Windows (SRWLOCK + CONDITION_VARIABLE)。init/deinit/set/wait/timedWait/reset/isSet/setFromSignal。7 tests
  - 创建 `queue.zig` — 从 zproxy 泛化为 Queue(T, comptime capacity)。pthread_mutex + ResetEvent + ring buffer。push/tryPop/drain/wait/len。7 tests
  - 更新 `foundation.zig` — 取消 yaml/store/event/queue 注释，barrel 导出，注册测试
  - `zig build test` 161/161 全绿 (Phase 3 134 + event 7 + queue 7 + store 12 + yaml 12 = 161)
- Files created/modified:
  - vendor/yaml/ (copied from zproxy — 8 .c + 3 .h)
  - build.zig (modified — libyaml addTranslateC + addCSourceFiles)
  - src/yaml.zig (created)
  - src/store.zig (created)
  - src/event.zig (created)
  - src/queue.zig (created)
  - src/foundation.zig (updated — barrel export)
- Errors encountered:
  - queue.zig: `.{}` 初始化缺少 mutex/event 默认值 → 添加 `= .{}`
  - store.zig: `std.fs.makeDirAbsolute` 不存在 (Zig 0.16.0) → `std.Io.Dir.createDirPath`
  - store.zig: `Io.Limit` 期望 enum 而非 usize → `Io.Limit.limited(n)`
  - store.zig: `renameAbsolute` path not absolute → init() 中用 getcwd + join 转换为绝对路径
  - store.zig: getcwd 返回 `?[*]u8` → `std.mem.sliceTo(ptr, 0)` 转换
  - store.zig: 内存泄漏 (12 tests) — dir_path 在 init() 中 allocator.dupe 但未释放 → deinit() 中 free
  - yaml.zig: translateC struct 字段名与 @cImport 不同 (sequence.top → items.top) → 逐字段对比纠正
  - yaml.zig: pointer subtraction 返回 usize 非 isize → 统一用 usize
  - yaml.zig: 未使用的 allocator 字段 → 移除

### Phase 5: 网络出站（std + libxev）
- **Status:** complete
- Actions taken:
  - 创建 `egress.zig` — 命名从 socket 改为 egress（更准确表达出站路由绑定意图）
  - Zig 0.16.0 适配：`std.posix.socket`/`std.posix.bind` 不存在 → 使用 `std.c.socket`/`std.c.bind`；`std.posix.AF`/`IPPROTO` 在 macOS 是 struct 非 enum → 使用原始 BSD socket 常量 (AF_INET=2, SOCK_STREAM=1, IPPROTO_TCP=6 等)
  - macOS sockaddr 布局：BSD 含 sin_len 字节前缀，Linux 无 → 双路径 sockaddr 构造 + SockAddrIn4/SockAddrIn6 平台条件编译
  - Ip4Address 字段：`.bytes[4]` 非 `.ip`；Ip6Address 字段：`.bytes[16]`/`.port`/`.flow`/`.interface` 非 `.scope_id`
  - 模块名全项目更新：CLAUDE.md (5处)、task_plan.md (4处)、foundation.zig (2处)
  - 12 tests: TCP/UDP socket 创建、IPv4/IPv6/双栈、SO_REUSEADDR、源地址绑定 loopback、close/fd 验证、多 socket
- Files created/modified:
  - src/egress.zig (created — ~350 lines)
  - src/foundation.zig (updated — uncomment egress export + test reference)
  - CLAUDE.md (updated — socket → egress, 5 locations)
  - task_plan.md (updated — module name + decisions)
- Errors encountered:
  - `std.net.Address` 不存在 (Zig 0.16.0) → 改用 `std.Io.net.Ip4Address` + 字符串解析
  - `std.posix.socket()` 不存在 → `std.c.socket(domain, type, proto)` + 原始常量
  - macOS `std.posix.AF` 是 struct 不是 enum → 原始常量 `AF_INET=2` 等
  - `std.posix.IPPROTO.IPV6` 是 comptime_int struct field → 原始常量 `IPPROTO_IPV6=41`
  - `std.posix.bind()` 不存在 → `std.c.bind()`
  - `setsockopt` level 参数类型 `i32` 非 `u32` → 协议级常量改为 i32
  - macOS sockaddr 布局需 sin_len 字段 → 平台条件编译 struct + byte-level 编码
  - `Ip4Address` 无 `.ip` 字段 → `.bytes[4]` + 手动 big-endian 拼接
  - `Ip6Address` 无 `.scope_id` → scope_id=0
  - `if` 不支持 error union 直接解包 → `catch null` + optional if
  - `std.posix.INVALID_SOCKET` 不存在 → 模块内自定义 INVALID_SOCKET 常量

### Phase 0: 项目初始化
- **Status:** complete
- Actions taken:
  - 创建 zigfoundation 独立库项目（目录、git init）
  - 创建 build.zig.zon、build.zig（静态库 + test/test-build 目标）
  - 创建 src/foundation.zig（barrel 模块，版本 0.1.0，子模块 import 已预留）
  - 编写 CLAUDE.md（中文，项目概述/设计原则/模块架构/构建命令/Zig 规则/提取规则）
  - 编写 API.md（模块目录框架，TBD 占位）
  - 创建 .claude/skills/ 软链接（zig、utm-vm → ../../zigbox/.claude/skills/）
  - 验证 `zig build test` + `zig build` 通过
  - Git commit d22c375 + push
  - 合并 zig-codegen.md（Zig 0.16.0 编码经验）→ commit 6310ac5
  - 修正 CLAUDE.md 跨项目引用路径（../zigtun/ → ./）→ 待提交
  - Git 基础环境：.gitignore（IDE/OS/构建产物）、.gitattributes（LF + binary）
  - Git 全局配置：user.name=fixnet-ai、user.email=noreply.github.com
  - Git commit 5d90ee4 + push
  - 规划文件重写：13 模块 × 5 阶段，独立 Phase 编号，依赖分层（std → libyaml → libxev）
- Files created/modified:
  - build.zig、build.zig.zon、src/foundation.zig
  - CLAUDE.md、API.md、zig-codegen.md
  - .gitignore、.gitattributes
  - .claude/skills/zig、utm-vm (symlinks)
  - task_plan.md、findings.md、progress.md

### Phase 1: 内存管理（std only）
- **Status:** complete
- Actions taken:
  - 创建 `ring.zig` — 从 zigproxy/src/ringbuf.zig 提取泛型 SPSC RingBuf(T)，适配 Zig 0.16.0 `.init` 初始化。push/pop/tryPush/tryPop/pushSlice/popSlice + 5 个测试
  - 创建 `buffer.zig` — 从 zigproxy/src/buffer.zig 提取 BufferPool，import 改为 `ring.zig`。LIFO 复用、shrink-to-initial + 6 个测试
  - 创建 `endian.zig` — 新建薄封装：read/write U16/U32/U64 Big/Little + 泛型 readInt*/writeInt*。16 个 round-trip 测试
  - 更新 `foundation.zig` — 取消 Phase 1 模块注释，barrel 导出，注册子模块测试
  - `zig build test` 28/28 全绿 + `zig build` 成功 + `zig fmt --check` 通过
- Files created/modified:
  - src/ring.zig (created)
  - src/buffer.zig (created)
  - src/endian.zig (created)
  - src/foundation.zig (updated — barrel export + test registration)

### Phase 2: 平台与网络（std only）
- **Status:** complete
- Actions taken:
  - 创建 `platform.zig` — 合并 zigproxy + zigtun 平台代码。平台检测 (isDarwin/isLinux/isWindows/isMobile)、跨平台时间 (monoMillis/monoMicros/monoNanos/absoluteMillis)、系统资源 (getCpuCount/getMaxFds/raiseMaxFds/getRecommendedPoolSize)、系统 DNS 探测 (detectSystemDns)。信号处理移至 cli.zig (Phase 3)。9 tests
  - 创建 `net.zig` — 从 zproxy/utils.zig + ip_cidr6.zig + ip_cidr.zig 提取，适配 Zig 0.16.0，去除 zio 依赖。IP 格式化 (formatIpv4/formatIpv6)、字节↔整数转换 (ip4ToInt/intToIp4/ip6ToInt/intToIp6)、IP 字符串解析 (parseIpv4/parseIpv6 via std.Io.net)、地址类型判断 (isIpv4/isIpv6/isDomain)、验证 (isValidPort/isValidIpv4String/isValidIpv6String/isValidDomain/isValidHost)、IPv4 CIDR (Cidr4: parse/contains/network/broadcast/netmask/prefixLen/format)、IPv6 CIDR (Cidr6: parse/contains/network/prefixLen/next/format)、host:port 解析 (parseHostPort/buildHostPort)。49 tests
  - 修复：parseIpv4 错误类型适配 (Overflow/Incomplete/InvalidCharacter)、Cidr4.format/Cidr6.format buffer 别名问题、isValidHost 的 "256.0.0.0" 回退到 isValidDomain 的可接受行为
  - 更新 `foundation.zig` — barrel 导出 platform + net，注册测试
  - `zig build test` 86/86 全绿 + `zig build` 成功 + `zig fmt --check` 通过
- Files created/modified:
  - src/platform.zig (created)
  - src/net.zig (created)
  - src/foundation.zig (updated — barrel export)

### Phase 3: 应用框架（std only）
- **Status:** complete
- Actions taken:
  - 创建 `strings.zig` — 原创模块，补充 std.mem 未提供的字符串工具。toLower/toUpper (alloc)、toLowerInPlace/toUpperInPlace (in-place)、contains/containsIgnoreCase、startsWithIgnoreCase/endsWithIgnoreCase、join (alloc)、splitLines、splitTrim (去空白迭代器)。20 tests
  - 创建 `cli.zig` — 原创模块。CliArgs 命令行参数解析（--flag/-f/--key=value/positional）、跨平台信号处理 (POSIX sigaction + Windows SetConsoleCtrlHandler)、守护进程化。~23 tests
  - 创建 `log.zig` — 原创模块。Level 五级枚举、WriteFn 回调模式、跨平台 stderr/stdout（POSIX std.c.write + Windows kernel32）、ANSI 颜色、动态切换级别/后端。10 tests
  - 修复 log.zig Zig 0.16.0 问题：`std.posix.write` 不存在 → 改用 `std.c.write`；`initTestLogger` 匿名结构体返回类型不匹配 → twWriteFn 工厂函数 + struct-var 模式
  - 更新 `foundation.zig` — barrel 导出 strings + cli + log
  - `zig build test` 134/134 全绿 + `zig build` 成功 + `zig fmt --check` 通过
- Files created/modified:
  - src/strings.zig (created)
  - src/cli.zig (created)
  - src/log.zig (created)
  - src/foundation.zig (updated — barrel export)

## Test Results
| Test | Input | Expected | Actual | Status |
|------|-------|----------|--------|--------|
| Phase 1 (28 tests) | ring/buffer/endian | 全绿 | 28/28 passed | ✓ |
| Phase 2 platform (9 tests) | 平台检测/时间/资源/DNS | 全绿 | 9/9 passed | ✓ |
| Phase 2 net (49 tests) | IP/验证/CIDR/host:port | 全绿 | 49/49 passed | ✓ |
| Phase 3 strings (20 tests) | 大小写/搜索/拼接/切分 | 全绿 | 20/20 passed | ✓ |
| Phase 3 cli (~23 tests) | 参数解析/信号/守护进程 | 全绿 | 23/23 passed | ✓ |
| Phase 3 log (10 tests) | 日志级别/格式化/颜色/后端切换 | 全绿 | 10/10 passed | ✓ |
| Phase 4 yaml (12 tests) | YAML 解析/导航/迭代 | 全绿 | 12/12 passed | ✓ |
| Phase 4 store (12 tests) | KV 存储/原子写入/过期 | 全绿 | 12/12 passed | ✓ |
| Phase 4 event (7 tests) | 跨线程事件通知 | 全绿 | 7/7 passed | ✓ |
| Phase 4 queue (7 tests) | MPSC 队列 | 全绿 | 7/7 passed | ✓ |
| Phase 5 egress (12 tests) | 网络出站/接口绑定 | 全绿 | 12/12 passed | ✓ |
| **Total** | **173 tests** | **全绿** | **173/173 passed** | **✓** |
| zig build | 静态库 | 成功 | 成功 | ✓ |
| zig fmt --check | 源码格式 | 通过 | 通过 | ✓ |

## Error Log
| Timestamp | Error | Attempt | Resolution |
|-----------|-------|---------|------------|

## 5-Question Reboot Check
| Question | Answer |
|----------|--------|
| 我在哪里？ | Phase 5 完成 → Phase 6 (集成验证) 即将开始 |
| 我要去哪里？ | Phase 6 (全量测试 + API.md + 兄弟项目验证) |
| 目标是什么？ | 实现 13 个工业级基础模块，100% 测试覆盖，五平台 |
| 我学到了什么？ | Zig 0.16.0 socket API 全面变化：std.posix.socket/bind 不存在→std.c.socket/bind；AF/SOCK/IPPROTO 在 macOS 是 struct 非 enum→原始常量；sockaddr 布局 macOS 含 sin_len 前缀→平台条件编译；if 不支持 error union 直接解包→catch null |
| 我做了什么？ | Phase 5 (egress.zig) 完成：12 tests = 173/173 全绿 + fmt 通过 |

---
*每个阶段完成或遇到错误后更新此文件*
