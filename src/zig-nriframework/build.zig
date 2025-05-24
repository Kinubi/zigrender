const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    const mode = b.standardReleaseOptions();
    const target = b.getTarget();
    const output_dir = b.path("zig-nriframework");

    const exe = b.addExecutable("nriframework", "src/main.zig");
    exe.setBuildMode(mode);
    exe.setTarget(target);
    exe.setOutputDir(output_dir);
    
    // Add source files
    exe.addSourceFile("src/nriframework.zig", "");
    exe.addSourceFile("src/camera.zig", "");
    exe.addSourceFile("src/controls.zig", "");
    exe.addSourceFile("src/helper.zig", "");
    exe.addSourceFile("src/timer.zig", "");
    exe.addSourceFile("src/utils.zig", "");
    exe.addSourceFile("src/types/index.zig", "");

    // Set the executable to be built
    b.default_step.dependOn(&exe.step);
}