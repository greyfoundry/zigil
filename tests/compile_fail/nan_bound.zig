const z = @import("zigil");
const std = @import("std");
comptime {
    _ = z.Float(f64, .{ .min = std.math.nan(f64) });
}
