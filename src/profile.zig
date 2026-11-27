const std = @import("std");

pub const Id = enum {
    mjolnir,
    muramasa,
};

pub const Profile = struct {
    id: Id,
    label: []const u8,
    image: []const u8,
    filesystem: []const u8 = "btrfs",
    bootloader: []const u8 = "systemd",
    min_disk_bytes: u64 = 20 * 1000 * 1000 * 1000,
    require_uki: bool = true,
    state_label: ?[]const u8 = null,
    kargs: []const []const u8 = &.{},
    accepts_identity: bool = true,
};

pub fn get(id: Id) Profile {
    return switch (id) {
        .mjolnir => .{
            .id = .mjolnir,
            .label = "Mjolnir server",
            .image = "ghcr.io/huntedraven7/mjolnir:testing",
            // bootc runs mkfs inside the target image, which ships mkfs.ext4
            // but no mkfs.btrfs. bootc adds -O verity for ext4, which a strict
            // composefs UKI needs.
            .filesystem = "ext4",
            .state_label = "MjolnirState",
            .accepts_identity = false,
            .kargs = &.{
                "systemd.firstboot=no",
                "quiet",
                "systemd.volatile=yes",
                "console=ttyS0,115200",
            },
        },
        .muramasa => .{
            .id = .muramasa,
            .label = "Muramasa desktop",
            .image = "ghcr.io/huntedraven7/muramasa:testing",
            .state_label = null,
            .kargs = &.{"quiet"},
        },
    };
}

pub fn parse(text: []const u8) ?Id {
    if (std.mem.eql(u8, text, "mjolnir")) return .mjolnir;
    if (std.mem.eql(u8, text, "muramasa")) return .muramasa;
    return null;
}

test "profile defaults" {
    const m = get(.mjolnir);
    try std.testing.expectEqualStrings("ext4", m.filesystem);
    try std.testing.expect(m.require_uki);
    try std.testing.expectEqualStrings("MjolnirState", m.state_label.?);
    try std.testing.expectEqualStrings("muramasa", @tagName(get(.muramasa).id));
}
