const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    const mode = b.standardReleaseOptions();
    const target = b.getTarget();
    const output_dir = b.path("zig-nriframework");

    const lib = b.addStaticLibrary("nriframework", "src/nriframework.zig");
    lib.setBuildMode(mode);
    lib.setTarget(target);
    lib.setOutputDir(output_dir);
    lib.addSourceFile("src/camera.zig", "");
    lib.addSourceFile("src/controls.zig", "");
    lib.addSourceFile("src/helper.zig", "");
    lib.addSourceFile("src/timer.zig", "");
    lib.addSourceFile("src/utils.zig", "");
    lib.addSourceFile("src/types/index.zig", "");

    b.installArtifact(lib);
}
