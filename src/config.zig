const std = @import("std");
const colour = @import("colour.zig");
const Regex = @import("regex").Regex;

pub const HighlightRule = struct {
    pattern: []const u8,
    re: ?Regex = null,
    colour_raw: []const u8,
    colour: colour.Colour,
    bold: bool,
};

const JsonConfig = struct {
    highlightRules: []struct {
        pattern: []const u8,
        colour_raw: []const u8,
        bold: bool,
    },
};

pub const Config = struct {
    highlightRules: []HighlightRule,
    _parsed: std.json.Parsed(JsonConfig),
    _content: []u8,

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        for (self.highlightRules) |*rule| {
            if (rule.re) |*r| {
                r.deinit();
            }
        }
        allocator.free(self.highlightRules);
        self._parsed.deinit();
        allocator.free(self._content);
    }
};

pub fn loadAndParseConfig(allocator: std.mem.Allocator, path: []const u8) !Config {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    errdefer allocator.free(content);

    const parsed = try std.json.parseFromSlice(JsonConfig, allocator, content, .{ .ignore_unknown_fields = true });
    errdefer parsed.deinit();

    var rules = try allocator.alloc(HighlightRule, parsed.value.highlightRules.len);
    errdefer allocator.free(rules);

    for (parsed.value.highlightRules, 0..) |json_rule, i| {
        rules[i] = .{
            .pattern = json_rule.pattern,
            .bold = json_rule.bold,
            .colour_raw = json_rule.colour_raw,
            .re = try Regex.compile(allocator, json_rule.pattern),
            .colour = .default,
        };

        if (json_rule.colour_raw.len > 0) {
            if (json_rule.colour_raw[0] == '#') {
                const r = try std.fmt.parseInt(u8, json_rule.colour_raw[1..3], 16);
                const g = try std.fmt.parseInt(u8, json_rule.colour_raw[3..5], 16);
                const b = try std.fmt.parseInt(u8, json_rule.colour_raw[5..7], 16);
                rules[i].colour = .{ .hex = .{ r, g, b } };
            } else {
                rules[i].colour = .{ .standard = json_rule.colour_raw };
            }
        }
    }

    return Config{
        .highlightRules = rules,
        ._parsed = parsed,
        ._content = content,
    };
}
