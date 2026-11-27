const std = @import("std");
const config_mod = @import("config.zig");
const runner_mod = @import("runner.zig");

pub const Role = enum { control_plane, worker };

pub const Kind = enum {
    role,
    join_token,
    ca_cert_hash,
    control_plane_endpoint,
    varlink_trust,
    fleet_kubeconfig,
};

pub const Requirement = enum {
    always,
    worker_only,
    optional,
};

pub const Entry = struct {
    name: []const u8,
    kind: Kind,
    requirement: Requirement,
};

/// Source of truth for the six Mjolnir provisioning credentials. The order
/// matters: role is first so the worker-only requirement is known before the
/// join credentials are considered. Only the Mjolnir profile reads this table.
pub const registry = [_]Entry{
    .{ .name = "role", .kind = .role, .requirement = .always },
    .{ .name = "join-token", .kind = .join_token, .requirement = .worker_only },
    .{ .name = "ca-cert-hash", .kind = .ca_cert_hash, .requirement = .worker_only },
    .{ .name = "control-plane-endpoint", .kind = .control_plane_endpoint, .requirement = .worker_only },
    .{ .name = "varlink-httpd.tls.trust", .kind = .varlink_trust, .requirement = .optional },
    .{ .name = "fleet-kubeconfig", .kind = .fleet_kubeconfig, .requirement = .optional },
};

pub const Check = struct {
    ok: bool,
    warning: ?[]const u8 = null,
};

fn lowerAlnum(ch: u8) bool {
    return (ch >= 'a' and ch <= 'z') or (ch >= '0' and ch <= '9');
}

fn hex(ch: u8) bool {
    return (ch >= '0' and ch <= '9') or (ch >= 'a' and ch <= 'f') or (ch >= 'A' and ch <= 'F');
}

pub fn parseRole(value: []const u8) ?Role {
    if (std.mem.eql(u8, value, "control-plane")) return .control_plane;
    if (std.mem.eql(u8, value, "worker")) return .worker;
    return null;
}

/// kubeadm bootstrap token format: six lowercase alphanumerics, a dot, then
/// sixteen lowercase alphanumerics.
pub fn validJoinToken(value: []const u8) bool {
    if (value.len != 23 or value[6] != '.') return false;
    for (value, 0..) |ch, i| {
        if (i == 6) continue;
        if (!lowerAlnum(ch)) return false;
    }
    return true;
}

fn checkCaCertHash(value: []const u8) Check {
    const prefix = "sha256:";
    if (!std.mem.startsWith(u8, value, prefix)) return .{ .ok = false };
    const digest = value[prefix.len..];
    if (digest.len < 32) return .{ .ok = false };
    for (digest) |ch| if (!hex(ch)) return .{ .ok = false };
    if (digest.len < 64) return .{ .ok = true, .warning = "shorter than the 64 hex characters kubeadm prints" };
    return .{ .ok = true };
}

fn validEndpoint(value: []const u8) bool {
    const colon = std.mem.lastIndexOfScalar(u8, value, ':') orelse return false;
    if (colon == 0 or colon + 1 >= value.len) return false;
    for (value[0..colon]) |ch| {
        if (ch == ':' or std.ascii.isWhitespace(ch)) return false;
    }
    const port_text = value[colon + 1 ..];
    if (port_text.len < 1 or port_text.len > 5) return false;
    var port: u32 = 0;
    for (port_text) |ch| {
        if (ch < '0' or ch > '9') return false;
        port = port * 10 + (ch - '0');
    }
    return port >= 1 and port <= 65535;
}

fn hasCertPair(value: []const u8) bool {
    return std.mem.indexOf(u8, value, "-----BEGIN CERTIFICATE-----") != null and
        std.mem.indexOf(u8, value, "-----END CERTIFICATE-----") != null;
}

fn validKubeconfig(value: []const u8) bool {
    if (value.len > 1048576) return false;
    const keys = [_][]const u8{ "apiVersion:", "kind: Config", "clusters:", "contexts:", "users:" };
    for (keys) |key| if (std.mem.indexOf(u8, value, key) == null) return false;
    return true;
}

pub fn check(kind: Kind, value: []const u8) Check {
    return switch (kind) {
        .role => .{ .ok = parseRole(value) != null },
        .join_token => .{ .ok = validJoinToken(value) },
        .ca_cert_hash => checkCaCertHash(value),
        .control_plane_endpoint => .{ .ok = validEndpoint(value) },
        .varlink_trust => .{ .ok = value.len <= 65536 and hasCertPair(value) },
        .fleet_kubeconfig => .{ .ok = validKubeconfig(value) },
    };
}

// Zig errors carry no payload. Record the offending name here so the top-level
// handler can name it without ever handling the value.
var failure_name: []const u8 = "";

