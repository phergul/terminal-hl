const std = @import("std");
const config = @import("config.zig");
const engine = @import("engine.zig");

var log_buffer: std.ArrayListUnmanaged(u8) = .{};
var log_mutex = std.Thread.Mutex{};
var log_allocator: ?std.mem.Allocator = null;

pub const std_options = std.Options{
    .logFn = logFn,
};

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    const scope_prefix = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";
    const prefix = "[" ++ @tagName(level) ++ "] " ++ scope_prefix;

    // log to stderr
    std.debug.lockStdErr();
    defer std.debug.unlockStdErr();
    var stderr_buffer: [4096]u8 = undefined;
    var stderr = std.fs.File.stderr().writer(&stderr_buffer);
    const w = &stderr.interface;
    nosuspend w.print(prefix ++ format ++ "\n", args) catch {};

    // log to buffer for dumping on a crash
    if (log_allocator) |alloc| {
        log_mutex.lock();
        defer log_mutex.unlock();
        nosuspend log_buffer.writer(alloc).print(prefix ++ format ++ "\n", args) catch {};
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    log_allocator = allocator;
    defer log_buffer.deinit(allocator);

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len != 2) {
        std.log.err("incorrect number of arguments: expected 2, got {d}", .{args.len});
        try printUsage();
        std.process.exit(1);
    }

    if (run(allocator, args[1])) {
        std.log.info("terminal-hl completed successfully", .{});
    } else |err| {
        std.log.err("fatal error occurred: {}", .{err});
        const log_path = dumpLog(allocator) catch "terminal-hl-crash.log";

        var stderr_buffer: [1024]u8 = undefined;
        var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
        const stderr = &stderr_writer.interface;
        switch (err) {
            error.ConfigFileNotFound => try stderr.print("Error: Configuration file '{s}' not found.\n", .{args[1]}),
            error.InvalidRegex => try stderr.print("Error: One of your regex patterns is invalid.\n", .{}),
            error.InvalidHexFormat => try stderr.print("Error: One of your colour hex codes is invalid.\n", .{}),
            else => try stderr.print("Error: Unexpected error occurred: {}\n", .{err}),
        }

        try stderr.print("A log file has been created at: {s}\n", .{log_path});
        try stderr.flush();
        std.process.exit(1);
    }
}

fn run(allocator: std.mem.Allocator, config_path: []const u8) !void {
    std.log.info("loading config from: {s}", .{config_path});
    var cfg = try config.loadAndParseConfig(allocator, config_path);
    defer cfg.deinit(allocator);
    std.log.info("config loaded successfully with {d} rules", .{cfg.highlightRules.len});

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

    std.log.debug("starting line processing loop", .{});
    while (true) {
        _ = reader.streamDelimiter(&line.writer, '\n') catch |err| {
            if (err == error.EndOfStream) {
                std.log.debug("reached end of stream", .{});
                break;
            } else return err;
        };

        try engine.processLine(writer, line.written(), cfg.highlightRules);
        try writer.writeByte('\n');

        reader.toss(1);
        line.clearRetainingCapacity();
    }

    if (line.written().len > 0) {
        std.log.debug("processing final line without newline", .{});
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

fn dumpLog(allocator: std.mem.Allocator) ![]const u8 {
    const tmp_dir_path = std.process.getEnvVarOwned(allocator, "TMPDIR") catch "/tmp";
    defer if (!std.mem.eql(u8, tmp_dir_path, "/tmp")) allocator.free(tmp_dir_path);

    const file_path = try std.fs.path.join(allocator, &.{ tmp_dir_path, "terminal-hl-crash.log" });

    std.log.info("writing log to: {s}", .{file_path});
    const file = try std.fs.createFileAbsolute(file_path, .{ .truncate = true });
    defer file.close();

    try file.writeAll(log_buffer.items);

    return file_path;
}
