const std = @import("std");
const colour = @import("colour.zig");
const mvzr = @import("mvzr");

pub const HighlightRule = struct {
    pattern: []const u8,
    re: ?mvzr.Regex = null,
    colour: colour.Colour,
    bold: bool,
};

// this is used to unmarshal the JSON config file by matching what can be directly set
const JsonRule = struct {
    pattern: []const u8,
    colour: []const u8 = "",
    bold: bool = false,
};

const JsonConfig = struct {
    highlight_rules: []JsonRule,
};

pub const Config = struct {
    highlightRules: []HighlightRule,
    _parsed: std.json.Parsed(JsonConfig),
    _content: []u8,

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        allocator.free(self.highlightRules);
        self._parsed.deinit();
        allocator.free(self._content);
    }
};

pub fn loadAndParseConfig(allocator: std.mem.Allocator, path: []const u8) !Config {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            std.log.err("config file not found: {s}", .{path});
            return error.ConfigFileNotFound;
        }
        return err;
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    errdefer allocator.free(content);
    std.log.debug("read {d} bytes from config file", .{content.len});

    const parsed = try std.json.parseFromSlice(JsonConfig, allocator, content, .{ .ignore_unknown_fields = true });
    errdefer parsed.deinit();
    std.log.debug("parsed JSON config with {d} rules", .{parsed.value.highlight_rules.len});

    var rules = try allocator.alloc(HighlightRule, parsed.value.highlight_rules.len);
    errdefer allocator.free(rules);

    for (parsed.value.highlight_rules, 0..) |json_rule, i| {
        std.log.debug("compiling rule {d}: pattern='{s}', colour='{s}', bold={}", .{ i, json_rule.pattern, json_rule.colour, json_rule.bold });
        const re = mvzr.Regex.compile(json_rule.pattern) orelse {
            std.log.err("invalid regex pattern: {s}", .{json_rule.pattern});
            return error.InvalidRegex;
        };

        rules[i] = .{
            .pattern = json_rule.pattern,
            .bold = json_rule.bold,
            .re = re,
            .colour = try colour.Colour.parse(json_rule.colour),
        };
    }

    return Config{
        .highlightRules = rules,
        ._parsed = parsed,
        ._content = content,
    };
}
