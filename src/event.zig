//! 跨线程事件通知 — 手动重置事件（manual-reset event）
//!
//! 从 zproxy/src/core/event.zig 提取，仅保留 StdResetEvent。
//! MainEvent（6-bit flag aggregator）属于 zproxy 特有的 T0 主线程逻辑，不在此提取。
//!
//! ## 设计
//!
//! - **ResetEvent**: 手动重置、电平触发事件。`set()` 唤醒所有等待者并保持置位状态，直到 `reset()`。
//!   用于一个线程向 N 个等待者发送"我已就绪"或"有新事件"信号。
//!
//! - 根据 `builtin.os.tag` 分派到 POSIX 实现 (pthread_mutex + pthread_cond + atomic state)
//!   或 Windows 实现 (SRWLOCK + CONDITION_VARIABLE)。
//!
//! ## 约束
//!
//! - **不要重定位**结构体实例。底层 pthread mutex/cond 可能在某些平台上包含自引用指针，
//!   移动存储（如 memcpy 到 ArrayList slot）会静默破坏等待。
//!   在结构体整个生命周期内保持地址稳定。
//!
//! - **`deinit()` 在 POSIX 上执行实际销毁**，与 `init()` 配对使用。
//!   Windows 上是 no-op（SRWLOCK/CONDITION_VARIABLE 无需清理）。
//!
//! - **`setFromSignal()` 是异步信号安全的**，但存在已知竞态窗口：
//!   它仅执行原子存储，不广播条件变量。信号处理器和后续 `wait()` 配对使用，
//!   因此延迟被限制在一个等待周期内。

const std = @import("std");
const builtin = @import("builtin");
const platform = @import("platform.zig");

/// Windows `INFINITE` 超时值，供 `SleepConditionVariableSRW` 使用。
const INFINITE: c_ulong = 0xFFFFFFFF;

// ============================================================================
// ResetEvent — 跨平台手动重置事件
// ============================================================================

/// 根据操作系统分派到正确的后端。
pub const ResetEvent = switch (builtin.os.tag) {
    .windows => WindowsResetEvent,
    else => PosixResetEvent,
};

