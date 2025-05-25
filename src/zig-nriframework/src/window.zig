const wayland = @import("wayland_window.zig");

pub const Window = wayland.WaylandWindow;

pub fn createWindow(width: u32, height: u32) !Window {
    return wayland.createWindow(width, height);
}

pub fn destroyWindow(win: *Window) void {
    wayland.destroyWindow(win);
}

pub fn pollEvents(win: *Window) void {
    wayland.pollEvents(win);
}

pub const FramebufferSize = struct { width: u32, height: u32 };

pub fn getFramebufferSize(win: *Window) FramebufferSize {
    const raw = wayland.getFramebufferSize(win);
    return FramebufferSize{ .width = raw.width, .height = raw.height };
}

pub fn isOpen(win: *Window) bool {
    return wayland.isOpen(win);
}
