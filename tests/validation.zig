const std = @import("std");
const z = @import("zigil");
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const strings = std.testing.expectEqualStrings;

test "UTF-8 strings use byte lengths with inclusive limits" {
    const Rule = z.String(.{ .length = .{ .min = 2, .max = 4 } });
    var path: [0]z.Segment = .{};
    try expect((try z.validate(Rule, "é", &path)) == null);
    try expect((try z.validate(Rule, "four", &path)) == null);
    try equal(z.Code.too_short, (try z.validate(Rule, "x", &path)).?.code);
    try equal(z.Code.too_long, (try z.validate(Rule, "12345", &path)).?.code);
    try equal(z.Code.invalid_utf8, (try z.validate(Rule, "\xc0\x80", &path)).?.code);
    try equal(z.Code.invalid_utf8, (try z.validate(Rule, "\xed\xa0\x80", &path)).?.code);
    try expect((try z.validate(z.String(.{ .utf8 = false }), "\xff", &path)) == null);
}

test "prefix suffix empty strings and embedded NUL" {
    const Rule = z.String(.{ .prefix = "pre", .suffix = "end" });
    var path: [0]z.Segment = .{};
    try expect((try z.validate(Rule, "pre-end", &path)) == null);
    try equal(z.Code.prefix, (try z.validate(Rule, "end", &path)).?.code);
    try equal(z.Code.suffix, (try z.validate(Rule, "pre", &path)).?.code);
    try expect((try z.validate(z.String(.{}), "", &path)) == null);
    try expect((try z.validate(z.String(.{}), "a\x00b", &path)) == null);
}

test "integer bounds include endpoints and do not do overflow-prone arithmetic" {
    var path: [0]z.Segment = .{};
    const Rule = z.Int(i8, .{ .min = -5, .max = 5 });
    try expect((try z.validate(Rule, -5, &path)) == null);
    try expect((try z.validate(Rule, 5, &path)) == null);
    try equal(z.Code.below_minimum, (try z.validate(Rule, -6, &path)).?.code);
    try equal(z.Code.above_maximum, (try z.validate(Rule, 6, &path)).?.code);
    try expect((try z.validate(z.Int(i128, .{ .min = std.math.minInt(i128) }), std.math.minInt(i128), &path)) == null);
    try expect((try z.validate(z.Int(u128, .{ .max = std.math.maxInt(u128) }), std.math.maxInt(u128), &path)) == null);
    try expect((try z.validate(z.Int(u0, .{}), 0, &path)) == null);
    try equal(z.Code.above_maximum, (try z.validate(z.Int(u8, .{ .max = 0 }), 255, &path)).?.code);
}

test "float finite policy includes negative zero and rejects NaN and infinities" {
    var path: [0]z.Segment = .{};
    inline for (.{ f16, f32, f64, f128 }) |T| {
        const Rule = z.Float(T, .{ .min = 0, .max = 1 });
        try expect((try z.validate(Rule, -0.0, &path)) == null);
        try expect((try z.validate(Rule, 1, &path)) == null);
        try equal(z.Code.below_minimum, (try z.validate(Rule, -1, &path)).?.code);
        try equal(z.Code.above_maximum, (try z.validate(Rule, 2, &path)).?.code);
        try equal(z.Code.not_finite, (try z.validate(Rule, std.math.nan(T), &path)).?.code);
        try equal(z.Code.not_finite, (try z.validate(Rule, std.math.inf(T), &path)).?.code);
        try equal(z.Code.not_finite, (try z.validate(Rule, -std.math.inf(T), &path)).?.code);
    }
}

test "booleans and enum subsets" {
    var path: [0]z.Segment = .{};
    try expect((try z.validate(z.Boolean(null), false, &path)) == null);
    try expect((try z.validate(z.Boolean(null), true, &path)) == null);
    try expect((try z.validate(z.Boolean(true), true, &path)) == null);
    try equal(z.Code.boolean_mismatch, (try z.validate(z.Boolean(true), false, &path)).?.code);
    try equal(z.Code.boolean_mismatch, (try z.validate(z.Boolean(false), true, &path)).?.code);
    const Role = enum { guest, member, admin };
    const Rule = z.Enumeration(Role, &.{ .guest, .member });
    try expect((try z.validate(Rule, .member, &path)) == null);
    try equal(z.Code.enum_value, (try z.validate(Rule, .admin, &path)).?.code);
    try expect((try z.validate(z.Enumeration(Role, null), .admin, &path)) == null);
    try equal(z.Code.enum_value, (try z.validate(z.Enumeration(Role, &.{}), .guest, &path)).?.code);
}

