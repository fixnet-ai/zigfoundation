//! 共享缓冲区池 — 基于 RingBuf 的空闲块管理
//!
//! 所有连接共享一个缓冲区池，避免 per-connection 内存分配。
//! 池从较小的初始容量（默认 2MB）起步，按需扩展到上限（默认 32MB），
//! 空闲时自动收缩回初始容量。
//!
//! 设计：
//! - blocks 数组预分配最大容量，索引 0..allocated-1 为已分配块
//! - free_queue (RingBuf) 持有所有空闲块的索引
//! - acquire: 从 free_queue 弹出一个索引；如果为空则扩展
//! - release: 将索引推回 free_queue
//! - shrink: 当全部块空闲时，释放超出 min_blocks 的部分
//!
//! 提取自 zigproxy/src/buffer.zig，适配 Zig 0.16.0。

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const ring = @import("ring.zig");
const platform = @import("platform.zig");

/// 从池中借出的缓冲区句柄，归还时需要原样传回。
pub const Buffer = struct {
    data: []u8,
    index: u32,
};

/// 缓冲区池配置。
pub const PoolConfig = struct {
    /// 单个块大小（字节），必须是 2 的幂
    block_size: u32 = 8192,
    /// 初始块数（决定初始内存占用）
    initial_blocks: u32 = 256, // 256 × 8KB = 2MB
    /// 最大块数上限
    max_blocks: u32 = 4096, // 4096 × 8KB = 32MB
};

/// 获取平台默认池配置（16KB TCP relay 专用）。
/// 池的价值在于缓冲区复用而非预热——初始不分配，按需扩展，空闲收缩。
/// - macOS/Windows: 16KB 块，上限 1024 块 (~16MB)，初始 0
/// - Linux:         8KB  块，上限 4096 块 (~32MB)，初始 0
/// - 移动端:        4KB  块，上限 512 块 (~2MB)，初始 0
pub fn defaultConfig() PoolConfig {
    return switch (builtin.os.tag) {
        .linux => if (builtin.abi == .android)
            PoolConfig{ .block_size = 4096, .initial_blocks = 0, .max_blocks = 512 }
        else
            PoolConfig{ .block_size = 8192, .initial_blocks = 0, .max_blocks = 4096 },
        .macos, .windows => PoolConfig{ .block_size = 16384, .initial_blocks = 0, .max_blocks = 1024 },
        .ios, .tvos, .watchos, .visionos => PoolConfig{ .block_size = 4096, .initial_blocks = 0, .max_blocks = 512 },
        else => PoolConfig{ .block_size = 8192, .initial_blocks = 0, .max_blocks = 4096 },
    };
}

/// 2KB 池配置 — UDP 数据报转发专用。
/// 初始不分配，按需扩展，上限 4096 块（~8MB）。
pub fn pool2K() PoolConfig {
    return .{ .block_size = 2048, .initial_blocks = 0, .max_blocks = 4096 };
}

/// 4KB 池配置 — 握手协议专用（SOCKS4/5、HTTP CONNECT、TLS SNI 嗅探）。
/// 初始不分配，按需扩展，上限 4096 块（~16MB）。
pub fn pool4K() PoolConfig {
    return .{ .block_size = 4096, .initial_blocks = 0, .max_blocks = 4096 };
}

