const z = @import("zigil");
const E = enum(u8) { known = 1, _ };
comptime {
    _ = z.Enumeration(E, &.{@fromBackingInt(@intCast(2))});
}
