const z = @import("zigil");
comptime {
    _ = z.validate(z.Int(u8, .{}), 256, &.{});
}
