const std = @import("std");
const config_mod = @import("config.zig");
const profile_mod = @import("profile.zig");

pub const Command = struct {
    label: []const u8,
    argv: []const []const u8,
    stdin: ?[]const u8 = null,
    allow_fail: bool = false,
    /// Emit begin/end labels around this step for serial-console diagnosis.
    trace: bool = false,
};

pub const WriteFile = struct {
    label: []const u8,
    path: []const u8,
    content: []const u8,
    mode: u32 = 0o600,
};

pub const PersistWifi = struct {
    label: []const u8,
    ssid: []const u8,
    psk: []const u8,
    state_label: ?[]const u8,
    required: bool,
};

pub const Verify = struct {
    label: []const u8,
    disk: []const u8,
    require_uki: bool,
};

pub const Action = union(enum) {
    command: Command,
    write_file: WriteFile,
    persist_wifi: PersistWifi,
    verify: Verify,
};

pub const Plan = struct {
    actions: []Action,
};

const container_root = "/var/lib/containers";
// bootc resolves the install source with `podman inspect` in the host mount
// namespace. That subprocess has no --root override, so it uses podman's
// default graphroot. Pull into that exact path so the source image is visible
// to bootc's source-info step.
const container_graphroot = "/var/lib/containers/storage";
const container_runroot = "/var/lib/containers/runroot";
const scratch_tmp = "/var/tmp";
const storage_conf_path = "/etc/containers/storage.conf";
const storage_conf_content =
    \\[storage]
    \\driver = "overlay"
    \\graphroot = "/var/lib/containers/storage"
    \\runroot = "/var/lib/containers/runroot"
    \\
;

fn dupeArgv(allocator: std.mem.Allocator, items: []const []const u8) ![]const []const u8 {
    return allocator.dupe([]const u8, items);
}

pub fn registryFromImage(image: []const u8) []const u8 {
    const slash = std.mem.indexOfScalar(u8, image, '/') orelse return "docker.io";
    const first = image[0..slash];
    if (std.mem.eql(u8, first, "localhost")) return first;
    if (std.mem.indexOfAny(u8, first, ".:") != null) return first;
    return "docker.io";
}

fn keyfile(allocator: std.mem.Allocator, ssid: []const u8, psk: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator,
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
    , .{ ssid, psk });
}

