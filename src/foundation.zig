//! zigfoundation — fixnet 生态基础库
//!
//! 提供与业务无关的工业级基础组件：
//! - 内存管理 (buffer, ring)
//! - 大小端转换 (endian)
//! - 平台抽象 (platform)
//! - 网络工具 (net, socket)
//! - 字符串处理 (strings)
//! - 应用框架 (cli, log, yaml)
//! - 存储框架 (store)
//! - 并发原语 (event, queue)
//!
//! 依赖: Zig std + libxev + libyaml C
//! 目标平台: Windows / macOS / Linux / iOS / Android

const foundation = @This();

// ---- 版本信息 ----
pub const version = "0.1.0";
pub const version_str = "zigfoundation 0.1.0";

// ---- Phase 1: 内存管理 (std only) ----
pub const buffer = @import("buffer.zig");
pub const ring = @import("ring.zig");
pub const endian = @import("endian.zig");

// ---- Phase 2: 平台与网络 (std only) ----
pub const platform = @import("platform.zig");
pub const net = @import("net.zig");

// ---- Phase 3: 应用框架 (std only) ----
pub const strings = @import("strings.zig");
pub const cli = @import("cli.zig");
pub const log = @import("log.zig");

// ---- Phase 4: 存储、配置与并发 (libyaml + libxev) ----
// pub const yaml = @import("yaml.zig");
// pub const store = @import("store.zig");
// pub const event = @import("event.zig");
// pub const queue = @import("queue.zig");

// ---- Phase 5: 网络出站 (libxev) ----
// pub const socket = @import("socket.zig");

test {
    _ = @import("foundation.zig");
    _ = @import("buffer.zig");
    _ = @import("ring.zig");
    _ = @import("endian.zig");
    _ = @import("platform.zig");
    _ = @import("net.zig");
    _ = @import("strings.zig");
    _ = @import("cli.zig");
    _ = @import("log.zig");
}
