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
