const std = @import("std");
const colour = @import("colour.zig");
const config = @import("config.zig");

const ColorMap = std.StaticStringMap([]const u8).initComptime(.{
    .{ "black", "\x1b[30m" },
    .{ "red", "\x1b[31m" },
    .{ "green", "\x1b[32m" },
    .{ "yellow", "\x1b[33m" },
    .{ "blue", "\x1b[34m" },
    .{ "magenta", "\x1b[35m" },
    .{ "cyan", "\x1b[36m" },
    .{ "white", "\x1b[37m" },
});

pub fn processLine(writer: anytype, line: []const u8, rules: []config.HighlightRule) !void {
    var pos: usize = 0;

    while (pos < line.len) {
        var best_start: usize = line.len;
        var best_end: usize = line.len;
        var best_rule: ?*config.HighlightRule = null;

        for (rules) |*rule| {
            if (rule.re) |*re| {
                if (re.captures(line[pos..]) catch null) |caps| {
                    var c = caps;
                    defer c.deinit();

                    if (c.boundsAt(0)) |bounds| {
                        const len = bounds.upper - bounds.lower;
                        const match_abs_start = pos + bounds.lower;
                        const match_abs_end = pos + bounds.upper;

                        if (len > 0 and match_abs_start < best_start) {
                            best_start = match_abs_start;
                            best_end = match_abs_end;
                            best_rule = rule;
                        }
                    }
                }
            }
        }

        if (best_rule) |match_rule| {
            if (best_start > pos) {
                try writer.writeAll(line[pos..best_start]);
            }

            try applyStyle(writer, match_rule.colour, match_rule.bold);
            try writer.writeAll(line[best_start..best_end]);
            try resetStyle(writer);

            pos = best_end;
        } else {
            try writer.writeAll(line[pos..]);
            break;
        }
    }
}

fn applyStyle(writer: anytype, selected_colour: colour.Colour, bold: bool) !void {
    if (bold) {
        try writer.writeAll("\x1b[1m");
    }

    switch (selected_colour) {
        .standard => |name| {
            if (ColorMap.get(name)) |ansi_code| {
                try writer.writeAll(ansi_code);
            } else {
                std.debug.print("WARNING: Unknown color name '{s}'\n", .{name});
            }
        },
        .hex => |rgb| {
            try writer.print("\x1b[38;2;{d};{d};{d}m", .{ rgb[0], rgb[1], rgb[2] });
        },
        .default => {},
    }
}

pub fn resetStyle(writer: anytype) !void {
    try writer.writeAll("\x1b[0m");
}
