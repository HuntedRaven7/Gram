const std = @import("std");
const config = @import("config.zig");
const credentials = @import("credentials.zig");
const plan = @import("plan.zig");
const runner = @import("runner.zig");
const execute = @import("execute.zig");
const cli = @import("cli.zig");

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

test "mjolnir rejects desktop identity fields" {
    var c = config.defaults();
    c.disk = "/dev/vda";
    c.username = "admin";
    try std.testing.expectError(error.MjolnirRejectsDesktopIdentity, config.validate(c));
    try std.testing.expectEqualStrings("mjolnir profile rejects username, passwordHash and sshKeys", config.errorMessage(error.MjolnirRejectsDesktopIdentity).?);

    c.username = "";
    c.password_hash = "$6$salt$hash";
    try std.testing.expectError(error.MjolnirRejectsDesktopIdentity, config.validate(c));

    c.password_hash = "";
    c.ssh_keys = &.{"ssh-ed25519 AAAA"};
    try std.testing.expectError(error.MjolnirRejectsDesktopIdentity, config.validate(c));

    config.applyProfile(&c, .muramasa);
    try config.validate(c);
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

test "DNS check waits for the network and retries a failing lookup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var r = runner.Runner.init(allocator, std.testing.io, false);
    defer r.deinit();

    const Probe = struct {
        network_calls: usize = 0,
        resolve_calls: usize = 0,
        network_ready: bool = false,
        premature: bool = false,

        pub fn networkUp(self: *@This(), _: std.mem.Allocator, _: std.Io) bool {
            self.network_calls += 1;
            if (self.network_calls == 3) self.network_ready = true;
            return self.network_ready;
        }

        pub fn resolve(self: *@This(), _: std.mem.Allocator, _: std.Io, _: []const u8, _: std.Io.Duration) bool {
            if (!self.network_ready) self.premature = true;
            self.resolve_calls += 1;
            return self.resolve_calls == 3;
        }
    };
    var probe: Probe = .{};
    try cli.checkDnsWith(Probe, allocator, std.testing.io, &r, quiet, "ghcr.io", &probe, std.Io.Duration.fromSeconds(5), .zero);

    try std.testing.expect(!probe.premature);
    try std.testing.expectEqual(@as(usize, 3), probe.resolve_calls);
    try std.testing.expect(std.mem.indexOf(u8, r.log.items, "waiting for network before DNS check for ghcr.io") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.log.items, "DNS ok for ghcr.io") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.log.items, "DNS failed for ghcr.io") == null);
}

test "unreachable registry still fails with its host after retries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var r = runner.Runner.init(allocator, std.testing.io, false);
    defer r.deinit();

    const Probe = struct {
        pub fn networkUp(_: *@This(), _: std.mem.Allocator, _: std.Io) bool {
            return true;
        }

        pub fn resolve(_: *@This(), _: std.mem.Allocator, _: std.Io, _: []const u8, _: std.Io.Duration) bool {
            return false;
        }
    };
    var probe: Probe = .{};
    const err = cli.checkDnsWith(Probe, allocator, std.testing.io, &r, quiet, "bad.example", &probe, std.Io.Duration.fromMicroseconds(100), .zero);

    try std.testing.expectError(error.DnsResolutionFailed, err);
    try std.testing.expect(std.mem.indexOf(u8, r.log.items, "DNS failed for bad.example") != null);
}

const CredFile = struct { name: []const u8, value: []const u8 };

const CredFixture = struct {
    tmp: std.testing.TmpDir,
    env: std.process.Environ.Map,

    fn deinit(self: *CredFixture) void {
        self.env.deinit();
        self.tmp.cleanup();
    }
};

fn credFixture(allocator: std.mem.Allocator, files: []const CredFile) !CredFixture {
    const tmp = std.testing.tmpDir(.{});
    const base = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    for (files) |f| {
        const path = try std.fs.path.join(allocator, &.{ base, f.name });
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = f.value });
    }
    var env = std.process.Environ.Map.init(allocator);
    try env.put("CREDENTIALS_DIRECTORY", base);
    return .{ .tmp = tmp, .env = env };
}

const valid_hash = "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
const valid_cert = "-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----\n";
const valid_kube = "apiVersion: v1\nkind: Config\nclusters: []\ncontexts: []\nusers: []\n";