pub fn build(allocator: std.mem.Allocator, c: config_mod.Config, machine_id: []const u8) !Plan {
    const p = profile_mod.get(c.profile);
    var actions: std.ArrayListUnmanaged(Action) = .empty;
    errdefer actions.deinit(allocator);

    if (c.ssid.len != 0) {
        try actions.append(allocator, .{ .write_file = .{
            .label = "write live WiFi profile",
            .path = "/etc/NetworkManager/system-connections/gram-wifi.nmconnection",
            .content = try keyfile(allocator, c.ssid, c.psk),
        } });
        try actions.append(allocator, .{ .command = .{
            .label = "reload NetworkManager",
            .argv = try dupeArgv(allocator, &.{ "nmcli", "connection", "reload" }),
        } });
        try actions.append(allocator, .{ .command = .{
            .label = "connect WiFi",
            .argv = try dupeArgv(allocator, &.{ "nmcli", "connection", "up", "gram-wifi" }),
        } });
    }

    if (c.registry_user.len != 0 and c.registry_token.len != 0) {
        const reg = if (c.registry.len != 0) c.registry else registryFromImage(c.image);
        try actions.append(allocator, .{ .command = .{
            .label = "registry login",
            .argv = try dupeArgv(allocator, &.{ "podman", "login", reg, "-u", c.registry_user, "--password-stdin" }),
            .stdin = try std.fmt.allocPrint(allocator, "{s}\n", .{c.registry_token}),
        } });
    }

    try actions.append(allocator, .{ .command = .{
        .label = "wipe target disk",
        .argv = try dupeArgv(allocator, &.{ "wipefs", "--all", "--force", c.disk }),
    } });
    try actions.append(allocator, .{ .command = .{
        .label = "scratch filesystem for pull",
        .argv = try dupeArgv(allocator, &.{ "mkfs.ext4", "-F", "-L", "GRAMSCRATCH", c.disk }),
    } });
    try actions.append(allocator, .{ .command = .{
        .label = "mount scratch for pull",
        .argv = try dupeArgv(allocator, &.{ "mount", c.disk, container_root }),
        .trace = true,
    } });
    try actions.append(allocator, .{ .command = .{
        .label = "mount scratch at /var/tmp for pull",
        .argv = try dupeArgv(allocator, &.{ "mount", c.disk, scratch_tmp }),
        .trace = true,
    } });
    try actions.append(allocator, .{ .command = .{
        .label = "create container runroot on scratch",
        .argv = try dupeArgv(allocator, &.{ "mkdir", "-p", container_runroot }),
    } });
    try actions.append(allocator, .{ .command = .{
        .label = "create container root on scratch",
        .argv = try dupeArgv(allocator, &.{ "mkdir", "-p", container_graphroot }),
    } });
    try actions.append(allocator, .{ .write_file = .{
        .label = "point container storage at scratch",
        .path = storage_conf_path,
        .content = storage_conf_content,
    } });
    try actions.append(allocator, .{ .command = .{
        .label = "check free space before pull",
        .argv = try dupeArgv(allocator, &.{ "df", "-h", scratch_tmp, container_root, "/run" }),
    } });

    const pull_tmpdir = try std.fmt.allocPrint(allocator, "TMPDIR={s}", .{scratch_tmp});
    try actions.append(allocator, .{ .command = .{
        .label = "pull image",
        .argv = try dupeArgv(allocator, &.{
            "env",               pull_tmpdir, "podman",          "--root",
            container_graphroot, "--runroot", container_runroot, "pull",
            c.image,
        }),
        .trace = true,
    } });

    var bootc_args: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer bootc_args.deinit(allocator);
    try bootc_args.appendSlice(allocator, &.{
        "podman",              "run",                     "--rm",
        "--privileged",        "--pid=host",              "--root",
        container_graphroot,   "--runroot",               container_runroot,
        "-v",                  "/dev:/dev",               "--tmpfs",
        "/run/udev",           "-v",                      "/var/lib/containers:/var/lib/containers",
        "--security-opt",      "label=type:unconfined_t", c.image,
        "bootc",               "install",                 "to-disk",
        "--composefs-backend",
    });
    if (c.encrypt) try bootc_args.appendSlice(allocator, &.{ "--block-setup", "tpm2-luks" });
    try bootc_args.appendSlice(allocator, &.{
        "--wipe",
        "--filesystem",
        p.filesystem,
        "--bootloader",
        p.bootloader,
        "--run-repart",
    });
    for (p.kargs) |karg| {
        try bootc_args.append(allocator, try std.fmt.allocPrint(allocator, "--karg={s}", .{karg}));
    }
    try bootc_args.append(allocator, try std.fmt.allocPrint(allocator, "--karg=systemd.machine_id={s}", .{machine_id}));
    try bootc_args.append(allocator, c.disk);
    try actions.append(allocator, .{ .command = .{
        .label = "bootc install to-disk",
        .argv = try bootc_args.toOwnedSlice(allocator),
    } });
    // The pulled image lives on the scratch filesystem. Keep every mount in
    // place until bootc install has consumed it; releasing it earlier makes
    // podman pull the image again into the RAM-backed live overlay and run out
    // of space while unpacking.
    try actions.append(allocator, .{ .command = .{
        .label = "restore default container storage config",
        .argv = try dupeArgv(allocator, &.{ "rm", "-f", storage_conf_path }),
    } });
    try actions.append(allocator, .{ .command = .{
        .label = "release scratch from /var/tmp",
        .argv = try dupeArgv(allocator, &.{ "umount", scratch_tmp }),
        .trace = true,
    } });
    try actions.append(allocator, .{ .command = .{
        .label = "release scratch filesystem",
        .argv = try dupeArgv(allocator, &.{ "umount", container_root }),
        .trace = true,
    } });

    if (c.ssid.len != 0) {
        try actions.append(allocator, .{ .persist_wifi = .{
            .label = "persist WiFi in target state partition",
            .ssid = c.ssid,
            .psk = c.psk,
            .state_label = p.state_label,
            .required = p.state_label != null,
        } });
    }

    try actions.append(allocator, .{ .verify = .{
        .label = "verify installed disk",
        .disk = c.disk,
        .require_uki = p.require_uki,
    } });

    return .{ .actions = try actions.toOwnedSlice(allocator) };
}

