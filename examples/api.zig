const std = @import("std");
const z = @import("zigil");
const Request = struct { name: []const u8, retries: u8 };
const Rule = z.Struct(Request, .{
    .name = z.String(.{ .unit = .code_points, .length = .{ .min = 1, .max = 40 } }),
    .retries = z.Default(z.Int(u8, .{ .max = 5 }), 2),
});
pub fn main() !void {
    // Boundary validation is separate from authentication and authorization.
    var request = try z.decodeJson(Rule, std.heap.page_allocator, "{\"name\":\"worker\"}", .{});
    defer request.deinit();
    if (request.outcome != .valid or request.outcome.valid.retries != 2) return error.InvalidRequest;
    var fragment = try z.openapi.exportSchema(Rule, std.heap.page_allocator, .{ .direction = .input });
    defer fragment.deinit();
    var schema = try z.runtime.compile(std.heap.page_allocator, fragment.json, &.{}, .{});
    defer schema.deinit();
    var valid = try schema.validate(std.heap.page_allocator, "{\"name\":\"worker\"}", .{});
    defer valid.deinit();
    if (valid.outcome != .valid) return error.SchemaMismatch;
}