fn allCredentials() []const CredFile {
    return &.{
        .{ .name = "role", .value = "worker" },
        .{ .name = "join-token", .value = "abcdef.0123456789abcdef" },
        .{ .name = "ca-cert-hash", .value = valid_hash },
        .{ .name = "control-plane-endpoint", .value = "192.0.2.1:6443" },
        .{ .name = "varlink-httpd.tls.trust", .value = valid_cert },
        .{ .name = "fleet-kubeconfig", .value = valid_kube },
    };
}

test "credential ingestion stages all six names without logging values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var f = try credFixture(allocator, allCredentials());
    defer f.deinit();

    var r = runner.Runner.init(allocator, std.testing.io, false);
    defer r.deinit();
    const staged = try credentials.ingest(allocator, std.testing.io, &f.env, &r);

    try std.testing.expectEqual(@as(usize, 6), staged.values.len);
    try std.testing.expectEqualStrings("role", staged.values[0].name);
    try std.testing.expectEqualStrings("fleet-kubeconfig", staged.values[5].name);
    try std.testing.expectEqualStrings("abcdef.0123456789abcdef", staged.values[1].value);
    try std.testing.expect(std.mem.indexOf(u8, r.log.items, "abcdef.0123456789abcdef") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.log.items, "warning:") == null);
}

test "invalid supplied credential fails with its name and never its value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const bad = "NOT-A-VALID-TOKEN-VALUE";
    var f = try credFixture(allocator, &.{
        .{ .name = "role", .value = "worker" },
        .{ .name = "join-token", .value = bad },
    });
    defer f.deinit();

    var r = runner.Runner.init(allocator, std.testing.io, false);
    defer r.deinit();
    const result = credentials.ingest(allocator, std.testing.io, &f.env, &r);
    try std.testing.expectError(error.InvalidCredential, result);
    const message = credentials.errorMessage(allocator, error.InvalidCredential).?;
    try std.testing.expect(std.mem.indexOf(u8, message, "join-token") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, bad) == null);
    try std.testing.expect(std.mem.indexOf(u8, r.log.items, bad) == null);
}

test "missing credentials warn and continue without staging" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var f = try credFixture(allocator, &.{});
    defer f.deinit();

    var r = runner.Runner.init(allocator, std.testing.io, false);
    defer r.deinit();
    const staged = try credentials.ingest(allocator, std.testing.io, &f.env, &r);

    try std.testing.expectEqual(@as(usize, 0), staged.values.len);
    const names = [_][]const u8{ "role", "join-token", "ca-cert-hash", "control-plane-endpoint", "varlink-httpd.tls.trust", "fleet-kubeconfig" };
    for (names) |name| {
        const expected = try std.fmt.allocPrint(allocator, "warning: mjolnir credential {s} not found, not staged", .{name});
        try std.testing.expect(std.mem.indexOf(u8, r.log.items, expected) != null);
    }
}

test "missing management credentials warn and are skipped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var f = try credFixture(allocator, &.{
        .{ .name = "role", .value = "control-plane" },
    });
    defer f.deinit();

    var r = runner.Runner.init(allocator, std.testing.io, false);
    defer r.deinit();
    const staged = try credentials.ingest(allocator, std.testing.io, &f.env, &r);

    try std.testing.expectEqual(@as(usize, 1), staged.values.len);
    try std.testing.expect(std.mem.indexOf(u8, r.log.items, "warning: mjolnir credential varlink-httpd.tls.trust not found, not staged") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.log.items, "warning: mjolnir credential fleet-kubeconfig not found, not staged") != null);
}

test "invalid supplied management credential fails with its name and never its value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const bad_cert = "not-a-certificate-value";
    var f = try credFixture(allocator, &.{
        .{ .name = "role", .value = "control-plane" },
        .{ .name = "varlink-httpd.tls.trust", .value = bad_cert },
    });
    defer f.deinit();

    var r = runner.Runner.init(allocator, std.testing.io, false);
    defer r.deinit();
    const result = credentials.ingest(allocator, std.testing.io, &f.env, &r);
    try std.testing.expectError(error.InvalidCredential, result);
    const message = credentials.errorMessage(allocator, error.InvalidCredential).?;
    try std.testing.expect(std.mem.indexOf(u8, message, "varlink-httpd.tls.trust") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, bad_cert) == null);
    try std.testing.expect(std.mem.indexOf(u8, r.log.items, bad_cert) == null);
}

