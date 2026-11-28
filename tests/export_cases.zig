//! Executable differential fixtures: native decoding supplies expected results.
const std = @import("std");
const z = @import("zigil");
const a = std.heap.page_allocator;
const Text = z.String(.{ .unit = .code_points, .length = .{ .min = 1, .max = 3 } });
const Config = struct { name: []const u8, count: u8, note: z.Presence([]const u8) };
const Rule = z.Struct(Config, .{
    .name = Text,
    .count = z.Default(z.Int(u8, .{ .min = 1 }), 2),
    .note = z.Field(Text, .{ .optional = true, .nullable = true }),
});
const Node = struct { name: []const u8, children: []const Node };
fn node() type {
    return z.Struct(Node, .{ .name = Text, .children = z.Slice(z.Recursive(Node, node), .{}) });
}
fn cases(comptime R: type, inputs: []const []const u8) !void {
    var schema = try z.exportSchema(R, a, .{});
    defer schema.deinit();
    for (inputs) |input| {
        var result = try z.decodeJson(R, a, input, .{});
        defer result.deinit();
        std.debug.print("{{\"schema\":{s},\"data\":{s},\"valid\":{s}}}\n", .{ schema.json, input, if (result.outcome == .valid) "true" else "false" });
    }
}
pub fn main() !void {
    try cases(Rule, &.{
        "{\"name\":\"🎉\"}",
        "{\"name\":\"abcd\"}",
        "{\"name\":\"a\",\"count\":255}",
        "{\"name\":\"a\",\"count\":256}",
        "{\"name\":\"a\",\"count\":0}",
        "{\"name\":\"a\",\"note\":null}",
        "{\"name\":\"a\",\"note\":\"\"}",
        "{\"name\":\"a\",\"note\":\"x\"}",
        "{\"name\":\"a\",\"extra\":true}",
        "{\"name\":\"a\",\"count\":\"1\"}",
        "{\"name\":\"a\",\"count\":null}",
        "{}",
    });
    try cases(z.Tuple(.{ Text, z.Boolean(true) }), &.{ "[\"x\",true]", "[\"\",true]", "[\"x\",false]", "[\"x\",true,1]", "[\"x\"]", "{}" });
    const Choice = union(enum) { left: bool, right: u8 };
    try cases(z.Union(Choice, .{ .left = z.Boolean(null), .right = z.Int(u8, .{}) }), &.{ "{\"tag\":\"left\",\"value\":false}", "{\"tag\":\"right\",\"value\":256}", "{\"tag\":\"wrong\",\"value\":0}", "{\"tag\":\"right\",\"value\":1}" });
    try cases(z.Map(Text, z.Int(u8, .{}), .{ .max = 2 }), &.{ "{}", "{\"a\":1}", "{\"\":1}", "{\"a\":256}", "{\"a\":1,\"b\":2,\"c\":3}" });
    try cases(z.Recursive(Node, node), &.{ "{\"name\":\"a\",\"children\":[{\"name\":\"b\",\"children\":[]}]}", "{\"name\":\"a\",\"children\":[{\"name\":\"\",\"children\":[]}]}", "{\"name\":\"a\"}" });
    try cases(z.Int(u128, .{}), &.{ "340282366920938463463374607431768211455", "340282366920938463463374607431768211456", "-1", "0" });
}
