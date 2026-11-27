const std = @import("std");
const zz = @import("zigzag");
const cli = @import("cli.zig");
const config_mod = @import("config.zig");
const profile_mod = @import("profile.zig");
const runner_mod = @import("runner.zig");
const execute_mod = @import("execute.zig");

const profiles = [_]profile_mod.Id{ .mjolnir, .muramasa };

var app_allocator: std.mem.Allocator = undefined;
var app_io: std.Io = undefined;
var prepared: cli.Prepared = undefined;
var app_runner: runner_mod.Runner = undefined;

const Text = struct {
    buf: [160]u8 = undefined,
    len: usize = 0,

    fn slice(self: *const Text) []const u8 {
        return self.buf[0..self.len];
    }

    fn set(self: *Text, value: []const u8) void {
        self.len = @min(value.len, self.buf.len);
        @memcpy(self.buf[0..self.len], value[0..self.len]);
    }

    fn push(self: *Text, ch: u21) void {
        if (self.len >= self.buf.len) return;
        var encoded: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(ch, &encoded) catch return;
        @memcpy(self.buf[self.len .. self.len + n], encoded[0..n]);
        self.len += n;
    }

    fn pop(self: *Text) void {
        if (self.len == 0) return;
        self.len -= 1;
        while (self.len > 0 and (self.buf[self.len] & 0xc0) == 0x80) self.len -= 1;
    }
};

const Step = enum {
    welcome,
    profile,
    image,
    network,
    identity,
    disk,
    review,
    installing,
    done,
    failed,
};

