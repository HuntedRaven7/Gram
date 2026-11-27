const std = @import("std");
const runner_mod = @import("runner.zig");

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

const mount_point = "/mnt/gram-verify-esp";
// The composefs backend keeps UKIs one level below EFI/Linux so systemd-boot
// shows only the BLS entries in its menu. Gram must check that directory, not
// the parent, which holds only the `bootc` subdirectory.
const uki_dir = mount_point ++ "/EFI/Linux/bootc";
const loader_dir = mount_point ++ "/EFI/BOOT";
const composefs_karg = "composefs=";
const mismatch_prefix = "composefs digest mismatch: embedded=";
const uki_cmdline_prefix = "gram-verify: uki-cmdline=";
const max_cmdline_bytes = 16 * 1024;

fn report(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    std.debug.print("{s}", .{line});
    const console = std.Io.Dir.openFileAbsolute(io, "/dev/console", .{ .mode = .write_only }) catch return;
    defer console.close(io);
    console.writeStreamingAll(io, line) catch return;
}

fn diag(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    report(io, "verify: " ++ fmt, args);
}

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
    diag(r.io, "composefs digest mismatch: embedded={s} computed={s}", .{ embedded, computed });
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
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return false;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch return false) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.endsWith(u8, entry.name, ".efi") or std.mem.endsWith(u8, entry.name, ".EFI")) return true;
    }
    return false;
}

fn firstEfiName(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !?[]u8 {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return null;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch return null) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.endsWith(u8, entry.name, ".efi") or std.mem.endsWith(u8, entry.name, ".EFI")) {
            return try allocator.dupe(u8, entry.name);
        }
    }
    return null;
}

const PeSection = struct {
    offset: u32,
    size: u32,
};

/// Look up the .cmdline section in a PE section table. `table` starts at the
/// first 40-byte section header, after the PE signature and COFF header.
fn findCmdlineSection(table: []const u8, count: u16) ?PeSection {
    if (table.len < @as(usize, count) * 40) return null;
    for (0..count) |i| {
        const entry = table[i * 40 ..][0..40];
        if (!std.mem.eql(u8, entry[0..8], ".cmdline")) continue;
        return .{
            .offset = std.mem.readInt(u32, entry[20..24], .little),
            .size = std.mem.readInt(u32, entry[16..20], .little),
        };
    }
    return null;
}

/// Read the plain-text .cmdline section of a signed UKI. Only the PE headers
/// and that one section are read; the rest of the UKI is left untouched.
fn readUkiCmdline(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    var dos: [64]u8 = undefined;
    if (try file.readPositionalAll(io, &dos, 0) != dos.len) return error.InvalidUki;
    if (dos[0] != 'M' or dos[1] != 'Z') return error.InvalidUki;
    const pe_at = std.mem.readInt(u32, dos[0x3c..][0..4], .little);

    var pe: [24]u8 = undefined;
    if (try file.readPositionalAll(io, &pe, pe_at) != pe.len) return error.InvalidUki;
    if (!std.mem.eql(u8, pe[0..4], "PE\x00\x00")) return error.InvalidUki;
    const count = std.mem.readInt(u16, pe[6..8], .little);
    if (count == 0 or count > 96) return error.InvalidUki;

    const table_len = @as(usize, count) * 40;
    const table = try allocator.alloc(u8, table_len);
    defer allocator.free(table);
    if (try file.readPositionalAll(io, table, @as(u64, pe_at) + 24) != table_len) return error.InvalidUki;
    const section = findCmdlineSection(table, count) orelse return error.MissingUkiCmdline;
    if (section.size == 0 or section.size > max_cmdline_bytes) return error.InvalidUki;

    const raw = try allocator.alloc(u8, section.size);
    defer allocator.free(raw);
    if (try file.readPositionalAll(io, raw, section.offset) != raw.len) return error.InvalidUki;
    const end = std.mem.indexOfScalar(u8, raw, 0) orelse raw.len;
    const text = std.mem.trim(u8, raw[0..end], " \t\r\n");
    if (text.len == 0) return error.MissingUkiCmdline;
    return allocator.dupe(u8, text);
}

const Layout = struct {
    esp: ?[]const u8 = null,
    root: ?[]const u8 = null,
};

fn collectParts(allocator: std.mem.Allocator, raw: Raw, list: *std.ArrayListUnmanaged(Raw)) !void {
    if (std.mem.eql(u8, raw.type, "part")) try list.append(allocator, raw);
    for (raw.children) |child| try collectParts(allocator, child, list);
}

// lsblk prints partitions as direct entries on some util-linux versions and as
// children of the disk on others. Both shapes must describe the installed disk.
fn onDisk(path: []const u8, disk: []const u8) bool {
    if (!std.mem.startsWith(u8, path, disk)) return false;
    if (path.len == disk.len) return false;
    const next = path[disk.len];
    return std.ascii.isDigit(next) or next == 'p';
}

fn scanLayout(parts: []const Raw, disk: []const u8) Layout {
    var layout: Layout = .{};
    for (parts) |part| {
        if (!std.mem.eql(u8, part.type, "part")) continue;
        if (!onDisk(part.path, disk)) continue;
        const fs = part.fstype orelse "";
        if (layout.esp == null and std.mem.eql(u8, fs, "vfat")) layout.esp = part.path;
        if (layout.root == null and (std.mem.eql(u8, fs, "btrfs") or std.mem.eql(u8, fs, "xfs") or std.mem.eql(u8, fs, "ext4"))) layout.root = part.path;
    }
    return layout;
}

