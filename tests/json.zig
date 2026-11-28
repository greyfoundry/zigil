const std = @import("std");
const z = @import("zigil");
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const Config = struct { name: []const u8, port: u16, note: ?[]const u8 };
const Rule = z.Struct(Config, .{
    .name = z.String(.{ .length = .{ .min = 1, .max = 80 } }),
    .port = z.Int(u16, .{ .min = 1 }),
    .note = z.Optional(z.String(.{})),
});

test "owning strict JSON decode and structured failure paths" {
    var result = try z.decodeJson(Rule, std.testing.allocator, "{\"name\":\"ok\",\"port\":443,\"note\":null}", .{});
    defer result.deinit();
    try equal(@as(u16, 443), result.outcome.valid.port);
    try expect(result.outcome.valid.note == null);
    var invalid = try z.decodeJson(Rule, std.testing.allocator, "{\"name\":\"ok\",\"port\":0,\"note\":null}", .{});
    defer invalid.deinit();
    try equal(z.Code.below_minimum, invalid.outcome.invalid.code);
    try std.testing.expectEqualStrings("port", invalid.outcome.invalid.path[0].field);
}

test "numeric strings defaults missing and unknown fields are never silently accepted" {
    const inputs = .{
        .{ "{\"name\":\"ok\",\"port\":\"443\",\"note\":null}", z.Code.type_mismatch },
        .{ "{\"name\":\"ok\",\"port\":443}", z.Code.missing_field },
        .{ "{\"name\":\"ok\",\"port\":443,\"note\":null,\"extra\":true}", z.Code.unknown_field },
        .{ "{\"name\":\"ok\",\"port\":443.5,\"note\":null}", z.Code.invalid_number },
        .{ "{\"name\":\"ok\",\"port\":65536,\"note\":null}", z.Code.invalid_number },
        .{ "{\"name\":\"ok\",\"port\":null,\"note\":null}", z.Code.type_mismatch },
    };
    inline for (inputs) |case| {
        var result = try z.decodeJson(Rule, std.testing.allocator, case[0], .{});
        defer result.deinit();
        try equal(case[1], result.outcome.invalid.code);
        try expect(result.outcome.invalid.path.len > 0);
    }
    const Default = struct { port: u16 = 443 };
    var missing = try z.decodeJson(z.Struct(Default, .{ .port = z.Int(u16, .{}) }), std.testing.allocator, "{}", .{});
    defer missing.deinit();
    try equal(z.Code.missing_field, missing.outcome.invalid.code);
}

test "malformed JSON and duplicate keys have distinct outcomes" {
    inline for (.{ "{", "{} trailing", "{\"x\":\"\\ud800\"}", "\xff", "[1,]" }) |input| {
        var result = try z.decodeJson(Rule, std.testing.allocator, input, .{});
        defer result.deinit();
        try expect(result.outcome == .malformed);
    }
    var duplicate = try z.decodeJson(Rule, std.testing.allocator, "{\"name\":\"one\",\"na\\u006de\":\"two\",\"port\":1,\"note\":null}", .{});
    defer duplicate.deinit();
    try equal(z.Code.duplicate_field, duplicate.outcome.invalid.code);
}

test "exact integers preserve 128 bit values and reject overflow" {
    var large = try z.decodeJson(z.Int(u128, .{}), std.testing.allocator, "340282366920938463463374607431768211455", .{});
    defer large.deinit();
    try equal(std.math.maxInt(u128), large.outcome.valid);
    var overflow = try z.decodeJson(z.Int(u128, .{}), std.testing.allocator, "340282366920938463463374607431768211456", .{});
    defer overflow.deinit();
    try equal(z.Code.invalid_number, overflow.outcome.invalid.code);
}

test "floats reject overflow underflow and coercion" {
    inline for (.{ "1e9999", "1e-9999", "\"1.0\"" }) |input| {
        var value = try z.decodeJson(z.Float(f64, .{}), std.testing.allocator, input, .{});
        defer value.deinit();
        try expect(value.outcome == .invalid);
    }
    var zero = try z.decodeJson(z.Float(f64, .{}), std.testing.allocator, "-0e-9999", .{});
    defer zero.deinit();
    try equal(@as(f64, 0), zero.outcome.valid);
}

