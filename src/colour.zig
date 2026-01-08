const std = @import("std");

pub const Colour = union(enum) {
    standard: []const u8,
    hex: [3]u8,
    default: void,

    pub fn parse(raw: []const u8) !Colour {
        if (raw.len == 0) return .default;

        if (raw[0] == '#') {
            if (raw.len != 7) return error.InvalidHexFormat;
            const r = try std.fmt.parseInt(u8, raw[1..3], 16);
            const g = try std.fmt.parseInt(u8, raw[3..5], 16);
            const b = try std.fmt.parseInt(u8, raw[5..7], 16);
            return .{ .hex = .{ r, g, b } };
        }

        return .{ .standard = raw };
    }
};
