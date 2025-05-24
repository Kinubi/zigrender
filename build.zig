const std = @import("std");

fn hasFileIn(dir_path: []const u8, file: []const u8) bool {
    var dir = std.fs.openDirAbsolute(dir_path, .{}) catch return false;
    defer dir.close();
    dir.access(file, .{}) catch return false;
    return true;
}

fn getObjSystemPath(
    native_path: std.zig.system.NativePaths,
    obj_full_file: []const u8,
) ![]const u8 {
    for (native_path.lib_dirs.items) |lib_dir| {
        const resolved_lib_dir = try std.fs.path.resolve(native_path.arena, &.{lib_dir});
        if (hasFileIn(resolved_lib_dir, obj_full_file)) {
            return try std.fs.path.join(native_path.arena, &.{ resolved_lib_dir, obj_full_file });
        }
    }
    return error.FileNotFound;
}

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Step 1: Build NRI using its own script
    const nri_build_step = b.addSystemCommand(&.{
        "sh", "vendor/NRI/2-Build.sh",
    });

    // Path to NRI build output and includes
    const nri_build = "vendor/NRI/_Build";
    const nri_include = "vendor/NRI/Include";

    // Main Zig executable or library
    const exe = b.addExecutable(.{
        .name = "main",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Make sure NRI is built before linking
    exe.step.dependOn(&nri_build_step.step);

    // Add NRI include path
    exe.addIncludePath(b.path(nri_include));

    // Link NRI static libraries (add/remove as needed)
    exe.addObjectFile(b.path(nri_build ++ "/libNRI.a")); // <-- Add this if it exists
    exe.addObjectFile(b.path(nri_build ++ "/libNRI_Shared.a"));
    exe.addObjectFile(b.path(nri_build ++ "/libNRI_NONE.a"));
    exe.addObjectFile(b.path(nri_build ++ "/libNRI_Validation.a"));
    exe.addObjectFile(b.path(nri_build ++ "/libNRI_VK.a"));
    // Add more .a files as needed

    // Link system libraries if needed
    exe.linkSystemLibrary("vulkan");
    exe.linkLibC();
    //exe.linkLibCpp();
    const libstdcxx_names: []const []const u8 = &.{
        "libstdc++.so",
        "libstdc++.a",
    };
    const native_path = try std.zig.system.NativePaths.detect(b.allocator, target.result);

    for (libstdcxx_names) |libstdcxx_name| {
        const libstdcxx_path = getObjSystemPath(native_path, libstdcxx_name) catch continue;
        exe.addObjectFile(.{ .cwd_relative = libstdcxx_path });
        break;
    }
    exe.linkSystemLibrary("stdc++");

    // Add RPATH to the executable
    exe.addRPath(b.path(nri_build));

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    b.step("run", "Build and run the executable").dependOn(&run_cmd.step);
}
