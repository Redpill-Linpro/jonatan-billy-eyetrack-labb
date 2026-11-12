//! Blink detection: eyelid state from MediaPipe's eyeBlink score, and the
//! N-blink gesture plus gaze hold derived from it.
const std = @import("std");

/// eyeBlink score rise over the open-eye baseline that means closed...
pub const rise = 0.2;
/// ...and the rise below which it is open again.
pub const reopen = 0.1;
/// A longer closure is not a blink: breaks a gesture, stops holding gaze.
pub const max_ms = 700;
/// Max open time between blinks of one gesture; the gesture fires after it.
pub const gap_ms = 600;
/// Gaze stays held this long after the eyes reopen (they roll back).
pub const settle_ms = 200;

/// eyeBlink score -> eye closed, against a running open-eye baseline: looking
/// down lowers the lids and raises the score for long stretches, a blink is a
/// short rise.
pub const EyeLids = struct {
    base: ?f64 = null,
    closed_at: ?i64 = null,

    /// `score` is null without a face; so is the result.
    pub fn update(self: *EyeLids, score: ?f64, t_ms: i64) ?bool {
        const s = score orelse {
            self.closed_at = null;
            return null;
        };
        const base = self.base orelse s;
        const closed = s - base > @as(f64, if (self.closed_at != null) reopen else rise);
        if (!closed) {
            self.closed_at = null;
        } else if (self.closed_at == null) {
            self.closed_at = t_ms;
        }
        // Too long for a blink: re-baseline (~1 s at 30 fps).
        self.base = if (!closed or t_ms - self.closed_at.? > max_ms) base + (s - base) / 30 else base;
        return closed;
    }
};

/// Per-frame eye-closed flags -> gaze hold, and the N-blink gesture event.
/// Either eye closed counts, so a wink is a blink.
pub const Blinks = struct {
    /// 0 disables the gesture.
    n: u32,
    count: u32 = 0,
    closed_at: ?i64 = null,
    opened_at: ?i64 = null,

    pub const Result = struct { hold: bool = false, gesture: bool = false };

    /// `closed` is null without a face.
    pub fn update(self: *Blinks, closed: ?bool, t_ms: i64) Result {
        const is_closed = closed orelse {
            self.count = 0;
            self.closed_at = null;
            return .{};
        };
        if (is_closed) {
            if (self.closed_at == null) self.closed_at = t_ms;
            return .{ .hold = t_ms - self.closed_at.? <= max_ms };
        }
        if (self.closed_at) |c| { // eyes just reopened
            self.count = if (t_ms - c <= max_ms) self.count + 1 else 0;
            self.closed_at = null;
            self.opened_at = t_ms;
        }
        const opened = self.opened_at orelse return .{};
        const open_ms = t_ms - opened;
        if (self.count != 0 and open_ms > gap_ms) { // run of blinks over: exactly N fires
            const done = self.count == self.n;
            self.count = 0;
            return .{ .gesture = done };
        }
        return .{ .hold = open_ms < settle_ms };
    }
};

const testing = std.testing;

/// Feeds `ms` of a constant score at 30 fps; returns whether a gesture fired.
fn feed(lids: *EyeLids, blinks: *Blinks, t: *i64, score: ?f64, ms: i64) bool {
    var fired = false;
    const end = t.* + ms;
    while (t.* < end) : (t.* += 33) {
        if (blinks.update(lids.update(score, t.*), t.*).gesture) fired = true;
    }
    return fired;
}

test "three quick blinks fire the gesture once; two or four do not" {
    for ([_]u32{ 2, 3, 4 }) |n| {
        var lids: EyeLids = .{};
        var blinks: Blinks = .{ .n = 3 };
        var t: i64 = 1000;
        var fired: u32 = 0;
        fired += @intFromBool(feed(&lids, &blinks, &t, 0.05, 500));
        for (0..n) |_| {
            fired += @intFromBool(feed(&lids, &blinks, &t, 0.6, 130));
            fired += @intFromBool(feed(&lids, &blinks, &t, 0.05, 200));
        }
        fired += @intFromBool(feed(&lids, &blinks, &t, 0.05, 1000));
        try testing.expectEqual(@as(u32, if (n == 3) 1 else 0), fired);
    }
}

test "gaze is held during a blink and briefly after, not during a long closure" {
    var blinks: Blinks = .{ .n = 3 };
    try testing.expect(!blinks.update(false, 0).hold);
    try testing.expect(blinks.update(true, 100).hold);
    try testing.expect(blinks.update(true, 300).hold);
    try testing.expect(blinks.update(false, 350).hold); // settling
    try testing.expect(!blinks.update(false, 600).hold);
    try testing.expect(blinks.update(true, 2000).hold);
    try testing.expect(!blinks.update(true, 2800).hold); // too long to be a blink
    try testing.expect(!blinks.update(null, 2900).hold);
}

test "a long closure re-baselines instead of counting as a blink" {
    var lids: EyeLids = .{};
    var blinks: Blinks = .{ .n = 1 };
    var t: i64 = 0;
    _ = feed(&lids, &blinks, &t, 0.1, 300);
    const fired = feed(&lids, &blinks, &t, 0.5, 6000) or feed(&lids, &blinks, &t, 0.1, 2000);
    try testing.expect(!fired);
    try testing.expect(lids.base.? < 0.2);
}
