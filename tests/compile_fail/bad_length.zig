const z = @import("zigil");
comptime {
    _ = z.String(.{ .length = .{ .min = 5, .max = 4 } });
}
