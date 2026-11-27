const std = @import("std");

const serial_prefixes = [_][]const u8{ "ttyS", "ttyUSB", "ttyACM", "ttyAMA" };

/// The last name in /sys/class/tty/console/active is the console the kernel
/// uses for /dev/console. Return it only when it is a serial console, since
/// virtual consoles keep the installer's /dev/tty1 default.
pub fn serialConsole(active: []const u8) ?[]const u8 {
    var last: []const u8 = "";
    var names = std.mem.tokenizeAny(u8, active, " \t\r\n");
    while (names.next()) |name| last = name;
    return if (isSerial(last)) last else null;
}

fn isSerial(name: []const u8) bool {
    for (serial_prefixes) |prefix| {
        if (!std.mem.startsWith(u8, name, prefix)) continue;
        const number = name[prefix.len..];
        if (number.len == 0) return false;
        for (number) |ch| {
            if (!std.ascii.isDigit(ch)) return false;
        }
        return true;
    }
    return false;
}

test "serial console selection uses the last active console" {
    try std.testing.expectEqualStrings("ttyS0", serialConsole("tty0 ttyS0\n").?);
    try std.testing.expectEqualStrings("ttyUSB0", serialConsole("tty0 ttyS0 ttyUSB0").?);
    try std.testing.expectEqualStrings("ttyACM0", serialConsole("ttyUSB1 ttyACM0\n").?);
    try std.testing.expectEqualStrings("ttyAMA0", serialConsole("ttyAMA0").?);
}

test "serial console selection keeps the virtual console default" {
    try std.testing.expect(serialConsole("tty0") == null);
    try std.testing.expect(serialConsole("ttyS0 tty0\n") == null);
    try std.testing.expect(serialConsole("") == null);
}

test "serial console selection ignores unknown and malformed names" {
    try std.testing.expect(serialConsole("tty0 hvc0") == null);
    try std.testing.expect(serialConsole("tty0 ttyS") == null);
    try std.testing.expect(serialConsole("tty0 ttyS0,115200") == null);
}
