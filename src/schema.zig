//! Deterministic Draft 2020-12 export. Unsupported conversions are errors,
//! never annotations pretending to enforce native constraints.
const std = @import("std");
const core = @import("core.zig");
const json = @import("json.zig");
const V = std.json.Value;
pub const dialect = "https://json-schema.org/draft/2020-12/schema";
pub const Direction = enum { input, output };
pub const Options = struct {
    direction: Direction = .input,
    max_depth: usize = 64,
    max_nodes: usize = 10_000,
    max_output_bytes: usize = 1_048_576,
    max_allocated_bytes: usize = 16_777_216,
};
pub const Exported = struct {
    state: *json.State,
    /// Owned by this handle. Move, do not copy; always deinit.
    json: []const u8,
    pub fn deinit(self: *Exported) void {
        self.state.destroy();
        self.* = undefined;
    }
};

pub fn exportSchema(comptime Rule: type, allocator: std.mem.Allocator, options: Options) !Exported {
    if (options.max_depth > 256) return error.DepthLimitExceeded;
    const state = try json.State.create(allocator, options.max_allocated_bytes);
    errdefer state.destroy();
    var builder: Builder = .{ .state = state, .options = options };
    const root = buildRoot(Rule, &builder) catch |err| switch (err) {
        error.OutOfMemory => return state.allocationFailure(),
        else => return err,
    };
    const bytes = std.json.Stringify.valueAlloc(state.allocator(), root, .{}) catch return state.allocationFailure();
    if (bytes.len > options.max_output_bytes) return error.OutputLimitExceeded;
    return .{ .state = state, .json = bytes };
}

const Builder = struct {
    state: *json.State,
    options: Options,
    nodes: usize = 0,
    depth: usize = 0,
    definitions: V = .{ .object = .empty },
    seen: std.array_hash_map.String([]const u8) = .empty,

    fn object(_: *Builder) V {
        return .{ .object = .empty };
    }
    fn array(self: *Builder) V {
        return .{ .array = if (@hasDecl(std.json.Array, "init")) .init(self.state.allocator()) else .empty };
    }
    fn put(self: *Builder, value: *V, key: []const u8, item: V) !void {
        try value.object.put(self.state.allocator(), key, item);
    }
    fn append(self: *Builder, value: *V, item: V) !void {
        // Actual std.json.Array churn observed by the pinned advisory compiler.
        if (@hasDecl(std.json.Array, "init")) try value.array.append(item) else try value.array.append(self.state.allocator(), item);
    }
    fn number(self: *Builder, value: anytype) !V {
        return .{ .number_string = try std.fmt.allocPrint(self.state.allocator(), "{d}", .{value}) };
    }
    fn typed(self: *Builder, name: []const u8) !V {
        var result = self.object();
        try self.put(&result, "type", .{ .string = name });
        return result;
    }
    fn length(self: *Builder, result: *V, comptime limits: core.Length, min: []const u8, max: []const u8) !void {
        if (limits.min > 0) try self.put(result, min, try self.number(limits.min));
        if (limits.max) |limit| try self.put(result, max, try self.number(limit));
    }
};

fn buildRoot(comptime Rule: type, b: *Builder) !V {
    var result = b.object();
    try b.put(&result, "$schema", .{ .string = dialect });
    const schema = try build(Rule, b);
    for (schema.object.keys(), schema.object.values()) |key, value| try b.put(&result, key, value);
    if (b.definitions.object.count() > 0) try b.put(&result, "$defs", b.definitions);
    return result;
}

