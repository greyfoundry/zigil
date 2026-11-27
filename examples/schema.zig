const std = @import("std");
const z = @import("zigil");
const Config = struct { name: []const u8, port: u16 };
const Rule = z.Struct(Config, .{
    .name = z.String(.{ .unit = .code_points, .length = .{ .min = 1, .max = 8 } }),
    .port = z.Default(z.Int(u16, .{ .min = 1 }), 443),
});
pub fn main() !void {
    var schema = try z.exportSchema(Rule, std.heap.page_allocator, .{});
    defer schema.deinit();
    // stderr keeps the example portable; tooling captures the emitted schema.
    std.debug.print("{s}\n", .{schema.json});
}
