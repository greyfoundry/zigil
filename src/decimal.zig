//! Exact decimal normalization for JSON numbers. No binary-float intermediary.
const std = @import("std");
const Big = std.math.big.int.Managed;

pub const Limits = struct { max_digits: usize = 4096, max_scale: usize = 10_000 };
pub const Decimal = struct {
    digits: []const u8,
    exponent: i64,
    negative: bool,

    pub fn parse(allocator: std.mem.Allocator, source: []const u8, limits: Limits) !Decimal {
        if (limits.max_scale > 100_000) return error.NumericLimitExceeded;
        const end = std.mem.indexOfAny(u8, source, "eE") orelse source.len;
        const start: usize = if (source[0] == '-') 1 else 0;
        const point = std.mem.indexOfScalar(u8, source[start..end], '.');
        const fraction = if (point) |p| end - start - p - 1 else 0;
        var first: ?usize = null;
        var last: usize = start;
        for (source[start..end], start..) |byte, index| {
            if (byte == '.') continue;
            if (byte != '0') {
                if (first == null) first = index;
                last = index;
            }
        }
        if (first == null) return .{ .digits = "0", .exponent = 0, .negative = false };
        var trailing: usize = 0;
        for (source[last + 1 .. end]) |byte| if (byte != '.') {
            trailing += 1;
        };
        const explicit = if (end < source.len) std.fmt.parseInt(i64, source[end + 1 ..], 10) catch return error.NumericLimitExceeded else 0;
        const exp1 = std.math.sub(i64, explicit, @intCast(fraction)) catch return error.NumericLimitExceeded;
        const exponent = std.math.add(i64, exp1, @intCast(trailing)) catch return error.NumericLimitExceeded;
        if (exponent > @as(i64, @intCast(limits.max_scale)) or exponent < -@as(i64, @intCast(limits.max_scale))) return error.NumericLimitExceeded;
        var significant: usize = 0;
        for (source[first.? .. last + 1]) |byte| if (byte != '.') {
            significant += 1;
        };
        if (significant > limits.max_digits) return error.NumericLimitExceeded;
        const digits = try allocator.alloc(u8, significant);
        var index: usize = 0;
        for (source[first.? .. last + 1]) |byte| if (byte != '.') {
            digits[index] = byte;
            index += 1;
        };
        return .{ .digits = digits, .exponent = exponent, .negative = source[0] == '-' };
    }

    pub fn zero(self: Decimal) bool {
        return self.digits.len == 1 and self.digits[0] == '0';
    }
    pub fn integer(self: Decimal) bool {
        return self.zero() or self.exponent >= 0;
    }

    pub fn order(a: Decimal, b: Decimal) std.math.Order {
        if (a.zero() and b.zero()) return .eq;
        if (a.negative != b.negative) return if (a.negative) .lt else .gt;
        const sign: std.math.Order = if (a.negative) .gt else .lt;
        if (a.zero()) return sign;
        if (b.zero()) return sign.invert();
        const a_size = @as(i64, @intCast(a.digits.len)) + a.exponent;
        const b_size = @as(i64, @intCast(b.digits.len)) + b.exponent;
        const abs_order: std.math.Order = block: {
            if (a_size != b_size) break :block std.math.order(a_size, b_size);
            for (0..@max(a.digits.len, b.digits.len)) |index| {
                const av: u8 = if (index < a.digits.len) a.digits[index] else '0';
                const bv: u8 = if (index < b.digits.len) b.digits[index] else '0';
                if (av != bv) break :block std.math.order(av, bv);
            }
            break :block .eq;
        };
        return if (a.negative) abs_order.invert() else abs_order;
    }

    pub fn toInt(self: Decimal, comptime T: type) !T {
        if (self.zero()) return 0;
        if (!self.integer()) return error.FractionalNumber;
        if (self.negative and @typeInfo(T).int.signedness == .unsigned) return error.Overflow;
        const max_digits = @as(usize, @typeInfo(T).int.bits) * 30103 / 100000 + 2;
        if (@as(u64, @intCast(self.exponent)) + self.digits.len > max_digits) return error.Overflow;
        const W = @Int(@typeInfo(T).int.signedness, @min(65535, @max(8, @as(usize, @typeInfo(T).int.bits) + 4)));
        var result: W = 0;
        const count = self.digits.len + @as(usize, @intCast(self.exponent));
        for (0..count) |index| {
            const digit: u8 = if (index < self.digits.len) self.digits[index] - '0' else 0;
            const cast = std.math.cast(W, digit) orelse return error.Overflow;
            result = std.math.mul(W, result, 10) catch return error.Overflow;
            result = if (self.negative) std.math.sub(W, result, cast) catch return error.Overflow else std.math.add(W, result, cast) catch return error.Overflow;
        }
        return std.math.cast(T, result) orelse error.Overflow;
    }

    pub fn exactFloat(self: Decimal, comptime T: type, allocator: std.mem.Allocator) !bool {
        if (self.zero()) return true;
        var coefficient = try Big.init(allocator);
        defer coefficient.deinit();
        try coefficient.setString(10, self.digits);
        var five = try Big.initSet(allocator, 5);
        defer five.deinit();
        var quotient = try Big.initSet(allocator, 0);
        defer quotient.deinit();
        var remainder = try Big.initSet(allocator, 0);
        defer remainder.deinit();
        if (self.exponent < 0) {
            for (0..@as(usize, @intCast(-self.exponent))) |_| {
                try Big.divTrunc(&quotient, &remainder, &coefficient, &five);
                if (!remainder.eqlZero()) return false;
                std.mem.swap(Big, &coefficient, &quotient);
            }
        } else {
            // Multiplication by five cannot reduce precision; stop as soon as
            // the significand exceeds the target precision.
            for (0..@as(usize, @intCast(self.exponent))) |_| {
                try coefficient.mul(&coefficient, &five);
                if (significantBits(coefficient) > std.math.floatMantissaBits(T) + 1) return false;
            }
        }
        return significantBits(coefficient) <= std.math.floatMantissaBits(T) + 1;
    }

    pub fn multipleOf(a: Decimal, b: Decimal, allocator: std.mem.Allocator) !bool {
        if (b.zero() or b.negative) return error.InvalidDivisor;
        if (a.zero()) return true;
        var numerator = try Big.init(allocator);
        defer numerator.deinit();
        var denominator = try Big.init(allocator);
        defer denominator.deinit();
        try numerator.setString(10, a.digits);
        try denominator.setString(10, b.digits);
        const difference = a.exponent - b.exponent;
        var ten = try Big.initSet(allocator, 10);
        defer ten.deinit();
        var power = try Big.initSet(allocator, 1);
        defer power.deinit();
        try power.pow(&ten, @intCast(@abs(difference)));
        if (difference > 0) try numerator.mul(&numerator, &power) else if (difference < 0) try denominator.mul(&denominator, &power);
        var quotient = try Big.initSet(allocator, 0);
        defer quotient.deinit();
        var remainder = try Big.initSet(allocator, 0);
        defer remainder.deinit();
        try Big.divTrunc(&quotient, &remainder, &numerator, &denominator);
        return remainder.eqlZero();
    }
};

fn significantBits(number: Big) usize {
    var trailing: usize = 0;
    for (number.toConst().limbs) |limb| {
        if (limb == 0) trailing += @bitSizeOf(@TypeOf(limb)) else {
            trailing += @ctz(limb);
            break;
        }
    }
    return number.bitCountAbs() - trailing;
}
