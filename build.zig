const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const zigil = b.addModule("zigil", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const test_module = b.createModule(.{
        .root_source_file = b.path("tests/validation.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zigil", .module = zigil }},
    });
    const tests = b.addTest(.{ .root_module = test_module });
    const test_step = b.step("test", "Run public API tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    // The compiler itself verifies that invalid schemas and narrowing input
    // conversions fail for the intended reason.
    inline for (.{
        .{ "missing_field", "Zigil: missing rule for field: age" },
        .{ "unknown_field", "Zigil: rule names an unknown field: typo" },
        .{ "wrong_type", "Zigil: rule type does not match field: age" },
        .{ "bad_bounds", "Zigil: minimum exceeds maximum" },
        .{ "bad_length", "Zigil: minimum length exceeds maximum length" },
        .{ "nan_bound", "Zigil: numeric bounds must be finite" },
        .{ "unknown_enum", "Zigil: enum subset contains an undeclared tag" },
        .{ "integer_overflow", "cannot represent integer value '256'" },
    }) |fixture| {
        const negative = b.addObject(.{
            .name = fixture[0],
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/compile_fail/" ++ fixture[0] ++ ".zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "zigil", .module = zigil }},
            }),
        });
        negative.expect_errors = .{ .contains = fixture[1] };
        test_step.dependOn(&negative.step);
    }
    const check = b.step("check", "Compile public API tests and examples");
    check.dependOn(&tests.step);
    const examples = b.step("examples", "Compile all public examples");
    const run_examples = b.step("run-examples", "Run all public examples");
    inline for (.{"basic"}) |name| {
        const exe = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path("examples/" ++ name ++ ".zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "zigil", .module = zigil }},
            }),
        });
        examples.dependOn(&exe.step);
        run_examples.dependOn(&b.addRunArtifact(exe).step);
    }
    check.dependOn(examples);
    const api_docs = b.addObject(.{ .name = "zigil-docs", .root_module = zigil });
    const install_docs = b.addInstallDirectory(.{
        .source_dir = api_docs.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    b.step("docs", "Generate native API documentation").dependOn(&install_docs.step);
    b.default_step.dependOn(check);
}
