# zigfoundation

fixnet 生态基础库 — 与业务无关的工业级 Zig 基础组件。

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

## 模块

| 模块 | 描述 |
|------|------|
| buffer | 共享缓冲区池（LIFO 复用，按需扩展） |
| ring | SPSC 无锁环缓冲区 |
| endian | 大小端读写统一 API |
| platform | 平台抽象（CPU/内存/DNS/时间） |
| net | IP 格式化/解析、CIDR、域名判断 |
| strings | 大小写转换、子串搜索、前后缀匹配 |
| cli | 命令行框架（zli + 信号处理 + 守护进程化） |
| log | 跨平台日志（Android logcat / iOS syslog / 桌面 stderr） |
| yaml | YAML 解析（libyaml 封装） |
| store | 持久化 KV 存储（文件系统） |
| event | 跨平台事件通知（pthread / SRWLOCK） |
| queue | MPSC 有界队列 |
| egress | 网络出站路由绑定 |
| memconn | 内存网络连接（基于 libxev Completion 模型） |
| fdconn | fd 流适配器（libxev TCP/File/Stream → 统一 Stream 接口） |
| relay | 双向数据中继（任意两个 Stream 端点间异步对拷） |

## 构建

```bash
zig build                    # 构建静态库 libzigfoundation.a
zig build test               # 运行全部单元测试
```

## 平台

macOS · Linux · Windows · iOS · Android

## 许可

MIT
