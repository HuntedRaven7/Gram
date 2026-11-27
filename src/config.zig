const std = @import("std");
const profile_mod = @import("profile.zig");

pub const Config = struct {
    profile: profile_mod.Id = .mjolnir,
    image: []const u8 = "",
    disk: []const u8 = "",
    scratch_disk: []const u8 = "",
    ssid: []const u8 = "",
    psk: []const u8 = "",
    registry_user: []const u8 = "",
    registry_token: []const u8 = "",
    registry: []const u8 = "",
    hostname: []const u8 = "",
    timezone: []const u8 = "",
    username: []const u8 = "",
    password_hash: []const u8 = "",
    ssh_keys: []const []const u8 = &.{},
    encrypt: bool = false,
    yes: bool = false,
    dry_run: bool = false,
    machine_id: []const u8 = "",
};

const Json = struct {
    profile: ?[]const u8 = null,
    image: ?[]const u8 = null,
    disk: ?[]const u8 = null,
    scratchDisk: ?[]const u8 = null,
    ssid: ?[]const u8 = null,
    psk: ?[]const u8 = null,
    registryUser: ?[]const u8 = null,
    registryToken: ?[]const u8 = null,
    registry: ?[]const u8 = null,
    hostname: ?[]const u8 = null,
    timezone: ?[]const u8 = null,
    username: ?[]const u8 = null,
    passwordHash: ?[]const u8 = null,
    sshKeys: ?[]const []const u8 = null,
    encrypted: ?bool = null,
    dryRun: ?bool = null,
};

pub fn defaults() Config {
    var c = Config{};
    applyProfile(&c, .mjolnir);
    return c;
}

pub fn applyProfile(c: *Config, id: profile_mod.Id) void {
    if (c.profile == id and c.image.len != 0) return;
    c.profile = id;
    c.image = profile_mod.get(id).image;
}

fn keep(allocator: std.mem.Allocator, value: ?[]const u8, current: []const u8) ![]const u8 {
    if (value) |v| return allocator.dupe(u8, v);
    return current;
}

pub fn fromJson(allocator: std.mem.Allocator, text: []const u8) !Config {
    const parsed = try std.json.parseFromSlice(Json, allocator, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    const j = parsed.value;

    var c = defaults();
    if (j.profile) |name| {
        if (profile_mod.parse(name)) |id| applyProfile(&c, id);
    }
    c.image = try keep(allocator, j.image, c.image);
    c.disk = try keep(allocator, j.disk, c.disk);
    c.scratch_disk = try keep(allocator, j.scratchDisk, c.scratch_disk);
    c.ssid = try keep(allocator, j.ssid, c.ssid);
    c.psk = try keep(allocator, j.psk, c.psk);
    c.registry_user = try keep(allocator, j.registryUser, c.registry_user);
    c.registry_token = try keep(allocator, j.registryToken, c.registry_token);
    c.registry = try keep(allocator, j.registry, c.registry);
    c.hostname = try keep(allocator, j.hostname, c.hostname);
    c.timezone = try keep(allocator, j.timezone, c.timezone);
    c.username = try keep(allocator, j.username, c.username);
    c.password_hash = try keep(allocator, j.passwordHash, c.password_hash);
    if (j.sshKeys) |keys| {
        const copy = try allocator.alloc([]const u8, keys.len);
        for (keys, 0..) |key, i| copy[i] = try allocator.dupe(u8, key);
        c.ssh_keys = copy;
    }
    if (j.encrypted) |v| c.encrypt = v;
    if (j.dryRun) |v| c.dry_run = v;
    return c;
}

pub fn validate(c: Config) !void {
    if (c.image.len == 0) return error.MissingImage;
    if (c.disk.len == 0 or !std.mem.startsWith(u8, c.disk, "/dev/")) return error.InvalidDisk;
    if (c.ssid.len != 0 and !validPsk(c.psk)) return error.InvalidPsk;
    if (c.registry.len != 0 and c.registry_user.len == 0 and c.registry_token.len != 0) return error.MissingRegistryUser;
    if (!profile_mod.get(c.profile).accepts_identity and (c.username.len != 0 or c.password_hash.len != 0 or c.ssh_keys.len != 0)) {
        return error.MjolnirRejectsDesktopIdentity;
    }
}

pub fn errorMessage(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.MjolnirRejectsDesktopIdentity => "mjolnir profile rejects username, passwordHash and sshKeys",
        error.NoEligibleDisk => "no eligible disks: removable, mounted and boot disks are excluded",
        error.DiskTooSmall => "target disk is below the profile minimum",
        error.DiskNotEligible => "configured disk is not eligible",
        else => null,
    };
}

pub fn validPsk(psk: []const u8) bool {
    if (psk.len != 64) return false;
    for (psk) |ch| {
        const ok = (ch >= '0' and ch <= '9') or (ch >= 'a' and ch <= 'f') or (ch >= 'A' and ch <= 'F');
        if (!ok) return false;
    }
    return true;
}

pub fn secret(
    allocator: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    explicit: []const u8,
    name: []const u8,
) ![]const u8 {
    if (explicit.len != 0) return explicit;
    var paths: [3][]const u8 = undefined;
    var count: usize = 0;
    if (env.get("CREDENTIALS_DIRECTORY")) |dir| {
        paths[count] = try std.fs.path.join(allocator, &.{ dir, name });
        count += 1;
    }
    paths[count] = try std.fmt.allocPrint(allocator, "/run/credentials/gram.service/{s}", .{name});
    count += 1;
    paths[count] = try std.fmt.allocPrint(allocator, "/run/credentials/@system/{s}", .{name});
    count += 1;
    for (paths[0..count]) |path| {
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited) catch continue;
        return std.mem.trim(u8, bytes, " \t\r\n");
    }
    return explicit;
}

test "json config with camelCase keys" {
    const text =
        \\{"profile":"muramasa","disk":"/dev/vda","scratchDisk":"/dev/vdb","encrypted":true,"registryUser":"bot","sshKeys":["ssh-ed25519 AAAA"]}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const c = try fromJson(arena.allocator(), text);
    try std.testing.expectEqual(profile_mod.Id.muramasa, c.profile);
    try std.testing.expectEqualStrings("/dev/vda", c.disk);
    try std.testing.expectEqualStrings("/dev/vdb", c.scratch_disk);
    try std.testing.expect(c.encrypt);
    try std.testing.expectEqualStrings("ghcr.io/huntedraven7/muramasa:testing", c.image);
    try std.testing.expectEqualStrings("bot", c.registry_user);
    try std.testing.expectEqual(@as(usize, 1), c.ssh_keys.len);
}

test "digest pinned image survives config parsing and validation" {
    const image = "ghcr.io/huntedraven7/mjolnir@sha256:243dc4c2ae1249ff4e078e3a74b73645e2b4a2d3493730ccd0fbe853540b030b";
    const text = try std.fmt.allocPrint(std.testing.allocator, "{{\"image\":\"{s}\",\"disk\":\"/dev/vda\"}}", .{image});
    defer std.testing.allocator.free(text);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const c = try fromJson(arena.allocator(), text);
    try validate(c);
    try std.testing.expectEqualStrings(image, c.image);
}

test "psk validation" {
    try std.testing.expect(validPsk("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"));
    try std.testing.expect(!validPsk("short"));
}
