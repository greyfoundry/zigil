//! Bounded native validation baseline; the direct implementation checks the same
//! fixture-domain constraints and first issue code/field. No cross-language claim.
const std = @import("std");
const z = @import("zigil");
const User = struct { name: []const u8, age: u8 };
const Rule = z.Struct(User, .{ .name = z.String(.{ .length = .{ .min = 1, .max = 80 } }), .age = z.Int(u8, .{ .min = 18, .max = 120 }) });
const Outcome = struct { code: ?z.Code, field: enum { none, name, age } = .none };
noinline fn direct(user: User) Outcome {
    if (user.name.len < 1) return .{ .code = .too_short, .field = .name };
    if (user.name.len > 80) return .{ .code = .too_long, .field = .name };
    if (!std.unicode.utf8ValidateSlice(user.name)) return .{ .code = .invalid_utf8, .field = .name };
    if (user.age < 18) return .{ .code = .below_minimum, .field = .age };
    if (user.age > 120) return .{ .code = .above_maximum, .field = .age };
    return .{ .code = null };
}
noinline fn native(user: User) Outcome {
    var path: [2]z.Segment = undefined;
    const issue = (z.validate(Rule, user, &path) catch unreachable) orelse return .{ .code = null };
    return .{ .code = issue.code, .field = if (std.mem.eql(u8, issue.path[0].field, "name")) .name else .age };
}
pub fn main(init: std.process.Init) !void {
    const long_name: [81]u8 = @splat('x');
    const choices = [_]User{ .{ .name = "Astoris", .age = 20 }, .{ .name = "", .age = 20 }, .{ .name = "\xff", .age = 20 }, .{ .name = &long_name, .age = 20 }, .{ .name = "worker", .age = 17 }, .{ .name = "worker", .age = 121 } };
    var random_state = std.Random.DefaultPrng.init(0x5a4947494c);
    const random = random_state.random();
    var fixtures: [128]User = undefined;
    var invalid: usize = 0;
    for (&fixtures) |*fixture| {
        fixture.* = choices[random.uintLessThan(usize, choices.len)];
        if (direct(fixture.*).code != null) invalid += 1;
    }
    std.mem.doNotOptimizeAway(&fixtures);
    for (fixtures) |fixture| if (!std.meta.eql(direct(fixture), native(fixture))) return error.SemanticMismatch;
    var checksum: usize = 0;
    for (0..5000) |iteration| {
        checksum +%= @intFromBool(native(fixtures[iteration % fixtures.len]).code != null);
        checksum +%= @intFromBool(direct(fixtures[iteration % fixtures.len]).code != null);
    }
    const iterations = 100_000;
    for (0..21) |sample| {
        inline for (.{ false, true }) |use_native| {
            const start = std.Io.Clock.awake.now(init.io);
            for (0..iterations) |iteration| {
                const outcome = if (use_native) native(fixtures[iteration % fixtures.len]) else direct(fixtures[iteration % fixtures.len]);
                checksum +%= @intFromBool(outcome.code != null);
            }
            const elapsed = start.durationTo(std.Io.Clock.awake.now(init.io)).nanoseconds;
            const per_op = @as(f64, @floatFromInt(elapsed)) / iterations;
            std.debug.print("SAMPLE {{\"implementation\":\"{s}\",\"sample\":{d},\"ns_per_operation\":{d}}}\n", .{ if (use_native) "zigil" else "direct", sample, per_op });
        }
    }
    std.mem.doNotOptimizeAway(checksum);
    var decoded = try z.decodeJson(Rule, init.gpa, "{\"name\":\"Astoris\",\"age\":20}", .{});
    defer decoded.deinit();
    std.debug.print("META {{\"zig\":\"{s}\",\"mode\":\"{s}\",\"iterations_per_sample\":{d},\"samples\":21,\"fixtures\":128,\"invalid_fixtures\":{d},\"seed\":\"0x5a4947494c\",\"native_validation_allocations\":0,\"direct_allocations\":0,\"example_decode_cumulative_requested_bytes\":{d},\"checksum\":{d}}}\n", .{ @import("builtin").zig_version_string, @tagName(@import("builtin").mode), iterations, invalid, decoded.state.used, checksum });
}
