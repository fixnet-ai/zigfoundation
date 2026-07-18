const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ---- 公开模块 "yaml_c" — 依赖方通过 dep.module("yaml_c") 获取 ----
    const yaml_c_mod = b.addModule("yaml_c", .{
        .root_source_file = b.path("yaml_c.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ---- translate-c: yaml.h → Zig 类型绑定 ----
    const yaml_h = b.addTranslateC(.{
        .root_source_file = b.path("include/yaml.h"),
        .target = b.resolveTargetQuery(.{}), // native target，类型定义跨平台通用
        .optimize = optimize,
    });
    yaml_h.addIncludePath(b.path("include"));
    yaml_c_mod.addImport("yaml_h_internal", yaml_h.createModule());

    // ---- 编译 libyaml C 源码 ----
    yaml_c_mod.addCSourceFiles(.{
        .root = b.path("src"),
        .files = &.{
            "api.c",    "dumper.c", "emitter.c", "loader.c",
            "parser.c", "reader.c", "scanner.c", "writer.c",
        },
        .flags = &.{
            "-O3",
            "-std=gnu11",
            "-DYAML_VERSION_MAJOR=0",
            "-DYAML_VERSION_MINOR=2",
            "-DYAML_VERSION_PATCH=5",
            "-DYAML_VERSION_STRING=\"0.2.5\"",
        },
    });
    yaml_c_mod.addIncludePath(b.path("src"));
    yaml_c_mod.addIncludePath(b.path("include"));
}
