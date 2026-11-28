const std = @import("std");

pub const Id = enum {
    mjolnir,
    muramasa,
};

/// bootc --block-setup mode for the target root. Mjolnir stays at .none: its
/// image enrolls the encrypted state key on first boot from the signed UKI, so
/// Gram must not install a root LUKS that would bind to a stale PCR policy.
pub const BlockSetup = enum {
    none,
    tpm2_luks,

    pub fn argument(self: BlockSetup) ?[]const u8 {
        return switch (self) {
            .none => null,
            .tpm2_luks => "tpm2-luks",
        };
    }
};

pub const Profile = struct {
    id: Id,
    label: []const u8,
    image: []const u8,
    certificate_identity: []const u8,
    oidc_issuer: []const u8,
    filesystem: []const u8 = "btrfs",
    bootloader: []const u8 = "systemd",
    min_disk_bytes: u64 = 20 * 1000 * 1000 * 1000,
    require_uki: bool = true,
    state_label: ?[]const u8 = null,
    kargs: []const []const u8 = &.{},
    block_setup: BlockSetup = .none,
    accepts_identity: bool = true,
};

pub fn get(id: Id) Profile {
    return switch (id) {
        .mjolnir => .{
            .id = .mjolnir,
            .label = "Mjolnir server",
            .image = "ghcr.io/huntedraven7/mjolnir:testing",
            .certificate_identity = "^https://github\\.com/HuntedRaven7/Mjolnir/\\.github/workflows/build\\.yml@refs/heads/(testing|gh-readonly-queue/testing/.+)$",
            .oidc_issuer = "https://token.actions.githubusercontent.com",
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
            .certificate_identity = "^https://github\\.com/HuntedRaven7/Muramasa/\\.github/workflows/build\\.yml@refs/heads/(testing|gh-readonly-queue/testing/.+)$",
            .oidc_issuer = "https://token.actions.githubusercontent.com",
            .state_label = null,
            .kargs = &.{"quiet"},
            .block_setup = .tpm2_luks,
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

test "block setup is owned by the profile" {
    try std.testing.expectEqual(BlockSetup.none, get(.mjolnir).block_setup);
    try std.testing.expectEqual(BlockSetup.tpm2_luks, get(.muramasa).block_setup);
    try std.testing.expect(get(.mjolnir).block_setup.argument() == null);
    try std.testing.expectEqualStrings("tpm2-luks", get(.muramasa).block_setup.argument().?);
}