fn shown(value: ?[]const u8) []const u8 {
    return value orelse "none";
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
    diag(r.io, "entry disk={s} require_uki={}", .{ disk, require_uki });
    // Query all block devices, as execute.findState does. Passing a device to
    // lsblk can yield no rows after bootc unmounts the target filesystems.
    const text = r.output(&.{ "lsblk", "-J", "-o", "PATH,TYPE,FSTYPE,LABEL" }) catch |err| {
        diag(r.io, "lsblk failed: {s}", .{@errorName(err)});
        return err;
    };
    defer allocator.free(text);
    diag(r.io, "lsblk bytes={d}", .{text.len});
    if (text.len == 0) {
        diag(r.io, "lsblk returned no data", .{});
        return error.InstalledLayoutMissing;
    }
    const parsed = std.json.parseFromSlice(Lsblk, allocator, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |err| {
        diag(r.io, "lsblk JSON parse failed: {s}", .{@errorName(err)});
        return err;
    };
    defer parsed.deinit();

    var parts: std.ArrayListUnmanaged(Raw) = .empty;
    defer parts.deinit(allocator);
    for (parsed.value.blockdevices) |raw| try collectParts(allocator, raw, &parts);
    diag(r.io, "parsed devices={d} partitions={d}", .{ parsed.value.blockdevices.len, parts.items.len });

    const layout = scanLayout(parts.items, disk);
    diag(r.io, "layout esp={s} root={s}", .{ shown(layout.esp), shown(layout.root) });
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

    if (require_uki) {
        const uki_name = (try firstEfiName(allocator, r.io, uki_dir)) orelse return error.MissingUki;
        defer allocator.free(uki_name);
        const uki_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ uki_dir, uki_name });
        defer allocator.free(uki_path);
        const cmdline = readUkiCmdline(allocator, r.io, uki_path) catch |err| {
            diag(r.io, "cannot read signed UKI cmdline: {s}", .{@errorName(err)});
            return err;
        };
        defer allocator.free(cmdline);
        // A stable prefix lets the CI install log prove which cmdline the
        // installer accepted from the signed UKI before the target reboots.
        report(r.io, uki_cmdline_prefix ++ "{s}", .{cmdline});
        if (composefs) |digests| try verifyComposefs(r, digests);
    }
    diag(r.io, "checks passed", .{});
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
    const layout = scanLayout(parsed.value.blockdevices, "/dev/vda");
    try std.testing.expectEqualStrings("/dev/vda2", layout.esp.?);
    try std.testing.expectEqualStrings("/dev/vda3", layout.root.?);
}

test "nested lsblk children are found and scoped to the selected disk" {
    const text =
        \\{"blockdevices":[
        \\{"path":"/dev/vda","type":"disk","fstype":null,"label":null,"children":[
        \\{"path":"/dev/vda1","type":"part","fstype":null,"label":null},
        \\{"path":"/dev/vda2","type":"part","fstype":"vfat","label":"EFI-SYSTEM"},
        \\{"path":"/dev/vda3","type":"part","fstype":"ext4","label":"root"}
        \\]},
        \\{"path":"/dev/vdb","type":"disk","fstype":null,"label":null,"children":[
        \\{"path":"/dev/vdb1","type":"part","fstype":"vfat","label":"SCRATCH-ESP"}
        \\]}
        \\]}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const parsed = try std.json.parseFromSlice(Lsblk, allocator, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    var parts: std.ArrayListUnmanaged(Raw) = .empty;
    defer parts.deinit(allocator);
    for (parsed.value.blockdevices) |raw| try collectParts(allocator, raw, &parts);
    try std.testing.expectEqual(@as(usize, 4), parts.items.len);
    const layout = scanLayout(parts.items, "/dev/vda");
    try std.testing.expectEqualStrings("/dev/vda2", layout.esp.?);
    try std.testing.expectEqualStrings("/dev/vda3", layout.root.?);
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

test "PE section lookup matches .cmdline exactly and uses raw offsets" {
    var table: [40]u8 = [_]u8{0} ** 40;
    @memcpy(table[0..8], ".cmdlinX");
    std.mem.writeInt(u32, table[16..20], 0x80, .little);
    std.mem.writeInt(u32, table[20..24], 0x1000, .little);
    try std.testing.expect(findCmdlineSection(&table, 1) == null);

    @memcpy(table[0..8], ".cmdline");
    const section = findCmdlineSection(&table, 1).?;
    try std.testing.expectEqual(@as(u32, 0x1000), section.offset);
    try std.testing.expectEqual(@as(u32, 0x80), section.size);
}

test "signed UKI cmdline comes from the PE .cmdline section" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    var image: [0x1020]u8 = [_]u8{0} ** 0x1020;
    image[0] = 'M';
    image[1] = 'Z';
    std.mem.writeInt(u32, image[0x3c..][0..4], 0x80, .little);
    @memcpy(image[0x80..0x84], "PE\x00\x00");
    std.mem.writeInt(u16, image[0x86..0x88], 1, .little);

    const table = image[0x98..0xc0];
    @memcpy(table[0..8], ".cmdline");
    std.mem.writeInt(u32, table[16..20], 0x20, .little);
    std.mem.writeInt(u32, table[20..24], 0x1000, .little);

    const cmd = "console=ttyS0 composefs=abc123";
    @memcpy(image[0x1000 .. 0x1000 + cmd.len], cmd);
    image[0x1000 + cmd.len] = 0;

    try tmp.dir.writeFile(io, .{ .sub_path = "uki.efi", .data = &image });
    const path = try tempEspPath(allocator, &tmp, "uki.efi");
    defer allocator.free(path);

    const cmdline = try readUkiCmdline(allocator, io, path);
    defer allocator.free(cmdline);
    try std.testing.expectEqualStrings(cmd, cmdline);
    try std.testing.expectEqualStrings("abc123", parseComposefsDigest(cmdline).?);
}
