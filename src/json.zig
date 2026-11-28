//! Strict JSON decoding. std.json owns JSON syntax; this adapter owns native
//! type policy, resource limits and the lifetime of all returned data.
const std = @import("std");
const core = @import("core.zig");
const decimal = @import("decimal.zig");
const Allocator = std.mem.Allocator;
pub const Value = std.json.Value;

pub const Options = struct {
    max_input_bytes: usize = 1_048_576,
    max_depth: usize = 64,
    max_tokens: usize = 100_000,
    max_members: usize = 10_000,
    max_string_bytes: usize = 65_536,
    /// Cumulative successful underlying allocation requests, including arenas.
    max_allocated_bytes: usize = 16_777_216,
    validation: core.Limits = .{},
    numbers: decimal.Limits = .{},
    float_rounding: enum { exact, nearest } = .exact,
};

pub const Syntax = struct { byte_offset: u64 };

// Heap-stable state is required: the arena retains its allocator context until
// the owning result is destroyed. A stack-backed budget context would dangle.
pub const State = struct {
    parent: Allocator,
    used: usize,
    maximum: usize,
    quota_denied: bool = false,
    arena: std.heap.ArenaAllocator,

    pub fn create(parent: Allocator, maximum: usize) !*State {
        if (maximum < @sizeOf(State)) return error.AllocationLimitExceeded;
        const self = try parent.create(State);
        self.* = .{ .parent = parent, .used = @sizeOf(State), .maximum = maximum, .arena = undefined };
        self.arena = std.heap.ArenaAllocator.init(self.budget());
        return self;
    }

    pub fn destroy(self: *State) void {
        const parent = self.parent;
        self.arena.deinit();
        parent.destroy(self);
    }

    pub fn allocator(self: *State) Allocator {
        return self.arena.allocator();
    }

    pub fn allocationFailure(self: *State) error{ OutOfMemory, AllocationLimitExceeded } {
        return if (self.quota_denied) error.AllocationLimitExceeded else error.OutOfMemory;
    }

    fn budget(self: *State) Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = Allocator.noResize, .remap = Allocator.noRemap, .free = free } };
    }

    fn alloc(pointer: *anyopaque, len: usize, alignment: std.mem.Alignment, address: usize) ?[*]u8 {
        const self: *State = @ptrCast(@alignCast(pointer));
        self.quota_denied = len > self.maximum - self.used;
        if (self.quota_denied) return null;
        const result = self.parent.rawAlloc(len, alignment, address) orelse return null;
        self.used += len;
        return result;
    }

    fn free(pointer: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, address: usize) void {
        const self: *State = @ptrCast(@alignCast(pointer));
        self.parent.rawFree(bytes, alignment, address);
    }
};

pub const Document = struct {
    state: *State,
    outcome: union(enum) { value: Value, malformed: Syntax, duplicate: void },

    pub fn deinit(self: *Document) void {
        self.state.destroy();
        self.* = undefined;
    }
};

