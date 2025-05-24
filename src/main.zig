const std = @import("std");
const wayland = @import("zig-nriframework/src/wayland_window.zig");

pub fn main() !void {
    var window = try wayland.createWindow(800, 600);
    defer wayland.destroyWindow(&window);
    std.debug.print("Window created!\n", .{});
    while (!window.should_close) {
        wayland.pollEvents(&window);
        // You can add rendering or input logic here
        std.time.sleep(16_000_000); // ~60 FPS
    }
    std.debug.print("Window closed.\n", .{});
}
