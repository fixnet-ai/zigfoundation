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
    // libyaml — vendor C 源码编译
    // =======================================================================

    const vendor_dir = "vendor";

    // 编译 libyaml C 源文件（跨平台，无 ar）
    // Vendor Makefile flags: -DYAML_VERSION_MAJOR=0 -DYAML_VERSION_MINOR=2
    //                        -DYAML_VERSION_PATCH=5 -DYAML_VERSION_STRING="0.2.5"
    const yaml_sources = &.{
        "api.c",
        "dumper.c",
        "emitter.c",
        "loader.c",
        "parser.c",
        "reader.c",
        "scanner.c",
        "writer.c",
    };

    const yaml_c_flags: []const []const u8 = &.{
        "-O3",
        "-std=gnu11",
        "-DYAML_VERSION_MAJOR=0",
        "-DYAML_VERSION_MINOR=2",
        "-DYAML_VERSION_PATCH=5",
        "-DYAML_VERSION_STRING=\"0.2.5\"",
    };

    // addTranslateC: 将 yaml.h 转译为 Zig 模块
    const yaml_h = b.addTranslateC(.{
        .root_source_file = b.path(vendor_dir ++ "/yaml/include/yaml.h"),
        .target = target,
        .optimize = optimize,
    });
    // 添加 include path 使 yaml.h 中的 #include <yaml.h> 可以解析自身
    yaml_h.addIncludePath(b.path(vendor_dir ++ "/yaml/include"));

    // =======================================================================
    // 库模块 — zigfoundation 基础库
    // =======================================================================

    const lib_module = b.createModule(.{
        .root_source_file = b.path("src/foundation.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_module.addImport("zli", zli_module);

    // libyaml C 源码编译 + 头文件
    lib_module.addCSourceFiles(.{
        .root = b.path(vendor_dir ++ "/yaml/src"),
        .files = yaml_sources,
        .flags = yaml_c_flags,
    });
    lib_module.addIncludePath(b.path(vendor_dir ++ "/yaml/src"));
    lib_module.addIncludePath(b.path(vendor_dir ++ "/yaml/include"));

    // 将 translateC 结果作为 yaml_c 模块导入
    lib_module.addImport("yaml_c", yaml_h.createModule());

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
