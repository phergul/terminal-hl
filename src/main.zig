const std = @import("std");
const config = @import("config.zig");
const engine = @import("engine.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len != 2) {
        try printUsage();
        std.process.exit(1);
    }

    if (run(allocator, args[1])) |ok| {
        _ = ok;
    } else |err| {
        var stderr_buffer: [1024]u8 = undefined;
        var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
        const stderr = &stderr_writer.interface;
        switch (err) {
            error.ConfigFileNotFound => try stderr.print("Error: Configuration file '{s}' not found.\n", .{args[1]}),
            error.InvalidRegex => try stderr.print("Error: One of your regex patterns is invalid.\n", .{}),
            error.InvalidHexFormat => try stderr.print("Error: One of your colour hex codes is invalid.\n", .{}),
            else => try stderr.print("Error: Unexpected error occurred: {}\n", .{err}),
        }
        try stderr.flush();
        std.process.exit(1);
    }
}

fn run(allocator: std.mem.Allocator, config_path: []const u8) !void {
    var cfg = try config.loadAndParseConfig(allocator, config_path);
    defer cfg.deinit(allocator);

    const stdin = std.fs.File.stdin();
    const stdout = std.fs.File.stdout();

    var stdin_buffer: [4096]u8 = undefined;
    var stdout_buffer: [4096]u8 = undefined;

    var stdin_reader = stdin.reader(&stdin_buffer);
    var stdout_writer = stdout.writer(&stdout_buffer);

    const reader = &stdin_reader.interface;
    const writer = &stdout_writer.interface;

    var line = std.Io.Writer.Allocating.init(allocator);
    defer line.deinit();

    while (true) {
        _ = reader.streamDelimiter(&line.writer, '\n') catch |err| {
            if (err == error.EndOfStream) break else return err;
        };

        try engine.processLine(writer, line.written(), cfg.highlightRules);
        try writer.writeByte('\n');

        reader.toss(1);
        line.clearRetainingCapacity();
    }

    if (line.written().len > 0) {
        try engine.processLine(writer, line.written(), cfg.highlightRules);
        try writer.writeByte('\n');
    }

    try writer.flush();
}

fn printUsage() !void {
    var stderr_buffer: [4096]u8 = undefined;
    var stderr = std.fs.File.stderr().writer(&stderr_buffer);
    const w = &stderr.interface;

    const usage =
        \\Usage: terminal-hl <config.json>
        \\  Highlights text from stdin based on regex patterns in JSON config.
        \\
        \\Example:
        \\  echo 'ERROR: Something failed' | terminal-hl rules.json
        \\  tail -f app.log | terminal-hl rules.json
        \\
        \\JSON Configuration Format:
        \\  {
        \\    "highlightRules": [
        \\      {
        \\        "pattern": "<regex>",      // Regex pattern to match
        \\        "colour_raw": "<color>",   // Color name or hex (#RRGGBB)
        \\        "bold": true|false         // Optional, default false
        \\      }
        \\    ]
        \\  }
        \\
        \\Supported color names:
        \\  black, red, green, yellow, blue, magenta, cyan, white
        \\
        \\Example config:
        \\  {
        \\    "highlightRules": [
        \\      {"pattern": "ERROR|FATAL", "colour_raw": "red", "bold": true},
        \\      {"pattern": "WARNING", "colour_raw": "yellow", "bold": true},
        \\      {"pattern": "INFO", "colour_raw": "blue", "bold": false},
        \\      {"pattern": "\\d{4}-\\d{2}-\\d{2}", "colour_raw": "#9370DB"}
        \\    ]
        \\  }
        \\
    ;

    try w.writeAll(usage);
    try w.flush();
}
