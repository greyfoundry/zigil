const z = @import("zigil");
fn invalid(value: u8) u8 {
    return value;
}
comptime {
    _ = z.Custom(u8, invalid, "invalid");
}
