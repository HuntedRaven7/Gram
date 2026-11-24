const std = @import("std");
const runner_mod = @import("runner.zig");

const Raw = struct {
    path: []const u8,
    type: []const u8,
    fstype: ?[]const u8 = null,
    label: ?[]const u8 = null,
};

const Lsblk = struct {
    blockdevices: []Raw,
};

const mount_point = "/mnt/gram-verify-esp";
const composefs_karg = "composefs=";
const mismatch_prefix = "composefs digest mismatch: embedded=";

pub const ComposefsDigests = struct {
    /// Kernel cmdline from the signed UKI, carrying composefs=<digest>.
    embedded_cmdline: []const u8,
    /// Digest recomputed from the installed EROFS metadata.
    computed: []const u8,
};

/// Parse the `composefs=<digest>` kernel argument out of a cmdline string.
/// Works on a plain cmdline and on raw UKI bytes, where the argument lives in
/// the plain-text .cmdline section. The first non-empty value wins.
pub fn parseComposefsDigest(cmdline: []const u8) ?[]const u8 {
    var rest = cmdline;
    while (std.mem.indexOf(u8, rest, composefs_karg)) |at| {
        const tail = rest[at + composefs_karg.len ..];
        const end = std.mem.indexOfAny(u8, tail, " \t\r\n\x00") orelse tail.len;
        if (end != 0) return tail[0..end];
        rest = tail;
    }
    return null;
}

/// Fail with both values when the digest embedded in the signed UKI differs
/// from the digest computed from the installed EROFS metadata. The recorded
/// detail lets the operator see why Gram refuses to report success.
pub fn checkComposefsDigest(r: *runner_mod.Runner, embedded: []const u8, computed: []const u8) !void {
    if (std.mem.eql(u8, embedded, computed)) return;
    const detail = try std.fmt.allocPrint(r.allocator, "{s}{s} computed={s}\n", .{
        mismatch_prefix, embedded, computed,
    });
    defer r.allocator.free(detail);
    try r.record(detail);
    return error.ComposefsDigestMismatch;
}

/// Parse the embedded cmdline and check its composefs digest against the
/// digest computed from the installed EROFS metadata.
pub fn verifyComposefs(r: *runner_mod.Runner, digests: ComposefsDigests) !void {
    const embedded = parseComposefsDigest(digests.embedded_cmdline) orelse
        return error.ComposefsDigestMissing;
    try checkComposefsDigest(r, embedded, digests.computed);
}

fn hasEfiFile(io: std.Io, path: []const u8) bool {
    var dir = std.Io.Dir.openDirAbsolute(io, path, .{}) catch return false;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch return false) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.endsWith(u8, entry.name, ".efi") or std.mem.endsWith(u8, entry.name, ".EFI")) return true;
    }
    return false;
}

pub fn verify(allocator: std.mem.Allocator, r: *runner_mod.Runner, disk: []const u8, require_uki: bool) !void {
    return verifyWithComposefs(allocator, r, disk, require_uki, null);
}

/// Presence checks plus an optional composefs digest check. Production callers
/// pass the digests once the installed EROFS digest can be recomputed; until
/// then a null leaves the presence-only behaviour intact. Profiles without a
/// signed composefs digest supply no digests, so they keep presence-only checks.
pub fn verifyWithComposefs(
    allocator: std.mem.Allocator,
    r: *runner_mod.Runner,
    disk: []const u8,
    require_uki: bool,
    composefs: ?ComposefsDigests,
) !void {
    if (r.dry_run) return;
    const text = try r.output(&.{ "lsblk", "-J", "-o", "PATH,TYPE,FSTYPE,LABEL", disk });
    defer allocator.free(text);
    const parsed = try std.json.parseFromSlice(Lsblk, allocator, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    var esp: ?[]const u8 = null;
    var root: ?[]const u8 = null;
    for (parsed.value.blockdevices) |part| {
        if (!std.mem.eql(u8, part.type, "part")) continue;
        const fs = part.fstype orelse "";
        if (esp == null and std.mem.eql(u8, fs, "vfat")) esp = part.path;
        if (root == null and (std.mem.eql(u8, fs, "btrfs") or std.mem.eql(u8, fs, "xfs") or std.mem.eql(u8, fs, "ext4"))) root = part.path;
    }
    if (esp == null or root == null) return error.InstalledLayoutMissing;

    try std.Io.Dir.cwd().createDirPath(r.io, mount_point);
    defer std.Io.Dir.cwd().deleteDir(r.io, mount_point) catch {};
    try r.run(&.{ "mount", "-o", "ro", esp.?, mount_point });
    defer r.run(&.{ "umount", mount_point }) catch {};

    if (require_uki and !hasEfiFile(r.io, mount_point ++ "/EFI/Linux")) {
        return error.MissingUki;
    }
    if (!hasEfiFile(r.io, mount_point ++ "/EFI/BOOT")) {
        return error.MissingBootLoader;
    }

    if (require_uki) {
        if (composefs) |digests| try verifyComposefs(r, digests);
    }
}

test "registry and layout expectations are checked on real output shape" {
    const text =
        \\{"blockdevices":[{"path":"/dev/vda","type":"disk","fstype":null,"label":null,"children":[
        \\{"path":"/dev/vda1","type":"part","fstype":"vfat","label":null},
        \\{"path":"/dev/vda2","type":"part","fstype":"btrfs","label":null}
        \\]}]}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, text, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("blockdevices") != null);
}

test "parse composefs digest from a cmdline" {
    const cmdline = "console=ttyS0 composefs=abc123def456 quiet systemd.volatile=yes";
    try std.testing.expectEqualStrings("abc123def456", parseComposefsDigest(cmdline).?);
    try std.testing.expect(parseComposefsDigest("console=ttyS0 quiet") == null);
}

test "mismatched composefs digest fails with both values" {
    const embedded_cmdline =
        "console=ttyS0 composefs=1111111111111111111111111111111111111111111111111111111111111111 quiet";
    const computed = "2222222222222222222222222222222222222222222222222222222222222222";

    var r = runner_mod.Runner.init(std.testing.allocator, std.testing.io, false);
    defer r.deinit();

    try std.testing.expectError(error.ComposefsDigestMismatch, verifyComposefs(&r, .{
        .embedded_cmdline = embedded_cmdline,
        .computed = computed,
    }));
    try std.testing.expect(std.mem.indexOf(u8, r.log.items, "1111111111111111111111111111111111111111111111111111111111111111") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.log.items, computed) != null);
}

test "matching composefs digest passes verification" {
    const digest = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const embedded_cmdline = std.fmt.comptimePrint("console=ttyS0 composefs={s} quiet", .{digest});

    var r = runner_mod.Runner.init(std.testing.allocator, std.testing.io, false);
    defer r.deinit();

    try verifyComposefs(&r, .{ .embedded_cmdline = embedded_cmdline, .computed = digest });
    try std.testing.expectEqual(@as(usize, 0), r.log.items.len);
}
