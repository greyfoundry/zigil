//! Validation rules for native Zig values. Built-ins never allocate or mutate input.
//! Issue paths borrow the buffer supplied to validate; see docs/errors-ownership.mdx.
const std = @import("std");

/// A field name (static schema storage) or a zero-based collection index.
pub const Segment = union(enum) { field: []const u8, index: usize };

/// Machine-readable invalid-data codes. Operational failures use Zig errors.
pub const Code = enum {
    too_short,
    too_long,
    invalid_utf8,
    prefix,
    suffix,
    below_minimum,
    above_maximum,
    not_finite,
    boolean_mismatch,
    enum_value,
    custom,
    type_mismatch,
    missing_field,
    unknown_field,
    duplicate_field,
    invalid_number,
    null_not_allowed,
};

pub const Issue = struct {
    code: Code,
    /// Borrows the caller's path buffer; overwritten when that buffer is reused.
    path: []const Segment,
    /// Static rule text. Does not contain input values.
    message: []const u8,

    /// RFC 6901 JSON Pointer, borrowed from output. Root is the empty string.
    /// No allocation; a short buffer returns NoSpaceLeft, never a partial result.
    pub fn jsonPointer(self: Issue, output: []u8) error{NoSpaceLeft}![]const u8 {
        var offset: usize = 0;
        for (self.path) |segment| switch (segment) {
            .field => |field| {
                try appendByte(output, &offset, '/');
                for (field) |byte| switch (byte) {
                    '~', '/' => {
                        try appendByte(output, &offset, '~');
                        try appendByte(output, &offset, if (byte == '~') '0' else '1');
                    },
                    else => try appendByte(output, &offset, byte),
                };
            },
            .index => |index| {
                const rendered = try std.fmt.bufPrint(output[offset..], "/{d}", .{index});
                offset += rendered.len;
            },
        };
        return output[0..offset];
    }
};

fn appendByte(output: []u8, offset: *usize, byte: u8) error{NoSpaceLeft}!void {
    if (offset.* == output.len) return error.NoSpaceLeft;
    output[offset.*] = byte;
    offset.* += 1;
}

/// Per-operation limits, independent from domain constraints. Limits bound
/// built-in traversal; they cannot interrupt arbitrary custom callback code.
pub const Limits = struct {
    max_depth: usize = 64,
    max_work: usize = 1_000_000,
    max_bytes: usize = 1_048_576,
    max_items: usize = 100_000,
};

pub const ResourceError = error{
    PathCapacityExceeded,
    DepthLimitExceeded,
    WorkLimitExceeded,
    InputLimitExceeded,
    ItemLimitExceeded,
};

// Internal traversal state. On failure the path is left intact for the caller.
const Context = struct {
    path: []Segment,
    depth: usize = 0,
    limits: Limits,
    work: usize = 0,
    bytes: usize = 0,
    items: usize = 0,

    fn fail(self: *Context, code: Code, comptime message: []const u8) Issue {
        return .{ .code = code, .path = self.path[0..self.depth], .message = message };
    }

    fn push(self: *Context, segment: Segment) ResourceError!void {
        if (self.depth == self.limits.max_depth) return error.DepthLimitExceeded;
        if (self.depth == self.path.len) return error.PathCapacityExceeded;
        self.path[self.depth] = segment;
        self.depth += 1;
    }

    fn consumeWork(self: *Context, amount: usize) ResourceError!void {
        if (amount > self.limits.max_work - self.work) return error.WorkLimitExceeded;
        self.work += amount;
    }

    fn consumeBytes(self: *Context, amount: usize) ResourceError!void {
        if (amount > self.limits.max_bytes - self.bytes) return error.InputLimitExceeded;
        self.bytes += amount;
    }

    fn consumeItems(self: *Context, amount: usize) ResourceError!void {
        if (amount > self.limits.max_items - self.items) return error.ItemLimitExceeded;
        self.items += amount;
    }
};

/// On completed validation, returns null for valid data or the first issue.
/// Resource and callback errors propagate separately from invalid input.
/// Borrows value only during this call. An issue's path borrows path_buffer;
/// keep it alive and unchanged.
/// Built-in rules allocate nothing. Custom predicates own their own side effects.
pub fn validate(comptime Rule: type, value: Rule.Value, path_buffer: []Segment) !?Issue {
    return validateWithLimits(Rule, value, path_buffer, .{});
}

/// The same validation with explicit traversal budgets. Zig errors mean the
/// operation did not complete. A returned Issue means invalid data, not OOM.
/// Custom callback error sets propagate without conversion to invalidity.
pub fn validateWithLimits(comptime Rule: type, value: Rule.Value, path_buffer: []Segment, limits: Limits) !?Issue {
    var context: Context = .{ .path = path_buffer, .limits = limits };
    return checkRule(Rule, value, &context);
}

fn checkRule(comptime Rule: type, value: Rule.Value, ctx: *Context) !?Issue {
    try ctx.consumeWork(1);
    return Rule.check(value, ctx);
}

