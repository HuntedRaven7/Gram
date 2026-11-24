const std = @import("std");

pub const Verification = struct {
    image: []const u8,
    certificate_identity: []const u8,
    oidc_issuer: []const u8,
};

pub fn argv(allocator: std.mem.Allocator, v: Verification) ![]const []const u8 {
    return allocator.dupe([]const u8, &.{
        "cosign",
        "verify",
        "--certificate-identity-regexp",
        v.certificate_identity,
        "--certificate-oidc-issuer",
        v.oidc_issuer,
        "--new-bundle-format=false",
        v.image,
    });
}

pub fn verify(allocator: std.mem.Allocator, r: anytype, v: Verification) !void {
    const args = try argv(allocator, v);
    defer allocator.free(args);
    r.run(args) catch |err| {
        if (err == error.CommandFailed) return error.SignatureVerificationFailed;
        return err;
    };
}

const FakeRunner = struct {
    fail: bool,
    saw_command: bool = false,

    fn run(self: *@This(), args: []const []const u8) !void {
        self.saw_command = std.mem.eql(u8, args[0], "cosign") and
            std.mem.eql(u8, args[1], "verify") and
            std.mem.eql(u8, args[2], "--certificate-identity-regexp") and
            std.mem.eql(u8, args[3], "https://github.com/HuntedRaven7/Mjolnir/.github/workflows/build.yml@refs/heads/testing") and
            std.mem.eql(u8, args[4], "--certificate-oidc-issuer") and
            std.mem.eql(u8, args[5], "https://token.actions.githubusercontent.com") and
            std.mem.eql(u8, args[6], "--new-bundle-format=false") and
            std.mem.eql(u8, args[7], "ghcr.io/huntedraven7/mjolnir:testing");
        if (self.fail) return error.CommandFailed;
    }
};

fn fixture() Verification {
    return .{
        .image = "ghcr.io/huntedraven7/mjolnir:testing",
        .certificate_identity = "https://github.com/HuntedRaven7/Mjolnir/.github/workflows/build.yml@refs/heads/testing",
        .oidc_issuer = "https://token.actions.githubusercontent.com",
    };
}

test "missing signature stops verification with an error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var r = FakeRunner{ .fail = true };
    try std.testing.expectError(error.SignatureVerificationFailed, verify(arena.allocator(), &r, fixture()));
    try std.testing.expect(r.saw_command);
}

test "matching signature passes verification" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var r = FakeRunner{ .fail = false };
    try verify(arena.allocator(), &r, fixture());
    try std.testing.expect(r.saw_command);
}
