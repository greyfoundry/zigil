const std = @import("std");
const z = @import("zigil");
const a = std.testing.allocator;
const t = std.testing;
const Text = z.String(.{});
const Count = z.Int(u16, .{ .min = 1 });
const Pair = z.Tuple(.{ Text, Count });
const Choice = union(enum) { name: []const u8, counts: []const u16 };
const ChoiceRule = z.Union(Choice, .{ .name = Text, .counts = z.Slice(Count, .{}) });
const Labels = z.Map(z.String(.{ .length = .{ .min = 1 } }), Count, .{ .max = 3 });

fn expectInvalid(comptime Rule: type, input: []const u8, code: z.Code, pointer: []const u8) !void {
    var result = try z.decodeJson(Rule, a, input, .{});
    defer result.deinit();
    try t.expect(result.outcome == .invalid);
    try t.expectEqual(code, result.outcome.invalid.code);
    var buffer: [128]u8 = undefined;
    try t.expectEqualStrings(pointer, try result.outcome.invalid.jsonPointer(&buffer));
}

test "tuple owns its fields, preserves types, and uses array paths" {
    var result = try z.decodeJson(Pair, a, "[\"hello\",7]", .{});
    defer result.deinit();
    try t.expectEqualStrings("hello", result.outcome.valid[0]);
    try t.expectEqual(@as(u16, 7), result.outcome.valid[1]);
    try expectInvalid(Pair, "[\"hello\",0]", .below_minimum, "/1");
    try expectInvalid(Pair, "[\"hello\"]", .type_mismatch, "");
}

test "tagged unions never guess variants or ignore unknown members" {
    var result = try z.decodeJson(ChoiceRule, a, "{\"tag\":\"counts\",\"value\":[1,2]}", .{});
    defer result.deinit();
    try t.expectEqual(@as(u16, 2), result.outcome.valid.counts[1]);
    try expectInvalid(ChoiceRule, "{\"tag\":\"counts\",\"value\":[0]}", .below_minimum, "/value/0");
    try expectInvalid(ChoiceRule, "{\"tag\":\"unknown\",\"value\":0}", .union_tag, "/tag");
    try expectInvalid(ChoiceRule, "{\"tag\":\"name\"}", .missing_field, "/value");
    try expectInvalid(ChoiceRule, "{\"tag\":\"name\",\"value\":\"x\",\"extra\":true}", .unknown_field, "/extra");
}

test "map validates keys, values, cardinality and escaped key paths" {
    var result = try z.decodeJson(Labels, a, "{\"a\":1,\"b\":2}", .{});
    defer result.deinit();
    try t.expectEqual(@as(u16, 2), result.outcome.valid.get("b").?);
    try expectInvalid(Labels, "{\"\":1}", .too_short, "/");
    try expectInvalid(Labels, "{\"a/~\":0}", .below_minimum, "/a~1~0");
    try expectInvalid(Labels, "{\"a\":1,\"b\":1,\"c\":1,\"d\":1}", .too_long, "");
}

const Window = struct { start: u16, end: u16 };
fn ordered(window: Window) bool {
    return window.start < window.end;
}
const WindowRule = z.Refine(z.Struct(Window, .{ .start = Count, .end = Count }), ordered, "start must precede end");

test "cross-field refinement runs after prerequisite validation" {
    try expectInvalid(WindowRule, "{\"start\":0,\"end\":2}", .below_minimum, "/start");
    try expectInvalid(WindowRule, "{\"start\":5,\"end\":2}", .custom, "");
}

test "defaults apply only to absent fields and remain constrained" {
    const Config = struct { port: u16 };
    const Rule = z.Struct(Config, .{ .port = z.Default(Count, 443) });
    var result = try z.decodeJson(Rule, a, "{}", .{});
    defer result.deinit();
    try t.expectEqual(@as(u16, 443), result.outcome.valid.port);
    try expectInvalid(Rule, "{\"port\":null}", .type_mismatch, "/port");
    try expectInvalid(Rule, "{\"port\":0}", .below_minimum, "/port");
    try expectInvalid(z.Struct(Config, .{ .port = z.Default(Count, 0) }), "{}", .below_minimum, "/port");
}

fn uppercase(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    const output = try allocator.dupe(u8, input);
    for (output) |*byte| byte.* = std.ascii.toUpper(byte.*);
    return output;
}
const Upper = z.Transform(Text, z.String(.{ .prefix = "HI" }), uppercase);

test "explicit transforms own output and validate input and output" {
    var result = try z.decodeJson(Upper, a, "\"hi there\"", .{});
    defer result.deinit();
    try t.expectEqualStrings("HI THERE", result.outcome.valid);
    try expectInvalid(Upper, "0", .type_mismatch, "");
    try expectInvalid(Upper, "\"bye\"", .prefix, "");
    const Wrapper = struct { value: []const u8 };
    const Wrapped = z.Struct(Wrapper, .{ .value = z.Transform(z.String(.{ .length = .{ .min = 1 } }), Text, uppercase) });
    try expectInvalid(Wrapped, "{\"value\":\"\"}", .too_short, "/value");
}

