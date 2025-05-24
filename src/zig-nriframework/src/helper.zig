const std = @import("std");

/// Utility functions for the NRI framework.
pub fn loadResource(resourcePath: []const u8) ![]u8 {
    const allocator = std.heap.page_allocator;
    const file = try std.fs.cwd().openFile(resourcePath, .{ .read = true });
    defer file.close();

    const fileSize = try file.getEndPos();
    const buffer = try allocator.alloc(u8, fileSize);
    const bytesRead = try file.readAll(buffer);
    if (bytesRead != fileSize) return error.ResourceLoadFailed;
    return buffer;
}

/// Print an error to stderr with a framework prefix.
pub fn handleError(err: anyerror) void {
    const stderr = std.io.getStdErr().writer();
    _ = stderr.print("[NRIFramework Error] {any}\n", .{err});
}

/// Print an info message to stdout with a framework prefix.
pub fn logInfo(msg: []const u8) void {
    const stdout = std.io.getStdOut().writer();
    _ = stdout.print("[NRIFramework] {s}\n", .{msg});
}