/// POSIX 实现 (macOS, Linux, Android, iOS)。
/// 手动重置事件：`set()` 粘性保持直到 `reset()`。
pub const PosixResetEvent = struct {
    state: std.atomic.Value(u32) = .init(0),
    mutex: std.c.pthread_mutex_t = .{},
    cond: std.c.pthread_cond_t = .{},

    /// 初始化 mutex 和 condvar。
    ///
    /// **关键**：macOS 上 pthread_mutex_t / pthread_cond_t 零初始化是无效的
    /// （`__sig` 字段必须设为魔数，通常为 `0x32AAABA7`）。跳过此步骤会导致
    /// pthread_cond_wait 操作垃圾状态并立即返回，表现为等待者 100% CPU 忙等。
    pub fn init(self: *PosixResetEvent) void {
        const pthread_mutex_init_fn = struct {
            extern "c" fn pthread_mutex_init(
                mutex: *std.c.pthread_mutex_t,
                attr: ?*const anyopaque,
            ) std.c.E;
        }.pthread_mutex_init;
        const pthread_cond_init_fn = struct {
            extern "c" fn pthread_cond_init(
                cond: *std.c.pthread_cond_t,
                attr: ?*const anyopaque,
            ) std.c.E;
        }.pthread_cond_init;
        _ = pthread_mutex_init_fn(&self.mutex, null);
        _ = pthread_cond_init_fn(&self.cond, null);
    }

    /// 销毁 mutex 和 condvar。与 `init()` 配对。
    pub fn deinit(self: *PosixResetEvent) void {
        const pthread_mutex_destroy_fn = struct {
            extern "c" fn pthread_mutex_destroy(mutex: *std.c.pthread_mutex_t) std.c.E;
        }.pthread_mutex_destroy;
        const pthread_cond_destroy_fn = struct {
            extern "c" fn pthread_cond_destroy(cond: *std.c.pthread_cond_t) std.c.E;
        }.pthread_cond_destroy;
        _ = pthread_mutex_destroy_fn(&self.mutex);
        _ = pthread_cond_destroy_fn(&self.cond);
    }

    /// 设置事件并唤醒所有等待者。后续 `wait()` 调用立即返回，直到 `reset()` 被调用。
    /// 可从任意线程安全调用。
    /// 始终广播条件变量（即使 state 已置位），以兼容 setFromSignal
    /// 仅做原子存储而不广播的场景。
    pub fn set(self: *PosixResetEvent) void {
        self.state.store(1, .release);
        _ = std.c.pthread_mutex_lock(&self.mutex);
        _ = std.c.pthread_cond_broadcast(&self.cond);
        _ = std.c.pthread_mutex_unlock(&self.mutex);
    }

    /// `set()` 的异步信号安全变体。仅执行原子存储，不广播条件变量。
    /// 参见文件级文档中的竞态窗口说明。
    /// 不得与同一事件的 `set()` 并发调用。
    pub fn setFromSignal(self: *PosixResetEvent) void {
        self.state.store(1, .release);
    }

    /// 阻塞直到事件被设置。通过锁下重新检查状态来处理虚假唤醒。
    /// 结构体必须保持地址稳定；参见文件级约束。
    pub fn wait(self: *PosixResetEvent) void {
        if (self.state.load(.acquire) != 0) return;
        _ = std.c.pthread_mutex_lock(&self.mutex);
        defer _ = std.c.pthread_mutex_unlock(&self.mutex);
        while (self.state.load(.acquire) == 0) {
            _ = std.c.pthread_cond_wait(&self.cond, &self.mutex);
        }
    }

    /// 阻塞直到事件被设置或 `timeout_ms` 超时。
    /// 截止时间计算为 CLOCK_REALTIME 中的**绝对**时间（`pthread_cond_timedwait` 要求）。
    /// 返回 `true` 表示事件已设置，`false` 表示超时。
    /// 包含虚假唤醒重试循环：pthread_cond_timedwait 可能无原因返回，
    /// 重试直到状态变更或 deadline 过期。
    pub fn timedWait(self: *PosixResetEvent, timeout_ms: u32) bool {
        if (self.state.load(.acquire) != 0) return true;
        if (timeout_ms == 0) return false;
        _ = std.c.pthread_mutex_lock(&self.mutex);
        defer _ = std.c.pthread_mutex_unlock(&self.mutex);

        // 计算 CLOCK_REALTIME 中的绝对截止时间。
        const ts_template: std.c.timespec = undefined;
        const Sec = @TypeOf(ts_template.sec);
        const Nsec = @TypeOf(ts_template.nsec);
        const abs_ms = platform.absoluteMillis();
        const sec_total = @divTrunc(abs_ms, std.time.ms_per_s);
        const ns_rem = @rem(abs_ms, std.time.ms_per_s) * std.time.ns_per_ms;
        var deadline: std.c.timespec = .{
            .sec = @as(Sec, @intCast(sec_total)),
            .nsec = @as(Nsec, @intCast(ns_rem)),
        };
        deadline.sec += @as(Sec, @intCast(timeout_ms / 1000));
        deadline.nsec += @as(Nsec, @intCast((timeout_ms % 1000) * 1_000_000));
        if (deadline.nsec >= 1_000_000_000) {
            deadline.sec += 1;
            deadline.nsec -= 1_000_000_000;
        }

        // 重试循环：pthread_cond_timedwait 可能虚假唤醒（spurious wakeup）
        while (self.state.load(.acquire) == 0) {
            const rc = std.c.pthread_cond_timedwait(&self.cond, &self.mutex, &deadline);
            if (rc != .SUCCESS) return false; // ETIMEDOUT
        }
        return true;
    }

    /// 清除信号。仅重置状态，不唤醒等待者。
    pub fn reset(self: *PosixResetEvent) void {
        self.state.store(0, .release);
    }

    /// 非阻塞检查当前状态。
    pub fn isSet(self: *const PosixResetEvent) bool {
        return self.state.load(.acquire) != 0;
    }
};