test "input depth token member string and allocation budgets are operational failures" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InputLimitExceeded, z.json.parse(allocator, "true", .{ .max_input_bytes = 3 }));
    try std.testing.expectError(error.DepthLimitExceeded, z.json.parse(allocator, "[[]]", .{ .max_depth = 1 }));
    try std.testing.expectError(error.TokenLimitExceeded, z.json.parse(allocator, "[true,false]", .{ .max_tokens = 3 }));
    try std.testing.expectError(error.MemberLimitExceeded, z.json.parse(allocator, "[true,false]", .{ .max_members = 1 }));
    try std.testing.expectError(error.StringLimitExceeded, z.json.parse(allocator, "\"abcd\"", .{ .max_string_bytes = 3 }));
    try std.testing.expectError(error.AllocationLimitExceeded, z.json.parse(allocator, "true", .{ .max_allocated_bytes = 1 }));
    var exact = try z.json.parse(allocator, "[true]", .{ .max_input_bytes = 6, .max_depth = 1, .max_tokens = 4, .max_members = 1 });
    defer exact.deinit();
    try expect(exact.outcome == .value);
}

test "arrays slices enums and nested paths" {
    const Kind = enum { a, b };
    const Row = struct { values: []const u8, kind: Kind };
    const Rows = z.Array(1, z.Struct(Row, .{ .values = z.String(.{}), .kind = z.Enumeration(Kind, null) }));
    var good = try z.decodeJson(Rows, std.testing.allocator, "[{\"values\":\"hi\\u0021\",\"kind\":\"a\"}]", .{});
    defer good.deinit();
    try std.testing.expectEqualStrings("hi!", good.outcome.valid[0].values);
    var bad = try z.decodeJson(Rows, std.testing.allocator, "[{\"values\":\"hi\",\"kind\":\"c\"}]", .{});
    defer bad.deinit();
    var pointer: [40]u8 = undefined;
    try std.testing.expectEqualStrings("/0/kind", try bad.outcome.invalid.jsonPointer(&pointer));
}

fn allocationPaths(allocator: std.mem.Allocator, input: []const u8) !void {
    var result = try z.decodeJson(Rule, allocator, input, .{});
    defer result.deinit();
}

test "every owning success invalid and malformed allocation failure cleans up" {
    inline for (.{ "{\"name\":\"a\\u0062\",\"port\":443,\"note\":null}", "{\"name\":\"\",\"port\":443,\"note\":null}", "{\"name\":\"escaped\\u0021\",\"port\":", "{\"port\":1,\"port\":2}" }) |input|
        try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationPaths, .{input});
}

test "output survives immediate destruction of the source bytes" {
    var result = block: {
        const input = try std.testing.allocator.dupe(u8, "{\"name\":\"owned\",\"port\":443,\"note\":\"also owned\"}");
        defer std.testing.allocator.free(input);
        break :block try z.decodeJson(Rule, std.testing.allocator, input, .{});
    };
    defer result.deinit();
    try std.testing.expectEqualStrings("owned", result.outcome.valid.name);
    try std.testing.expectEqualStrings("also owned", result.outcome.valid.note.?);
}

test "presence distinguishes missing null false zero and empty" {
    const Model = struct { flag: z.Presence(bool), count: z.Presence(i32), name: z.Presence([]const u8) };
    const Schema = z.Struct(Model, .{
        .flag = z.Field(z.Boolean(null), .{ .optional = true, .nullable = true }),
        .count = z.Field(z.Int(i32, .{}), .{ .optional = true, .nullable = true }),
        .name = z.Field(z.String(.{}), .{ .optional = true, .nullable = true }),
    });
    var absent = try z.decodeJson(Schema, std.testing.allocator, "{}", .{});
    defer absent.deinit();
    try expect(absent.outcome.valid.flag == .missing);
    var nulls = try z.decodeJson(Schema, std.testing.allocator, "{\"flag\":null,\"count\":null,\"name\":null}", .{});
    defer nulls.deinit();
    try expect(nulls.outcome.valid.flag == .null_value);
    var values = try z.decodeJson(Schema, std.testing.allocator, "{\"flag\":false,\"count\":0,\"name\":\"\"}", .{});
    defer values.deinit();
    try expect(!values.outcome.valid.flag.value);
    try equal(@as(i32, 0), values.outcome.valid.count.value);
    try std.testing.expectEqualStrings("", values.outcome.valid.name.value);
    const Required = struct { flag: z.Presence(bool) };
    const RequiredRule = z.Struct(Required, .{ .flag = z.Field(z.Boolean(null), .{}) });
    var bad = try z.decodeJson(RequiredRule, std.testing.allocator, "{}", .{});
    defer bad.deinit();
    try equal(z.Code.missing_field, bad.outcome.invalid.code);
    var bad_null = try z.decodeJson(RequiredRule, std.testing.allocator, "{\"flag\":null}", .{});
    defer bad_null.deinit();
    try equal(z.Code.null_not_allowed, bad_null.outcome.invalid.code);
}