test "plan builds both profiles and keeps secrets out of argv" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var c = config_mod.defaults();
    c.disk = "/dev/vda";
    c.ssid = "test-net";
    c.psk = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    c.registry_user = "bot";
    c.registry_token = "secret";
    const plan = try build(a, c, "00000000-0000-4000-8000-000000000000");

    var found_install = false;
    for (plan.actions) |action| switch (action) {
        .command => |cmd| {
            for (cmd.argv) |arg| try std.testing.expect(!std.mem.eql(u8, arg, "secret"));
            if (std.mem.eql(u8, cmd.label, "bootc install to-disk")) {
                found_install = true;
                try std.testing.expect(std.mem.indexOf(u8, cmd.argv[cmd.argv.len - 1], "/dev/vda") != null);
            }
        },
        else => {},
    };
    try std.testing.expect(found_install);
}

test "registry derived from image" {
    try std.testing.expectEqualStrings("ghcr.io", registryFromImage("ghcr.io/huntedraven7/mjolnir:testing"));
    try std.testing.expectEqualStrings("docker.io", registryFromImage("fedora:latest"));
}

test "scratch disk mounts at container storage for the pull" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var c = config_mod.defaults();
    c.disk = "/dev/vda";
    const plan = try build(a, c, "00000000-0000-4000-8000-000000000000");

    var mount_index: ?usize = null;
    var pull_index: ?usize = null;
    var unmount_index: ?usize = null;
    var install_index: ?usize = null;
    for (plan.actions, 0..) |action, i| switch (action) {
        .command => |cmd| {
            if (std.mem.eql(u8, cmd.label, "mount scratch for pull")) {
                mount_index = i;
                try std.testing.expectEqual(@as(usize, 3), cmd.argv.len);
                try std.testing.expectEqualStrings("mount", cmd.argv[0]);
                try std.testing.expectEqualStrings(c.disk, cmd.argv[1]);
                try std.testing.expectEqualStrings("/var/lib/containers", cmd.argv[2]);
            } else if (std.mem.eql(u8, cmd.label, "pull image")) {
                pull_index = i;
            } else if (std.mem.eql(u8, cmd.label, "release scratch filesystem")) {
                unmount_index = i;
                try std.testing.expectEqual(@as(usize, 2), cmd.argv.len);
                try std.testing.expectEqualStrings("umount", cmd.argv[0]);
                try std.testing.expectEqualStrings("/var/lib/containers", cmd.argv[1]);
            } else if (std.mem.eql(u8, cmd.label, "bootc install to-disk")) {
                install_index = i;
            }
        },
        else => {},
    };

    try std.testing.expect(mount_index != null);
    try std.testing.expect(pull_index != null);
    try std.testing.expect(unmount_index != null);
    try std.testing.expect(install_index != null);
    try std.testing.expect(mount_index.? < pull_index.?);
    try std.testing.expect(pull_index.? < install_index.?);
    try std.testing.expect(install_index.? < unmount_index.?);
}

test "runroot config keeps podman state on the scratch filesystem" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var c = config_mod.defaults();
    c.disk = "/dev/vda";
    const plan = try build(a, c, "00000000-0000-4000-8000-000000000000");

    var mount_index: ?usize = null;
    var runroot_dir_index: ?usize = null;
    var config_index: ?usize = null;
    var pull_index: ?usize = null;
    var restore_index: ?usize = null;
    var unmount_index: ?usize = null;
    for (plan.actions, 0..) |action, i| switch (action) {
        .command => |cmd| {
            if (std.mem.eql(u8, cmd.label, "mount scratch for pull")) {
                mount_index = i;
            } else if (std.mem.eql(u8, cmd.label, "create container runroot on scratch")) {
                runroot_dir_index = i;
                try std.testing.expectEqual(@as(usize, 3), cmd.argv.len);
                try std.testing.expectEqualStrings("mkdir", cmd.argv[0]);
                try std.testing.expectEqualStrings("-p", cmd.argv[1]);
                try std.testing.expectEqualStrings(container_runroot, cmd.argv[2]);
            } else if (std.mem.eql(u8, cmd.label, "pull image")) {
                pull_index = i;
            } else if (std.mem.eql(u8, cmd.label, "restore default container storage config")) {
                restore_index = i;
                try std.testing.expectEqual(@as(usize, 3), cmd.argv.len);
                try std.testing.expectEqualStrings("rm", cmd.argv[0]);
                try std.testing.expectEqualStrings("-f", cmd.argv[1]);
                try std.testing.expectEqualStrings(storage_conf_path, cmd.argv[2]);
            } else if (std.mem.eql(u8, cmd.label, "release scratch filesystem")) {
                unmount_index = i;
            }
        },
        .write_file => |wf| {
            if (std.mem.eql(u8, wf.path, storage_conf_path)) {
                config_index = i;
                try std.testing.expect(std.mem.indexOf(u8, wf.content, "graphroot = \"/var/lib/containers/storage\"") != null);
                try std.testing.expect(std.mem.indexOf(u8, wf.content, "runroot = \"/var/lib/containers/runroot\"") != null);
            }
        },
        else => {},
    };

    try std.testing.expect(mount_index != null);
    try std.testing.expect(runroot_dir_index != null);
    try std.testing.expect(config_index != null);
    try std.testing.expect(pull_index != null);
    try std.testing.expect(restore_index != null);
    try std.testing.expect(unmount_index != null);
    try std.testing.expect(mount_index.? < runroot_dir_index.?);
    try std.testing.expect(runroot_dir_index.? < config_index.?);
    try std.testing.expect(config_index.? < pull_index.?);
    try std.testing.expect(pull_index.? < restore_index.?);
    try std.testing.expect(restore_index.? < unmount_index.?);
}

