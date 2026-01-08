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
        const stderr = getStderrWriter() catch return;
        switch (err) {
            error.ConfigFileNotFound => try stderr.print("Error: Configuration file '{s}' not found.\n", .{args[1]}),
            error.InvalidRegex => try stderr.print("Error: One of your regex patterns is invalid.\n", .{}),
            error.InvalidHexFormat => try stderr.print("Error: One of your colour hex codes is invalid.\n", .{}),
            else => try stderr.print("Error: Unexpected error occurred: {}\n", .{err}),
        }
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
    const err_writer = getStderrWriter() catch return;
    try err_writer.writeAll("Usage: terminal_hl <config.json>\n");
    try err_writer.writeAll("Example: echo 'some text' | terminal_hl rules.json\n");
}

fn getStderrWriter() !*std.io.Writer {
    var stderr_buffer: [1024]u8 = undefined;
    var stderr = std.fs.File.stderr().writer(&stderr_buffer);
    return &stderr.interface;
}
