//! opentrack's "UDP over network" input: six native-endian doubles per
//! packet: x, y, z (cm), yaw, pitch, roll (degrees).
const std = @import("std");
const Io = std.Io;

pub const default_port = 4242;

pub const Client = struct {
    socket: Io.net.Socket,
    dest: Io.net.IpAddress,
    send_failed: bool = false,

    pub fn init(io: Io, dest: Io.net.IpAddress) !Client {
        const local: Io.net.IpAddress = .{ .ip4 = .unspecified(0) };
        return .{ .socket = try local.bind(io, .{ .mode = .dgram }), .dest = dest };
    }

    pub fn deinit(self: *Client, io: Io) void {
        self.socket.close(io);
    }

    pub fn send(self: *Client, io: Io, pose: [6]f64) void {
        self.socket.send(io, &self.dest, std.mem.asBytes(&pose)) catch |err| {
            if (!self.send_failed) std.debug.print("WARNING: Sending to opentrack failed ({t}); will keep trying.\n", .{err});
            self.send_failed = true;
            return;
        };
        self.send_failed = false;
    }
};

test "a packet is 48 bytes of little-endian doubles" {
    const pose = [6]f64{ 1, 2, 3, 4, 5, 6 };
    const bytes = std.mem.asBytes(&pose);
    try std.testing.expectEqual(48, bytes.len);
    try std.testing.expectEqual(@as(f64, 2), @as(f64, @bitCast(std.mem.readInt(u64, bytes[8..16], .little))));
}
