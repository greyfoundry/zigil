const z = @import("zigil");
comptime {
    _ = z.Struct(struct { age: u8 }, .{ .age = z.Int(u8, .{}), .typo = z.Int(u8, .{}) });
}
