const std = @import("std");
const z = @import("zigil");
const a = std.testing.allocator;
const t = std.testing;
fn check(schema: []const u8, input: []const u8, valid: bool) !void {
    var compiled = try z.runtime.compile(a, schema, &.{}, .{});
    defer compiled.deinit();
    var result = try compiled.validate(a, input, .{});
    defer result.deinit();
    try t.expectEqual(valid, result.outcome == .valid);
}
test "external schema exact numbers, types, Unicode and object equality" {
    try check("{\"type\":\"integer\",\"minimum\":9007199254740993}", "9007199254740993.0", true);
    try check("{\"type\":\"integer\",\"minimum\":9007199254740993}", "9007199254740992", false);
    try check("{\"multipleOf\":0.1}", "0.3", true);
    try check("{\"multipleOf\":0.1}", "0.31", false);
    try check("{\"minLength\":1,\"maxLength\":1}", "\"🎉\"", true);
    try check("{\"uniqueItems\":true}", "[{\"a\":1,\"b\":2},{\"b\":2.0,\"a\":1e0}]", false);
    try check("{\"type\":\"number\"}", "\"3\"", false);
}
test "applicator annotations include all successful branches and discard failures" {
    try check("{\"anyOf\":[{\"properties\":{\"a\":true}},{\"properties\":{\"b\":true}}],\"unevaluatedProperties\":false}", "{\"a\":1,\"b\":2}", true);
    try check("{\"anyOf\":[{\"properties\":{\"a\":true},\"required\":[\"missing\"]},{\"properties\":{\"b\":true}}],\"unevaluatedProperties\":false}", "{\"a\":1,\"b\":2}", false);
    try check("{\"contains\":{\"type\":\"integer\"},\"unevaluatedItems\":false}", "[1,2]", true);
    try check("{\"contains\":{\"type\":\"integer\"},\"unevaluatedItems\":false}", "[1,\"x\"]", false);
    try check("{\"contains\":false,\"minContains\":0,\"unevaluatedItems\":false}", "[1]", false);
}
test "references are explicit, local and adjacent constraints still apply" {
    try check("{\"$defs\":{\"small\":{\"type\":\"integer\"}},\"$ref\":\"#/$defs/small\",\"minimum\":5}", "4", false);
    var schema = try z.runtime.compile(a, "{\"$ref\":\"https://example.org/base\"}", &.{.{ .uri = "https://example.org/base", .schema = "{\"type\":\"boolean\"}" }}, .{});
    defer schema.deinit();
    var result = try schema.validate(a, "true", .{});
    defer result.deinit();
    try t.expect(result.outcome == .valid);
    try t.expectError(error.UnresolvedReference, z.runtime.compile(a, "{\"$ref\":\"https://example.org/missing\"}", &.{}, .{}));
}
test "malformed input, invalid schema and unsupported vocabulary are distinct" {
    try t.expectError(error.InvalidSchema, z.runtime.compile(a, "{\"type\":\"fake\"}", &.{}, .{}));
    try t.expectError(error.MalformedSchema, z.runtime.compile(a, "{", &.{}, .{}));
    try t.expectError(error.DuplicateSchemaKey, z.runtime.compile(a, "{\"type\":\"string\",\"type\":\"number\"}", &.{}, .{}));
    try t.expectError(error.UnsupportedVocabulary, z.runtime.compile(a, "{\"$vocabulary\":{\"https://example.org/unknown\":true}}", &.{}, .{}));
    try check("{\"$vocabulary\":{\"https://example.org/unknown\":false}}", "true", true);
    var schema = try z.runtime.compile(a, "true", &.{}, .{});
    defer schema.deinit();
    var result = try schema.validate(a, "{", .{});
    defer result.deinit();
    try t.expect(result.outcome == .malformed);
}
test "runtime diagnostics include paths, keyword and schema location" {
    var schema = try z.runtime.compile(a, "{\"properties\":{\"a/~\":{\"minimum\":5}}}", &.{}, .{});
    defer schema.deinit();
    var result = try schema.validate(a, "{\"a/~\":4}", .{});
    defer result.deinit();
    var buffer: [100]u8 = undefined;
    try t.expectEqualStrings("/a~1~0", try result.outcome.invalid.issue.jsonPointer(&buffer));
    try t.expectEqualStrings("minimum", result.outcome.invalid.keyword);
    try t.expect(std.mem.endsWith(u8, result.outcome.invalid.schema_location, "/properties/a~1~0/minimum"));
}
test "runtime traversal and reference cycles exhaust budgets operationally" {
    var schema = try z.runtime.compile(a, "{\"$ref\":\"#\"}", &.{}, .{});
    defer schema.deinit();
    try t.expectError(error.DepthLimitExceeded, schema.validate(a, "true", .{ .max_depth = 8 }));
    try t.expectError(error.WorkLimitExceeded, schema.validate(a, "true", .{ .max_work = 1 }));
    try t.expectError(error.AllocationLimitExceeded, schema.validate(a, "true", .{ .json = .{ .max_allocated_bytes = 1 } }));
}
fn exercise(allocator: std.mem.Allocator) !void {
    var schema = try z.runtime.compile(allocator, "{\"allOf\":[{\"properties\":{\"x\":{\"multipleOf\":0.1}}}],\"unevaluatedProperties\":false}", &.{}, .{});
    defer schema.deinit();
    var good = try schema.validate(allocator, "{\"x\":0.3}", .{});
    defer good.deinit();
    try t.expect(good.outcome == .valid);
    var bad = try schema.validate(allocator, "{\"x\":0.31}", .{});
    defer bad.deinit();
    try t.expect(bad.outcome == .invalid);
}
test "runtime compilation, references, decimals and findings clean up every allocation failure" {
    try t.checkAllAllocationFailures(a, exercise, .{});
}
test "optional regex engine is explicit and checks Unicode properties with bounded work" {
    if (!z.runtime.regex_enabled) {
        try t.expectError(error.PatternEngineUnavailable, z.runtime.compile(a, "{\"pattern\":\"a\"}", &.{}, .{}));
        return;
    }
    try check("{\"pattern\":\"^\\\\p{Letter}+$\"}", "\"π\"", true);
    try check("{\"pattern\":\"^a*$\"}", "\"aaa\"", true);
    try check("{\"pattern\":\"^a*$\"}", "\"abc\"", false);
    try check("{\"pattern\":\"^.$\"}", "\"\r\"", false);
}

