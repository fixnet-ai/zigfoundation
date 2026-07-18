const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // =======================================================================
    // 外部依赖
    // =======================================================================

    const zli_dep = b.dependency("zli", .{});
    const zli_module = zli_dep.module("zli");

    // =======================================================================
    // 库模块 — zigfoundation 基础库
    // =======================================================================

    const lib_module = b.createModule(.{
        .root_source_file = b.path("src/foundation.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_module.addImport("zli", zli_module);

    // ---- 目标: 静态库 ----
    const lib = b.addLibrary(.{
        .name = "zigfoundation",
        .linkage = .static,
        .root_module = lib_module,
    });
    b.installArtifact(lib);

    const lib_step = b.step("lib", "构建静态库 libzigfoundation.a");
    lib_step.dependOn(&b.addInstallArtifact(lib, .{}).step);

    // ---- 测试 ----
    const lib_tests = b.addTest(.{
        .name = "zigfoundation-tests",
        .root_module = lib_module,
    });
    const test_step = b.step("test", "运行所有单元测试");
    test_step.dependOn(&b.addRunArtifact(lib_tests).step);

    // test-build: 仅编译测试（不运行），用于交叉编译
    const test_install = b.addInstallArtifact(lib_tests, .{});
    const test_build_step = b.step("test-build", "编译测试二进制 (不运行，用于交叉编译)");
    test_build_step.dependOn(&test_install.step);
}