/// Parse a bounded, owning JSON document without numeric precision loss.
/// Number lexemes remain number_string; duplicate object keys are rejected.
pub fn parse(parent: Allocator, input: []const u8, options: Options) !Document {
    if (input.len > options.max_input_bytes) return error.InputLimitExceeded;
    if (options.max_depth > 256) return error.DepthLimitExceeded;
    const state = try State.create(parent, options.max_allocated_bytes);
    errdefer state.destroy();
    var scanner = std.json.Scanner.initCompleteInput(state.budget(), input);
    defer scanner.deinit();
    var diagnostics: std.json.Diagnostics = .{};
    scanner.enableDiagnostics(&diagnostics);
    const Frame = struct { object: bool, key: bool = true, members: usize = 0 };
    var frames: [256]Frame = undefined;
    var depth: usize = 0;
    var tokens: usize = 0;
    while (true) {
        if (tokens == options.max_tokens) return error.TokenLimitExceeded;
        tokens += 1;
        const token = scanner.nextAllocMax(state.budget(), .alloc_if_needed, options.max_string_bytes) catch |err| switch (err) {
            error.OutOfMemory => return state.allocationFailure(),
            error.ValueTooLong => return error.StringLimitExceeded,
            else => return .{ .state = state, .outcome = .{ .malformed = .{ .byte_offset = diagnostics.getByteOffset() } } },
        };
        defer switch (token) {
            .allocated_string, .allocated_number => |bytes| state.budget().free(bytes),
            else => {},
        };
        switch (token) {
            .end_of_document => break,
            .object_end, .array_end => depth -= 1,
            else => {
                const is_key = depth > 0 and frames[depth - 1].object and frames[depth - 1].key;
                if (depth > 0) {
                    const frame = &frames[depth - 1];
                    if (is_key or !frame.object) {
                        if (frame.members == options.max_members) return error.MemberLimitExceeded;
                        frame.members += 1;
                    }
                    if (frame.object) frame.key = !is_key;
                }
                switch (token) {
                    .string, .number, .allocated_string, .allocated_number => |bytes| {
                        if (bytes.len > options.max_string_bytes) return error.StringLimitExceeded;
                    },
                    .object_begin, .array_begin => {
                        if (depth == options.max_depth) return error.DepthLimitExceeded;
                        frames[depth] = .{ .object = token == .object_begin };
                        depth += 1;
                    },
                    else => {},
                }
            },
        }
    }
    const value = std.json.parseFromSliceLeaky(Value, state.allocator(), input, .{
        .allocate = .alloc_always,
        .parse_numbers = false,
        .duplicate_field_behavior = .@"error",
        .max_value_len = options.max_string_bytes,
    }) catch |err| switch (err) {
        error.OutOfMemory => return state.allocationFailure(),
        error.DuplicateField => return .{ .state = state, .outcome = .duplicate },
        else => return .{ .state = state, .outcome = .{ .malformed = .{ .byte_offset = 0 } } },
    };
    return .{ .state = state, .outcome = .{ .value = value } };
}

pub fn Decoded(comptime T: type) type {
    return struct {
        state: *State,
        outcome: union(enum) { valid: T, invalid: core.Issue, malformed: Syntax },

        /// Release output and issue storage. Move this result; do not copy it.
        pub fn deinit(self: *@This()) void {
            self.state.destroy();
            self.* = undefined;
        }
    };
}

const DecodeContext = struct {
    state: *State,
    path: []core.Segment,
    depth: usize = 0,
    recursion_depth: usize = 0,
    issue: ?core.Issue = null,
    work: usize = 0,
    max_work: usize,
    options: Options,

    fn fail(self: *DecodeContext, code: core.Code, message: []const u8) error{Reported} {
        self.issue = .{ .code = code, .path = self.path[0..self.depth], .message = message };
        return error.Reported;
    }

    fn charge(self: *DecodeContext, amount: usize) core.ResourceError!void {
        if (amount > self.max_work - self.work) return error.WorkLimitExceeded;
        self.work += amount;
    }

    fn push(self: *DecodeContext, segment: core.Segment) !void {
        if (self.depth == self.path.len or self.depth >= self.options.validation.max_depth) return error.DepthLimitExceeded;
        self.path[self.depth] = segment;
        self.depth += 1;
    }
};

