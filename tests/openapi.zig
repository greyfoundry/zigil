const std = @import("std");
const z = @import("zigil");
const a = std.testing.allocator;
const t = std.testing;
test "OpenAPI 3.1 and 3.2 fragments use their shared actual base dialect" {
    var fragment = try z.openapi.exportSchema(z.Optional(z.Int(u8, .{})), a, .{});
    defer fragment.deinit();
    const parsed = try std.json.parseFromSlice(std.json.Value, a, fragment.json, .{});
    defer parsed.deinit();
    try t.expectEqualStrings("https://spec.openapis.org/oas/3.1/dialect/base", parsed.value.object.get("$schema").?.string);
    var compiled = try z.runtime.compile(a, fragment.json, &.{}, .{});
    defer compiled.deinit();
    var result = try compiled.validate(a, "null", .{});
    defer result.deinit();
    try t.expect(result.outcome == .valid);
    var invalid = try compiled.validate(a, "256", .{});
    defer invalid.deinit();
    try t.expect(invalid.outcome == .invalid);
}
test "OpenAPI annotations never change oneOf validation or enforce format" {
    var schema = try z.runtime.compile(a, "{\"$schema\":\"https://spec.openapis.org/oas/3.1/dialect/base\",\"oneOf\":[{\"type\":\"integer\"},{\"type\":\"number\"}],\"discriminator\":{\"propertyName\":\"kind\"},\"format\":\"int32\",\"readOnly\":true}", &.{}, .{});
    defer schema.deinit();
    var result = try schema.validate(a, "1", .{});
    defer result.deinit();
    try t.expect(result.outcome == .invalid);
}
test "OpenAPI export preserves direction and unsupported conversion errors" {
    try t.expectError(error.UnsupportedConversion, z.openapi.exportSchema(z.Float(f64, .{}), a, .{}));
    try t.expectError(error.OutputLimitExceeded, z.openapi.exportSchema(z.Boolean(null), a, .{ .max_output_bytes = 1 }));
}
fn exercise(allocator: std.mem.Allocator) !void {
    var fragment = try z.openapi.exportSchema(z.Int(u128, .{}), allocator, .{});
    defer fragment.deinit();
}
test "OpenAPI fragment allocation failures clean up" {
    try t.checkAllAllocationFailures(a, exercise, .{});
}
