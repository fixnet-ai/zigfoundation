//! zigfoundation — fixnet 生态基础库
//!
//! 提供与业务无关的工业级基础组件：
//! - 内存管理 (buffer, ringbuf)
//! - 网络工具 (endian, net)
//! - 字符串处理 (strings)
//! - 平台抽象 (platform)
//! - 应用框架 (cli, log, store)
//! - 并发原语 (event, queue)
//!
//! 零外部依赖，仅使用 Zig 标准库。
//! 目标平台: Windows / macOS / Linux / iOS / Android

const foundation = @This();

// ---- 版本信息 ----
pub const version = "0.1.0";
pub const version_str = "zigfoundation 0.1.0";

// ---- 模块（按 Phase 逐步实现）----
// pub const buffer = @import("buffer.zig");     // Phase 8b
// pub const ringbuf = @import("ringbuf.zig");   // Phase 8b
// pub const endian = @import("endian.zig");     // Phase 8b
// pub const platform = @import("platform.zig"); // Phase 8c
// pub const net = @import("net.zig");           // Phase 8c
// pub const strings = @import("strings.zig");   // Phase 8d
// pub const cli = @import("cli.zig");           // Phase 8d
// pub const log = @import("log.zig");           // Phase 8d
// pub const store = @import("store.zig");       // Phase 8e
// pub const event = @import("event.zig");       // Phase 8e
// pub const queue = @import("queue.zig");       // Phase 8e

test {
    _ = @import("foundation.zig");
    // 各子模块的测试将在实现时通过 _ = @import("buffer.zig"); 等方式挂接
}