/// Strictly decode Rule.Value, then validate it. The returned result owns all
/// strings, slices and paths; input can be freed immediately. Always deinit the
/// result, including invalid/malformed outcomes. No defaults or coercion occur.
pub fn decode(comptime Rule: type, allocator: Allocator, input: []const u8, options: Options) !Decoded(Rule.Value) {
    const document = try parse(allocator, input, options);
    errdefer document.state.destroy();
    const state = document.state;
    switch (document.outcome) {
        .malformed => |syntax| return .{ .state = state, .outcome = .{ .malformed = syntax } },
        .duplicate => return .{ .state = state, .outcome = .{ .invalid = .{ .code = .duplicate_field, .path = &.{}, .message = "duplicate JSON object member" } } },
        .value => |value| {
            const path = state.allocator().alloc(core.Segment, options.max_depth) catch return state.allocationFailure();
            var ctx: DecodeContext = .{ .state = state, .path = path, .max_work = options.validation.max_work, .options = options };
            const typed = fromRule(Rule, value, &ctx) catch |err| switch (err) {
                error.Reported => return .{ .state = state, .outcome = .{ .invalid = ctx.issue.? } },
                error.OutOfMemory => return state.allocationFailure(),
                else => return err,
            };
            if (try core.validateWithLimits(Rule, typed, path, options.validation)) |issue|
                return .{ .state = state, .outcome = .{ .invalid = issue } };
            return .{ .state = state, .outcome = .{ .valid = typed } };
        },
    }
}