/// 共享缓冲区池。
pub const BufferPool = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    blocks: [][]u8, // 所有已分配块，索引即块 ID
    free_queue: ring.RingBuf(u32), // 空闲块索引队列
    free_backing: []u32, // free_queue 的底层存储
    block_size: u32,
    initial_blocks: u32,
    allocated: u32, // 当前已分配块数
    max_blocks: u32, // 最大块数上限

    /// 全部块空闲的起始时间戳（毫秒）。null 表示有块在使用中。
    /// release() 时若 usedBlocks==0 记录；acquire() 时清除。
    idle_since_ms: ?i64 = null,

    /// 初始化缓冲区池。
    /// block_size 和 initial_blocks 必须是 2 的幂。
    pub fn init(allocator: std.mem.Allocator, cfg: PoolConfig) !Self {
        assert(std.math.isPowerOfTwo(cfg.block_size));
        assert(cfg.initial_blocks == 0 or std.math.isPowerOfTwo(cfg.initial_blocks));
        assert(cfg.initial_blocks <= cfg.max_blocks);

        // ringbuf 容量需为 2 的幂，向上取整
        const ring_cap = std.math.ceilPowerOfTwo(u32, cfg.max_blocks) catch |err| switch (err) {
            error.Overflow => return error.PoolTooLarge,
        };

        const free_backing = try allocator.alloc(u32, ring_cap);
        errdefer allocator.free(free_backing);

        const blocks = try allocator.alloc([]u8, cfg.max_blocks);
        errdefer allocator.free(blocks);

        var free_queue = ring.RingBuf(u32).init(free_backing);

        // 预分配初始块，全部入队。
        var allocated: u32 = 0;
        errdefer {
            for (0..allocated) |i| allocator.free(blocks[i]);
        }
        for (0..cfg.initial_blocks) |i| {
            blocks[i] = try allocator.alloc(u8, cfg.block_size);
            allocated += 1;
            free_queue.push(@intCast(i));
        }

        return .{
            .allocator = allocator,
            .blocks = blocks,
            .free_queue = free_queue,
            .free_backing = free_backing,
            .block_size = cfg.block_size,
            .initial_blocks = cfg.initial_blocks,
            .allocated = cfg.initial_blocks,
            .max_blocks = cfg.max_blocks,
        };
    }

    /// 释放池占用的全部内存。
    pub fn deinit(self: *Self) void {
        for (0..self.allocated) |i| {
            self.allocator.free(self.blocks[i]);
        }
        self.allocator.free(self.blocks);
        self.allocator.free(self.free_backing);
    }

    /// 获取一个缓冲区。池耗尽且无法扩展时返回 null。
    pub fn acquire(self: *Self) !?Buffer {
        if (self.free_queue.tryPop()) |idx| {
            self.idle_since_ms = null; // 有块被借出，取消空闲计时
            return .{ .data = self.blocks[idx], .index = idx };
        }
        // 尝试扩展
        if (self.allocated >= self.max_blocks) return null;
        const idx = self.allocated;
        self.blocks[idx] = try self.allocator.alloc(u8, self.block_size);
        self.allocated += 1;
        self.idle_since_ms = null; // 新建块被借出，取消空闲计时
        return .{ .data = self.blocks[idx], .index = idx };
    }

    /// 归还缓冲区到池中。
    pub fn release(self: *Self, buf: Buffer) void {
        self.free_queue.push(buf.index);
        // 归还后若全部空闲则记录时间戳（用于 checkShrink 判断空闲时长）
        if (self.usedBlocks() == 0) {
            if (self.idle_since_ms == null) {
                self.idle_since_ms = platform.monoMillis();
            }
        }
    }

    /// 收缩池：释放超出 min_blocks 的块。
    /// 仅在无借出块时执行（usedBlocks() == 0）。
    /// 返回释放的块数。
    pub fn shrink(self: *Self, min_blocks: u32) u32 {
        if (self.usedBlocks() > 0) return 0;
        var freed: u32 = 0;
        // 释放最高索引的块（最后扩展的），避免在 free_queue 中留悬空指针
        while (self.allocated > min_blocks) {
            self.allocated -= 1;
            self.allocator.free(self.blocks[self.allocated]);
            freed += 1;
        }
        // 重建 free_queue：仅包含 0..allocated-1 的索引
        self.free_queue = ring.RingBuf(u32).init(self.free_backing);
        for (0..self.allocated) |i| {
            self.free_queue.push(@intCast(i));
        }
        return freed;
    }

    /// 收缩到初始容量。仅在无借出块时执行。
    pub fn shrinkToInitial(self: *Self) u32 {
        return self.shrink(self.initial_blocks);
    }

    /// 周期性检查收缩：全部块空闲超过 idle_timeout_ms 则收缩到初始容量。
    /// 由外部定时器（如 ShutdownPoller 500ms）驱动调用。
    /// 返回释放的块数（0 表示无需收缩或仍有块在使用）。
    pub fn checkShrink(self: *Self, now_ms: i64, idle_timeout_ms: u64) u32 {
        if (self.usedBlocks() > 0) return 0;
        if (self.idle_since_ms) |idle_since| {
            const elapsed: u64 = @intCast(now_ms - idle_since);
            if (elapsed >= idle_timeout_ms) {
                self.idle_since_ms = null; // 重置，避免重复收缩
                return self.shrinkToInitial();
            }
        }
        return 0;
    }

    // ===== 统计 =====

    /// 总内存使用（字节）。
    pub fn totalMemory(self: *const Self) usize {
        return @as(usize, self.allocated) * @as(usize, self.block_size);
    }

    /// 空闲块数。
    pub fn freeBlocks(self: *const Self) usize {
        return self.free_queue.len();
    }

    /// 当前借出的块数。
    pub fn usedBlocks(self: *const Self) usize {
        return self.allocated - self.free_queue.len();
    }

    /// 已分配块总数。
    pub fn totalBlocks(self: *const Self) u32 {
        return self.allocated;
    }

    /// 块大小。
    pub fn blockSize(self: *const Self) u32 {
        return self.block_size;
    }
};