fn fail(name: []const u8, err: anyerror) anyerror {
    failure_name = name;
    return err;
}

pub fn errorMessage(allocator: std.mem.Allocator, err: anyerror) ?[]const u8 {
    return switch (err) {
        error.MissingCredential => std.fmt.allocPrint(
            allocator,
            "mjolnir credential {s} is required but was not found",
            .{failure_name},
        ) catch null,
        error.InvalidCredential => std.fmt.allocPrint(
            allocator,
            "mjolnir credential {s} is invalid",
            .{failure_name},
        ) catch null,
        else => null,
    };
}

fn warn(r: *runner_mod.Runner, allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    try r.record(try std.fmt.allocPrint(allocator, "warning: " ++ fmt ++ "\n", args));
}

/// Read the allowlisted names from the existing credential sources only. Pass
/// an empty explicit value so nothing can come from JSON config or CLI flags.
/// Required failures abort a real install before the plan is built; a dry run
/// records a warning and stages nothing. Optional failures always warn.
pub fn ingest(
    allocator: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    r: *runner_mod.Runner,
) !config_mod.StagedCredentials {
    var values: std.ArrayListUnmanaged(config_mod.CredentialValue) = .empty;
    errdefer values.deinit(allocator);
    var role: Role = .control_plane;

    for (registry) |entry| {
        const value = try config_mod.secret(allocator, io, env, "", entry.name);
        const needed = switch (entry.requirement) {
            .always => true,
            .worker_only => role == .worker,
            .optional => false,
        };

        if (value.len == 0) {
            if (needed and !r.dry_run) return fail(entry.name, error.MissingCredential);
            if (needed) {
                try warn(r, allocator, "mjolnir credential {s} not found, not staged", .{entry.name});
            } else if (entry.requirement == .optional) {
                try warn(r, allocator, "optional mjolnir credential {s} not found, not staged", .{entry.name});
            }
            continue;
        }

        const result = check(entry.kind, value);
        if (!result.ok) {
            if (needed and !r.dry_run) return fail(entry.name, error.InvalidCredential);
            if (needed) {
                try warn(r, allocator, "mjolnir credential {s} is invalid, not staged", .{entry.name});
            } else if (entry.requirement == .optional) {
                try warn(r, allocator, "optional mjolnir credential {s} is invalid, not staged", .{entry.name});
            } else {
                try warn(r, allocator, "mjolnir credential {s} is invalid for this role, not staged", .{entry.name});
            }
            continue;
        }
        if (result.warning) |text| {
            try warn(r, allocator, "mjolnir credential {s}: {s}", .{ entry.name, text });
        }
        if (entry.kind == .role) role = parseRole(value).?;
        try values.append(allocator, .{ .name = entry.name, .value = value });
    }

    return .{ .values = try values.toOwnedSlice(allocator) };
}

test "role and join token validation" {
    try std.testing.expectEqual(Role.control_plane, parseRole("control-plane").?);
    try std.testing.expectEqual(Role.worker, parseRole("worker").?);
    try std.testing.expect(parseRole("admin") == null);
    try std.testing.expect(validJoinToken("abcdef.0123456789abcdef"));
    try std.testing.expect(!validJoinToken("ABCDEF.0123456789abcdef"));
    try std.testing.expect(!validJoinToken("abcdef.0123456789abcde"));
    try std.testing.expect(!validJoinToken("abcdef-0123456789abcdef"));
}

test "remaining credentials validate at their documented bounds" {
    const hash = "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    try std.testing.expect(check(.ca_cert_hash, hash).ok);
    try std.testing.expect(check(.ca_cert_hash, "sha256:0123456789abcdef0123456789abcdef").warning != null);
    try std.testing.expect(!check(.ca_cert_hash, "md5:0123456789abcdef0123456789abcdef").ok);
    try std.testing.expect(check(.control_plane_endpoint, "192.0.2.1:6443").ok);
    try std.testing.expect(!check(.control_plane_endpoint, "192.0.2.1:99999").ok);
    try std.testing.expect(!check(.control_plane_endpoint, "192.0.2.1").ok);
    const cert = "-----BEGIN CERTIFICATE-----\nAAAA\n-----END CERTIFICATE-----\n";
    try std.testing.expect(check(.varlink_trust, cert).ok);
    try std.testing.expect(!check(.varlink_trust, "not a certificate").ok);
    const kube = "apiVersion: v1\nkind: Config\nclusters: []\ncontexts: []\nusers: []\n";
    try std.testing.expect(check(.fleet_kubeconfig, kube).ok);
    try std.testing.expect(!check(.fleet_kubeconfig, "kind: Config\n").ok);
}
