//! Small fixed-size linear algebra: just what the pose maths needs.
const std = @import("std");

pub const Vec3 = [3]f64;
/// Row-major: m[row][col].
pub const Mat3 = [3][3]f64;

pub fn add(a: Vec3, b: Vec3) Vec3 {
    return .{ a[0] + b[0], a[1] + b[1], a[2] + b[2] };
}

pub fn sub(a: Vec3, b: Vec3) Vec3 {
    return .{ a[0] - b[0], a[1] - b[1], a[2] - b[2] };
}

pub fn scale(a: Vec3, s: f64) Vec3 {
    return .{ a[0] * s, a[1] * s, a[2] * s };
}

pub fn dot(a: Vec3, b: Vec3) f64 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

pub fn cross(a: Vec3, b: Vec3) Vec3 {
    return .{
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    };
}

pub fn norm(a: Vec3) f64 {
    return @sqrt(dot(a, a));
}

pub fn unit(a: Vec3) Vec3 {
    return scale(a, 1.0 / norm(a));
}

pub fn mean(pts: []const Vec3) Vec3 {
    var s: Vec3 = .{ 0, 0, 0 };
    for (pts) |p| s = add(s, p);
    return scale(s, 1.0 / @as(f64, @floatFromInt(pts.len)));
}

pub fn col(m: Mat3, c: usize) Vec3 {
    return .{ m[0][c], m[1][c], m[2][c] };
}

pub fn setCol(m: *Mat3, c: usize, v: Vec3) void {
    for (0..3) |r| m[r][c] = v[r];
}

pub fn negateCol(m: *Mat3, c: usize) void {
    for (0..3) |r| m[r][c] = -m[r][c];
}

/// m * v
pub fn mulVec(m: Mat3, v: Vec3) Vec3 {
    return .{ dot(m[0], v), dot(m[1], v), dot(m[2], v) };
}

/// transpose(m) * v
pub fn mulVecT(m: Mat3, v: Vec3) Vec3 {
    return .{ dot(col(m, 0), v), dot(col(m, 1), v), dot(col(m, 2), v) };
}

pub fn det(m: Mat3) f64 {
    return dot(col(m, 0), cross(col(m, 1), col(m, 2)));
}

/// Eigenvectors of a symmetric 3x3 matrix as the columns of the result, by
/// descending eigenvalue (cyclic Jacobi). Column signs are arbitrary.
pub fn symmetricEigenvectors(sym: Mat3) Mat3 {
    var a = sym;
    var v: Mat3 = .{ .{ 1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, 0, 1 } };
    for (0..64) |_| {
        const off = a[0][1] * a[0][1] + a[0][2] * a[0][2] + a[1][2] * a[1][2];
        const diag = a[0][0] * a[0][0] + a[1][1] * a[1][1] + a[2][2] * a[2][2];
        if (off <= 1e-30 * diag or off == 0) break;
        inline for (.{ .{ 0, 1 }, .{ 0, 2 }, .{ 1, 2 } }) |pq| {
            const p = pq[0];
            const q = pq[1];
            if (a[p][q] != 0) {
                const theta = (a[q][q] - a[p][p]) / (2 * a[p][q]);
                const t = std.math.sign(theta) / (@abs(theta) + @sqrt(theta * theta + 1));
                const c = 1 / @sqrt(t * t + 1);
                const s = if (theta == 0) @sqrt(0.5) else t * c;
                const cc = if (theta == 0) @sqrt(0.5) else c;
                for (0..3) |k| { // A <- A J
                    const akp = a[k][p];
                    const akq = a[k][q];
                    a[k][p] = cc * akp - s * akq;
                    a[k][q] = s * akp + cc * akq;
                }
                for (0..3) |k| { // A <- J^T A
                    const apk = a[p][k];
                    const aqk = a[q][k];
                    a[p][k] = cc * apk - s * aqk;
                    a[q][k] = s * apk + cc * aqk;
                }
                for (0..3) |k| { // V <- V J
                    const vkp = v[k][p];
                    const vkq = v[k][q];
                    v[k][p] = cc * vkp - s * vkq;
                    v[k][q] = s * vkp + cc * vkq;
                }
            }
        }
    }
    var order = [3]usize{ 0, 1, 2 };
    const Ctx = struct {
        fn desc(d: Mat3, i: usize, j: usize) bool {
            return d[i][i] > d[j][j];
        }
    };
    std.mem.sort(usize, &order, a, Ctx.desc);
    var out: Mat3 = undefined;
    for (order, 0..) |src, dst| setCol(&out, dst, col(v, src));
    return out;
}

