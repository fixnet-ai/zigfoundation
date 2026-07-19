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
    const libxev_dep = b.dependency("libxev", .{});

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
    lib_module.addImport("xev", libxev_dep.module("xev"));

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

    // test-build: 编译测试并安装到 zig-out/bin/（用于交叉编译）
    const test_install = b.addInstallArtifact(lib_tests, .{});
    const test_build_step = b.step("test-build", "编译测试二进制 (不运行，用于交叉编译)");
    test_build_step.dependOn(&test_install.step);

    // test: 直接运行已安装的测试二进制（terminal 模式，避免 --listen=- 模式
    // 与 libxev 事件循环 / 跨线程测试的兼容性问题导致 hang）。
    const test_run = b.addSystemCommand(&.{
        b.pathJoin(&.{ b.install_path, "bin", "zigfoundation-tests" }),
    });
    test_run.step.dependOn(&test_install.step);
    const test_step = b.step("test", "运行所有单元测试");
    test_step.dependOn(&test_run.step);

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
    const example_cli_step = b.step("example-cli", "构建 CLI 示例程序，集成测试所有 14 模块");
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

    // ---- iOS 模拟器 CLI 测试 (可直接通过 simctl spawn 运行) ----
    const ios_test_mod = b.createModule(.{
        .root_source_file = b.path("examples/ios/test_runner.zig"),
        .target = target,
        .optimize = optimize,
    });
    ios_test_mod.addImport("foundation", lib_module);
    if (sysroot) |s| {
        const sysroot_include = b.pathJoin(&.{ s, "usr", "include" });
        ios_test_mod.addSystemIncludePath(.{ .cwd_relative = sysroot_include });
        // Zig 交叉链接 iOS exe/dylib 不会自动在 sysroot 下查找 libSystem.tbd。
        // 显式 -L/usr/lib：MachO linker 会自动加 sysroot 前缀 → <sysroot>/usr/lib
        ios_test_mod.addLibraryPath(.{ .cwd_relative = "/usr/lib" });
    }

    const ios_test_exe = b.addExecutable(.{
        .name = "zigfoundation-ios-test",
        .root_module = ios_test_mod,
    });
    const ios_test_install = b.addInstallArtifact(ios_test_exe, .{});
    const ios_test_step = b.step("ios-test-runner", "构建 iOS 模拟器 CLI 测试 (simctl spawn 运行)");
    ios_test_step.dependOn(&ios_test_install.step);

    // ---- iOS 模拟器动态库 (swiftc 链接用，避免静态库 .o 对齐问题) ----
    const ios_dylib = b.addLibrary(.{
        .name = "zigfoundation-ios-dylib",
        .linkage = .dynamic,
        .root_module = ios_test_mod,
    });
    const ios_dylib_install = b.addInstallArtifact(ios_dylib, .{});
    ios_test_step.dependOn(&ios_dylib_install.step);

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

    // ---- Android 可执行测试 (通过 adb push + shell 直接运行) ----
    const android_test_mod = b.createModule(.{
        .root_source_file = b.path("examples/android/test_runner.zig"),
        .target = target,
        .optimize = optimize,
    });
    android_test_mod.addImport("foundation", lib_module);
    if (sysroot) |s| {
        const sysroot_include = b.pathJoin(&.{ s, "usr", "include" });
        android_test_mod.addSystemIncludePath(.{ .cwd_relative = sysroot_include });
    }

    const android_test_exe = b.addExecutable(.{
        .name = "zigfoundation-android-test",
        .root_module = android_test_mod,
        .linkage = .dynamic, // Android 使用动态链接 (Bionic linker64)
    });
    if (libc_file_opt) |lf| {
        android_test_exe.setLibCFile(.{ .cwd_relative = lf });
    }
    if (sysroot) |s| {
        android_test_exe.root_module.addObjectFile(.{ .cwd_relative = b.pathJoin(&.{ s, "usr", "lib", "aarch64-linux-android", "liblog.so" }) });
    }
    const android_test_install = b.addInstallArtifact(android_test_exe, .{});
    const android_test_step = b.step("android-test", "构建 Android 可执行测试 (adb push + shell 运行)");
    android_test_step.dependOn(&android_test_install.step);
}
