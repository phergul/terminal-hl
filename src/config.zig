const std = @import("std");
const colour = @import("colour.zig");
const Regex = @import("regex").Regex;

pub const HighlightRule = struct {
    pattern: []const u8,
    re: ?Regex = null,
    colour: colour.Colour,
    bold: bool,

    pub fn deinit(self: *HighlightRule) void {
        if (self.re) |*r| r.deinit();
    }
};

// this is used to unmarshal the JSON config file by matching what can be directly set
const JsonRule = struct {
    pattern: []const u8,
    colour_raw: []const u8 = "",
    bold: bool = false,
};

const JsonConfig = struct {
    highlightRules: []JsonRule,
};

pub const Config = struct {
    highlightRules: []HighlightRule,
    _parsed: std.json.Parsed(JsonConfig),
    _content: []u8,

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        for (self.highlightRules) |*rule| rule.deinit();
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
    std.log.debug("parsed JSON config with {d} rules", .{parsed.value.highlightRules.len});

    var rules = try allocator.alloc(HighlightRule, parsed.value.highlightRules.len);
    errdefer allocator.free(rules);

    for (parsed.value.highlightRules, 0..) |json_rule, i| {
        std.log.debug("compiling rule {d}: pattern='{s}', colour='{s}', bold={}", .{ i, json_rule.pattern, json_rule.colour_raw, json_rule.bold });
        const re = Regex.compile(allocator, json_rule.pattern) catch {
            std.log.err("invalid regex pattern: {s}", .{json_rule.pattern});
            return error.InvalidRegex;
        };

        rules[i] = .{
            .pattern = json_rule.pattern,
            .bold = json_rule.bold,
            .re = re,
            .colour = try colour.Colour.parse(json_rule.colour_raw),
        };
    }

    return Config{
        .highlightRules = rules,
        ._parsed = parsed,
        ._content = content,
    };
}
