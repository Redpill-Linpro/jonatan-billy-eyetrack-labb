//! Tracking state: lost/reacquired transitions, auto-centring, and the
//! previous head rotation used to keep the SVD axes from flipping.
const std = @import("std");
const linalg = @import("linalg.zig");
const OneEuro = @import("filter.zig").OneEuro;

pub const Values = [6]f64; // x, y, z, yaw, pitch, roll

pub const StateMonitor = struct {
    timeout_ms: i64,
    auto_center: bool,
    /// Axes auto-centring leaves alone (z; yaw/pitch once calibrated).
    uncentered: [6]bool,
    last_valid_ms: i64 = 0,
    is_lost: bool = true,
    offsets: Values = @splat(0),
    /// Rotation of the last valid frame.
    r_prev: ?linalg.Mat3 = null,

    /// Flips the columns of `r` that point away from the previous frame's.
    pub fn stabilize(self: *const StateMonitor, r: *linalg.Mat3) void {
        const prev = self.r_prev orelse return;
        for (0..3) |i| {
            if (linalg.dot(linalg.col(r.*, i), linalg.col(prev, i)) < 0) linalg.negateCol(r, i);
        }
    }

    /// `raw` is the frame's pose, or null when there is nothing usable.
    /// `r_current` must already be stabilised. Returns the centred pose to send.
    pub fn check(
        self: *StateMonitor,
        raw: ?Values,
        now_ms: i64,
        filters: []OneEuro,
        r_current: ?linalg.Mat3,
        log: *std.Io.Writer,
    ) !?Values {
        const values = raw orelse {
            const since = now_ms - self.last_valid_ms;
            if (since > self.timeout_ms and !self.is_lost) {
                try log.print("[Tracking] Target Lost (No data for {d}ms)\n", .{since});
                self.is_lost = true;
                self.r_prev = null;
            }
            return null;
        };

        if (self.is_lost) {
            try log.print("[Tracking] Reacquired after {d}ms gap.\n", .{now_ms - self.last_valid_ms});
            self.is_lost = false;
            // After a long gap the old head pose is stale: do not stabilise against it.
            self.r_prev = null;
            for (filters) |*f| f.reset();
            if (self.auto_center) {
                try log.print("[Tracking] Auto-Centering...\n", .{});
                self.center(values);
            }
        }
        if (r_current) |r| self.r_prev = r;

        self.last_valid_ms = now_ms;
        var out: Values = undefined;
        for (&out, values, self.offsets) |*o, v, off| o.* = v - off;
        for (out[3..]) |*a| { // wrap into +-180, e.g. roll -347 -> 13
            if (@abs(a.*) > 180) a.* = @mod(a.* + 180, 360) - 180;
        }
        return out;
    }

    pub fn center(self: *StateMonitor, raw: Values) void {
        for (&self.offsets, raw, self.uncentered) |*o, v, skip| o.* = if (skip) 0 else v;
    }
};

const testing = std.testing;

test "auto-centres on acquire, wraps angles, reports loss after the timeout" {
    var buf: [512]u8 = undefined;
    var log: std.Io.Writer = .fixed(&buf);
    var filters: [6]OneEuro = @splat(.{ .freq = 30 });
    var m: StateMonitor = .{ .timeout_ms = 500, .auto_center = true, .uncentered = .{ false, false, true, false, false, false } };

    const first = (try m.check(.{ 1, 2, 3, 170, 5, 6 }, 1000, &filters, null, &log)).?;
    try testing.expectEqualSlices(f64, &.{ 0, 0, 3, 0, 0, 0 }, &first);
    try testing.expect(!m.is_lost);

    const second = (try m.check(.{ 1, 2, 4, -175, 5, 6 }, 1033, &filters, null, &log)).?;
    try testing.expectApproxEqAbs(@as(f64, 15), second[3], 1e-9); // -345 wrapped

    try testing.expect(try m.check(null, 1400, &filters, null, &log) == null);
    try testing.expect(!m.is_lost);
    try testing.expect(try m.check(null, 1600, &filters, null, &log) == null);
    try testing.expect(m.is_lost);
    try testing.expect(std.mem.indexOf(u8, log.buffered(), "Target Lost") != null);
}