const Model = struct {
    step: Step = .welcome,
    profile_index: usize = 0,
    image: Text = .{},
    ssid: Text = .{},
    psk: Text = .{},
    registry_user: Text = .{},
    registry_token: Text = .{},
    hostname: Text = .{},
    timezone: Text = .{},
    username: Text = .{},
    confirm: Text = .{},
    disk_index: usize = 0,
    field: usize = 0,
    message: []const u8 = "",
    detail: []const u8 = "",
    pending_start: bool = false,

    pub const Msg = union(enum) {
        key: zz.KeyEvent,
        tick: zz.msg.Tick,
    };

    pub fn init(self: *Model, _: *zz.Context) zz.Cmd(Msg) {
        self.* = .{};
        self.profile_index = switch (prepared.config.profile) {
            .mjolnir => 0,
            .muramasa => 1,
        };
        self.image.set(prepared.config.image);
        self.ssid.set(prepared.config.ssid);
        self.psk.set(prepared.config.psk);
        self.registry_user.set(prepared.config.registry_user);
        self.registry_token.set(prepared.config.registry_token);
        self.hostname.set(prepared.config.hostname);
        self.timezone.set(prepared.config.timezone);
        self.username.set(prepared.config.username);
        return .none;
    }

    fn identityFields(self: *const Model) usize {
        return if (profile_mod.get(profiles[self.profile_index]).accepts_identity) 3 else 2;
    }

    fn current(self: *Model) ?*Text {
        return switch (self.step) {
            .image => &self.image,
            .network => switch (self.field) {
                0 => &self.ssid,
                1 => &self.psk,
                2 => &self.registry_user,
                3 => &self.registry_token,
                else => null,
            },
            .identity => switch (self.field) {
                0 => &self.hostname,
                1 => &self.timezone,
                2 => if (self.identityFields() == 3) &self.username else null,
                else => null,
            },
            .review => &self.confirm,
            else => null,
        };
    }

    fn nextStep(self: *Model) void {
        self.field = 0;
        self.step = switch (self.step) {
            .welcome => .profile,
            .profile => .image,
            .image => .network,
            .network => .identity,
            .identity => .disk,
            .disk => .review,
            .review => .installing,
            else => self.step,
        };
        if (self.step == .installing) self.pending_start = true;
    }

    fn previousStep(self: *Model) void {
        self.field = 0;
        self.step = switch (self.step) {
            .profile => .welcome,
            .image => .profile,
            .network => .image,
            .identity => .network,
            .disk => .identity,
            .review => .disk,
            else => self.step,
        };
    }

    fn config(self: *const Model) config_mod.Config {
        var c = prepared.config;
        config_mod.applyProfile(&c, profiles[self.profile_index]);
        if (self.image.slice().len != 0) c.image = self.image.slice();
        c.ssid = self.ssid.slice();
        c.psk = self.psk.slice();
        c.registry_user = self.registry_user.slice();
        c.registry_token = self.registry_token.slice();
        c.hostname = self.hostname.slice();
        c.timezone = self.timezone.slice();
        c.username = if (self.identityFields() == 3) self.username.slice() else "";
        if (prepared.disks.len != 0) c.disk = prepared.disks[self.disk_index].path;
        return c;
    }

    fn runInstall(self: *Model) void {
        const c = self.config();
        app_runner = runner_mod.Runner.init(app_allocator, app_io, false);
        cli.apply(app_allocator, app_io, c, &app_runner, execute_mod.printStdout) catch |err| {
            self.step = .failed;
            self.message = @errorName(err);
            self.detail = app_runner.log.items;
            return;
        };
        self.step = .done;
        self.message = "Install complete";
        self.detail = app_runner.log.items;
    }

    pub fn update(self: *Model, msg: Msg, _: *zz.Context) zz.Cmd(Msg) {
        switch (msg) {
            .tick => {
                if (self.pending_start) {
                    self.pending_start = false;
                    self.runInstall();
                }
                return .none;
            },
            .key => |event| {
                switch (event.key) {
                    .escape => return .quit,
                    .char => |ch| {
                        if (self.step == .profile) {
                            if (ch == 'l' or ch == 'L') self.profile_index = (self.profile_index + 1) % profiles.len;
                            if (ch == 'h' or ch == 'H') self.profile_index = (self.profile_index + profiles.len - 1) % profiles.len;
                        } else if (self.current()) |text| {
                            text.push(ch);
                        }
                    },
                    .backspace => if (self.current()) |text| text.pop(),
                    .tab => {
                        const count: usize = switch (self.step) {
                            .network => 4,
                            .identity => self.identityFields(),
                            else => 1,
                        };
                        self.field = (self.field + 1) % count;
                    },
                    .up => {
                        if (self.step == .disk and self.disk_index > 0) self.disk_index -= 1;
                    },
                    .down => {
                        if (self.step == .disk and self.disk_index + 1 < prepared.disks.len) self.disk_index += 1;
                    },
                    .enter => {
                        switch (self.step) {
                            .review => {
                                const expected = if (prepared.disks.len != 0) prepared.disks[self.disk_index].path else "";
                                if (std.mem.eql(u8, self.confirm.slice(), expected)) {
                                    self.nextStep();
                                    return zz.Cmd(Msg).everyMs(50);
                                }
                                self.message = "Confirmation did not match the disk path";
                            },
                            .done, .failed => return .quit,
                            else => self.nextStep(),
                        }
                    },
                    else => {},
                }
            },
        }
        return .none;
    }

    fn append(alloc: std.mem.Allocator, list: *std.ArrayListUnmanaged(u8), comptime fmt: []const u8, args: anytype) !void {
        const text = try std.fmt.allocPrint(alloc, fmt, args);
        try list.appendSlice(alloc, text);
    }

    pub fn view(self: *const Model, ctx: *const zz.Context) ![]const u8 {
        const alloc = ctx.allocator;
        var body: std.ArrayListUnmanaged(u8) = .empty;

        var title_style = zz.Style{};
        title_style = title_style.bold(true);
        title_style = title_style.fg(zz.Color.cyan);
        title_style = title_style.inline_style(true);
        const title = try title_style.render(alloc, "Gram bootc installer");
        try append(alloc, &body, "{s}\n\n", .{title});

        switch (self.step) {
            .welcome => {
                try body.appendSlice(alloc, "Install a bootc composefs image to a local disk.\n\n");
                try body.appendSlice(alloc, "Enter  continue\nEsc    quit\n");
            },
            .profile => {
                try append(alloc, &body, "Profile: {s}  ({d}/{d})\n", .{ @tagName(profiles[self.profile_index]), self.profile_index + 1, profiles.len });
                try append(alloc, &body, "Image:   {s}\n\n", .{self.image.slice()});
                try body.appendSlice(alloc, "h/l  switch profile   Enter  edit image and continue   Esc  quit\n");
            },
            .image => {
                try append(alloc, &body, "Image reference: {s}\n\n", .{self.image.slice()});
                try body.appendSlice(alloc, "Enter  continue   Esc  quit\n");
            },
            .network => {
                try append(alloc, &body, "WiFi SSID [{s}]: {s}\n", .{ if (self.field == 0) "*" else " ", self.ssid.slice() });
                try append(alloc, &body, "WPA PSK   [{s}]: {s}\n", .{ if (self.field == 1) "*" else " ", if (self.psk.slice().len == 0) "" else "<set>" });
                try append(alloc, &body, "Registry user [{s}]: {s}\n", .{ if (self.field == 2) "*" else " ", self.registry_user.slice() });
                try append(alloc, &body, "Registry token [{s}]: {s}\n\n", .{ if (self.field == 3) "*" else " ", if (self.registry_token.slice().len == 0) "" else "<set>" });
                try body.appendSlice(alloc, "Tab  next field   Enter  continue   Esc  quit\n");
            },
            .identity => {
                try append(alloc, &body, "Hostname [{s}]: {s}\n", .{ if (self.field == 0) "*" else " ", self.hostname.slice() });
                try append(alloc, &body, "Timezone [{s}]: {s}\n", .{ if (self.field == 1) "*" else " ", self.timezone.slice() });
                if (self.identityFields() == 3) {
                    try append(alloc, &body, "Username [{s}]: {s}\n", .{ if (self.field == 2) "*" else " ", self.username.slice() });
                }
                try body.appendSlice(alloc, "\nTab  next field   Enter  continue   Esc  quit\n");
            },
            .disk => {
                try body.appendSlice(alloc, "Target disk:\n");
                for (prepared.disks, 0..) |d, i| {
                    try append(alloc, &body, "  {s} {s} {s} {s}\n", .{ if (i == self.disk_index) ">" else " ", d.path, d.size, d.model });
                }
                try body.appendSlice(alloc, "\nUp/Down  select   Enter  continue   Esc  quit\n");
            },
            .review => {
                const c = self.config();
                try append(alloc, &body, "Profile: {s}\nImage:   {s}\nDisk:    {s}\nWiFi:    {s}\nEncrypt: {s}\n\n", .{
                    @tagName(profiles[self.profile_index]), c.image,                        c.disk,
                    if (c.ssid.len == 0) "no" else c.ssid,  if (c.encrypt) "yes" else "no",
                });
                try append(alloc, &body, "Type {s} to confirm erase: {s}\n", .{ c.disk, self.confirm.slice() });
                if (self.message.len != 0) try append(alloc, &body, "\n{s}\n", .{self.message});
            },
            .installing => try body.appendSlice(alloc, "Installing. The target disk will be erased.\n"),
            .done, .failed => {
                try append(alloc, &body, "{s}\n\n", .{self.message});
                const tail = if (self.detail.len > 1200) self.detail[self.detail.len - 1200 ..] else self.detail;
                try body.appendSlice(alloc, tail);
                try body.appendSlice(alloc, "\n\nEnter or Esc  quit\n");
            },
        }

        var box_style = zz.Style{};
        box_style = box_style.borderAll(zz.Border.rounded);
        box_style = box_style.borderForeground(zz.Color.cyan);
        box_style = box_style.paddingAll(1);
        const boxed = try box_style.render(alloc, body.items);
        return zz.place.place(alloc, ctx.width, ctx.height, .center, .middle, boxed);
    }
};

pub fn start(allocator: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, p: cli.Prepared) !void {
    app_allocator = allocator;
    app_io = io;
    prepared = p;
    var program = zz.Program(Model).init(allocator, io, env);
    defer program.deinit();
    try program.run();
}