test "non-exhaustive enum values must name a declared tag" {
    const Wire = enum(u8) { known = 1, _ };
    var path: [0]z.Segment = .{};
    try expect((try z.validate(z.Enumeration(Wire, null), .known, &path)) == null);
    try equal(z.Code.enum_value, (try z.validate(z.Enumeration(Wire, null), @fromBackingInt(@intCast(255)), &path)).?.code);
}

test "native optionals accept null and validate present values" {
    const Rule = z.Optional(z.Int(u16, .{ .min = 10 }));
    var path: [0]z.Segment = .{};
    try expect((try z.validate(Rule, null, &path)) == null);
    try expect((try z.validate(Rule, 10, &path)) == null);
    try equal(z.Code.below_minimum, (try z.validate(Rule, 9, &path)).?.code);
}

const Item = struct { name: []const u8, active: bool };
const ItemRule = z.Struct(Item, .{
    .name = z.String(.{ .length = .{ .min = 1 } }),
    .active = z.Boolean(true),
});
const Basket = struct { items: []const Item, note: ?[]const u8 };
// Deliberately reverse the rule map's order: native struct order is authoritative.
const BasketRule = z.Struct(Basket, .{
    .note = z.Optional(z.String(.{})),
    .items = z.Slice(ItemRule, .{ .max = 4 }),
});

test "nested struct and slice failure has exact typed path" {
    var path: [3]z.Segment = undefined;
    const items = [_]Item{ .{ .name = "one", .active = true }, .{ .name = "", .active = true } };
    const issue = (try z.validate(BasketRule, .{ .items = &items, .note = null }, &path)).?;
    try equal(z.Code.too_short, issue.code);
    try equal(@as(usize, 3), issue.path.len);
    try strings("items", issue.path[0].field);
    try equal(@as(usize, 1), issue.path[1].index);
    try strings("name", issue.path[2].field);
    try strings("length must be at least 1", issue.message);
}

test "path capacity is an operational error even for otherwise valid values" {
    var path: [2]z.Segment = undefined;
    const items = [_]Item{.{ .name = "good", .active = true }};
    try std.testing.expectError(error.PathCapacityExceeded, z.validate(BasketRule, .{ .items = &items, .note = null }, &path));
}

test "successful siblings reset path depth and do not mutate input" {
    var path: [3]z.Segment = undefined;
    var items = [_]Item{ .{ .name = "one", .active = true }, .{ .name = "two", .active = false } };
    const value: Basket = .{ .items = &items, .note = "ok" };
    const issue = (try z.validate(BasketRule, value, &path)).?;
    try strings("active", issue.path[2].field);
    try equal(@as(usize, 1), issue.path[1].index);
    try expect(!items[1].active);
    items[1].active = true;
    try expect((try z.validate(BasketRule, value, &path)) == null);
}

test "slice limits are checked before iteration and empty slices need no path" {
    const Rule = z.Slice(z.Int(u8, .{ .min = 1 }), .{ .min = 1, .max = 2 });
    var path: [1]z.Segment = undefined;
    try equal(z.Code.too_short, (try z.validate(Rule, &.{}, &path)).?.code);
    try expect((try z.validate(Rule, &.{ 1, 2 }, &path)) == null);
    try equal(z.Code.too_long, (try z.validate(Rule, &.{ 0, 0, 0 }, &path)).?.code);
    try equal(z.Code.below_minimum, (try z.validate(Rule, &.{0}, &path)).?.code);
    try expect((try z.validate(z.Slice(z.Boolean(null), .{}), &.{}, &.{})) == null);
}

