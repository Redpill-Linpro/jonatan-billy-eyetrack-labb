const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // libc is only needed for dlopen; Windows uses kernel32 directly.
    const root = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = target.result.os.tag != .windows,
    });

    const exe = b.addExecutable(.{ .name = "zimt", .root_module = root });
    b.installArtifact(exe);

    const run_tests = b.addRunArtifact(b.addTest(.{ .root_module = root }));
    b.step("test", "Run unit tests").dependOn(&run_tests.step);
}