pub const Length = struct { min: usize = 0, max: ?usize = null };

fn checkLength(comptime length: Length) void {
    if (length.max) |max| {
        if (length.min > max) @compileError("Zigil: minimum length exceeds maximum length");
    }
}

fn lengthIssue(len: usize, comptime limits: Length, ctx: *Context) ?Issue {
    if (len < limits.min) return ctx.fail(.too_short, std.fmt.comptimePrint("length must be at least {d}", .{limits.min}));
    if (limits.max) |max| {
        if (len > max) return ctx.fail(.too_long, std.fmt.comptimePrint("length must be at most {d}", .{max}));
    }
    return null;
}

pub const StringOptions = struct {
    /// Length limits count bytes, including when utf8 is true.
    length: Length = .{},
    /// Validate UTF-8 by default; disable for arbitrary byte strings.
    utf8: bool = true,
    prefix: ?[]const u8 = null,
    suffix: ?[]const u8 = null,
};

pub fn String(comptime options: StringOptions) type {
    checkLength(options.length);
    return struct {
        pub const Value = []const u8;
        fn check(value: Value, ctx: *Context) !?Issue {
            try ctx.consumeBytes(value.len);
            // Reject oversized inputs before scanning their contents.
            if (lengthIssue(value.len, options.length, ctx)) |issue| return issue;
            if (options.utf8) {
                try ctx.consumeWork(value.len);
                if (!std.unicode.utf8ValidateSlice(value))
                    return ctx.fail(.invalid_utf8, "must contain valid UTF-8");
            }
            if (options.prefix) |prefix| {
                try ctx.consumeWork(@min(value.len, prefix.len));
                if (!std.mem.startsWith(u8, value, prefix)) return ctx.fail(.prefix, "must start with the configured prefix");
            }
            if (options.suffix) |suffix| {
                try ctx.consumeWork(@min(value.len, suffix.len));
                if (!std.mem.endsWith(u8, value, suffix)) return ctx.fail(.suffix, "must end with the configured suffix");
            }
            return null;
        }
    };
}

pub fn Bounds(comptime T: type) type {
    return struct { min: ?T = null, max: ?T = null };
}

fn checkBounds(comptime T: type, comptime bounds: Bounds(T)) void {
    if (@typeInfo(T) != .int and @typeInfo(T) != .float)
        @compileError("Zigil: bounds require an integer or floating-point type");
    if (@typeInfo(T) == .float) {
        if (bounds.min) |min| {
            if (!std.math.isFinite(min)) @compileError("Zigil: numeric bounds must be finite");
        }
        if (bounds.max) |max| {
            if (!std.math.isFinite(max)) @compileError("Zigil: numeric bounds must be finite");
        }
    }
    if (bounds.min) |min| {
        if (bounds.max) |max| {
            if (min > max) @compileError("Zigil: minimum exceeds maximum");
        }
    }
}

fn numberIssue(comptime T: type, value: T, comptime bounds: Bounds(T), ctx: *Context) ?Issue {
    if (bounds.min) |min| {
        if (value < min) return ctx.fail(.below_minimum, std.fmt.comptimePrint("must be at least {any}", .{min}));
    }
    if (bounds.max) |max| {
        if (value > max) return ctx.fail(.above_maximum, std.fmt.comptimePrint("must be at most {any}", .{max}));
    }
    return null;
}

pub fn Int(comptime T: type, comptime bounds: Bounds(T)) type {
    if (@typeInfo(T) != .int) @compileError("Zigil: Int requires an integer type");
    checkBounds(T, bounds);
    return struct {
        pub const Value = T;
        fn check(value: T, ctx: *Context) !?Issue {
            return numberIssue(T, value, bounds, ctx);
        }
    };
}

/// Rejects NaN and both infinities. Bounds are inclusive; no rounding/coercion.
pub fn Float(comptime T: type, comptime bounds: Bounds(T)) type {
    if (@typeInfo(T) != .float) @compileError("Zigil: Float requires a floating-point type");
    checkBounds(T, bounds);
    return struct {
        pub const Value = T;
        fn check(value: T, ctx: *Context) !?Issue {
            if (!std.math.isFinite(value)) return ctx.fail(.not_finite, "must be finite");
            return numberIssue(T, value, bounds, ctx);
        }
    };
}

/// null accepts either boolean; true or false requires that exact value.
pub fn Boolean(comptime expected: ?bool) type {
    return struct {
        pub const Value = bool;
        fn check(value: bool, ctx: *Context) !?Issue {
            if (expected) |required| {
                if (value != required) return ctx.fail(.boolean_mismatch, if (required) "must be true" else "must be false");
            }
            return null;
        }
    };
}

