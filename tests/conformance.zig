//! Pinned official fixtures; reporting distinguishes dialect/tag exclusion,
//! unsupported schemas, operational errors and actual validity mismatches.
const std = @import("std");
const z = @import("zigil");
const V = std.json.Value;
fn compatible(case: V) bool {
    const value = case.object.get("compatibility") orelse return true;
    var constraints = std.mem.splitScalar(u8, value.string, ',');
    var valid = true;
    while (constraints.next()) |constraint| {
        const le = std.mem.startsWith(u8, constraint, "<=");
        const eq = std.mem.startsWith(u8, constraint, "=");
        const version = std.fmt.parseInt(u32, constraint[if (le) @as(usize, 2) else if (eq) @as(usize, 1) else @as(usize, 0)..], 10) catch unreachable;
        valid = if (le) 2020 <= version else if (eq) 2020 == version else 2020 >= version;
        if (2020 <= version) break;
    }
    return valid;
}
fn annotation(case: V) bool {
    if (case.object.get("tags")) |tags| for (tags.array.items) |tag| if (std.mem.eql(u8, tag.string, "format-assertion")) return false;
    return true;
}
pub fn main() !void {
    var passed: usize = 0;
    var failed: usize = 0;
    var unsupported: usize = 0;
    var excluded: usize = 0;
    var errors: usize = 0;
    var mandatory_unsupported: usize = 0;
    var mandatory_passed: usize = 0;
    var optional_profile_excluded: usize = 0;
    for (@import("conformance_files.zig").files) |file| {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const corpus = try std.json.parseFromSliceLeaky(V, a, file[1], .{ .parse_numbers = false });
        for (corpus.object.get("tests").?.array.items) |case| {
            const tests = case.object.get("tests").?.array.items;
            // These optional profiles change defaults or add retired keywords;
            // they are not part of the declared 2020-12 annotation profile.
            if (std.mem.eql(u8, file[0], "optional/dependencies-compatibility.json") or std.mem.eql(u8, file[0], "optional/format-assertion.json")) {
                optional_profile_excluded += tests.len;
                continue;
            }
            if (!compatible(case) or !annotation(case)) {
                excluded += tests.len;
                continue;
            }
            const source = try std.json.Stringify.valueAlloc(a, case.object.get("schema").?, .{});
            var registry: std.array_list.Managed(z.runtime.RegistryEntry) = .init(a);
            if (case.object.get("externalSchemas")) |external| for (external.object.keys(), external.object.values()) |uri, schema| try registry.append(.{ .uri = uri, .schema = try std.json.Stringify.valueAlloc(a, schema, .{}) });
            var schema = z.runtime.compile(a, source, registry.items, .{ .json = .{ .max_allocated_bytes = 64 * 1024 * 1024 } }) catch |err| {
                switch (err) {
                    error.UnsupportedDialect, error.UnsupportedVocabulary, error.UnsupportedPattern, error.PatternEngineUnavailable => {
                        unsupported += tests.len;
                        if (!std.mem.startsWith(u8, file[0], "optional/")) mandatory_unsupported += tests.len;
                    },
                    else => errors += tests.len,
                }
                std.debug.print("SCHEMA {s}: {s}: {s}\n", .{ file[0], case.object.get("description").?.string, @errorName(err) });
                continue;
            };
            defer schema.deinit();
            for (tests) |test_case| {
                const input = try std.json.Stringify.valueAlloc(a, test_case.object.get("data").?, .{});
                var result = schema.validate(a, input, .{ .max_work = 50_000_000, .max_depth = 128, .json = .{ .max_allocated_bytes = 64 * 1024 * 1024 } }) catch |err| {
                    errors += 1;
                    std.debug.print("ERROR {s}: {s}: {s}\n", .{ file[0], test_case.object.get("description").?.string, @errorName(err) });
                    continue;
                };
                defer result.deinit();
                const valid = result.outcome == .valid;
                if (valid == test_case.object.get("valid").?.bool) {
                    passed += 1;
                    if (!std.mem.startsWith(u8, file[0], "optional/")) mandatory_passed += 1;
                } else {
                    failed += 1;
                    std.debug.print("FAIL {s}: {s}: {s} expected={} actual={}\n", .{ file[0], case.object.get("description").?.string, test_case.object.get("description").?.string, test_case.object.get("valid").?.bool, valid });
                }
            }
        }
    }
    std.debug.print("CONFORMANCE {{\"passed\":{d},\"failed\":{d},\"unsupported\":{d},\"excluded_dialect_or_tag\":{d},\"errors\":{d}}}\n", .{ passed, failed, unsupported, excluded, errors });
    std.debug.print("PROFILE {{\"mandatory_passed\":{d},\"mandatory_unsupported\":{d},\"optional_profile_excluded\":{d}}}\n", .{ mandatory_passed, mandatory_unsupported, optional_profile_excluded });
    if (failed > 0 or errors > 0 or mandatory_unsupported > 0) return error.ConformanceFailure;
}
