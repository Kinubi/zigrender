const std = @import("std");

/// Utility functions for the NRI framework.
pub fn loadResource(resourcePath: []const u8) ![]u8 {
    const allocator = std.heap.page_allocator;
    const file = try std.fs.cwd().openFile(resourcePath, .{ .read = true });
    defer file.close();

    const fileSize = try file.getEndPos();
    const buffer = try allocator.alloc(u8, fileSize);
    const bytesRead = try file.readAll(buffer);
    
    if (bytesRead != fileSize) {
        return error.ResourceLoadFailed;
    }

    return buffer;
}

pub fn handleError(err: anyerror) void {
    const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();
    
    switch (err) {
        error.ResourceLoadFailed => {
            _ = stdout.print("Error: Resource could not be loaded.\n");
        },
        // Add more error handling cases as needed
        else => {
            _ = stderr.print("An unknown error occurred: {}\n", .{err});
        },
    }
}