/// null allows all declared tags; a non-null slice selects a subset. Unknown
/// values of non-exhaustive enums are rejected even when allowed is null.
pub fn Enumeration(comptime T: type, comptime allowed: ?[]const T) type {
    if (@typeInfo(T) != .@"enum") @compileError("Zigil: Enumeration requires an enum type");
    const tags = std.meta.tags(T);
    if (allowed) |subset| {
        for (subset) |candidate| {
            var known = false;
            for (tags) |tag| {
                if (tag == candidate) known = true;
            }
            if (!known) @compileError("Zigil: enum subset contains an undeclared tag");
        }
    }
    return struct {
        pub const Value = T;
        fn check(value: T, ctx: *Context) !?Issue {
            for (allowed orelse tags) |candidate| {
                try ctx.consumeWork(1);
                if (value == candidate) return null;
            }
            return ctx.fail(.enum_value, "must be one of the permitted enum tags");
        }
    };
}

/// Native ?T: null succeeds; a present value is checked by Child. This does not
/// represent a missing wire-format field separately from explicit null.
pub fn Optional(comptime Child: type) type {
    return struct {
        pub const Value = ?Child.Value;
        fn check(value: Value, ctx: *Context) !?Issue {
            if (value) |present| return checkRule(Child, present, ctx);
            return null;
        }
    };
}

/// A rule for every field is required. Fields are checked in T's declaration order.
/// Extra/missing rules or mismatched native types are compile-time errors.
pub fn Struct(comptime T: type, comptime rules: anytype) type {
    if (@typeInfo(T) != .@"struct") @compileError("Zigil: Struct requires a struct type");
    const info = @typeInfo(T).@"struct";
    for (@typeInfo(@TypeOf(rules)).@"struct".field_names) |name| {
        if (!@hasField(T, name)) @compileError("Zigil: rule names an unknown field: " ++ name);
    }
    for (info.field_names, info.field_types) |name, FieldType| {
        if (!@hasField(@TypeOf(rules), name)) @compileError("Zigil: missing rule for field: " ++ name);
        const Rule = @field(rules, name);
        if (Rule.Value != FieldType) @compileError("Zigil: rule type does not match field: " ++ name);
    }
    return struct {
        pub const Value = T;
        fn check(value: T, ctx: *Context) !?Issue {
            inline for (info.field_names) |name| {
                try ctx.push(.{ .field = name });
                if (try checkRule(@field(rules, name), @field(value, name), ctx)) |issue| return issue;
                ctx.depth -= 1;
            }
            return null;
        }
    };
}

fn sequence(comptime T: type, comptime Child: type, comptime limits: Length) type {
    checkLength(limits);
    return struct {
        pub const Value = T;
        fn check(value: T, ctx: *Context) !?Issue {
            try ctx.consumeItems(value.len);
            if (lengthIssue(value.len, limits, ctx)) |issue| return issue;
            for (value, 0..) |item, index| {
                try ctx.push(.{ .index = index });
                if (try checkRule(Child, item, ctx)) |issue| return issue;
                ctx.depth -= 1;
            }
            return null;
        }
    };
}

pub fn Slice(comptime Child: type, comptime limits: Length) type {
    return sequence([]const Child.Value, Child, limits);
}

pub fn Array(comptime len: usize, comptime Child: type) type {
    return sequence([len]Child.Value, Child, .{});
}

/// predicate returns bool or an error union of bool. Errors propagate unchanged.
/// It is called synchronously and must not retain borrowed input.
/// message is static. The caller is responsible for predicate cost and effects.
pub fn Custom(comptime T: type, comptime predicate: anytype, comptime message: []const u8) type {
    if (@typeInfo(@TypeOf(predicate)) != .@"fn") @compileError("Zigil: custom predicate requires a compile-time function");
    const Return = @typeInfo(@TypeOf(predicate)).@"fn".return_type.?;
    const Payload = if (@typeInfo(Return) == .error_union) @typeInfo(Return).error_union.payload else Return;
    if (Payload != bool) @compileError("Zigil: custom predicate must return bool or an error union of bool");
    return struct {
        pub const Value = T;
        fn check(value: T, ctx: *Context) !?Issue {
            const result = predicate(value);
            const valid = if (@typeInfo(Return) == .error_union) try result else result;
            if (!valid) return ctx.fail(.custom, message);
            return null;
        }
    };
}

/// Wire-boundary presence: missing, explicitly null, or a present native value.
pub fn Presence(comptime T: type) type {
    return union(enum) {
        missing,
        null_value,
        value: T,
        pub const zigil_presence = T;
    };
}

pub const FieldOptions = struct { optional: bool = false, nullable: bool = false };

pub fn Field(comptime Child: type, comptime options: FieldOptions) type {
    return struct {
        pub const Value = Presence(Child.Value);
        pub const ChildRule = Child;
        pub const config = options;
        fn check(value: Value, ctx: *Context) !?Issue {
            return switch (value) {
                .missing => if (options.optional) null else ctx.fail(.missing_field, "required field is missing"),
                .null_value => if (options.nullable) null else ctx.fail(.null_not_allowed, "null is not permitted"),
                .value => |present| checkRule(Child, present, ctx),
            };
        }
    };
}
