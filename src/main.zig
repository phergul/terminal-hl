const std = @import("std");
const config = @import("config.zig");
const engine = @import("engine.zig");

var log_buffer: std.ArrayListUnmanaged(u8) = .{};
var log_mutex = std.Thread.Mutex{};
var log_allocator: ?std.mem.Allocator = null;
var debug_mode: bool = false;

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

    // log to stderr only if debug mode is on, or if it's an error/warning
    const should_log_to_stderr = debug_mode or level == .err or level == .warn;
    if (should_log_to_stderr) {
        std.debug.lockStdErr();
        defer std.debug.unlockStdErr();
        var stderr_buffer: [4096]u8 = undefined;
        var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
        const stderr = &stderr_writer.interface;
        nosuspend stderr.print(prefix ++ format ++ "\n", args) catch {};
        nosuspend stderr.flush() catch {};
    }

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

    if (args.len < 2 or args.len > 3) {
        std.log.err("missing required argument: config file path", .{});
        try printUsage();
        std.process.exit(1);
    }

    var config_path: ?[]const u8 = null;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--debug") or std.mem.eql(u8, arg, "-d")) {
            debug_mode = true;
        } else if (config_path == null) {
            config_path = arg;
        }
    }

    if (config_path == null) {
        std.log.err("missing required argument: config file path", .{});
        try printUsage();
        std.process.exit(1);
    }

    if (run(allocator, config_path.?)) {
        std.log.info("terminal-hl completed successfully", .{});
    } else |err| {
        std.log.err("fatal error occurred: {}", .{err});
        const log_path = dumpLog(allocator) catch "terminal-hl-crash.log";

        var stderr_buffer: [1024]u8 = undefined;
        var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
        const stderr = &stderr_writer.interface;
        switch (err) {
            error.ConfigFileNotFound => std.log.err("Error: Configuration file '{s}' not found.\n", .{config_path.?}),
            error.InvalidRegex => std.log.err("Error: One of your regex patterns is invalid.\n", .{}),
            error.InvalidHexFormat => std.log.err("Error: One of your colour hex codes is invalid.\n", .{}),
            else => std.log.err("Error: Unexpected error occurred: {}\n", .{err}),
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

    var logical_line = try std.ArrayList(u8).initCapacity(allocator, 4096);
    defer logical_line.deinit(allocator);

    std.log.debug("starting line processing loop", .{});
    while (true) {
        const b = reader.take(1) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (b.len == 0) break;

        if (b[0] == '\n' or b[0] == '\r') {
            std.log.debug("processing logical line of length {d}", .{logical_line.items.len});
            try engine.processLine(writer, logical_line.items, cfg.highlightRules);
            try writer.writeByte(b[0]);
            try writer.flush();
            logical_line.clearRetainingCapacity();
        } else {
            try logical_line.append(allocator, b[0]);
        }
    }

    if (logical_line.items.len > 0) {
        std.log.debug("processing final line without newline", .{});
        try engine.processLine(writer, logical_line.items, cfg.highlightRules);
        try writer.flush();
    }
}

fn printUsage() !void {
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    const w = &stderr_writer.interface;

    const usage =
        \\Usage: terminal-hl [--debug|-d] <config.json>
        \\  Highlights text from stdin based on regex patterns in JSON config.
        \\
        \\Options:
        \\  --debug, -d    Enable debug logging to stderr
        \\
        \\Example:
        \\  echo 'ERROR: Something failed' | terminal-hl rules.json
        \\  tail -f app.log | terminal-hl --debug rules.json
        \\
        \\JSON Configuration Format:
        \\  {
        \\    "highlight_rules": [
        \\      {
        \\        "pattern": "<regex>",      // Regex pattern to match
        \\        "colour": "<color>",   // Color name or hex (#RRGGBB)
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
        \\    "highlight_rules": [
        \\      {"pattern": "ERROR|FATAL", "colour": "red", "bold": true},
        \\      {"pattern": "WARNING", "colour": "yellow", "bold": true},
        \\      {"pattern": "INFO", "colour": "blue", "bold": false},
        \\      {"pattern": "\\d{4}-\\d{2}-\\d{2}", "colour": "#9370DB"}
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
