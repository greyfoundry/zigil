const z = @import("zigil");
comptime {
    _ = z.Struct(struct { age: u8 }, .{});
}
