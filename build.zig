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

    // Step 1: Build NRIFramework (which will also build NRI as a subproject)
    const nriframework_build_step = b.addSystemCommand(&.{
        "sh", "vendor/NRIFramework/2-Build.sh",
    });

    // Path to NRIFramework build output and includes
    const nriframework_build = "vendor/NRIFramework/_Build";
    const nriframework_include = "vendor/NRIFramework/Include";
    const nri_include = "vendor/NRIFramework/External/NRI/Include"; // NRI headers as built by NRIFramework

    // Build zig-nriframework as a static library
    const nriframework_lib = b.addStaticLibrary(.{
        .name = "nriframework",
        .root_source_file = b.path("src/zig-nriframework/src/nriframework.zig"),
        .target = target,
        .optimize = optimize,
    });
    nriframework_lib.addIncludePath(b.path("src/zig-nriframework/src"));
    // Remove all addSourceFile calls; rely on @import in nriframework.zig
    b.installArtifact(nriframework_lib);

    // Main Zig executable or library
    const exe = b.addExecutable(.{
        .name = "main",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.linkLibrary(nriframework_lib);

    // Make sure NRIFramework (and thus NRI) is built before linking
    exe.step.dependOn(&nriframework_build_step.step);

    // Add NRI and NRIFramework include paths
    exe.addIncludePath(b.path(nriframework_include));
    exe.addIncludePath(b.path(nri_include));

    // Link NRI and NRIFramework static libraries from the NRIFramework build output
    exe.addObjectFile(b.path(nriframework_build ++ "/External/NRI/libNRI.a"));
    exe.addObjectFile(b.path(nriframework_build ++ "/External/NRI/libNRI_Shared.a"));
    exe.addObjectFile(b.path(nriframework_build ++ "/External/NRI/libNRI_NONE.a"));
    exe.addObjectFile(b.path(nriframework_build ++ "/External/NRI/libNRI_Validation.a"));
    exe.addObjectFile(b.path(nriframework_build ++ "/External/NRI/libNRI_VK.a"));
    exe.addObjectFile(b.path(nriframework_build ++ "/libNRIFramework.a"));
    exe.addObjectFile(b.path(nriframework_build ++ "/_deps/shadermake-build/libShaderMakeBlob.a"));
    // Add more .a files as needed (imgui, detex, etc.)

    // Link system libraries if needed
    exe.linkSystemLibrary("vulkan");
    exe.linkLibC();
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
    // Add RPATH to the executable for NRIFramework and its NRI subdir
    exe.addRPath(b.path(nriframework_build));
    exe.addRPath(b.path(nriframework_build ++ "/NRI"));

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    b.step("run", "Build and run the executable").dependOn(&run_cmd.step);
}