test "fixed arrays and nested arrays preserve indices" {
    const Rule = z.Array(2, z.Array(2, z.Int(i32, .{ .min = 0 })));
    var path: [2]z.Segment = undefined;
    try expect((try z.validate(Rule, .{ .{ 0, 1 }, .{ 2, 3 } }, &path)) == null);
    const issue = (try z.validate(Rule, .{ .{ 0, 1 }, .{ 2, -1 } }, &path)).?;
    try equal(@as(usize, 1), issue.path[0].index);
    try equal(@as(usize, 1), issue.path[1].index);
    try expect((try z.validate(z.Array(0, z.Boolean(null)), .{}, &.{})) == null);
}

fn even(value: u8) bool {
    return value % 2 == 0;
}

fn ordered(value: struct { low: i32, high: i32 }) bool {
    return value.low <= value.high;
}

test "custom predicates apply to scalars and cross-field native values" {
    var path: [0]z.Segment = .{};
    const Rule = z.Custom(u8, even, "must be even");
    try expect((try z.validate(Rule, 2, &path)) == null);
    const issue = (try z.validate(Rule, 3, &path)).?;
    try equal(z.Code.custom, issue.code);
    try strings("must be even", issue.message);
    const Pair = @typeInfo(@TypeOf(ordered)).@"fn".param_types[0].?;
    try equal(z.Code.custom, (try z.validate(z.Custom(Pair, ordered, "low must not exceed high"), .{ .low = 2, .high = 1 }, &path)).?.code);
}

test "validation can run at compile time" {
    const passed = comptime (try z.validate(z.Int(u8, .{ .min = 1 }), 1, &.{})) == null;
    const code = comptime (try z.validate(z.String(.{ .length = .{ .min = 1 } }), "", &.{})).?.code;
    try expect(passed);
    try equal(z.Code.too_short, code);
}

test "decoding boundary rejects overflow and malformed numbers before validation" {
    // Parsing is deliberately stdlib-owned, outside Zigil's typed validation API.
    try std.testing.expectError(error.Overflow, std.fmt.parseInt(u8, "256", 10));
    try std.testing.expectError(error.Overflow, std.fmt.parseInt(i8, "-129", 10));
    try std.testing.expectError(error.InvalidCharacter, std.fmt.parseInt(u8, "12x", 10));
    const decoded = try std.fmt.parseInt(u8, "255", 10);
    try expect((try z.validate(z.Int(u8, .{}), decoded, &.{})) == null);
}

test "native JSON decoding composes without hidden ownership" {
    const allocator = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(Item, allocator, "{\"name\":\"one\",\"active\":true}", .{});
    defer parsed.deinit();
    var path: [1]z.Segment = undefined;
    try expect((try z.validate(ItemRule, parsed.value, &path)) == null);
    try std.testing.expectError(error.UnexpectedEndOfInput, std.json.parseFromSlice(Item, allocator, "{", .{}));
    try std.testing.expectError(error.UnknownField, std.json.parseFromSlice(Item, allocator, "{\"name\":\"one\",\"active\":true,\"extra\":1}", .{}));
}

fn decodeAndValidate(allocator: std.mem.Allocator) !void {
    const parsed = try std.json.parseFromSlice(Item, allocator, "{\"name\":\"a\\u0062\",\"active\":true}", .{ .allocate = .alloc_always });
    defer parsed.deinit();
    var path: [1]z.Segment = undefined;
    try expect((try z.validate(ItemRule, parsed.value, &path)) == null);
}

test "allocation failures and leak checks at the stdlib decoding boundary" {
    // Built-ins take no allocator. Exercise all allocation failures of a real
    // consumer's owning decoder instead of inventing allocation paths in Zigil.
    try std.testing.checkAllAllocationFailures(std.testing.allocator, decodeAndValidate, .{});
}

test "resource budgets accept exact boundaries and reject one over" {
    var path: [3]z.Segment = undefined;
    const text = z.String(.{});
    try expect((try z.validateWithLimits(text, "four", &path, .{ .max_bytes = 4, .max_work = 5 })) == null);
    try std.testing.expectError(error.InputLimitExceeded, z.validateWithLimits(text, "four", &path, .{ .max_bytes = 3 }));
    try std.testing.expectError(error.WorkLimitExceeded, z.validateWithLimits(text, "four", &path, .{ .max_work = 4 }));
    try std.testing.expectError(error.WorkLimitExceeded, z.validateWithLimits(z.Boolean(null), true, &path, .{ .max_work = 0 }));
    const Rule = z.Slice(z.Boolean(null), .{});
    try expect((try z.validateWithLimits(Rule, &.{ true, false }, &path, .{ .max_items = 2, .max_work = 3, .max_depth = 1 })) == null);
    try std.testing.expectError(error.ItemLimitExceeded, z.validateWithLimits(Rule, &.{ true, false }, &path, .{ .max_items = 1 }));
    try std.testing.expectError(error.DepthLimitExceeded, z.validateWithLimits(Rule, &.{true}, &path, .{ .max_depth = 0 }));
}

