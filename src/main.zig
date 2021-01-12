const std = @import("std");
const clap = @import("clap");
const zfetch = @import("zfetch");
usingnamespace @import("commands.zig");

//pub const io_mode = .evented;

const Command = enum {
    package,
    fetch,
    update,
    build,
};

fn printUsage() noreturn {
    const stderr = std.io.getStdErr().writer();
    _ = stderr.write(
        \\gyro <cmd> [cmd specific options]
        \\
        \\cmds:
        \\  build    Build your project with build dependencies
        \\  fetch    Download any undownloaded dependencies
        \\  package  Bundle package(s) into a ziglet 
        \\  update   Delete lock file and fetch new package versions
        \\
        \\for more information: gyro <cmd> --help
        \\
        \\
    ) catch {};

    std.os.exit(1);
}

fn showHelp(comptime summary: []const u8, comptime params: anytype) void {
    const stderr = std.io.getStdErr().writer();
    _ = stderr.write(summary ++ "\n\n") catch {};
    clap.help(stderr, params) catch {};
    _ = stderr.write("\n") catch {};
}

fn parseHandlingHelpAndErrors(
    allocator: *std.mem.Allocator,
    comptime summary: []const u8,
    comptime params: anytype,
    iter: anytype,
) clap.ComptimeClap(clap.Help, params) {
    var diag: clap.Diagnostic = undefined;
    var args = clap.ComptimeClap(clap.Help, params).parse(allocator, iter, &diag) catch |err| {
        // Report useful error and exit
        const stderr = std.io.getStdErr().writer();
        diag.report(stderr, err) catch {};
        showHelp(summary, params);
        std.os.exit(1);
    };
    // formerly checkHelp(summary, params, args);
    if (args.flag("--help")) {
        showHelp(summary, params);
        std.os.exit(0);
    }
    return args;
}

pub fn main() !void {
    try zfetch.init();
    defer zfetch.deinit();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = &gpa.allocator;
    runCommands(allocator) catch |err| {
        switch (err) {
            error.Explained => std.process.exit(1),
            else => return err,
        }
    };
}

fn runCommands(allocator: *std.mem.Allocator) !void {
    var iter = try clap.args.OsIterator.init(allocator);
    defer iter.deinit();

    const stderr = std.io.getStdErr().writer();
    const cmd_str = (try iter.next()) orelse {
        try stderr.print("no command given\n", .{});
        printUsage();
    };

    const cmd = inline for (std.meta.fields(Command)) |field| {
        if (std.mem.eql(u8, cmd_str, field.name)) {
            break @field(Command, field.name);
        }
    } else {
        try stderr.print("{s} is not a valid command\n", .{cmd_str});
        printUsage();
    };

    switch (cmd) {
        // TODO: pass down arguments
        .build => try build(allocator, &iter),
        .fetch => try fetch(allocator),
        .update => try update(allocator),
        .package => {
            const summary = "Bundle package(s) into a ziglet";
            const params = comptime [_]clap.Param(clap.Help){
                clap.parseParam("-h, --help              Display help") catch unreachable,
                clap.parseParam("-o, --output-dir <DIR>  Directory to put tarballs in") catch unreachable,
                clap.Param(clap.Help){
                    .takes_value = .Many,
                },
            };

            var args = parseHandlingHelpAndErrors(allocator, summary, &params, &iter);
            defer args.deinit();

            try package(allocator, args.option("--output-dir"), args.positionals());
        },
    }
}

test "all" {
    std.testing.refAllDecls(@import("Dependency.zig"));
}