// ============================================================
// 测试
// ============================================================

const testing = std.testing;

test "buffer: reference all pub decls (lazy-analysis guard)" {
    testing.refAllDecls(@This());
}

test "buffer: init/deinit" {
    var pool = try BufferPool.init(testing.allocator, .{ .block_size = 4096, .initial_blocks = 4, .max_blocks = 16 });
    defer pool.deinit();

    try testing.expectEqual(@as(usize, 4 * 4096), pool.totalMemory());
    try testing.expectEqual(@as(usize, 4), pool.freeBlocks());
    try testing.expectEqual(@as(usize, 0), pool.usedBlocks());
}

test "buffer: acquire/release" {
    var pool = try BufferPool.init(testing.allocator, .{ .block_size = 4096, .initial_blocks = 4, .max_blocks = 16 });
    defer pool.deinit();

    const b1 = (try pool.acquire()).?;
    const b2 = (try pool.acquire()).?;
    try testing.expectEqual(@as(usize, 2), pool.usedBlocks());
    try testing.expectEqual(@as(usize, 2), pool.freeBlocks());

    // 写入数据验证缓冲区可用
    @memset(b1.data[0..5], 0xAB);
    @memset(b2.data[0..5], 0xCD);
    try testing.expectEqual(@as(u8, 0xAB), b1.data[0]);
    try testing.expectEqual(@as(u8, 0xCD), b2.data[0]);

    pool.release(b1);
    pool.release(b2);
    try testing.expectEqual(@as(usize, 0), pool.usedBlocks());
    try testing.expectEqual(@as(usize, 4), pool.freeBlocks());
}

test "buffer: auto expand on exhaustion" {
    var pool = try BufferPool.init(testing.allocator, .{ .block_size = 4096, .initial_blocks = 2, .max_blocks = 8 });
    defer pool.deinit();

    // 借出所有初始块
    const b1 = (try pool.acquire()).?;
    const b2 = (try pool.acquire()).?;
    try testing.expectEqual(@as(usize, 0), pool.freeBlocks());

    // 再借 — 触发扩展
    const b3 = (try pool.acquire()).?;
    try testing.expectEqual(@as(u32, 3), pool.totalBlocks());
    try testing.expectEqual(@as(usize, 0), pool.freeBlocks());

    pool.release(b1);
    pool.release(b2);
    pool.release(b3);
}

test "buffer: acquire returns null at max" {
    var pool = try BufferPool.init(testing.allocator, .{ .block_size = 4096, .initial_blocks = 2, .max_blocks = 2 });
    defer pool.deinit();

    const b1 = (try pool.acquire()).?;
    const b2 = (try pool.acquire()).?;
    try testing.expect(pool.freeBlocks() == 0);

    // 池已满
    try testing.expectEqual(@as(?Buffer, null), try pool.acquire());

    pool.release(b1);
    pool.release(b2);
}

