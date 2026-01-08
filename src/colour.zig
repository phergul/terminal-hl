const std = @import("std");

pub const ColourType = enum {
    standard,
    hex,
    default,
};

pub const Colour = union(ColourType) {
    standard: []const u8,
    hex: [3]u8,
    default: void,
};
