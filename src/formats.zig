//! Local syntax checks. No DNS, network, normalization or identity verification.
const std = @import("std");
pub const Format = enum { uuid, ipv4, ipv6, uri };

pub fn valid(format: Format, text: []const u8) bool {
    return switch (format) {
        .uuid => block: {
            if (text.len != 36) break :block false;
            for (text, 0..) |byte, index| {
                if (index == 8 or index == 13 or index == 18 or index == 23) {
                    if (byte != '-') break :block false;
                } else if (!std.ascii.isHex(byte)) break :block false;
            }
            break :block true;
        },
        .ipv4 => block: {
            _ = std.Io.net.IpAddress.parseIp4(text, 0) catch break :block false;
            break :block true;
        },
        .ipv6 => block: {
            // Zone identifiers are outside the address format's contract.
            if (std.mem.indexOfScalar(u8, text, '%') != null) break :block false;
            _ = std.Io.net.IpAddress.parseIp6(text, 0) catch break :block false;
            break :block true;
        },
        .uri => block: {
            var index: usize = 0;
            while (index < text.len) : (index += 1) {
                const byte = text[index];
                if (byte <= 0x20 or byte >= 0x7f or std.mem.indexOfScalar(u8, "<>\\\"{}|^`", byte) != null) break :block false;
                if (byte == '%') {
                    if (text.len - index < 3 or !std.ascii.isHex(text[index + 1]) or !std.ascii.isHex(text[index + 2])) break :block false;
                    index += 2;
                }
            }
            _ = std.Uri.parse(text) catch break :block false;
            break :block true;
        },
    };
}
