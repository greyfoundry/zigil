const std = @import("std");
const z = @import("zigil");
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const strings = std.testing.expectEqualStrings;

test "UTF-8 strings use byte lengths with inclusive limits" {
    const Rule = z.String(.{ .length = .{ .min = 2, .max = 4 } });
    var path: [0]z.Segment = .{};
    try expect(z.validate(Rule, "é", &path) == null);
    try expect(z.validate(Rule, "four", &path) == null);
    try equal(z.Code.too_short, z.validate(Rule, "x", &path).?.code);
    try equal(z.Code.too_long, z.validate(Rule, "12345", &path).?.code);
    try equal(z.Code.invalid_utf8, z.validate(Rule, "\xc0\x80", &path).?.code);
    try equal(z.Code.invalid_utf8, z.validate(Rule, "\xed\xa0\x80", &path).?.code);
    try expect(z.validate(z.String(.{ .utf8 = false }), "\xff", &path) == null);
}

test "prefix suffix empty strings and embedded NUL" {
    const Rule = z.String(.{ .prefix = "pre", .suffix = "end" });
    var path: [0]z.Segment = .{};
    try expect(z.validate(Rule, "pre-end", &path) == null);
    try equal(z.Code.prefix, z.validate(Rule, "end", &path).?.code);
    try equal(z.Code.suffix, z.validate(Rule, "pre", &path).?.code);
    try expect(z.validate(z.String(.{}), "", &path) == null);
    try expect(z.validate(z.String(.{}), "a\x00b", &path) == null);
}

test "integer bounds include endpoints and do not do overflow-prone arithmetic" {
    var path: [0]z.Segment = .{};
    const Rule = z.Int(i8, .{ .min = -5, .max = 5 });
    try expect(z.validate(Rule, -5, &path) == null);
    try expect(z.validate(Rule, 5, &path) == null);
    try equal(z.Code.below_minimum, z.validate(Rule, -6, &path).?.code);
    try equal(z.Code.above_maximum, z.validate(Rule, 6, &path).?.code);
    try expect(z.validate(z.Int(i128, .{ .min = std.math.minInt(i128) }), std.math.minInt(i128), &path) == null);
    try expect(z.validate(z.Int(u128, .{ .max = std.math.maxInt(u128) }), std.math.maxInt(u128), &path) == null);
    try expect(z.validate(z.Int(u0, .{}), 0, &path) == null);
    try equal(z.Code.above_maximum, z.validate(z.Int(u8, .{ .max = 0 }), 255, &path).?.code);
}

test "float finite policy includes negative zero and rejects NaN and infinities" {
    var path: [0]z.Segment = .{};
    inline for (.{ f16, f32, f64, f128 }) |T| {
        const Rule = z.Float(T, .{ .min = 0, .max = 1 });
        try expect(z.validate(Rule, -0.0, &path) == null);
        try expect(z.validate(Rule, 1, &path) == null);
        try equal(z.Code.below_minimum, z.validate(Rule, -1, &path).?.code);
        try equal(z.Code.above_maximum, z.validate(Rule, 2, &path).?.code);
        try equal(z.Code.not_finite, z.validate(Rule, std.math.nan(T), &path).?.code);
        try equal(z.Code.not_finite, z.validate(Rule, std.math.inf(T), &path).?.code);
        try equal(z.Code.not_finite, z.validate(Rule, -std.math.inf(T), &path).?.code);
    }
}

test "booleans and enum subsets" {
    var path: [0]z.Segment = .{};
    try expect(z.validate(z.Boolean(null), false, &path) == null);
    try expect(z.validate(z.Boolean(null), true, &path) == null);
    try expect(z.validate(z.Boolean(true), true, &path) == null);
    try equal(z.Code.boolean_mismatch, z.validate(z.Boolean(true), false, &path).?.code);
    try equal(z.Code.boolean_mismatch, z.validate(z.Boolean(false), true, &path).?.code);
    const Role = enum { guest, member, admin };
    const Rule = z.Enumeration(Role, &.{ .guest, .member });
    try expect(z.validate(Rule, .member, &path) == null);
    try equal(z.Code.enum_value, z.validate(Rule, .admin, &path).?.code);
    try expect(z.validate(z.Enumeration(Role, null), .admin, &path) == null);
    try equal(z.Code.enum_value, z.validate(z.Enumeration(Role, &.{}), .guest, &path).?.code);
}

test "non-exhaustive enum values must name a declared tag" {
    const Wire = enum(u8) { known = 1, _ };
    var path: [0]z.Segment = .{};
    try expect(z.validate(z.Enumeration(Wire, null), .known, &path) == null);
    try equal(z.Code.enum_value, z.validate(z.Enumeration(Wire, null), @fromBackingInt(@intCast(255)), &path).?.code);
}

test "native optionals accept null and validate present values" {
    const Rule = z.Optional(z.Int(u16, .{ .min = 10 }));
    var path: [0]z.Segment = .{};
    try expect(z.validate(Rule, null, &path) == null);
    try expect(z.validate(Rule, 10, &path) == null);
    try equal(z.Code.below_minimum, z.validate(Rule, 9, &path).?.code);
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
    const issue = z.validate(BasketRule, .{ .items = &items, .note = null }, &path).?;
    try equal(z.Code.too_short, issue.code);
    try equal(@as(usize, 3), issue.path.len);
    try strings("items", issue.path[0].field);
    try equal(@as(usize, 1), issue.path[1].index);
    try strings("name", issue.path[2].field);
    try strings("length must be at least 1", issue.message);
}