// Rule-directed decoding preserves explicit defaults, transformations and
// composition. Native reflection remains the fallback for custom leaf types.
fn fromRule(comptime Rule: type, value: Value, ctx: *DecodeContext) anyerror!Rule.Value {
    if (!@hasDecl(Rule, "kind")) return fromValue(Rule.Value, value, ctx);
    const T = Rule.Value;
    switch (Rule.kind) {
        .refinement, .default => return fromRule(Rule.ChildRule, value, ctx),
        .recursive => {
            if (ctx.recursion_depth == ctx.options.max_depth or ctx.recursion_depth >= ctx.options.validation.max_depth) return error.DepthLimitExceeded;
            ctx.recursion_depth += 1;
            defer ctx.recursion_depth -= 1;
            try ctx.charge(1);
            return fromRule(Rule.resolve(), value, ctx);
        },
        .transform => {
            const input = try fromRule(Rule.InputRule, value, ctx);
            // Validate before invoking user code; its operational errors remain
            // errors, not invalid input. Arena allocation failures are translated.
            var validation_context: core.Context = .{ .path = ctx.path, .depth = ctx.depth, .limits = ctx.options.validation, .work = ctx.work };
            const finding = try core.checkRule(Rule.InputRule, input, &validation_context);
            ctx.work = validation_context.work;
            if (finding) |issue| {
                ctx.issue = issue;
                return error.Reported;
            }
            const converted = Rule.convert(ctx.state.allocator(), input);
            return if (@typeInfo(@TypeOf(converted)) == .error_union) try converted else converted;
        },
        .optional => return if (value == .null) null else try fromRule(Rule.ChildRule, value, ctx),
        .field => return if (value == .null) .null_value else .{ .value = try fromRule(Rule.ChildRule, value, ctx) },
        .sequence => {
            if (value != .array) return ctx.fail(.type_mismatch, "expected a JSON array");
            const info = @typeInfo(T);
            if (info == .array and value.array.items.len != info.array.len) return ctx.fail(.type_mismatch, "array length must match the native array");
            var result: if (info == .array) T else []Rule.ChildRule.Value = if (info == .array) undefined else try ctx.state.allocator().alloc(Rule.ChildRule.Value, value.array.items.len);
            for (value.array.items, 0..) |item, index| {
                try ctx.charge(1);
                try ctx.push(.{ .index = index });
                result[index] = try fromRule(Rule.ChildRule, item, ctx);
                ctx.depth -= 1;
            }
            return result;
        },
        .tuple => {
            if (value != .array or value.array.items.len != Rule.element_rules.len) return ctx.fail(.type_mismatch, "expected a fixed-length JSON tuple");
            var result: T = undefined;
            inline for (Rule.element_rules, 0..) |Child, index| {
                try ctx.charge(1);
                try ctx.push(.{ .index = index });
                result[index] = try fromRule(Child, value.array.items[index], ctx);
                ctx.depth -= 1;
            }
            return result;
        },
        .object => {
            if (value != .object) return ctx.fail(.type_mismatch, "expected a JSON object");
            const info = @typeInfo(T).@"struct";
            for (value.object.keys()) |key| {
                var known = false;
                inline for (info.field_names) |name| if (!known) {
                    try ctx.charge(1);
                    try ctx.charge(@min(name.len, key.len));
                    known = std.mem.eql(u8, key, name);
                };
                if (!known) {
                    try ctx.push(.{ .field = key });
                    return ctx.fail(.unknown_field, "unknown JSON object member");
                }
            }
            var result: T = undefined;
            inline for (info.field_names, info.field_types) |name, FieldType| {
                const Child = @field(Rule.field_rules, name);
                try ctx.charge(1);
                try ctx.push(.{ .field = name });
                @field(result, name) = if (value.object.get(name)) |item| try fromRule(Child, item, ctx) else missing: {
                    if (@hasDecl(Child, "default_value")) break :missing Child.default_value;
                    if (@typeInfo(FieldType) == .@"union" and @hasDecl(FieldType, "zigil_presence")) break :missing .missing;
                    return ctx.fail(.missing_field, "required JSON object member is missing");
                };
                ctx.depth -= 1;
            }
            return result;
        },
        .tagged_union => {
            if (value != .object) return ctx.fail(.type_mismatch, "expected a tagged JSON object");
            for (value.object.keys()) |key| {
                try ctx.charge(1);
                try ctx.charge(key.len);
                if (!std.mem.eql(u8, key, "tag") and !std.mem.eql(u8, key, "value")) {
                    try ctx.push(.{ .field = key });
                    return ctx.fail(.unknown_field, "unknown tagged union member");
                }
            }
            try ctx.push(.{ .field = "tag" });
            const tag = value.object.get("tag") orelse return ctx.fail(.missing_field, "union tag is missing");
            if (tag != .string) return ctx.fail(.union_tag, "union tag must be a string");
            inline for (@typeInfo(T).@"union".field_names) |name| {
                try ctx.charge(1);
                try ctx.charge(@min(name.len, tag.string.len));
                if (std.mem.eql(u8, name, tag.string)) {
                    ctx.depth -= 1;
                    try ctx.push(.{ .field = "value" });
                    const payload = value.object.get("value") orelse return ctx.fail(.missing_field, "union value is missing");
                    const result = @unionInit(T, name, try fromRule(@field(Rule.variant_rules, name), payload, ctx));
                    ctx.depth -= 1;
                    return result;
                }
            }
            return ctx.fail(.union_tag, "unknown union tag");
        },
        .map => {
            if (value != .object) return ctx.fail(.type_mismatch, "expected a JSON map object");
            var result: T = .empty;
            for (value.object.keys(), value.object.values()) |key, item| {
                try ctx.charge(1);
                try ctx.charge(key.len);
                try ctx.push(.{ .field = key });
                try result.put(ctx.state.allocator(), key, try fromRule(Rule.ChildRule, item, ctx));
                ctx.depth -= 1;
            }
            return result;
        },
        else => return fromValue(T, value, ctx),
    }
}