test "scratch covers container storage and var tmp around the pull" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var c = config_mod.defaults();
    c.disk = "/dev/vda";
    const plan = try build(a, c, "00000000-0000-4000-8000-000000000000");

    var container_mount: ?usize = null;
    var tmp_mount: ?usize = null;
    var pull_index: ?usize = null;
    var tmp_unmount: ?usize = null;
    var container_unmount: ?usize = null;
    var install_index: ?usize = null;
    for (plan.actions, 0..) |action, i| switch (action) {
        .command => |cmd| {
            if (cmd.argv.len == 3 and std.mem.eql(u8, cmd.argv[0], "mount") and std.mem.eql(u8, cmd.argv[1], c.disk)) {
                if (std.mem.eql(u8, cmd.argv[2], container_root)) container_mount = i;
                if (std.mem.eql(u8, cmd.argv[2], scratch_tmp)) tmp_mount = i;
            } else if (cmd.argv.len == 2 and std.mem.eql(u8, cmd.argv[0], "umount")) {
                if (std.mem.eql(u8, cmd.argv[1], container_root)) container_unmount = i;
                if (std.mem.eql(u8, cmd.argv[1], scratch_tmp)) tmp_unmount = i;
            } else if (std.mem.eql(u8, cmd.label, "pull image")) {
                pull_index = i;
            } else if (std.mem.eql(u8, cmd.label, "bootc install to-disk")) {
                install_index = i;
            }
        },
        else => {},
    };

    try std.testing.expect(container_mount != null);
    try std.testing.expect(tmp_mount != null);
    try std.testing.expect(pull_index != null);
    try std.testing.expect(tmp_unmount != null);
    try std.testing.expect(container_unmount != null);
    try std.testing.expect(install_index != null);
    try std.testing.expect(container_mount.? < pull_index.?);
    try std.testing.expect(tmp_mount.? < pull_index.?);
    try std.testing.expect(pull_index.? < install_index.?);
    try std.testing.expect(install_index.? < tmp_unmount.?);
    try std.testing.expect(install_index.? < container_unmount.?);
}

fn expectArgv(actual: []const []const u8, expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |want, got| try std.testing.expectEqualStrings(want, got);
}

test "pull runs explicitly on scratch paths with TMPDIR set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var c = config_mod.defaults();
    c.disk = "/dev/vda";
    const plan = try build(a, c, "00000000-0000-4000-8000-000000000000");

    var root_dir_index: ?usize = null;
    var runroot_dir_index: ?usize = null;
    var df_index: ?usize = null;
    var pull_index: ?usize = null;
    for (plan.actions, 0..) |action, i| switch (action) {
        .command => |cmd| {
            if (std.mem.eql(u8, cmd.label, "create container root on scratch")) {
                root_dir_index = i;
                try expectArgv(cmd.argv, &.{ "mkdir", "-p", container_graphroot });
            } else if (std.mem.eql(u8, cmd.label, "create container runroot on scratch")) {
                runroot_dir_index = i;
            } else if (std.mem.eql(u8, cmd.label, "check free space before pull")) {
                df_index = i;
                try expectArgv(cmd.argv, &.{ "df", "-h", scratch_tmp, container_root, "/run" });
            } else if (std.mem.eql(u8, cmd.label, "pull image")) {
                pull_index = i;
                try expectArgv(cmd.argv, &.{
                    "env",
                    "TMPDIR=/var/tmp",
                    "podman",
                    "--root",
                    container_graphroot,
                    "--runroot",
                    container_runroot,
                    "pull",
                    c.image,
                });
            }
        },
        else => {},
    };

    try std.testing.expect(root_dir_index != null);
    try std.testing.expect(runroot_dir_index != null);
    try std.testing.expect(df_index != null);
    try std.testing.expect(pull_index != null);
    try std.testing.expect(root_dir_index.? < pull_index.?);
    try std.testing.expect(runroot_dir_index.? < pull_index.?);
    try std.testing.expect(df_index.? < pull_index.?);
}