test "buffer: shrink when all free" {
    var pool = try BufferPool.init(testing.allocator, .{ .block_size = 4096, .initial_blocks = 2, .max_blocks = 16 });
    defer pool.deinit();

    // 借出初始 2 块，再借 2 次触发扩展
    const b1 = (try pool.acquire()).?;
    const b2 = (try pool.acquire()).?;
    const b3 = (try pool.acquire()).?; // 触发扩展 → allocated = 3
    const b4 = (try pool.acquire()).?; // 触发扩展 → allocated = 4
    try testing.expectEqual(@as(u32, 4), pool.totalBlocks());

    // 归还所有块
    pool.release(b1);
    pool.release(b2);
    pool.release(b3);
    pool.release(b4);
    try testing.expectEqual(@as(usize, 0), pool.usedBlocks());

    // 收缩到初始 2 块
    const freed = pool.shrinkToInitial();
    try testing.expectEqual(@as(u32, 2), freed);
    try testing.expectEqual(@as(u32, 2), pool.totalBlocks());
    try testing.expectEqual(@as(usize, 2 * 4096), pool.totalMemory());
}

test "buffer: shrink blocked when blocks in use" {
    var pool = try BufferPool.init(testing.allocator, .{ .block_size = 4096, .initial_blocks = 4, .max_blocks = 16 });
    defer pool.deinit();

    const b = (try pool.acquire()).?;
    defer pool.release(b);

    // 有块在使用，shrink 应返回 0
    try testing.expectEqual(@as(u32, 0), pool.shrinkToInitial());
}

test "buffer: pool2K returns correct config" {
    const cfg = pool2K();
    try testing.expectEqual(@as(usize, 2048), cfg.block_size);
    try testing.expectEqual(@as(u32, 0), cfg.initial_blocks);
    try testing.expectEqual(@as(u32, 4096), cfg.max_blocks);
}

test "buffer: pool4K returns correct config" {
    const cfg = pool4K();
    try testing.expectEqual(@as(usize, 4096), cfg.block_size);
    try testing.expectEqual(@as(u32, 0), cfg.initial_blocks);
    try testing.expectEqual(@as(u32, 4096), cfg.max_blocks);
}

test "buffer: checkShrink on idle pool shrinks to initial" {
    var pool = try BufferPool.init(testing.allocator, .{ .block_size = 1024, .initial_blocks = 0, .max_blocks = 4 });
    defer pool.deinit();

    // 获取一个块：触发按需分配
    const b = (try pool.acquire()).?;
    pool.release(b);

    // 确认分配了 1 个块
    try testing.expectEqual(@as(u32, 1), pool.allocated);

    // 全部空闲时记录 idle_since_ms
    try testing.expect(pool.idle_since_ms != null);

    // 空闲 100ms 后触发收缩（idle_timeout_ms = 60，initial_blocks = 0 → 释放全部）
    const now_ms = pool.idle_since_ms.? + 100;
    const freed = pool.checkShrink(now_ms, 60);
    try testing.expectEqual(@as(u32, 1), freed);
    try testing.expectEqual(@as(u32, 0), pool.allocated);
}

test "buffer: checkShrink with blocks in use returns 0" {
    var pool = try BufferPool.init(testing.allocator, .{ .block_size = 1024, .initial_blocks = 0, .max_blocks = 4 });
    defer pool.deinit();

    const b = (try pool.acquire()).?;
    defer pool.release(b);

    // 有块在使用中，不收缩
    const freed = pool.checkShrink(platform.monoMillis(), 60);
    try testing.expectEqual(@as(u32, 0), freed);
}

test "buffer: checkShrink not idle long enough returns 0" {
    var pool = try BufferPool.init(testing.allocator, .{ .block_size = 1024, .initial_blocks = 0, .max_blocks = 4 });
    defer pool.deinit();

    const b = (try pool.acquire()).?;
    pool.release(b);

    // 空闲但未到 timeout
    const now_ms = pool.idle_since_ms.? + 30;
    const freed = pool.checkShrink(now_ms, 60);
    try testing.expectEqual(@as(u32, 0), freed);
}

test "buffer: acquire clears idle_since_ms" {
    var pool = try BufferPool.init(testing.allocator, .{ .block_size = 1024, .initial_blocks = 0, .max_blocks = 4 });
    defer pool.deinit();

    const b = (try pool.acquire()).?;
    pool.release(b);

    // 归还后全部空闲，idle_since_ms 已记录
    try testing.expect(pool.idle_since_ms != null);

    // 重新获取块，idle_since_ms 应被清除
    _ = (try pool.acquire()).?;
    try testing.expectEqual(@as(?i64, null), pool.idle_since_ms);
}
