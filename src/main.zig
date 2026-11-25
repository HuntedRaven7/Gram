const std = @import("std");

const profile = @import("profile.zig");
const config = @import("config.zig");
const runner = @import("runner.zig");
const disk = @import("disk.zig");
const plan = @import("plan.zig");
const execute = @import("execute.zig");
const verify = @import("verify.zig");
const cli = @import("cli.zig");
const tui = @import("tui.zig");
const tests = @import("tests.zig");

comptime {
    _ = profile;
    _ = config;
    _ = runner;
    _ = disk;
    _ = plan;
    _ = execute;
    _ = verify;
    _ = tests;
}

fn writeOut(io: std.Io, text: []const u8) !void {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buffer);
    try writer.interface.writeAll(text);
    try writer.interface.flush();
}

fn writeErr(io: std.Io, text: []const u8) !void {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stderr().writer(io, &buffer);
    try writer.interface.writeAll(text);
    try writer.interface.flush();
}

fn run(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    var it = std.process.Args.Iterator.init(init.minimal.args);
    defer it.deinit();
    var args: std.ArrayListUnmanaged([]const u8) = .empty;
    while (it.next()) |arg| try args.append(allocator, arg);

    const opts = cli.parseArgs(allocator, args.items) catch |err| {
        try writeErr(init.io, cli.help);
        if (err == error.HelpRequested) return;
        return err;
    };
    if (opts.version) {
        try writeOut(init.io, "gram 0.1.0\n");
        return;
    }

    var r = runner.Runner.init(std.heap.page_allocator, init.io, opts.dry_run);
    defer r.deinit();
    const prepared = try cli.prepare(allocator, init.io, init.environ_map, opts, &r);

    const headless = opts.config_path != null or opts.dry_run or opts.yes or
        opts.profile != null or opts.image != null or opts.disk != null;
    if (headless) {
        try cli.apply(allocator, init.io, prepared.config, &r, execute.printStdout);
        try writeOut(init.io, r.log.items);
        return;
    }

    r.log.clearRetainingCapacity();
    try tui.start(allocator, init.io, init.environ_map, prepared);
}

pub fn main(init: std.process.Init) !void {
    run(init) catch |err| {
        const message = config.errorMessage(err) orelse @errorName(err);
        writeErr(init.io, message) catch {};
        writeErr(init.io, "\n") catch {};
        std.process.exit(1);
    };
}
