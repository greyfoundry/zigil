const std = @import("std");
const z = @import("zigil");
const Config = struct { port: u16, label: z.Presence([]const u8) };
const Rule = z.Struct(Config, .{
    .port = z.Int(u16, .{ .min = 1 }),
    .label = z.Field(z.String(.{}), .{ .optional = true, .nullable = true }),
});

pub fn main() !void {
    var result = try z.decodeJson(Rule, std.heap.page_allocator, "{\"port\":443}", .{});
    defer result.deinit(); // Required for all three outcomes.
    switch (result.outcome) {
        .valid => |config| {
            if (config.port != 443 or config.label != .missing) return error.UnexpectedValue;
        },
        .invalid => |issue| {
            var buffer: [256]u8 = undefined;
            std.debug.print("{s}: {s}\n", .{ try issue.jsonPointer(&buffer), issue.message });
            return error.InvalidConfig;
        },
        .malformed => |syntax| {
            std.debug.print("Malformed JSON at byte {d}\n", .{syntax.byte_offset});
            return error.MalformedConfig;
        },
    }
}
