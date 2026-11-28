const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const zigil = b.addModule("zigil", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const regex_enabled = b.option(bool, "schema-regex", "Enable the optional native bounded JSON Schema pattern backend") orelse false;
    const features = b.addOptions();
    features.addOption(bool, "schema_regex", regex_enabled);
    zigil.addOptions("features", features);
    if (regex_enabled) {
        if (b.lazyDependency("ezi_gex", .{ .target = target, .optimize = optimize })) |regex|
            zigil.addImport("ezi_gex", regex.module("ezi_gex"));
    }
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
        .{ "wrong_custom", "Zigil: custom predicate must return bool or an error union of bool" },
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
    inline for (.{ "basic", "json", "schema" }) |name| {
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
    const oracle = b.addExecutable(.{
        .name = "schema-oracle",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/export_cases.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zigil", .module = zigil }},
        }),
    });
    b.step("schema-oracle", "Emit independent schema export fixtures").dependOn(&b.addRunArtifact(oracle).step);
    const conformance = b.addExecutable(.{
        .name = "conformance",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/conformance.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zigil", .module = zigil }},
        }),
    });
    b.step("conformance", "Run pinned official Draft 2020-12 fixtures").dependOn(&b.addRunArtifact(conformance).step);
    const api_docs = b.addObject(.{ .name = "zigil-docs", .root_module = zigil });
    const install_docs = b.addInstallDirectory(.{
        .source_dir = api_docs.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    b.step("docs", "Generate native API documentation").dependOn(&install_docs.step);
    b.default_step.dependOn(check);
}
