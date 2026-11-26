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
// The composefs backend keeps UKIs one level below EFI/Linux so systemd-boot
// shows only the BLS entries in its menu. Gram must check that directory, not
// the parent, which holds only the `bootc` subdirectory.
const uki_dir = mount_point ++ "/EFI/Linux/bootc";
const loader_dir = mount_point ++ "/EFI/BOOT";

fn diag(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "verify: " ++ fmt ++ "\n", args) catch return;
    std.debug.print("{s}", .{line});
    const console = std.Io.Dir.openFileAbsolute(io, "/dev/console", .{ .mode = .write_only }) catch return;
    defer console.close(io);
    console.writeStreamingAll(io, line) catch return;
}

fn hasEfiFile(io: std.Io, path: []const u8) bool {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return false;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch return false) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.endsWith(u8, entry.name, ".efi") or std.mem.endsWith(u8, entry.name, ".EFI")) return true;
    }
    return false;
}

const Layout = struct {
    esp: ?[]const u8 = null,
    root: ?[]const u8 = null,
};

fn scanLayout(parts: []const Raw) Layout {
    var layout: Layout = .{};
    for (parts) |part| {
        if (!std.mem.eql(u8, part.type, "part")) continue;
        const fs = part.fstype orelse "";
        if (layout.esp == null and std.mem.eql(u8, fs, "vfat")) layout.esp = part.path;
        if (layout.root == null and (std.mem.eql(u8, fs, "btrfs") or std.mem.eql(u8, fs, "xfs") or std.mem.eql(u8, fs, "ext4"))) layout.root = part.path;
    }
    return layout;
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

    const layout = scanLayout(parsed.value.blockdevices);
    if (layout.esp == null) {
        diag(r.io, "no vfat ESP partition on {s}", .{disk});
        return error.InstalledLayoutMissing;
    }
    if (layout.root == null) {
        diag(r.io, "no btrfs/xfs/ext4 root partition on {s}", .{disk});
        return error.InstalledLayoutMissing;
    }

    try std.Io.Dir.cwd().createDirPath(r.io, mount_point);
    defer std.Io.Dir.cwd().deleteDir(r.io, mount_point) catch {};
    r.run(&.{ "mount", "-o", "ro", layout.esp.?, mount_point }) catch |err| {
        diag(r.io, "cannot mount ESP {s} at {s}: {s}", .{ layout.esp.?, mount_point, @errorName(err) });
        return err;
    };
    defer r.run(&.{ "umount", mount_point }) catch {};

    if (require_uki and !hasEfiFile(r.io, uki_dir)) {
        diag(r.io, "no .efi UKI in {s}", .{uki_dir});
        return error.MissingUki;
    }
    if (!hasEfiFile(r.io, loader_dir)) {
        diag(r.io, "no .efi systemd-boot loader in {s}", .{loader_dir});
        return error.MissingBootLoader;
    }
}

fn tempEspPath(allocator: std.mem.Allocator, tmp: *const std.testing.TmpDir, suffix: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/{s}", .{ &tmp.sub_path, suffix });
}

test "bootc composefs UKI is under EFI/Linux/bootc, not directly in EFI/Linux" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    try tmp.dir.createDirPath(io, "EFI/Linux/bootc");
    try tmp.dir.writeFile(io, .{ .sub_path = "EFI/Linux/bootc/4f2a.efi", .data = "signed uki" });
    try tmp.dir.createDirPath(io, "EFI/BOOT");
    try tmp.dir.writeFile(io, .{ .sub_path = "EFI/BOOT/BOOTX64.EFI", .data = "loader" });

    const efi_linux = try tempEspPath(allocator, &tmp, "EFI/Linux");
    defer allocator.free(efi_linux);
    const uki = try tempEspPath(allocator, &tmp, "EFI/Linux/bootc");
    defer allocator.free(uki);
    const loader = try tempEspPath(allocator, &tmp, "EFI/BOOT");
    defer allocator.free(loader);

    try std.testing.expect(!hasEfiFile(io, efi_linux));
    try std.testing.expect(hasEfiFile(io, uki));
    try std.testing.expect(hasEfiFile(io, loader));
}

test "an empty bootc directory still fails both EFI checks" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    try tmp.dir.createDirPath(io, "EFI/Linux/bootc");
    try tmp.dir.writeFile(io, .{ .sub_path = "EFI/Linux/bootc/notes.txt", .data = "not a UKI" });
    try tmp.dir.createDirPath(io, "EFI/BOOT");
    try tmp.dir.writeFile(io, .{ .sub_path = "EFI/BOOT/loader.conf", .data = "not a loader" });

    const uki = try tempEspPath(allocator, &tmp, "EFI/Linux/bootc");
    defer allocator.free(uki);
    const loader = try tempEspPath(allocator, &tmp, "EFI/BOOT");
    defer allocator.free(loader);

    try std.testing.expect(!hasEfiFile(io, uki));
    try std.testing.expect(!hasEfiFile(io, loader));
}

test "installed Mjolnir disk layout classifies the vfat ESP and ext4 root" {
    const text =
        \\{"blockdevices":[
        \\{"path":"/dev/vda","type":"disk","fstype":null,"label":null},
        \\{"path":"/dev/vda1","type":"part","fstype":null,"label":null},
        \\{"path":"/dev/vda2","type":"part","fstype":"vfat","label":"EFI-SYSTEM"},
        \\{"path":"/dev/vda3","type":"part","fstype":"ext4","label":"root"}
        \\]}
    ;
    const parsed = try std.json.parseFromSlice(Lsblk, std.testing.allocator, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    const layout = scanLayout(parsed.value.blockdevices);
    try std.testing.expectEqualStrings("/dev/vda2", layout.esp.?);
    try std.testing.expectEqualStrings("/dev/vda3", layout.root.?);
}
