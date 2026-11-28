//! OpenAPI 3.1 and 3.2 Schema Object fragments. Both specifications identify
//! the same base dialect URI. This does not generate/validate whole API documents.
const std = @import("std");
const schema = @import("schema.zig");
pub const dialect = "https://spec.openapis.org/oas/3.1/dialect/base";

/// Same ownership, limits, direction and unsupported conversions as schema export.
pub fn exportSchema(comptime Rule: type, allocator: std.mem.Allocator, options: schema.Options) !schema.Exported {
    var exported = try schema.exportSchema(Rule, allocator, options);
    errdefer exported.deinit();
    const arena = exported.state.allocator();
    var root = std.json.parseFromSliceLeaky(std.json.Value, arena, exported.json, .{ .parse_numbers = false }) catch return exported.state.allocationFailure();
    root.object.put(arena, "$schema", .{ .string = dialect }) catch return exported.state.allocationFailure();
    const output = std.json.Stringify.valueAlloc(arena, root, .{}) catch return exported.state.allocationFailure();
    if (output.len > options.max_output_bytes) return error.OutputLimitExceeded;
    exported.json = output;
    return exported;
}