fn rootFrom(argv: []const []const u8) ?[]const u8 {
    for (argv, 0..) |arg, i| {
        if (std.mem.eql(u8, arg, "--root") and i + 1 < argv.len) return argv[i + 1];
    }
    return null;
}

fn runrootFrom(argv: []const []const u8) ?[]const u8 {
    for (argv, 0..) |arg, i| {
        if (std.mem.eql(u8, arg, "--runroot") and i + 1 < argv.len) return argv[i + 1];
    }
    return null;
}

test "bootc install reuses the storage the pull populated" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var c = config_mod.defaults();
    c.disk = "/dev/vda";
    const plan = try build(a, c, "00000000-0000-4000-8000-000000000000");

    var pull_root: ?[]const u8 = null;
    var pull_runroot: ?[]const u8 = null;
    var install_root: ?[]const u8 = null;
    var install_runroot: ?[]const u8 = null;
    for (plan.actions) |action| switch (action) {
        .command => |cmd| {
            if (std.mem.eql(u8, cmd.label, "pull image")) {
                pull_root = rootFrom(cmd.argv);
                pull_runroot = runrootFrom(cmd.argv);
            } else if (std.mem.eql(u8, cmd.label, "bootc install to-disk")) {
                install_root = rootFrom(cmd.argv);
                install_runroot = runrootFrom(cmd.argv);
            }
        },
        else => {},
    };

    try std.testing.expectEqualStrings(container_graphroot, pull_root.?);
    try std.testing.expectEqualStrings(container_runroot, pull_runroot.?);
    try std.testing.expectEqualStrings(pull_root.?, install_root.?);
    try std.testing.expectEqualStrings(pull_runroot.?, install_runroot.?);
}

fn graphrootFrom(content: []const u8) ?[]const u8 {
    const prefix = "graphroot = \"";
    const start = std.mem.indexOf(u8, content, prefix) orelse return null;
    const rest = content[start + prefix.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    return rest[0..end];
}

test "storage config points at the storage the pull and bootc install use" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var c = config_mod.defaults();
    c.disk = "/dev/vda";
    const plan = try build(a, c, "00000000-0000-4000-8000-000000000000");

    var config_root: ?[]const u8 = null;
    var pull_root: ?[]const u8 = null;
    var install_root: ?[]const u8 = null;
    for (plan.actions) |action| switch (action) {
        .write_file => |wf| {
            if (std.mem.eql(u8, wf.path, storage_conf_path)) config_root = graphrootFrom(wf.content);
        },
        .command => |cmd| {
            if (std.mem.eql(u8, cmd.label, "pull image")) pull_root = rootFrom(cmd.argv);
            if (std.mem.eql(u8, cmd.label, "bootc install to-disk")) install_root = rootFrom(cmd.argv);
        },
        else => {},
    };

    try std.testing.expectEqualStrings(container_graphroot, config_root.?);
    try std.testing.expectEqualStrings(config_root.?, pull_root.?);
    try std.testing.expectEqualStrings(config_root.?, install_root.?);
}

test "mounts, unmounts and pull are traced on the serial console" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var c = config_mod.defaults();
    c.disk = "/dev/vda";
    const plan = try build(a, c, "00000000-0000-4000-8000-000000000000");

    const traced = [_][]const u8{
        "mount scratch for pull",
        "mount scratch at /var/tmp for pull",
        "release scratch from /var/tmp",
        "release scratch filesystem",
        "pull image",
    };
    for (traced) |want| {
        var found = false;
        for (plan.actions) |action| switch (action) {
            .command => |cmd| {
                if (std.mem.eql(u8, cmd.label, want)) {
                    try std.testing.expect(cmd.trace);
                    found = true;
                }
            },
            else => {},
        };
        try std.testing.expect(found);
    }
}
