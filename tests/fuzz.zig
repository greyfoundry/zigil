//! Reproducible bounded mutation campaigns, run in normal native tests.
const std = @import("std");
const z = @import("zigil");
const t = std.testing;
const a = t.allocator;
const Config = struct { port: u16, enabled: bool };
const Rule = z.Struct(Config, .{ .port = z.Int(u16, .{ .min = 1 }), .enabled = z.Boolean(null) });
fn expectedBudget(err: anyerror) bool {
    return switch (err) {
        error.InputLimitExceeded, error.TokenLimitExceeded, error.MemberLimitExceeded, error.StringLimitExceeded, error.DepthLimitExceeded, error.WorkLimitExceeded, error.AllocationLimitExceeded, error.NumericLimitExceeded, error.SchemaNodeLimitExceeded => true,
        else => false,
    };
}
test "fixed seed 0x5a4947494c: 512 byte mutations of untrusted JSON instances" {
    var prng = std.Random.DefaultPrng.init(0x5a4947494c);
    const random = prng.random();
    const seed = "{\"port\":443,\"enabled\":true}";
    var buffer: [96]u8 = undefined;
    var compiled = try z.runtime.compile(a, "{\"type\":\"object\",\"properties\":{\"port\":{\"type\":\"integer\",\"minimum\":1,\"maximum\":65535},\"enabled\":{\"type\":\"boolean\"}},\"required\":[\"port\",\"enabled\"],\"additionalProperties\":false}", &.{}, .{});
    defer compiled.deinit();
    for (0..512 * @import("campaign").rounds) |_| {
        @memcpy(buffer[0..seed.len], seed);
        const mutations = random.intRangeAtMost(usize, 1, 8);
        for (0..mutations) |_| buffer[random.uintLessThan(usize, seed.len)] = random.int(u8);
        const input = buffer[0..random.intRangeAtMost(usize, 0, seed.len)];
        var decoded = z.decodeJson(Rule, a, input, .{ .max_depth = 12, .max_tokens = 128, .max_allocated_bytes = 65536 }) catch |err| {
            if (expectedBudget(err)) continue;
            return err;
        };
        defer decoded.deinit();
        var evaluated = compiled.validate(a, input, .{ .max_depth = 12, .max_work = 10000, .json = .{ .max_depth = 12, .max_tokens = 128, .max_allocated_bytes = 65536 } }) catch |err| {
            if (expectedBudget(err)) continue;
            return err;
        };
        defer evaluated.deinit();
        try t.expectEqual(decoded.outcome == .valid, evaluated.outcome == .valid);
    }
}
test "fixed seed 0x534348454d41: 256 schema mutations fail explicitly or evaluate safely" {
    var prng = std.Random.DefaultPrng.init(0x534348454d41);
    const random = prng.random();
    const seed = "{\"allOf\":[{\"type\":\"integer\"},{\"minimum\":0}]}";
    var buffer: [seed.len]u8 = undefined;
    for (0..256 * @import("campaign").rounds) |_| {
        @memcpy(&buffer, seed);
        buffer[random.uintLessThan(usize, seed.len)] = random.int(u8);
        var schema = z.runtime.compile(a, &buffer, &.{}, .{ .max_schema_nodes = 64, .max_work = 10000, .json = .{ .max_depth = 12, .max_tokens = 128, .max_allocated_bytes = 65536 } }) catch |err| {
            if (expectedBudget(err)) continue;
            switch (err) {
                error.InvalidSchema, error.MalformedSchema, error.DuplicateSchemaKey, error.UnsupportedDialect, error.UnsupportedVocabulary, error.InvalidSchemaUri, error.UnresolvedReference, error.InvalidPattern, error.UnsupportedPattern, error.PatternEngineUnavailable => continue,
                else => return err,
            }
        };
        defer schema.deinit();
        var result = schema.validate(a, "-1", .{ .max_depth = 12, .max_work = 10000, .json = .{ .max_allocated_bytes = 65536 } }) catch |err| {
            if (expectedBudget(err)) continue;
            return err;
        };
        defer result.deinit();
        try t.expect(result.outcome != .malformed);
    }
}
test "fixed seed 0x444543494d414c: 1000 integral decimal conversions agree with checked arithmetic" {
    var prng = std.Random.DefaultPrng.init(0x444543494d414c);
    const random = prng.random();
    for (0..1000 * @import("campaign").rounds) |_| {
        const coefficient = random.intRangeAtMost(i64, -1_000_000, 1_000_000);
        const exponent = random.intRangeAtMost(i8, -6, 6);
        var buffer: [64]u8 = undefined;
        const source = try std.fmt.bufPrint(&buffer, "{d}e{d}", .{ coefficient, exponent });
        var power: i64 = 1;
        for (0..@as(usize, @intCast(@abs(exponent)))) |_| power *= 10;
        const expected: ?i64 = if (exponent >= 0) coefficient * power else if (@rem(coefficient, power) == 0) @divExact(coefficient, power) else null;
        var result = try z.decodeJson(z.Int(i64, .{}), a, source, .{});
        defer result.deinit();
        if (expected) |value| try t.expectEqual(value, result.outcome.valid) else try t.expect(result.outcome == .invalid);
    }
}
