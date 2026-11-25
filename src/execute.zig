const std = @import("std");
const plan_mod = @import("plan.zig");
const runner_mod = @import("runner.zig");
const verify_mod = @import("verify.zig");

const state_mount = "/mnt/gram-state";

const Raw = struct {
    path: []const u8,
    type: []const u8,
    fstype: ?[]const u8 = null,
    label: ?[]const u8 = null,
    children: []Raw = &.{},
};

const Lsblk = struct {
    blockdevices: []Raw,
};

fn collectParts(allocator: std.mem.Allocator, raw: Raw, list: *std.ArrayListUnmanaged(Raw)) !void {
    if (std.mem.eql(u8, raw.type, "part")) try list.append(allocator, raw);
    for (raw.children) |child| try collectParts(allocator, child, list);
}

pub fn writeFile(r: *runner_mod.Runner, path: []const u8, content: []const u8, mode: u32) !void {
    if (r.dry_run) return;
    if (std.fs.path.dirname(path)) |dir| {
        if (dir.len != 0) try std.Io.Dir.cwd().createDirPath(r.io, dir);
    }
    const file = try std.Io.Dir.createFileAbsolute(r.io, path, .{});
    defer file.close(r.io);
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(r.io, &buffer);
    try writer.interface.writeAll(content);
    try writer.interface.flush();
    try file.setPermissions(r.io, .fromMode(mode));
}

fn findState(allocator: std.mem.Allocator, r: *runner_mod.Runner, expected: ?[]const u8) !?[]const u8 {
    const text = try r.output(&.{ "lsblk", "-J", "-o", "PATH,TYPE,FSTYPE,LABEL" });
    defer allocator.free(text);
    if (text.len == 0) return null;
    const parsed = try std.json.parseFromSlice(Lsblk, allocator, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    var parts: std.ArrayListUnmanaged(Raw) = .empty;
    defer parts.deinit(allocator);
    for (parsed.value.blockdevices) |raw| try collectParts(allocator, raw, &parts);
    for (parts.items) |part| {
        const label = part.label orelse continue;
        if (expected) |want| {
            if (std.mem.eql(u8, label, want)) return @as(?[]const u8, try allocator.dupe(u8, part.path));
        } else if (std.mem.endsWith(u8, label, "State")) {
            return @as(?[]const u8, try allocator.dupe(u8, part.path));
        }
    }
    return null;
}

pub fn persistWifi(allocator: std.mem.Allocator, r: *runner_mod.Runner, p: plan_mod.PersistWifi) !void {
    if (r.dry_run) return;
    const dev = (try findState(allocator, r, p.state_label)) orelse {
        if (p.required) return error.StatePartitionNotFound;
        try r.record(try std.fmt.allocPrint(allocator, "warning: no state partition found, WiFi profile not persisted\n", .{}));
        return;
    };
    defer allocator.free(dev);

    try std.Io.Dir.cwd().createDirPath(r.io, state_mount);
    defer std.Io.Dir.cwd().deleteDir(r.io, state_mount) catch {};
    try r.run(&.{ "mount", "-o", "rw", dev, state_mount });
    defer r.run(&.{ "umount", state_mount }) catch {};

    const content = try std.fmt.allocPrint(allocator,
        \\[connection]
        \\id=gram-wifi
        \\type=wifi
        \\autoconnect=true
        \\
        \\[wifi]
        \\mode=infrastructure
        \\ssid={s}
        \\
        \\[wifi-security]
        \\key-mgmt=wpa-psk
        \\psk={s}
        \\
        \\[ipv4]
        \\method=auto
        \\
        \\[ipv6]
        \\method=auto
        \\
    , .{ p.ssid, p.psk });
    const path = try std.fmt.allocPrint(allocator, "{s}/etc/NetworkManager/system-connections/gram-wifi.nmconnection", .{state_mount});
    try writeFile(r, path, content, 0o600);
}

fn note(r: *runner_mod.Runner, text: []const u8) !void {
    try r.record(text);
    try r.record("\n");
}

pub fn execute(allocator: std.mem.Allocator, r: *runner_mod.Runner, actions: []plan_mod.Action, print: *const fn ([]const u8) void) !void {
    for (actions) |action| {
        switch (action) {
            .command => |cmd| {
                try note(r, cmd.label);
                print(cmd.label);
                const outcome = if (cmd.stdin) |input|
                    r.runStdin(input, cmd.argv)
                else
                    r.run(cmd.argv);
                outcome catch |err| {
                    if (!cmd.allow_fail) return err;
                    print("step failed, continuing");
                };
            },
            .write_file => |wf| {
                try note(r, wf.label);
                print(wf.label);
                try writeFile(r, wf.path, wf.content, wf.mode);
            },
            .persist_wifi => |pw| {
                try note(r, pw.label);
                print(pw.label);
                try persistWifi(allocator, r, pw);
            },
            .verify => |v| {
                try note(r, v.label);
                print(v.label);
                try verify_mod.verify(allocator, r, v.disk, v.require_uki);
            },
        }
    }
}

pub fn printStdout(line: []const u8) void {
    std.debug.print("{s}\n", .{line});
}
