const z = @import("zigil");
comptime {
    _ = z.Struct(struct { age: u8 }, .{ .age = z.Int(u16, .{}) });
}
