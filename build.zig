const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // 交叉编译 sysroot 选项 (iOS: xcrun --sdk iphonesimulator --show-sdk-path; Android: $NDK/.../sysroot)
    const sysroot = b.option([]const u8, "sysroot", "交叉编译时使用的 sysroot 路径 (iOS SDK / Android NDK)");
    if (sysroot) |s| {
        b.sysroot = s;
    }

    // 自定义 libc 配置文件 (Android 交叉编译需要，指向 NDK Bionic)
    const libc_file_opt = b.option([]const u8, "libc-file", "libc 配置文件路径 (Android: 指向 NDK Bionic)");

    // =======================================================================
    // 外部依赖
    // =======================================================================

    const zli_dep = b.dependency("zli", .{});
    const zli_module = zli_dep.module("zli");

    const yaml_dep = b.dependency("yaml", .{});

    // =======================================================================
    // 库模块 — zigfoundation 基础库
    // =======================================================================

    const lib_module = b.createModule(.{
        .root_source_file = b.path("src/foundation.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_module.addImport("zli", zli_module);
    lib_module.addImport("yaml_c", yaml_dep.module("yaml_c"));

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

    // =======================================================================
    // Phase 6: 示例程序 — 三个平台的集成测试
    // =======================================================================

    // ---- 示例：CLI 桌面程序 (macOS/Linux/Windows) ----
    const example_cli_mod = b.createModule(.{
        .root_source_file = b.path("examples/cli/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    example_cli_mod.addImport("foundation", lib_module);

    const example_cli = b.addExecutable(.{
        .name = "zigfoundation-example-cli",
        .root_module = example_cli_mod,
    });
    const example_cli_install = b.addInstallArtifact(example_cli, .{});
    const example_cli_step = b.step("example-cli", "构建 CLI 示例程序，集成测试所有 13 模块");
    example_cli_step.dependOn(&example_cli_install.step);

    // ---- 示例：iOS 静态库 (aarch64-ios-simulator / x86_64-ios-simulator) ----
    const example_ios_mod = b.createModule(.{
        .root_source_file = b.path("examples/ios/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    example_ios_mod.addImport("foundation", lib_module);

    // 交叉编译时添加 sysroot include path
    if (sysroot) |s| {
        const sysroot_include = b.pathJoin(&.{ s, "usr", "include" });
        example_ios_mod.addSystemIncludePath(.{ .cwd_relative = sysroot_include });
    }

    const example_ios = b.addLibrary(.{
        .name = "zigfoundation-example-ios",
        .linkage = .static,
        .root_module = example_ios_mod,
    });
    const example_ios_install = b.addInstallArtifact(example_ios, .{});
    const example_ios_step = b.step("example-ios", "构建 iOS 示例静态库 (用于 Xcode 集成)");
    example_ios_step.dependOn(&example_ios_install.step);

    // ---- 示例：Android 共享库 (aarch64-linux-android / x86_64-linux-android) ----
    const example_android_mod = b.createModule(.{
        .root_source_file = b.path("examples/android/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    example_android_mod.addImport("foundation", lib_module);

    // 交叉编译时添加 sysroot include path
    if (sysroot) |s| {
        const sysroot_include = b.pathJoin(&.{ s, "usr", "include" });
        example_android_mod.addSystemIncludePath(.{ .cwd_relative = sysroot_include });
    }

    const example_android = b.addLibrary(.{
        .name = "zigfoundation-example-android",
        .linkage = .dynamic,
        .root_module = example_android_mod,
    });
    if (libc_file_opt) |lf| {
        example_android.setLibCFile(.{ .cwd_relative = lf });
    }
    const example_android_install = b.addInstallArtifact(example_android, .{});
    const example_android_step = b.step("example-android", "构建 Android 示例共享库 (用于 JNI 集成)");
    example_android_step.dependOn(&example_android_install.step);
}