/// Windows 实现，使用 SRWLOCK + CONDITION_VARIABLE。
pub const WindowsResetEvent = struct {
    state: std.atomic.Value(u32) = .init(0),
    srwlock: std.os.windows.SRWLOCK = .{},
    cond: std.os.windows.CONDITION_VARIABLE = .{},

    extern "kernel32" fn AcquireSRWLockExclusive(srwlock: *std.os.windows.SRWLOCK) callconv(.winapi) void;
    extern "kernel32" fn ReleaseSRWLockExclusive(srwlock: *std.os.windows.SRWLOCK) callconv(.winapi) void;
    extern "kernel32" fn SleepConditionVariableSRW(
        cond: *std.os.windows.CONDITION_VARIABLE,
        srwlock: *std.os.windows.SRWLOCK,
        timeout_ms: c_ulong,
        flags: c_ulong,
    ) callconv(.winapi) c_int;
    extern "kernel32" fn WakeAllConditionVariable(cond: *std.os.windows.CONDITION_VARIABLE) callconv(.winapi) void;

    /// No-op。字段默认值 `= .{}` 已经是有效的静态初始化器。
    pub fn init(self: *WindowsResetEvent) void {
        _ = self;
    }

    /// No-op。参见文件级约束。
    pub fn deinit(self: *WindowsResetEvent) void {
        _ = self;
    }

    pub fn set(self: *WindowsResetEvent) void {
        self.state.store(1, .release);
        AcquireSRWLockExclusive(&self.srwlock);
        WakeAllConditionVariable(&self.cond);
        ReleaseSRWLockExclusive(&self.srwlock);
    }

    pub fn setFromSignal(self: *WindowsResetEvent) void {
        self.state.store(1, .release);
    }

    pub fn wait(self: *WindowsResetEvent) void {
        if (self.state.load(.acquire) != 0) return;
        AcquireSRWLockExclusive(&self.srwlock);
        while (self.state.load(.acquire) == 0) {
            _ = SleepConditionVariableSRW(&self.cond, &self.srwlock, INFINITE, 0);
        }
        ReleaseSRWLockExclusive(&self.srwlock);
    }

    pub fn timedWait(self: *WindowsResetEvent, timeout_ms: u32) bool {
        if (self.state.load(.acquire) != 0) return true;
        if (timeout_ms == 0) return false;
        AcquireSRWLockExclusive(&self.srwlock);
        defer ReleaseSRWLockExclusive(&self.srwlock);
        // Retry on spurious wakeup until state changes or timeout expires
        const tick = struct {
            extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
        };
        const start = tick.GetTickCount64();
        while (self.state.load(.acquire) == 0) {
            const elapsed_ms: u64 = tick.GetTickCount64() - start;
            if (elapsed_ms >= timeout_ms) return false;
            _ = SleepConditionVariableSRW(&self.cond, &self.srwlock, @intCast(timeout_ms - elapsed_ms), 0);
        }
        return true;
    }

    pub fn reset(self: *WindowsResetEvent) void {
        self.state.store(0, .release);
    }

    pub fn isSet(self: *const WindowsResetEvent) bool {
        return self.state.load(.acquire) != 0;
    }
};

// ============================================================================
// 测试
// ============================================================================

const testing = std.testing;

test "event: reference all pub decls (lazy-analysis guard)" {
    testing.refAllDecls(@This());
}

test "event: ResetEvent set/wait notifies" {
    var e: PosixResetEvent = .{};
    e.init();
    defer e.deinit();
    try testing.expect(!e.isSet());
    e.set();
    try testing.expect(e.isSet());
    e.wait();
}

test "event: ResetEvent timedWait timeout" {
    var e: PosixResetEvent = .{};
    e.init();
    defer e.deinit();
    try testing.expect(!e.timedWait(50));
}

test "event: ResetEvent setFromSignal" {
    var e: PosixResetEvent = .{};
    e.init();
    defer e.deinit();
    e.setFromSignal();
    try testing.expect(e.isSet());
}

test "event: ResetEvent reset after set" {
    var e: PosixResetEvent = .{};
    e.init();
    defer e.deinit();
    e.set();
    try testing.expect(e.isSet());
    e.reset();
    try testing.expect(!e.isSet());
}

test "event: ResetEvent isSet after reset" {
    var e: PosixResetEvent = .{};
    e.init();
    defer e.deinit();
    e.set();
    try testing.expect(e.isSet());
    e.reset();
    try testing.expect(!e.isSet());
    e.set();
    try testing.expect(e.isSet());
}

test "event: ResetEvent timedWait immediate success when already set" {
    var e: PosixResetEvent = .{};
    e.init();
    defer e.deinit();
    e.set();
    try testing.expect(e.timedWait(0));
    try testing.expect(e.timedWait(1000));
}

test "event: ResetEvent cross-thread notify" {
    var e: PosixResetEvent = .{};
    e.init();
    defer e.deinit();

    const Ctx = struct {
        ev: *PosixResetEvent,
    };
    var ctx = Ctx{ .ev = &e };

    const Worker = struct {
        fn run(c: *Ctx) void {
            _ = std.c.nanosleep(&.{ .sec = 0, .nsec = 50 * std.time.ns_per_ms }, null);
            c.ev.set();
        }
    };

    const handle = try std.Thread.spawn(.{}, Worker.run, .{&ctx});
    e.wait();
    handle.join();
}