test "exact decimal conversion never rounds integers or floats implicitly" {
    var integer = try z.decodeJson(z.Int(u128, .{}), std.testing.allocator, "9007199254740993.0", .{});
    defer integer.deinit();
    try equal(@as(u128, 9007199254740993), integer.outcome.valid);
    var fraction = try z.decodeJson(z.Float(f64, .{}), std.testing.allocator, "0.1", .{});
    defer fraction.deinit();
    try equal(z.Code.invalid_number, fraction.outcome.invalid.code);
    var exact = try z.decodeJson(z.Float(f64, .{}), std.testing.allocator, "0.5", .{});
    defer exact.deinit();
    try equal(@as(f64, 0.5), exact.outcome.valid);
    var nearest = try z.decodeJson(z.Float(f64, .{}), std.testing.allocator, "0.1", .{ .float_rounding = .nearest });
    defer nearest.deinit();
    try equal(@as(f64, 0.1), nearest.outcome.valid);
}

test "small signed widths and signed integer minimum decode without narrowing traps" {
    var one = try z.decodeJson(z.Int(u1, .{}), std.testing.allocator, "1", .{});
    defer one.deinit();
    try equal(@as(u1, 1), one.outcome.valid);
    var minimum = try z.decodeJson(z.Int(i2, .{}), std.testing.allocator, "-2", .{});
    defer minimum.deinit();
    try equal(@as(i2, -2), minimum.outcome.valid);
    var signed = try z.decodeJson(z.Int(i128, .{}), std.testing.allocator, "-170141183460469231731687303715884105728", .{});
    defer signed.deinit();
    try equal(std.math.minInt(i128), signed.outcome.valid);
}

fn floatAllocations(allocator: std.mem.Allocator) !void {
    var value = try z.decodeJson(z.Float(f64, .{}), allocator, "0.5", .{});
    defer value.deinit();
}

test "exact float big-integer allocation failures release all state" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, floatAllocations, .{});
    try std.testing.expectError(error.AllocationLimitExceeded, z.decodeJson(Rule, std.testing.allocator, "{}", .{ .max_allocated_bytes = @sizeOf(z.json.State) + 1 }));
    try std.testing.expectError(error.WorkLimitExceeded, z.decodeJson(Rule, std.testing.allocator, "{}", .{ .validation = .{ .max_work = 0 } }));
}

test "exact float decoding rejects subnormal rounding at half a representable step" {
    var exact = try z.decodeJson(z.Float(f16, .{}), std.testing.allocator, "0.000000059604644775390625", .{});
    defer exact.deinit();
    try std.testing.expect(exact.outcome == .valid);
    var rounded = try z.decodeJson(z.Float(f16, .{}), std.testing.allocator, "0.0000000894069671630859375", .{});
    defer rounded.deinit();
    try std.testing.expect(rounded.outcome == .invalid);
}

test "extended precision floats count their explicit leading bit correctly" {
    var result = try z.decodeJson(z.Float(f80, .{}), std.testing.allocator, "18446744073709551617", .{});
    defer result.deinit();
    try std.testing.expect(result.outcome == .invalid);
    var exact = try z.decodeJson(z.Float(f80, .{}), std.testing.allocator, "18446744073709551616", .{});
    defer exact.deinit();
    try std.testing.expect(exact.outcome == .valid);
}