test "dry run rejects invalid supplied credentials" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const bad = "bad-token-value";
    var f = try credFixture(allocator, &.{
        .{ .name = "role", .value = "worker" },
        .{ .name = "join-token", .value = bad },
    });
    defer f.deinit();

    var r = runner.Runner.init(allocator, std.testing.io, true);
    defer r.deinit();
    const result = credentials.ingest(allocator, std.testing.io, &f.env, &r);

    try std.testing.expectError(error.InvalidCredential, result);
    const message = credentials.errorMessage(allocator, error.InvalidCredential).?;
    try std.testing.expect(std.mem.indexOf(u8, message, "join-token") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, bad) == null);
    try std.testing.expect(std.mem.indexOf(u8, r.log.items, bad) == null);
}

test "dry run stages supplied credentials when the rest are missing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const token = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ "abcdef", "0123456789abcdef" });
    var f = try credFixture(allocator, &.{
        .{ .name = "role", .value = "worker" },
        .{ .name = "join-token", .value = token },
    });
    defer f.deinit();

    var r = runner.Runner.init(allocator, std.testing.io, true);
    defer r.deinit();
    const staged = try credentials.ingest(allocator, std.testing.io, &f.env, &r);

    try std.testing.expectEqual(@as(usize, 2), staged.values.len);
    try std.testing.expect(std.mem.indexOf(u8, r.log.items, "warning: mjolnir credential ca-cert-hash not found, not staged") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.log.items, token) == null);
}

test "credential plan action stages names in log and keeps values out of argv and log" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const token = "JOINTOKEN-MUST-NOT-APPEAR";
    const id = "00000000-0000-4000-8000-000000000000";

    var c = config.defaults();
    c.disk = "/dev/vda";
    c.staged_credentials = .{ .values = &.{
        .{ .name = "role", .value = "worker" },
        .{ .name = "join-token", .value = token },
    } };

    const p = try plan.build(allocator, c, id);
    var found = false;
    for (p.actions) |action| switch (action) {
        .command => |cmd| for (cmd.argv) |arg| {
            try std.testing.expect(std.mem.indexOf(u8, arg, token) == null);
        },
        .persist_credentials => |pc| {
            found = true;
            try std.testing.expectEqual(@as(usize, 2), pc.values.len);
            try std.testing.expectEqualStrings("MjolnirState", pc.state_label.?);
        },
        else => {},
    };
    try std.testing.expect(found);

    var r = runner.Runner.init(allocator, std.testing.io, true);
    defer r.deinit();
    try execute.execute(allocator, &r, p.actions, quiet);
    try std.testing.expect(std.mem.indexOf(u8, r.log.items, "persist Mjolnir credentials in target state partition") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.log.items, "mjolnir credential: role") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.log.items, "mjolnir credential: join-token") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.log.items, token) == null);
}

test "Muramasa never reads or stages Mjolnir credentials" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var f = try credFixture(allocator, allCredentials());
    defer f.deinit();
    const io = std.testing.io;

    var muramasa_run = runner.Runner.init(allocator, io, true);
    defer muramasa_run.deinit();
    const muramasa = try cli.prepare(allocator, io, &f.env, .{ .profile = "muramasa", .dry_run = true }, &muramasa_run);
    try std.testing.expectEqual(@as(usize, 0), muramasa.config.staged_credentials.values.len);
    const muramasa_plan = try plan.build(allocator, muramasa.config, "00000000-0000-4000-8000-000000000000");
    for (muramasa_plan.actions) |action| switch (action) {
        .persist_credentials => return error.TestUnexpectedResult,
        else => {},
    };

    var mjolnir_run = runner.Runner.init(allocator, io, true);
    defer mjolnir_run.deinit();
    const mjolnir = try cli.prepare(allocator, io, &f.env, .{ .profile = "mjolnir", .dry_run = true }, &mjolnir_run);
    try std.testing.expectEqual(@as(usize, 6), mjolnir.config.staged_credentials.values.len);
    try std.testing.expect(std.mem.indexOf(u8, mjolnir_run.log.items, "abcdef.0123456789abcdef") == null);
}
