const std = @import("std");
const config = @import("config.zig");
const plan = @import("plan.zig");
const runner = @import("runner.zig");
const execute = @import("execute.zig");

fn quiet(_: []const u8) void {}

test "config JSON parser accepts arbitrary bytes" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, smith: *std.testing.Smith) !void {
            var buffer: [512]u8 = undefined;
            const len = smith.slice(&buffer);
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();
            _ = config.fromJson(arena.allocator(), buffer[0..len]) catch return;
        }
    }.one, .{});
}

test "dry-run plan never contains secrets" {
    const psk = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    const token = "registry-token-must-not-appear";
    const hash = "$6$rounds=10000$salt$hash-must-not-appear";

    var c = config.defaults();
    c.disk = "/dev/vda";
    c.ssid = "testnet";
    c.psk = psk;
    c.registry_user = "bot";
    c.registry_token = token;
    c.password_hash = hash;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const p = try plan.build(allocator, c, "00000000-0000-4000-8000-000000000000");
    var r = runner.Runner.init(allocator, std.testing.io, true);
    defer r.deinit();
    try execute.execute(allocator, &r, p.actions, quiet);

    for ([_][]const u8{ psk, token, hash }) |secret| {
        try std.testing.expect(std.mem.indexOf(u8, r.log.items, secret) == null);
    }
    try std.testing.expect(std.mem.indexOf(u8, r.log.items, "stdin: credential") != null);
}

test "Mjolnir dry-run has no kargs and persists the machine ID; Muramasa keeps its kargs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const id = "00000000-0000-4000-8000-000000000000";

    var c = config.defaults();
    c.disk = "/dev/vda";

    const mjolnir = try plan.build(allocator, c, id);
    var mjolnir_run = runner.Runner.init(allocator, std.testing.io, true);
    defer mjolnir_run.deinit();
    try execute.execute(allocator, &mjolnir_run, mjolnir.actions, quiet);
    try std.testing.expect(std.mem.indexOf(u8, mjolnir_run.log.items, "--karg") == null);
    try std.testing.expect(std.mem.indexOf(u8, mjolnir_run.log.items, "persist machine ID in target state partition") != null);

    config.applyProfile(&c, .muramasa);
    const muramasa = try plan.build(allocator, c, id);
    var muramasa_run = runner.Runner.init(allocator, std.testing.io, true);
    defer muramasa_run.deinit();
    try execute.execute(allocator, &muramasa_run, muramasa.actions, quiet);
    try std.testing.expect(std.mem.indexOf(u8, muramasa_run.log.items, "--karg=quiet") != null);
    try std.testing.expect(std.mem.indexOf(u8, muramasa_run.log.items, try std.fmt.allocPrint(allocator, "--karg=systemd.machine_id={s}", .{id})) != null);
}

test "dry-run verifies each profile image signature before pulling" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const id = "00000000-0000-4000-8000-000000000000";

    var c = config.defaults();
    c.disk = "/dev/vda";

    for ([_][]const u8{ "Mjolnir", "Muramasa" }, 0..) |repo, i| {
        if (i != 0) config.applyProfile(&c, .muramasa);
        const p = try plan.build(allocator, c, id);
        var r = runner.Runner.init(allocator, std.testing.io, true);
        defer r.deinit();
        try execute.execute(allocator, &r, p.actions, quiet);

        const log = r.log.items;
        const verify_pos = std.mem.indexOf(u8, log, "[dry-run] cosign verify --certificate-identity-regexp ");
        try std.testing.expect(verify_pos != null);
        const pull_pos = std.mem.indexOf(u8, log, "podman --root /var/lib/containers/storage --runroot /var/lib/containers/runroot pull ");
        try std.testing.expect(pull_pos != null);
        try std.testing.expect(verify_pos.? < pull_pos.?);

        const end = std.mem.indexOfScalarPos(u8, log, verify_pos.?, '\n') orelse log.len;
        const line = log[verify_pos.?..end];
        try std.testing.expect(std.mem.indexOf(u8, line, repo) != null);
        try std.testing.expect(std.mem.indexOf(u8, line, "--certificate-oidc-issuer https://token.actions.githubusercontent.com") != null);
        try std.testing.expect(std.mem.indexOf(u8, line, c.image) != null);
    }
}
