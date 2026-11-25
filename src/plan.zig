const std = @import("std");
const config_mod = @import("config.zig");
const profile_mod = @import("profile.zig");

pub const Command = struct {
    label: []const u8,
    argv: []const []const u8,
    stdin: ?[]const u8 = null,
    allow_fail: bool = false,
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
        .label = "pull image",
        .argv = try dupeArgv(allocator, &.{ "podman", "pull", c.image }),
    } });
    try actions.append(allocator, .{ .command = .{
        .label = "release scratch filesystem",
        .argv = try dupeArgv(allocator, &.{ "umount", "/var/tmp" }),
    } });

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
        .argv = try dupeArgv(allocator, &.{ "mount", c.disk, "/var/tmp" }),
    } });

    var bootc_args: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer bootc_args.deinit(allocator);
    try bootc_args.appendSlice(allocator, &.{
        "podman",                                  "run",            "--rm",                    "--privileged", "--pid=host",
        "-v",                                      "/dev:/dev",      "--tmpfs",                 "/run/udev",    "-v",
        "/var/lib/containers:/var/lib/containers", "--security-opt", "label=type:unconfined_t", c.image,        "bootc",
        "install",                                 "to-disk",        "--composefs-backend",
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
