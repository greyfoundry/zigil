const z = @import("zigil");

const Config = struct { workers: u16, names: []const []const u8 };
const Rule = z.Struct(Config, .{
    .workers = z.Int(u16, .{ .min = 1, .max = 64 }),
    .names = z.Slice(z.String(.{ .length = .{ .min = 1, .max = 80 } }), .{ .max = 10 }),
});

pub fn main() !void {
    var path: [2]z.Segment = undefined;
    if ((try z.validate(Rule, .{ .workers = 4, .names = &.{"worker"} }, &path)) != null)
        return error.UnexpectedIssue;
    const issue = (try z.validate(Rule, .{ .workers = 4, .names = &.{""} }, &path)) orelse return error.ExpectedIssue;
    if (issue.code != .too_short or issue.path.len != 2 or issue.path[1].index != 0)
        return error.WrongIssue;
}
