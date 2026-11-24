const std = @import("std");

pub const Runner = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    dry_run: bool = false,
    log: std.ArrayListUnmanaged(u8) = .empty,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, dry_run: bool) Runner {
        return .{ .allocator = allocator, .io = io, .dry_run = dry_run };
    }

    pub fn deinit(self: *Runner) void {
        self.log.deinit(self.allocator);
    }

    pub fn record(self: *Runner, bytes: []const u8) !void {
        try self.log.appendSlice(self.allocator, bytes);
    }

    fn describe(self: *Runner, argv: []const []const u8, stdin_note: ?[]const u8) !void {
        try self.record("[dry-run] ");
        for (argv, 0..) |arg, i| {
            if (i != 0) try self.record(" ");
            try self.record(arg);
        }
        if (stdin_note) |note| {
            try self.record(" (stdin: ");
            try self.record(note);
            try self.record(")");
        }
        try self.record("\n");
    }

    pub fn run(self: *Runner, argv: []const []const u8) !void {
        if (self.dry_run) return self.describe(argv, null);
        const result = try std.process.run(self.allocator, self.io, .{ .argv = argv });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);
        try self.record(result.stdout);
        try self.record(result.stderr);
        switch (result.term) {
            .exited => |code| if (code != 0) return error.CommandFailed,
            else => return error.CommandFailed,
        }
    }

    pub fn output(self: *Runner, argv: []const []const u8) ![]u8 {
        if (self.dry_run) {
            try self.describe(argv, null);
            return self.allocator.dupe(u8, "");
        }
        const result = try std.process.run(self.allocator, self.io, .{ .argv = argv });
        defer self.allocator.free(result.stderr);
        try self.record(result.stderr);
        switch (result.term) {
            .exited => |code| if (code != 0) {
                self.allocator.free(result.stdout);
                return error.CommandFailed;
            },
            else => {
                self.allocator.free(result.stdout);
                return error.CommandFailed;
            },
        }
        return result.stdout;
    }

    pub fn runStdin(self: *Runner, input: []const u8, argv: []const []const u8) !void {
        if (self.dry_run) return self.describe(argv, "credential");
        var child = try std.process.spawn(self.io, .{
            .argv = argv,
            .stdin = .pipe,
            .stdout = .inherit,
            .stderr = .inherit,
        });
        defer child.kill(self.io);
        var buffer: [4096]u8 = undefined;
        var writer = child.stdin.?.writer(self.io, &buffer);
        try writer.interface.writeAll(input);
        try writer.interface.flush();
        child.stdin.?.close(self.io);
        child.stdin = null;
        const term = try child.wait(self.io);
        switch (term) {
            .exited => |code| if (code != 0) return error.CommandFailed,
            else => return error.CommandFailed,
        }
    }
};

test "dry runner records commands without executing" {
    var runner = Runner.init(std.testing.allocator, std.testing.io, true);
    defer runner.deinit();
    try runner.run(&.{ "podman", "pull", "example/image:tag" });
    try std.testing.expect(std.mem.indexOf(u8, runner.log.items, "podman pull example/image:tag") != null);
}
