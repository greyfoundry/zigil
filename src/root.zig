//! Validation rules for native Zig values. Built-ins never allocate or mutate input.
//! Issue paths borrow the buffer supplied to validate; see docs/errors-ownership.mdx.
const std = @import("std");

/// A field name (static schema storage) or a zero-based collection index.
pub const Segment = union(enum) { field: []const u8, index: usize };

/// Machine-readable failures. path_capacity is a resource failure, not invalid data.
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
    path_capacity,
};

pub const Issue = struct {
    code: Code,
    /// Borrows the caller's path buffer; overwritten when that buffer is reused.
    path: []const Segment,
    /// Static rule text. Does not contain input values.
    message: []const u8,
};

// Internal traversal state. On failure the path is left intact for the caller.
const Context = struct {
    path: []Segment,
    depth: usize = 0,

    fn fail(self: *Context, code: Code, comptime message: []const u8) Issue {
        return .{ .code = code, .path = self.path[0..self.depth], .message = message };
    }

    fn push(self: *Context, segment: Segment) ?Issue {
        if (self.depth == self.path.len)
            return self.fail(.path_capacity, "provide more path segments to validate this value");
        self.path[self.depth] = segment;
        self.depth += 1;
        return null;
    }
};

/// Returns null on success, otherwise the first issue. Borrows value only during
/// this call. An issue's path borrows path_buffer; keep it alive and unchanged.
/// Built-in rules allocate nothing. Custom predicates own their own side effects.
pub fn validate(comptime Rule: type, value: Rule.Value, path_buffer: []Segment) ?Issue {
    var context: Context = .{ .path = path_buffer };
    return Rule.check(value, &context);
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
        fn check(value: Value, ctx: *Context) ?Issue {
            // Reject oversized inputs before scanning their contents.
            if (lengthIssue(value.len, options.length, ctx)) |issue| return issue;
            if (options.utf8 and !std.unicode.utf8ValidateSlice(value))
                return ctx.fail(.invalid_utf8, "must contain valid UTF-8");
            if (options.prefix) |prefix| {
                if (!std.mem.startsWith(u8, value, prefix)) return ctx.fail(.prefix, "must start with the configured prefix");
            }
            if (options.suffix) |suffix| {
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
        fn check(value: T, ctx: *Context) ?Issue {
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
        fn check(value: T, ctx: *Context) ?Issue {
            if (!std.math.isFinite(value)) return ctx.fail(.not_finite, "must be finite");
            return numberIssue(T, value, bounds, ctx);
        }
    };
}

/// null accepts either boolean; true or false requires that exact value.
pub fn Boolean(comptime expected: ?bool) type {
    return struct {
        pub const Value = bool;
        fn check(value: bool, ctx: *Context) ?Issue {
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
        fn check(value: T, ctx: *Context) ?Issue {
            for (allowed orelse tags) |candidate| {
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
        fn check(value: Value, ctx: *Context) ?Issue {
            if (value) |present| return Child.check(present, ctx);
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
        fn check(value: T, ctx: *Context) ?Issue {
            inline for (info.field_names) |name| {
                if (ctx.push(.{ .field = name })) |issue| return issue;
                if (@field(rules, name).check(@field(value, name), ctx)) |issue| return issue;
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
        fn check(value: T, ctx: *Context) ?Issue {
            if (lengthIssue(value.len, limits, ctx)) |issue| return issue;
            for (value, 0..) |item, index| {
                if (ctx.push(.{ .index = index })) |issue| return issue;
                if (Child.check(item, ctx)) |issue| return issue;
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

/// predicate is called synchronously and must not retain borrowed input.
/// message is static. The caller is responsible for predicate cost and effects.
pub fn Custom(comptime T: type, comptime predicate: fn (T) bool, comptime message: []const u8) type {
    return struct {
        pub const Value = T;
        fn check(value: T, ctx: *Context) ?Issue {
            if (!predicate(value)) return ctx.fail(.custom, message);
            return null;
        }
    };
}