fn unavailable(_: std.mem.Allocator, _: []const u8) error{Unavailable}![]const u8 {
    return error.Unavailable;
}
test "transform operational errors propagate without becoming invalidity" {
    try t.expectError(error.Unavailable, z.decodeJson(z.Transform(Text, Text, unavailable), a, "\"x\"", .{}));
}

const Node = struct { value: u16, children: []const Node };
fn nodeRule() type {
    return z.Struct(Node, .{ .value = Count, .children = z.Slice(z.Recursive(Node, nodeRule), .{}) });
}
const Tree = z.Recursive(Node, nodeRule);

test "recursive native schema decodes, validates and enforces bounds" {
    var result = try z.decodeJson(Tree, a, "{\"value\":1,\"children\":[{\"value\":2,\"children\":[]}]}", .{});
    defer result.deinit();
    try t.expectEqual(@as(u16, 2), result.outcome.valid.children[0].value);
    try expectInvalid(Tree, "{\"value\":1,\"children\":[{\"value\":0,\"children\":[]}]}", .below_minimum, "/children/0/value");
    var path: [32]z.Segment = undefined;
    try t.expectError(error.DepthLimitExceeded, z.validateWithLimits(Tree, result.outcome.valid, &path, .{ .max_depth = 2 }));
    // Cyclic borrowed native values terminate at the same traversal budget.
    var cycle: [1]Node = .{.{ .value = 1, .children = undefined }};
    cycle[0].children = &cycle;
    try t.expectError(error.DepthLimitExceeded, z.validateWithLimits(Tree, cycle[0], &path, .{ .max_depth = 8 }));
}

test "Unicode code-point constraints differ explicitly from byte constraints" {
    var path: [1]z.Segment = undefined;
    try t.expectEqual(@as(?z.Issue, null), try z.validate(z.String(.{ .unit = .code_points, .length = .{ .max = 1 } }), "🎉", &path));
    try t.expectEqual(z.Code.too_long, (try z.validate(z.String(.{ .length = .{ .max = 1 } }), "🎉", &path)).?.code);
}

fn exercise(allocator: std.mem.Allocator) !void {
    inline for (.{
        .{ Pair, "[\"hello\",7]" },
        .{ ChoiceRule, "{\"tag\":\"counts\",\"value\":[1,2]}" },
        .{ Labels, "{\"a\":1,\"b\":2}" },
        .{ Upper, "\"hi there\"" },
        .{ Tree, "{\"value\":1,\"children\":[{\"value\":2,\"children\":[]}]}" },
    }) |item| {
        var result = try z.decodeJson(item[0], allocator, item[1], .{});
        defer result.deinit();
        try t.expect(result.outcome == .valid);
    }
}
test "all composition allocations clean up at every failure point" {
    try t.checkAllAllocationFailures(a, exercise, .{});
}

test "named formats check local syntax without network or normalization" {
    inline for (.{
        .{ z.Format.uuid, "00000000-0000-0000-0000-000000000000", "00000000-0000-0000-0000-00000000000x" },
        .{ z.Format.ipv4, "192.0.2.1", "192.0.2.256" },
        .{ z.Format.ipv6, "2001:db8::1", "fe80::1%eth0" },
        .{ z.Format.uri, "https://example.org/a%20b?q=1", "https://example.org/a b" },
    }) |case| {
        var path: [1]z.Segment = undefined;
        try t.expectEqual(@as(?z.Issue, null), try z.validate(z.Formatted(case[0]), case[1], &path));
        try t.expectEqual(z.Code.invalid_format, (try z.validate(z.Formatted(case[0]), case[2], &path)).?.code);
    }
}

test "code-point scans consume a separate bounded pass" {
    const Rule = z.String(.{ .unit = .code_points });
    var path: [1]z.Segment = undefined;
    try t.expectError(error.WorkLimitExceeded, z.validateWithLimits(Rule, "a", &path, .{ .max_work = 2 }));
    try t.expectEqual(@as(?z.Issue, null), try z.validateWithLimits(Rule, "a", &path, .{ .max_work = 3 }));
}
test "rendering a native borrowed map path creates an independent text copy" {
    var map: Labels.Value = .empty;
    defer map.deinit(a);
    const key = try a.dupe(u8, "a/~");
    var released = false;
    defer if (!released) a.free(key);
    try map.put(a, key, 0);
    var path: [2]z.Segment = undefined;
    const finding = (try z.validate(Labels, map, &path)).?;
    var buffer: [32]u8 = undefined;
    const pointer = try finding.jsonPointer(&buffer);
    a.free(key);
    released = true;
    try t.expectEqualStrings("/a~1~0", pointer);
}

test "binary native map keys cannot be silently rendered as Unicode JSON Pointers" {
    const Bytes = z.Map(z.String(.{ .utf8 = false }), Count, .{});
    var map: Bytes.Value = .empty;
    defer map.deinit(a);
    try map.put(a, "\xff", 0);
    var path: [2]z.Segment = undefined;
    const finding = (try z.validate(Bytes, map, &path)).?;
    var buffer: [32]u8 = undefined;
    try t.expectError(error.InvalidUtf8, finding.jsonPointer(&buffer));
}
