const std = @import("std");
const z = @import("zigil");

const User = struct { name: []const u8, age: u8, nickname: ?[]const u8 };
const UserRule = z.Struct(User, .{
    .name = z.String(.{ .length = .{ .min = 1, .max = 80 } }),
    .age = z.Int(u8, .{ .min = 18 }),
    .nickname = z.Optional(z.String(.{ .length = .{ .max = 40 } })),
});

pub fn main() !void {
    var path: [4]z.Segment = undefined;
    const good: User = .{ .name = "Astoris", .age = 20, .nickname = null };
    if (z.validate(UserRule, good, &path) != null) return error.UnexpectedIssue;
    const bad: User = .{ .name = "", .age = 20, .nickname = null };
    const issue = z.validate(UserRule, bad, &path) orelse return error.ExpectedIssue;
    // Field names and indices are separate typed segments, never an ambiguous
    // dotted string. Inspect/copy the path before reusing its backing buffer.
    if (!std.mem.eql(u8, issue.path[0].field, "name")) return error.WrongPath;
    std.debug.print("{s}: {s}\n", .{ @tagName(issue.code), issue.message });
}