test "findings survive compiled schema destruction, including absent schema-named fields" {
    var schema = try z.runtime.compile(a, "{\"required\":[\"secret~name\"]}", &.{}, .{});
    var result = try schema.validate(a, "{}", .{});
    schema.deinit();
    defer result.deinit();
    var buffer: [64]u8 = undefined;
    try t.expectEqualStrings("/secret~0name", try result.outcome.invalid.issue.jsonPointer(&buffer));
    try t.expectEqualStrings("required", result.outcome.invalid.keyword);
}
test "custom offline vocabularies disable undeclared assertions and reject unknown required semantics" {
    const meta = "{\"$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"$vocabulary\":{\"https://json-schema.org/draft/2020-12/vocab/core\":true,\"https://json-schema.org/draft/2020-12/vocab/applicator\":true}}";
    var schema = try z.runtime.compile(a, "{\"$schema\":\"https://example.org/meta\",\"properties\":{\"x\":{\"minimum\":5}}}", &.{.{ .uri = "https://example.org/meta", .schema = meta }}, .{});
    defer schema.deinit();
    var result = try schema.validate(a, "{\"x\":1}", .{});
    defer result.deinit();
    try t.expect(result.outcome == .valid);
}
test "schema compilation has independent node, work, URI and registry budgets" {
    try t.expectError(error.WorkLimitExceeded, z.runtime.compile(a, "{}", &.{}, .{ .max_work = 0 }));
    try t.expectError(error.SchemaNodeLimitExceeded, z.runtime.compile(a, "{\"properties\":{\"x\":true}}", &.{}, .{ .max_schema_nodes = 1 }));
    try t.expectError(error.RegistryLimitExceeded, z.runtime.compile(a, "{}", &.{.{ .uri = "https://example.org/x", .schema = "true" }}, .{ .max_registry_entries = 0 }));
    try t.expectError(error.RegistryLimitExceeded, z.runtime.compile(a, "{}", &.{.{ .uri = "https://example.org/x", .schema = "true" }}, .{ .max_registry_bytes = 1 }));
    try t.expectError(error.AllocationLimitExceeded, z.runtime.compile(a, "{}", &.{}, .{ .json = .{ .max_allocated_bytes = 1 } }));
    const uri = try a.alloc(u8, 16_385);
    defer a.free(uri);
    @memset(uri, 'x');
    try t.expectError(error.UriLimitExceeded, z.runtime.compile(a, "{}", &.{}, .{ .base_uri = uri }));
}
fn exerciseRegex(allocator: std.mem.Allocator) !void {
    var schema = try z.runtime.compile(allocator, "{\"pattern\":\"^[a-z]+$\"}", &.{}, .{});
    defer schema.deinit();
    var result = try schema.validate(allocator, "\"abc\"", .{});
    defer result.deinit();
    try t.expect(result.outcome == .valid);
}
test "NFA compilation and scratch allocation failures never panic or leak" {
    if (!z.runtime.regex_enabled) return;
    try t.checkAllAllocationFailures(a, exerciseRegex, .{});
    try t.expectError(error.UnsupportedPattern, z.runtime.compile(a, "{\"pattern\":\"(?=secret)\"}", &.{}, .{}));
    var schema = try z.runtime.compile(a, "{\"pattern\":\"a\"}", &.{}, .{});
    defer schema.deinit();
    try t.expectError(error.WorkLimitExceeded, schema.validate(a, "\"a\"", .{ .max_work = 1 }));
}

test "malformed URI references fail before registry or pointer resolution" {
    inline for (.{ "{\"$ref\":\"https://example.org/%zz\"}", "{\"$id\":\"https://example.org/has space\"}", "{\"$ref\":\"#/%\"}" }) |source| {
        try t.expectError(error.InvalidSchemaUri, z.runtime.compile(a, source, &.{}, .{}));
    }
}
