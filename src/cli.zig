const std = @import("std");
const config_mod = @import("config.zig");
const profile_mod = @import("profile.zig");
const disk_mod = @import("disk.zig");
const plan_mod = @import("plan.zig");
const runner_mod = @import("runner.zig");
const execute_mod = @import("execute.zig");

pub const Options = struct {
    config_path: ?[]const u8 = null,
    profile: ?[]const u8 = null,
    image: ?[]const u8 = null,
    disk: ?[]const u8 = null,
    dry_run: bool = false,
    yes: bool = false,
    encrypt: bool = false,
    version: bool = false,
};

pub const Prepared = struct {
    config: config_mod.Config,
    disks: []const disk_mod.Disk,
};

pub fn parseArgs(allocator: std.mem.Allocator, args: []const []const u8) !Options {
    var opts = Options{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--config") or std.mem.eql(u8, arg, "-c")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            opts.config_path = args[i];
        } else if (std.mem.eql(u8, arg, "--profile")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            opts.profile = args[i];
        } else if (std.mem.eql(u8, arg, "--image")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            opts.image = args[i];
        } else if (std.mem.eql(u8, arg, "--disk")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            opts.disk = args[i];
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            opts.dry_run = true;
        } else if (std.mem.eql(u8, arg, "--yes") or std.mem.eql(u8, arg, "-y")) {
            opts.yes = true;
        } else if (std.mem.eql(u8, arg, "--encrypt")) {
            opts.encrypt = true;
        } else if (std.mem.eql(u8, arg, "--version")) {
            opts.version = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return error.HelpRequested;
        } else {
            return error.UnknownOption;
        }
    }
    _ = allocator;
    return opts;
}

pub const help =
    \\Usage: gram [options]
    \\
    \\  --config <file>   JSON configuration, skips prompts for set fields
    \\  --profile <name>  mjolnir or muramasa
    \\  --image <ref>     override the image reference
    \\  --disk <path>     target disk
    \\  --dry-run         print the actions without executing them
    \\  --yes             unattended install, no prompts
    \\  --encrypt         TPM2-bound LUKS root
    \\  --version         print version
    \\
;

fn machineId(allocator: std.mem.Allocator, io: std.Io) ![]const u8 {
    var bytes: [16]u8 = undefined;
    const file = try std.Io.Dir.openFileAbsolute(io, "/dev/urandom", .{});
    defer file.close(io);
    var buffer: [16]u8 = undefined;
    var reader = file.reader(io, &buffer);
    try reader.interface.readSliceAll(&bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    return std.fmt.allocPrint(
        allocator,
        "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}",
        .{ bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15] },
    );
}

pub fn prepare(allocator: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, opts: Options, r: *runner_mod.Runner) !Prepared {
    var c = config_mod.defaults();
    if (opts.config_path) |path| {
        const text = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
        c = try config_mod.fromJson(allocator, text);
    }
    if (opts.profile) |name| {
        const id = profile_mod.parse(name) orelse return error.UnknownProfile;
        config_mod.applyProfile(&c, id);
    }
    if (opts.image) |image| c.image = image;
    if (opts.disk) |path| c.disk = path;
    c.dry_run = opts.dry_run;
    c.yes = opts.yes;
    if (opts.encrypt) c.encrypt = true;

    c.registry_user = try config_mod.secret(allocator, io, env, c.registry_user, "registry-user");
    c.registry_token = try config_mod.secret(allocator, io, env, c.registry_token, "registry-token");
    c.ssid = try config_mod.secret(allocator, io, env, c.ssid, "wifi-ssid");
    c.psk = try config_mod.secret(allocator, io, env, c.psk, "wifi-psk");

    const json = try r.output(&.{ "lsblk", "-J", "-d", "-o", "PATH,SIZE,TYPE,MODEL,SERIAL,TRAN,RM,MOUNTPOINT" });
    const cmdline = try std.Io.Dir.cwd().readFileAlloc(io, "/proc/cmdline", allocator, .unlimited);
    const disks = if (json.len == 0)
        &[_]disk_mod.Disk{}
    else
        try disk_mod.eligible(allocator, json, cmdline);
    if (c.disk.len == 0) {
        if (disks.len == 0) {
            if (r.dry_run) c.disk = "/dev/vda" else return error.NoEligibleDisk;
        } else {
            c.disk = disks[0].path;
        }
    } else if (disks.len != 0) {
        var found = false;
        for (disks) |d| {
            if (std.mem.eql(u8, d.path, c.disk)) found = true;
        }
        if (!found and !r.dry_run) return error.DiskNotEligible;
    }

    if (!r.dry_run) {
        const p = profile_mod.get(c.profile);
        var selected: ?disk_mod.Disk = null;
        for (disks) |d| {
            if (std.mem.eql(u8, d.path, c.disk)) selected = d;
        }
        if (selected) |d| {
            if (d.bytes != 0 and d.bytes < p.min_disk_bytes) return error.DiskTooSmall;
        }
    }

    return .{ .config = c, .disks = disks };
}

fn checkDns(allocator: std.mem.Allocator, io: std.Io, r: *runner_mod.Runner, host: []const u8) !void {
    if (r.dry_run) {
        try r.record(try std.fmt.allocPrint(allocator, "dns check skipped in dry-run for {s}\n", .{host}));
        return;
    }
    try r.record(try std.fmt.allocPrint(allocator, "checking DNS for {s}\n", .{host}));
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "getent", "hosts", host },
        .timeout = .{ .duration = .{
            .raw = std.Io.Duration.fromSeconds(60),
            .clock = .boot,
        } },
    }) catch |err| {
        try r.record(try std.fmt.allocPrint(allocator, "DNS failed for {s}: {s}\n", .{ host, @errorName(err) }));
        return error.DnsResolutionFailed;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code == 0) {
            try r.record(try std.fmt.allocPrint(allocator, "DNS ok for {s}\n", .{host}));
            return;
        },
        else => {},
    }
    try r.record(try std.fmt.allocPrint(allocator, "DNS failed for {s}\n", .{host}));
    return error.DnsResolutionFailed;
}

pub fn apply(allocator: std.mem.Allocator, io: std.Io, c: config_mod.Config, r: *runner_mod.Runner, print: *const fn ([]const u8) void) !void {
    try config_mod.validate(c);
    try checkDns(allocator, io, r, plan_mod.registryFromImage(c.image));
    const id = if (r.dry_run) "00000000-0000-4000-8000-000000000000" else try machineId(allocator, io);
    const p = try plan_mod.build(allocator, c, id);
    try execute_mod.execute(allocator, r, p.actions, print);
    if (r.dry_run) {
        try r.record("[dry-run] install complete\n");
    } else {
        print("install complete");
    }
}
