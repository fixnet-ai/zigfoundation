# Progress Log

## 2026-07-21: foundation.zig → mod.zig 重命名

- `src/foundation.zig` 重命名为 `src/mod.zig`，与其他库（zigtun/zigdns/zigproxy）统一
- build.zig: `root_source_file` 路径更新
- 对外接口 (`@import("zigfoundation")`) 不变，其他项目无需修改

## 2026-07-21: tunconn.zig TUN 连接 vtable 接口 + zigproxy 解耦

- 新建 `src/tunconn.zig`（从 zigtun 提取，原 `conn.zig`）
- 提取 6 个 vtable 接口类型：TcpConn / UdpConn / Handler / DirectRouteContext / DirectRouteDestination / NetworkType
- 解耦 zigproxy → zigtun 依赖：zigproxy/build.zig 删除 zigtun_module，3 文件改为 `@import("zigfoundation").tunconn`
- zigtun 重导出 6 个类型保持 API 兼容
- conn.zig → tunconn.zig 重命名：公开路径 zf.conn → zf.tunconn
- 22 tests 全覆盖（mock 实现验证所有 vtable dispatch），272 tests 全绿
- zigbox 55/55 tests 通过
- 版本升级 0.1.8 → 0.1.9
- API.md 新增 tunconn.zig 完整文档章节
- README.md 模块表新增 tunconn

## 2026-07-20: fdconn.zig 独立模块 — FdStream 提取

- 将 `FdStream` 从 `src/relay.zig` 移出到新建 `src/fdconn.zig`
- 原因：FdStream 为 relay/memconn 等多模块所需，位于 relay 中引致循环依赖
- relay.zig 添加 `const fdconn = @import("fdconn.zig")`，测试更新引用
- foundation.zig 新增 `pub const fdconn` 导出 + 测试引用
- API.md 新增 fdconn.zig 章节（适配规则表 + API + 示例），relay 章节同步更新
- 测试：239/239 ✅（新增 fdconn 2 tests）

## 2026-07-20: 文档矛盾修复 + log.zig 增强 + Linux VM 测试

- 修复 6 个文档/注释矛盾点（memconn/foundation/buffer/log/README）
- log.zig: Android `__android_log_write`(logcat) + iOS `syslog`，macOS 保持 stderr
- Linux aarch64-musl: `utmm --upload` + `--exec linuxvm` → 219/219 ✅
- Windows aarch64-gnu: 重新验证构建确认 5 个错误已消除（PE32+ + CLI exe 均成功）
- README.md 创建
- Windows/iOS VM 测试：待 utmm 更新后继续

## 2026-07-19: Phase 7-9 完成 + memconn 异步重写

- Phase 7: 62 项全库审查修复（P0 崩溃 5 + P1 编译/I/O 9 + P2 示例假 PASS 8 + P3 MEDIUM 8）
- Phase 8: memconn.zig libxev Completion 模型重写（4 Async 模式，219 tests 零泄漏）
- Phase 9: Windows 交叉编译 5 错误修复（pthread void / nanosleep / zli remaining）

### 五平台交叉编译 (2026-07-20 更新)

| 平台 | 构建 | 测试 | 备注 |
|------|------|------|------|
| macOS aarch64 (host) | ✅ | 219/219 ✅ + CLI 13/13 ✅ | - |
| Linux aarch64-musl | ✅ | 219/219 ✅ | UTM VM 实测 |
| iOS aarch64-simulator | ✅ | 二进制就绪 | 待 utmm 更新后 VM 测试 |
| Android aarch64 | ✅ | 13/13 ✅ | 模拟器 (Phase 6e) |
| Windows aarch64-gnu | ✅ | 二进制就绪 | 待 utmm 更新后 VM 测试 |

## 2026-07-18: Phase 0-6 完成

- Phase 0: 项目骨架 + 文档 + git 环境
- Phase 1: buffer/ring/endian (28 tests)
- Phase 2: platform/net (58 tests, total 86)
- Phase 3: strings/cli/log (48 tests, total 134)
- Phase 4: yaml/store/event/queue (38 tests, total 172)
- Phase 5: egress (12 tests, total 184)
- Phase 6: 13 模块集成 + CLI 示例 + iOS/Android 静态库 + 三平台 VM 测试 (13/13)

## 2026-07-17: 项目启动
