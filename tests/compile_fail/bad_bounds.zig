const z = @import("zigil");
comptime {
    _ = z.Int(i32, .{ .min = 5, .max = 4 });
}
