//! Optional, pinned native NFA adapter. Only the declared ECMAScript-compatible
//! subset is accepted; unsupported constructs fail at schema compilation.
const std = @import("std");
pub const enabled = @import("features").schema_regex;
const engine = if (enabled) @import("ezi_gex") else struct {};
const Regex = if (enabled) engine.Compiled(engine.backends.pikevm) else void;
pub const Program = struct {
    regex: Regex,
    pub fn compile(allocator: std.mem.Allocator, pattern: []const u8) !Program {
        if (!enabled) return error.PatternEngineUnavailable;
        if (pattern.len > 1024) return error.PatternLimitExceeded;
        var translated: std.array_list.Managed(u8) = .init(allocator);
        var in_class = false;
        var depth: usize = 0;
        const whitespace = "\\t\\n\\v\\f\\r \\u00a0\\u1680\\u2000-\\u200a\\u2028\\u2029\\u202f\\u205f\\u3000\\ufeff";
        var index: usize = 0;
        while (index < pattern.len) : (index += 1) {
            const byte = pattern[index];
            switch (byte) {
                '\\' => {
                    index += 1;
                    if (index == pattern.len) return error.InvalidPattern;
                    const escaped = pattern[index];
                    if (escaped == 'c') {
                        index += 1;
                        if (index == pattern.len or !std.ascii.isAlphabetic(pattern[index])) return error.InvalidPattern;
                        try translated.appendSlice(try std.fmt.allocPrint(allocator, "\\x{x:0>2}", .{pattern[index] % 32}));
                        continue;
                    }
                    if ((escaped == 'p' or escaped == 'P') and std.mem.startsWith(u8, pattern[index + 1 ..], "{digit}")) {
                        try translated.appendSlice(if (escaped == 'p') "\\p{Nd}" else "\\P{Nd}");
                        index += 7;
                        continue;
                    }
                    if (escaped >= '1' and escaped <= '9') return error.UnsupportedPattern;
                    if (std.mem.indexOfScalar(u8, "bBAzZXRCk", escaped) != null) return error.UnsupportedPattern;
                    if (escaped == 's' or escaped == 'S') {
                        if (in_class and escaped == 'S') return error.UnsupportedPattern;
                        if (!in_class) try translated.appendSlice(if (escaped == 'S') "[^" else "[");
                        try translated.appendSlice(whitespace);
                        if (!in_class) try translated.append(']');
                    } else {
                        // Reject non-ECMAScript alphabetic identity escapes.
                        if (std.ascii.isAlphabetic(escaped) and std.mem.indexOfScalar(u8, "dDwWnrtvfuxpP", escaped) == null) return error.UnsupportedPattern;
                        try translated.append('\\');
                        try translated.append(escaped);
                    }
                },
                '[' => {
                    in_class = true;
                    try translated.append(byte);
                },
                ']' => {
                    in_class = false;
                    try translated.append(byte);
                },
                '(' => {
                    if (!in_class) {
                        depth += 1;
                        if (depth > 32) return error.PatternLimitExceeded;
                        if (index + 1 < pattern.len and pattern[index + 1] == '?' and !(index + 2 < pattern.len and pattern[index + 2] == ':')) return error.UnsupportedPattern;
                    }
                    try translated.append(byte);
                },
                ')' => {
                    if (!in_class) {
                        if (depth == 0) return error.InvalidPattern;
                        depth -= 1;
                    }
                    try translated.append(byte);
                },
                '.' => try translated.appendSlice(if (in_class) "." else "[^\\n\\r\\u2028\\u2029]"),
                '$' => {
                    if (in_class) try translated.append(byte) else {
                        if (index + 1 != pattern.len) return error.UnsupportedPattern;
                        try translated.appendSlice("(?:\\r\\n|[\\n\\r\\u2028\\u2029])?\\z");
                    }
                },
                else => try translated.append(byte),
            }
        }
        if (in_class or depth != 0) return error.InvalidPattern;
        var diagnostic: engine.Diagnostic = undefined;
        const regex = try engine.compileRuntimeWith(engine.backends.pikevm, allocator, translated.items, &diagnostic, .{ .unicode = false, .max_repetition = 256, .size_limit = 16_384 });
        return .{ .regex = regex };
    }
    pub fn workUnits(self: *const Program) usize {
        if (!enabled) return 0;
        return self.regex.program.insts.len + self.regex.program.ranges.len + 1;
    }
    pub fn matches(self: *const Program, allocator: std.mem.Allocator, text: []const u8) !bool {
        if (!enabled) return error.PatternEngineUnavailable;
        var scratch = try self.regex.initScratch(allocator);
        defer scratch.deinit(allocator);
        return self.regex.isMatch(&scratch, text);
    }
};