/// Angles in degrees of the extrinsic y, x, z rotation sequence, i.e.
/// R = Rz(roll) * Rx(pitch) * Ry(yaw): scipy's `as_euler('yxz', degrees=True)`.
pub fn eulerYxz(r: Mat3) Vec3 {
    const deg = std.math.deg_per_rad;
    const sx = std.math.clamp(r[2][1], -1.0, 1.0);
    return .{
        std.math.atan2(-r[2][0], r[2][2]) * deg,
        std.math.asin(sx) * deg,
        std.math.atan2(-r[0][1], r[1][1]) * deg,
    };
}

const testing = std.testing;

fn rot(axis: u2, deg: f64) Mat3 {
    const c = @cos(deg * std.math.rad_per_deg);
    const s = @sin(deg * std.math.rad_per_deg);
    return switch (axis) {
        0 => .{ .{ 1, 0, 0 }, .{ 0, c, -s }, .{ 0, s, c } },
        1 => .{ .{ c, 0, s }, .{ 0, 1, 0 }, .{ -s, 0, c } },
        else => .{ .{ c, -s, 0 }, .{ s, c, 0 }, .{ 0, 0, 1 } },
    };
}

fn mul(a: Mat3, b: Mat3) Mat3 {
    var out: Mat3 = undefined;
    for (0..3) |r| for (0..3) |c| {
        out[r][c] = dot(a[r], col(b, c));
    };
    return out;
}

test "eulerYxz inverts Rz*Rx*Ry" {
    const cases = [_]Vec3{ .{ 10, 20, 30 }, .{ -170, 45, 5 }, .{ 100, -80, -120 }, .{ 0, 0, 0 } };
    for (cases) |e| {
        const got = eulerYxz(mul(rot(2, e[2]), mul(rot(0, e[1]), rot(1, e[0]))));
        for (0..3) |i| try testing.expectApproxEqAbs(e[i], got[i], 1e-9);
    }
}

test "eulerYxz matches scipy" {
    // Rotation.from_euler('yxz', [25, -35, 70], degrees=True).as_matrix()
    const got = eulerYxz(.{
        .{ 0.53776065, -0.76975113, -0.34394284 },
        .{ 0.76874373, 0.2801665, 0.57492592 },
        .{ -0.34618861, -0.57357644, 0.74240388 },
    });
    for ([_]f64{ 25, -35, 70 }, got) |want, g| try testing.expectApproxEqAbs(want, g, 1e-5);
}

test "symmetricEigenvectors diagonalises" {
    const s: Mat3 = .{ .{ 4, 1, -2 }, .{ 1, 3, 0.5 }, .{ -2, 0.5, 9 } };
    const v = symmetricEigenvectors(s);
    var prev: f64 = std.math.inf(f64);
    for (0..3) |i| {
        const e = col(v, i);
        const se = mulVec(s, e);
        const lambda = dot(e, se);
        try testing.expectApproxEqAbs(@as(f64, 1), norm(e), 1e-12);
        for (0..3) |k| try testing.expectApproxEqAbs(lambda * e[k], se[k], 1e-9);
        try testing.expect(lambda <= prev);
        prev = lambda;
    }
}
