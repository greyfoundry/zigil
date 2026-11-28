const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const schema_regex = b.option(bool, "schema-regex", "Enable optional native regex") orelse false;
    const dependency = b.dependency("zigil", .{ .target = target, .optimize = optimize, .@"schema-regex" = schema_regex });
    const exe = b.addExecutable(.{
        .name = "consumer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zigil", .module = dependency.module("zigil") }},
        }),
    });
    b.step("check", "Compile the independent consumer").dependOn(&exe.step);
    b.default_step.dependOn(&b.addRunArtifact(exe).step);
}
