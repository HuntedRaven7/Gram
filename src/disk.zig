const std = @import("std");

pub const Disk = struct {
    path: []const u8,
    size: []const u8,
    model: []const u8,
    serial: []const u8,
    tran: []const u8,
    mountpoint: []const u8,
    bytes: u64,
};

const Raw = struct {
    path: []const u8,
    size: []const u8,
    type: []const u8,
    model: ?[]const u8 = null,
    serial: ?[]const u8 = null,
    tran: ?[]const u8 = null,
    rm: ?bool = null,
    mountpoint: ?[]const u8 = null,
};

const Lsblk = struct {
    blockdevices: []Raw,
};

pub fn deinit(allocator: std.mem.Allocator, disks: []Disk) void {
    for (disks) |d| {
        allocator.free(d.path);
        allocator.free(d.size);
        allocator.free(d.model);
        allocator.free(d.serial);
        allocator.free(d.tran);
        allocator.free(d.mountpoint);
    }
    allocator.free(disks);
}

pub fn parseSize(text: []const u8) ?u64 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len < 2) return null;
    const unit = trimmed[trimmed.len - 1];
    const number = trimmed[0 .. trimmed.len - 1];
    const value = std.fmt.parseFloat(f64, number) catch return null;
    const factor: f64 = switch (unit) {
        'K', 'k' => 1e3,
        'M', 'm' => 1e6,
        'G', 'g' => 1e9,
        'T', 't' => 1e12,
        'P', 'p' => 1e15,
        else => return null,
    };
    if (value < 0) return null;
    return @intFromFloat(value * factor);
}

fn bootPath(cmdline: []const u8, path: []const u8) bool {
    var words = std.mem.tokenizeAny(u8, cmdline, " \t\r\n");
    while (words.next()) |word| {
        if (std.mem.startsWith(u8, word, "/dev/") and std.mem.eql(u8, word, path)) return true;
    }
    return false;
}

pub fn eligible(allocator: std.mem.Allocator, json_text: []const u8, cmdline: []const u8) ![]Disk {
    const parsed = try std.json.parseFromSlice(Lsblk, allocator, json_text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    var list: std.ArrayListUnmanaged(Disk) = .empty;
    errdefer list.deinit(allocator);
    for (parsed.value.blockdevices) |raw| {
        if (!std.mem.eql(u8, raw.type, "disk")) continue;
        if (raw.rm orelse false) continue;
        if (raw.mountpoint) |mount| if (mount.len != 0) continue;
        if (bootPath(cmdline, raw.path)) continue;
        const bytes = parseSize(raw.size) orelse 0;
        try list.append(allocator, .{
            .path = try allocator.dupe(u8, raw.path),
            .size = try allocator.dupe(u8, raw.size),
            .model = try allocator.dupe(u8, raw.model orelse ""),
            .serial = try allocator.dupe(u8, raw.serial orelse ""),
            .tran = try allocator.dupe(u8, raw.tran orelse ""),
            .mountpoint = try allocator.dupe(u8, raw.mountpoint orelse ""),
            .bytes = bytes,
        });
    }
    std.mem.sort(Disk, list.items, {}, struct {
        fn lessThan(_: void, a: Disk, b: Disk) bool {
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.lessThan);
    return list.toOwnedSlice(allocator);
}

test "lsblk filters removable, mounted and boot disks" {
    const text =
        \\{"blockdevices":[
        \\{"path":"/dev/vda","size":"40G","type":"disk","model":"Disk A","serial":"a","tran":"virtio","rm":false,"mountpoint":""},
        \\{"path":"/dev/sdb","size":"32G","type":"disk","model":"USB","serial":"u","tran":"usb","rm":true,"mountpoint":""},
        \\{"path":"/dev/sdc","size":"30G","type":"disk","model":"Mounted","serial":"m","tran":"sata","rm":false,"mountpoint":"/mnt"},
        \\{"path":"/dev/vdb","size":"20G","type":"disk","model":"Boot","serial":"b","tran":"virtio","rm":false,"mountpoint":""}
        \\]}
    ;
    const disks = try eligible(std.testing.allocator, text, "root=UUID=x /dev/vdb quiet");
    defer deinit(std.testing.allocator, disks);
    try std.testing.expectEqual(@as(usize, 1), disks.len);
    try std.testing.expectEqualStrings("/dev/vda", disks[0].path);
    try std.testing.expectEqual(@as(u64, 40_000_000_000), disks[0].bytes);
}

test "size parsing" {
    try std.testing.expectEqual(@as(u64, 1_500_000_000), parseSize("1.5G").?);
    try std.testing.expectEqual(@as(u64, 20_000_000_000), parseSize("20G").?);
    try std.testing.expect(parseSize("bogus") == null);
}