test "aggregate resource accounting does not wrap or reset at siblings" {
    var path: [2]z.Segment = undefined;
    const Rule = z.Slice(z.String(.{}), .{});
    try std.testing.expectError(error.InputLimitExceeded, z.validateWithLimits(Rule, &.{ "ab", "cd" }, &path, .{ .max_bytes = 3 }));
    const Nested = z.Slice(z.Slice(z.Boolean(null), .{}), .{});
    try std.testing.expectError(error.ItemLimitExceeded, z.validateWithLimits(Nested, &.{&.{true}}, &path, .{ .max_items = 1 }));
    try expect((try z.validateWithLimits(z.String(.{}), "safe", &path, .{
        .max_work = std.math.maxInt(usize),
        .max_bytes = std.math.maxInt(usize),
        .max_items = std.math.maxInt(usize),
        .max_depth = std.math.maxInt(usize),
    })) == null);
}

fn available(value: u8) error{Unavailable}!bool {
    if (value == 0) return error.Unavailable;
    return value == 2;
}

fn allocationFailed(_: u8) error{OutOfMemory}!bool {
    return error.OutOfMemory;
}

test "fallible custom predicates preserve operational errors and invalidity" {
    const Rule = z.Custom(u8, available, "must be two");
    try expect((try z.validate(Rule, 2, &.{})) == null);
    try equal(z.Code.custom, (try z.validate(Rule, 1, &.{})).?.code);
    try std.testing.expectError(error.Unavailable, z.validate(Rule, 0, &.{}));
    try std.testing.expectError(error.OutOfMemory, z.validate(z.Custom(u8, allocationFailed, "invalid"), 0, &.{}));
}

test "JSON Pointer escapes keys and preserves typed path segments" {
    const Strange = struct { @"a/b~c": []const []const u8 };
    const Rule = z.Struct(Strange, .{ .@"a/b~c" = z.Slice(z.String(.{ .length = .{ .min = 1 } }), .{}) });
    var path: [2]z.Segment = undefined;
    const issue = (try z.validate(Rule, .{ .@"a/b~c" = &.{""} }, &path)).?;
    var output: [64]u8 = undefined;
    try strings("/a~1b~0c/0", try issue.jsonPointer(&output));
    try strings("a/b~c", issue.path[0].field);
    try equal(@as(usize, 0), issue.path[1].index);
    var exact: [10]u8 = undefined;
    try strings("/a~1b~0c/0", try issue.jsonPointer(exact[0..10]));
    try std.testing.expectError(error.NoSpaceLeft, issue.jsonPointer(exact[0..9]));
    const root_issue = (try z.validate(z.Boolean(true), false, &.{})).?;
    try strings("", try root_issue.jsonPointer(&.{}));
    const keys = [_]z.Segment{ .{ .field = "" }, .{ .field = "0" }, .{ .field = "a.b[0]" }, .{ .index = 0 } };
    const key_issue: z.Issue = .{ .code = .custom, .path = &keys, .message = "test" };
    try strings("//0/a.b[0]/0", try key_issue.jsonPointer(&output));
}

test "issues do not borrow decoded input after parser cleanup" {
    var path: [1]z.Segment = undefined;
    const issue = block: {
        const parsed = try std.json.parseFromSlice(Item, std.testing.allocator, "{\"name\":\"\",\"active\":true}", .{ .allocate = .alloc_always });
        defer parsed.deinit();
        break :block (try z.validate(ItemRule, parsed.value, &path)).?;
    };
    try strings("name", issue.path[0].field);
    try strings("length must be at least 1", issue.message);
}

test {
    _ = @import("json.zig");
}

test {
    _ = @import("composition.zig");
}

test {
    _ = @import("schema.zig");
}

test {
    _ = @import("runtime.zig");
}