test "path capacity fails explicitly at the available prefix" {
    var path: [2]z.Segment = undefined;
    const items = [_]Item{.{ .name = "good", .active = true }};
    const issue = z.validate(BasketRule, .{ .items = &items, .note = null }, &path).?;
    try equal(z.Code.path_capacity, issue.code);
    try equal(@as(usize, 2), issue.path.len);
    try strings("items", issue.path[0].field);
    try equal(@as(usize, 0), issue.path[1].index);
}

test "successful siblings reset path depth and do not mutate input" {
    var path: [3]z.Segment = undefined;
    var items = [_]Item{ .{ .name = "one", .active = true }, .{ .name = "two", .active = false } };
    const value: Basket = .{ .items = &items, .note = "ok" };
    const issue = z.validate(BasketRule, value, &path).?;
    try strings("active", issue.path[2].field);
    try equal(@as(usize, 1), issue.path[1].index);
    try expect(!items[1].active);
    items[1].active = true;
    try expect(z.validate(BasketRule, value, &path) == null);
}

test "slice limits are checked before iteration and empty slices need no path" {
    const Rule = z.Slice(z.Int(u8, .{ .min = 1 }), .{ .min = 1, .max = 2 });
    var path: [1]z.Segment = undefined;
    try equal(z.Code.too_short, z.validate(Rule, &.{}, &path).?.code);
    try expect(z.validate(Rule, &.{ 1, 2 }, &path) == null);
    try equal(z.Code.too_long, z.validate(Rule, &.{ 0, 0, 0 }, &path).?.code);
    try equal(z.Code.below_minimum, z.validate(Rule, &.{0}, &path).?.code);
    try expect(z.validate(z.Slice(z.Boolean(null), .{}), &.{}, &.{}) == null);
}

test "fixed arrays and nested arrays preserve indices" {
    const Rule = z.Array(2, z.Array(2, z.Int(i32, .{ .min = 0 })));
    var path: [2]z.Segment = undefined;
    try expect(z.validate(Rule, .{ .{ 0, 1 }, .{ 2, 3 } }, &path) == null);
    const issue = z.validate(Rule, .{ .{ 0, 1 }, .{ 2, -1 } }, &path).?;
    try equal(@as(usize, 1), issue.path[0].index);
    try equal(@as(usize, 1), issue.path[1].index);
    try expect(z.validate(z.Array(0, z.Boolean(null)), .{}, &.{}) == null);
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
    try expect(z.validate(Rule, 2, &path) == null);
    const issue = z.validate(Rule, 3, &path).?;
    try equal(z.Code.custom, issue.code);
    try strings("must be even", issue.message);
    const Pair = @typeInfo(@TypeOf(ordered)).@"fn".param_types[0].?;
    try equal(z.Code.custom, z.validate(z.Custom(Pair, ordered, "low must not exceed high"), .{ .low = 2, .high = 1 }, &path).?.code);
}

test "validation can run at compile time" {
    const passed = comptime z.validate(z.Int(u8, .{ .min = 1 }), 1, &.{}) == null;
    const code = comptime z.validate(z.String(.{ .length = .{ .min = 1 } }), "", &.{}).?.code;
    try expect(passed);
    try equal(z.Code.too_short, code);
}

test "decoding boundary rejects overflow and malformed numbers before validation" {
    // Parsing is deliberately stdlib-owned, outside Zigil's typed validation API.
    try std.testing.expectError(error.Overflow, std.fmt.parseInt(u8, "256", 10));
    try std.testing.expectError(error.Overflow, std.fmt.parseInt(i8, "-129", 10));
    try std.testing.expectError(error.InvalidCharacter, std.fmt.parseInt(u8, "12x", 10));
    const decoded = try std.fmt.parseInt(u8, "255", 10);
    try expect(z.validate(z.Int(u8, .{}), decoded, &.{}) == null);
}

test "native JSON decoding composes without hidden ownership" {
    const allocator = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(Item, allocator, "{\"name\":\"one\",\"active\":true}", .{});
    defer parsed.deinit();
    var path: [1]z.Segment = undefined;
    try expect(z.validate(ItemRule, parsed.value, &path) == null);
    try std.testing.expectError(error.UnexpectedEndOfInput, std.json.parseFromSlice(Item, allocator, "{", .{}));
    try std.testing.expectError(error.UnknownField, std.json.parseFromSlice(Item, allocator, "{\"name\":\"one\",\"active\":true,\"extra\":1}", .{}));
}

fn decodeAndValidate(allocator: std.mem.Allocator) !void {
    const parsed = try std.json.parseFromSlice(Item, allocator, "{\"name\":\"a\\u0062\",\"active\":true}", .{ .allocate = .alloc_always });
    defer parsed.deinit();
    var path: [1]z.Segment = undefined;
    try expect(z.validate(ItemRule, parsed.value, &path) == null);
}

test "allocation failures and leak checks at the stdlib decoding boundary" {
    // Built-ins take no allocator. Exercise all allocation failures of a real
    // consumer's owning decoder instead of inventing allocation paths in Zigil.
    try std.testing.checkAllAllocationFailures(std.testing.allocator, decodeAndValidate, .{});
}
