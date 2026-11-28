const std = @import("std");
const z = @import("zigil");
const a = std.testing.allocator;
const t = std.testing;
const Text = z.String(.{ .unit = .code_points, .length = .{ .min = 1, .max = 8 } });
const Config = struct { name: []const u8, port: u16, enabled: z.Presence(bool) };
const Rule = z.Struct(Config, .{
    .name = Text,
    .port = z.Default(z.Int(u16, .{ .min = 1 }), 443),
    .enabled = z.Field(z.Boolean(null), .{ .optional = true, .nullable = true }),
});

test "deterministic export represents strict fields, presence and defaults" {
    var first = try z.exportSchema(Rule, a, .{});
    defer first.deinit();
    var second = try z.exportSchema(Rule, a, .{});
    defer second.deinit();
    try t.expectEqualStrings(first.json, second.json);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, first.json, .{});
    defer parsed.deinit();
    const object = parsed.value.object;
    try t.expectEqualStrings(z.schema.dialect, object.get("$schema").?.string);
    try t.expectEqual(@as(usize, 1), object.get("required").?.array.items.len);
    try t.expectEqual(@as(i64, 443), object.get("properties").?.object.get("port").?.object.get("default").?.integer);
    var output = try z.exportSchema(Rule, a, .{ .direction = .output });
    defer output.deinit();
    const result = try std.json.parseFromSlice(std.json.Value, a, output.json, .{});
    defer result.deinit();
    try t.expectEqual(@as(usize, 2), result.value.object.get("required").?.array.items.len);
    try t.expect(result.value.object.get("properties").?.object.get("port").?.object.get("default") == null);
}

fn yes(_: []const u8) bool {
    return true;
}
test "unrepresentable native constraints fail rather than disappearing" {
    inline for (.{
        z.String(.{ .length = .{ .min = 1 } }),
        z.String(.{ .utf8 = false }),
        z.String(.{ .prefix = "a" }),
        z.Float(f64, .{}),
        z.Custom([]const u8, yes, "custom"),
        z.Refine(z.String(.{}), yes, "custom"),
        z.Formatted(.uuid),
    }) |Unsupported| try t.expectError(error.UnsupportedConversion, z.exportSchema(Unsupported, a, .{}));
}
const Node = struct { name: []const u8, children: []const Node };
fn node() type {
    return z.Struct(Node, .{ .name = Text, .children = z.Slice(z.Recursive(Node, node), .{}) });
}
test "recursive rules export bounded reusable definitions" {
    var result = try z.exportSchema(z.Recursive(Node, node), a, .{});
    defer result.deinit();
    const parsed = try std.json.parseFromSlice(std.json.Value, a, result.json, .{});
    defer parsed.deinit();
    try t.expectEqualStrings("#/$defs/schema_0", parsed.value.object.get("$ref").?.string);
    try t.expectEqual(@as(usize, 1), parsed.value.object.get("$defs").?.object.count());
}

test "tuple, map, enum, union and array exports use valid schemas" {
    const Mode = enum { one, two };
    const Choice = union(enum) { left: bool, right: u8 };
    inline for (.{
        z.Tuple(.{ Text, z.Boolean(true) }),
        z.Tuple(.{}),
        z.Map(Text, z.Int(u8, .{}), .{ .max = 3 }),
        z.Enumeration(Mode, null),
        z.Enumeration(Mode, &.{}),
        z.Union(Choice, .{ .left = z.Boolean(null), .right = z.Int(u8, .{}) }),
        z.Array(2, z.Optional(z.Int(u128, .{}))),
    }) |Supported| {
        var result = try z.exportSchema(Supported, a, .{});
        defer result.deinit();
        try t.expect(result.json.len > 0);
    }
}

test "export budgets and invalid defaults remain operational errors" {
    try t.expectError(error.OutputLimitExceeded, z.exportSchema(Rule, a, .{ .max_output_bytes = 1 }));
    try t.expectError(error.SchemaNodeLimitExceeded, z.exportSchema(Rule, a, .{ .max_nodes = 1 }));
    try t.expectError(error.DepthLimitExceeded, z.exportSchema(Rule, a, .{ .max_depth = 1 }));
    try t.expectError(error.AllocationLimitExceeded, z.exportSchema(Rule, a, .{ .max_allocated_bytes = 1 }));
    try t.expectError(error.InvalidDefault, z.exportSchema(z.Default(z.Int(u8, .{ .min = 1 }), 0), a, .{}));
}
fn exercise(allocator: std.mem.Allocator) !void {
    var result = try z.exportSchema(z.Recursive(Node, node), allocator, .{});
    defer result.deinit();
}
test "export frees all partially built schemas at every allocation failure" {
    try t.checkAllAllocationFailures(a, exercise, .{});
}

test "presence wrappers outside a direct field or wrapping nullable native values never lose wire constraints" {
    const Present = z.Field(z.Boolean(null), .{ .optional = true, .nullable = true });
    const Nested = struct { flag: z.Presence(Present.Value) };
    inline for (.{
        Present,
        z.Optional(Present),
        z.Struct(Nested, .{ .flag = z.Field(z.Field(z.Boolean(null), .{ .nullable = true }), .{}) }),
    }) |UnsupportedRule| try t.expectError(error.UnsupportedConversion, z.exportSchema(UnsupportedRule, a, .{}));
}
