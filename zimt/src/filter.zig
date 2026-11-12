//! One Euro filter (Casiez et al.), fixed sample rate.
const std = @import("std");

pub const OneEuro = struct {
    freq: f64,
    min_cutoff: f64 = 1.0,
    beta: f64 = 0.0,
    d_cutoff: f64 = 1.0,
    x_prev: ?f64 = null,
    dx_prev: f64 = 0.0,

    pub fn reset(self: *OneEuro) void {
        self.x_prev = null;
        self.dx_prev = 0.0;
    }

    fn alpha(self: *const OneEuro, cutoff: f64) f64 {
        const tau = 1.0 / (2 * std.math.pi * cutoff);
        return 1.0 / (1.0 + tau * self.freq);
    }

    pub fn apply(self: *OneEuro, x: f64) f64 {
        const prev = self.x_prev orelse {
            self.x_prev = x;
            return x;
        };
        const dx = (x - prev) * self.freq;
        const ad = self.alpha(self.d_cutoff);
        const edx = ad * dx + (1 - ad) * self.dx_prev;
        self.dx_prev = edx;
        const a = self.alpha(self.min_cutoff + self.beta * @abs(edx));
        const out = a * x + (1 - a) * prev;
        self.x_prev = out;
        return out;
    }
};

test "first sample passes through, then smooths towards the input" {
    var f: OneEuro = .{ .freq = 30, .min_cutoff = 0.05, .beta = 0.03 };
    try std.testing.expectEqual(@as(f64, 5), f.apply(5));
    const y = f.apply(6);
    try std.testing.expect(y > 5 and y < 6);
    f.reset();
    try std.testing.expectEqual(@as(f64, -2), f.apply(-2));
}
