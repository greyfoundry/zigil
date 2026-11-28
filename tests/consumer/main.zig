const z = @import("zigil");
const std = @import("std");

const Config = struct { workers: u16, names: []const []const u8 };
const Rule = z.Struct(Config, .{
    .workers = z.Int(u16, .{ .min = 1, .max = 64 }),
    .names = z.Slice(z.String(.{ .length = .{ .min = 1, .max = 80 } }), .{ .max = 10 }),
});

pub fn main() !void {
    var decoded = try z.decodeJson(Rule, std.heap.page_allocator, "{\"workers\":4,\"names\":[\"consumer\"]}", .{});
    defer decoded.deinit();
    if (decoded.outcome != .valid) return error.InvalidDecodedValue;
    var pair = try z.decodeJson(z.Tuple(.{ z.String(.{}), z.Boolean(true) }), std.heap.page_allocator, "[\"consumer\",true]", .{});
    defer pair.deinit();
    if (pair.outcome != .valid) return error.InvalidTuple;
    var schema = try z.exportSchema(z.Int(u128, .{}), std.heap.page_allocator, .{});
    defer schema.deinit();
    if (schema.json.len == 0) return error.EmptySchema;
    var compiled = try z.runtime.compile(std.heap.page_allocator, "{\"type\":\"boolean\"}", &.{}, .{});
    defer compiled.deinit();
    var validated = try compiled.validate(std.heap.page_allocator, "true", .{});
    defer validated.deinit();
    if (validated.outcome != .valid) return error.InvalidExternalSchemaValue;
    var fragment = try z.openapi.exportSchema(z.Boolean(null), std.heap.page_allocator, .{});
    defer fragment.deinit();
    if (fragment.json.len == 0) return error.EmptyOpenApiFragment;
    if (z.runtime.regex_enabled) {
        var pattern = try z.runtime.compile(std.heap.page_allocator, "{\"pattern\":\"^[A-Z]+$\"}", &.{}, .{});
        defer pattern.deinit();
        var match = try pattern.validate(std.heap.page_allocator, "\"ABC\"", .{});
        defer match.deinit();
        if (match.outcome != .valid) return error.PatternMismatch;
    }
    var path: [2]z.Segment = undefined;
    if ((try z.validate(Rule, .{ .workers = 4, .names = &.{"worker"} }, &path)) != null)
        return error.UnexpectedIssue;
    const issue = (try z.validate(Rule, .{ .workers = 4, .names = &.{""} }, &path)) orelse return error.ExpectedIssue;
    if (issue.code != .too_short or issue.path.len != 2 or issue.path[1].index != 0)
        return error.WrongIssue;
}