fn fromValue(comptime T: type, value: Value, ctx: *DecodeContext) (Allocator.Error || core.ResourceError || error{ Reported, UnsupportedType, NumericLimitExceeded, InvalidCharacter, InvalidBase })!T {
    try ctx.charge(1);
    return switch (@typeInfo(T)) {
        .bool => if (value == .bool) value.bool else ctx.fail(.type_mismatch, "expected a JSON boolean"),
        .int => block: {
            if (value != .number_string) return ctx.fail(.type_mismatch, "expected a JSON number");
            const number = try decimal.Decimal.parse(ctx.state.allocator(), value.number_string, ctx.options.numbers);
            break :block number.toInt(T) catch return ctx.fail(.invalid_number, "expected an exactly representable integer");
        },
        .float => block: {
            if (value != .number_string) return ctx.fail(.type_mismatch, "expected a JSON number");
            const number = std.fmt.parseFloat(T, value.number_string) catch return ctx.fail(.invalid_number, "invalid floating-point value");
            if (!std.math.isFinite(number)) return ctx.fail(.invalid_number, "floating-point overflow is not permitted");
            // Reject nonzero values rounded to zero (underflow).
            if (number == 0) {
                const significant = std.mem.sliceTo(value.number_string, 'e');
                const mantissa = std.mem.sliceTo(significant, 'E');
                for (mantissa) |byte| if (byte >= '1' and byte <= '9') return ctx.fail(.invalid_number, "floating-point underflow is not permitted");
            }
            if (ctx.options.float_rounding == .exact) {
                const exact = try decimal.Decimal.parse(ctx.state.allocator(), value.number_string, ctx.options.numbers);
                if (!try exact.exactFloat(T, ctx.state.allocator())) return ctx.fail(.invalid_number, "float rounding requires explicit nearest policy");
            }
            break :block number;
        },
        .optional => |info| if (value == .null) null else try fromValue(info.child, value, ctx),
        .@"enum" => if (value == .string) std.meta.stringToEnum(T, value.string) orelse ctx.fail(.enum_value, "unknown enum name") else ctx.fail(.type_mismatch, "expected an enum name string"),
        .pointer => |info| block: {
            if (info.size != .slice or info.sentinel_ptr != null) return error.UnsupportedType;
            if (info.child == u8) {
                if (value != .string) return ctx.fail(.type_mismatch, "expected a JSON string");
                break :block if (info.attrs.@"const") value.string else try ctx.state.allocator().dupe(u8, value.string);
            }
            if (value != .array) return ctx.fail(.type_mismatch, "expected a JSON array");
            const items = try ctx.state.allocator().alloc(info.child, value.array.items.len);
            for (value.array.items, 0..) |item, index| {
                try ctx.push(.{ .index = index });
                items[index] = try fromValue(info.child, item, ctx);
                ctx.depth -= 1;
            }
            break :block items;
        },
        .array => |info| block: {
            if (value != .array) return ctx.fail(.type_mismatch, "expected a JSON array");
            if (value.array.items.len != info.len) return ctx.fail(.type_mismatch, "array length must match the native array");
            var result: T = undefined;
            for (value.array.items, 0..) |item, index| {
                try ctx.push(.{ .index = index });
                result[index] = try fromValue(info.child, item, ctx);
                ctx.depth -= 1;
            }
            break :block result;
        },
        .@"struct" => |info| block: {
            if (info.is_tuple) return error.UnsupportedType;
            if (value != .object) return ctx.fail(.type_mismatch, "expected a JSON object");
            var result: T = undefined;
            for (value.object.keys()) |key| {
                var known = false;
                inline for (info.field_names) |name| {
                    if (!known) {
                        try ctx.charge(1);
                        try ctx.charge(@min(name.len, key.len));
                        known = std.mem.eql(u8, name, key);
                    }
                }
                if (!known) {
                    try ctx.push(.{ .field = key });
                    return ctx.fail(.unknown_field, "unknown JSON object member");
                }
            }
            inline for (info.field_names, info.field_types) |name, FieldType| {
                try ctx.push(.{ .field = name });
                @field(result, name) = if (value.object.get(name)) |field|
                    try fromValue(FieldType, field, ctx)
                else missing: {
                    if (@typeInfo(FieldType) == .@"union" and @hasDecl(FieldType, "zigil_presence")) break :missing .missing;
                    return ctx.fail(.missing_field, "required JSON object member is missing");
                };
                ctx.depth -= 1;
            }
            break :block result;
        },
        .@"union" => block: {
            if (!@hasDecl(T, "zigil_presence")) return error.UnsupportedType;
            if (value == .null) break :block .null_value;
            break :block .{ .value = try fromValue(T.zigil_presence, value, ctx) };
        },
        else => error.UnsupportedType,
    };
}