fn build(comptime Rule: type, b: *Builder) anyerror!V {
    if (b.nodes == b.options.max_nodes) return error.SchemaNodeLimitExceeded;
    if (b.depth == b.options.max_depth) return error.DepthLimitExceeded;
    b.nodes += 1;
    b.depth += 1;
    defer b.depth -= 1;
    if (!@hasDecl(Rule, "kind")) return error.UnsupportedConversion;
    const T = Rule.Value;
    switch (Rule.kind) {
        .string => {
            const config = Rule.config;
            if (!config.utf8 or config.prefix != null or config.suffix != null) return error.UnsupportedConversion;
            if (config.unit == .bytes and (config.length.min != 0 or config.length.max != null)) return error.UnsupportedConversion;
            var result = try b.typed("string");
            try b.length(&result, config.length, "minLength", "maxLength");
            return result;
        },
        .integer => {
            var result = try b.typed("integer");
            try b.put(&result, "minimum", try b.number(Rule.config.min orelse std.math.minInt(T)));
            try b.put(&result, "maximum", try b.number(Rule.config.max orelse std.math.maxInt(T)));
            return result;
        },
        .boolean => {
            var result = try b.typed("boolean");
            if (Rule.expected_value) |expected| try b.put(&result, "const", .{ .bool = expected });
            return result;
        },
        .enumeration => {
            var result = try b.typed("string");
            var values = b.array();
            inline for (Rule.allowed_values) |tag| try b.append(&values, .{ .string = @tagName(tag) });
            // Empty enum is not a valid schema. An always-false applicator is.
            if (Rule.allowed_values.len == 0) {
                try b.put(&result, "not", .{ .object = .empty });
            } else try b.put(&result, "enum", values);
            return result;
        },
        .optional => return nullable(Rule.ChildRule, b),
        .field => {
            if (@typeInfo(Rule.ChildRule.Value) == .optional) return error.UnsupportedConversion;
            return if (Rule.config.nullable) nullable(Rule.ChildRule, b) else build(Rule.ChildRule, b);
        },
        .default => {
            var result = try build(Rule.ChildRule, b);
            // Only scalar defaults have a canonical JSON representation here.
            switch (@typeInfo(T)) {
                .bool, .int, .@"enum" => {},
                .pointer => |info| if (info.size != .slice or info.child != u8) {
                    return error.UnsupportedConversion;
                },
                else => return error.UnsupportedConversion,
            }
            var path: [256]core.Segment = undefined;
            if (try core.validate(Rule.ChildRule, Rule.default_value, &path) != null) return error.InvalidDefault;
            if (b.options.direction == .input) {
                // Zig's serializer is only used for an annotation, never parsing
                // native input. Number lexemes survive this conversion intact.
                const text = try std.json.Stringify.valueAlloc(b.state.allocator(), Rule.default_value, .{});
                const value = try std.json.parseFromSliceLeaky(V, b.state.allocator(), text, .{ .parse_numbers = false });
                try b.put(&result, "default", value);
            }
            return result;
        },
        .object => {
            var result = try b.typed("object");
            var properties = b.object();
            var required = b.array();
            inline for (@typeInfo(T).@"struct".field_names) |name| {
                const Child = @field(Rule.field_rules, name);
                try b.put(&properties, name, try build(Child, b));
                const absent = if (@hasDecl(Child, "kind")) switch (Child.kind) {
                    .field => Child.config.optional,
                    .default => b.options.direction == .input,
                    else => false,
                } else false;
                if (!absent) try b.append(&required, .{ .string = name });
            }
            try b.put(&result, "properties", properties);
            if (required.array.items.len > 0) try b.put(&result, "required", required);
            try b.put(&result, "additionalProperties", .{ .bool = false });
            return result;
        },
        .sequence => {
            var result = try b.typed("array");
            try b.put(&result, "items", try build(Rule.ChildRule, b));
            if (@typeInfo(T) == .array) {
                try b.put(&result, "minItems", try b.number(@typeInfo(T).array.len));
                try b.put(&result, "maxItems", try b.number(@typeInfo(T).array.len));
            } else try b.length(&result, Rule.config, "minItems", "maxItems");
            return result;
        },
        .tuple => {
            var result = try b.typed("array");
            var items = b.array();
            inline for (Rule.element_rules) |Child| try b.append(&items, try build(Child, b));
            if (Rule.element_rules.len > 0) try b.put(&result, "prefixItems", items);
            try b.put(&result, "items", .{ .bool = false });
            try b.put(&result, "minItems", try b.number(Rule.element_rules.len));
            return result;
        },
        .map => {
            var result = try b.typed("object");
            try b.put(&result, "propertyNames", try build(Rule.KeyRule, b));
            try b.put(&result, "additionalProperties", try build(Rule.ChildRule, b));
            try b.length(&result, Rule.config, "minProperties", "maxProperties");
            return result;
        },
        .tagged_union => {
            var result = b.object();
            var variants = b.array();
            inline for (@typeInfo(T).@"union".field_names) |name| {
                var variant = try b.typed("object");
                var properties = b.object();
                var tag = b.object();
                try b.put(&tag, "const", .{ .string = name });
                try b.put(&properties, "tag", tag);
                try b.put(&properties, "value", try build(@field(Rule.variant_rules, name), b));
                try b.put(&variant, "properties", properties);
                var required = b.array();
                try b.append(&required, .{ .string = "tag" });
                try b.append(&required, .{ .string = "value" });
                try b.put(&variant, "required", required);
                try b.put(&variant, "additionalProperties", .{ .bool = false });
                try b.append(&variants, variant);
            }
            try b.put(&result, "oneOf", variants);
            return result;
        },
        .recursive => {
            const key = @typeName(Rule);
            const name = b.seen.get(key) orelse new: {
                const name = try std.fmt.allocPrint(b.state.allocator(), "schema_{d}", .{b.seen.count()});
                try b.seen.put(b.state.allocator(), key, name);
                try b.put(&b.definitions, name, .{ .bool = true });
                const body = try build(Rule.resolve(), b);
                try b.put(&b.definitions, name, body);
                break :new name;
            };
            var result = b.object();
            try b.put(&result, "$ref", .{ .string = try std.fmt.allocPrint(b.state.allocator(), "#/$defs/{s}", .{name}) });
            return result;
        },
        // JSON Schema cannot assert native byte lengths, binary float fidelity,
        // arbitrary callbacks/transforms or our local format contract exactly.
        else => return error.UnsupportedConversion,
    }
}

fn nullable(comptime Child: type, b: *Builder) !V {
    var result = b.object();
    var variants = b.array();
    try b.append(&variants, try build(Child, b));
    try b.append(&variants, try b.typed("null"));
    try b.put(&result, "anyOf", variants);
    return result;
}
