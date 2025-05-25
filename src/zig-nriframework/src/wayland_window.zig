const std = @import("std");
const c = @cImport({
    @cDefine("GLFW_EXPOSE_NATIVE_WAYLAND", "1");
    @cInclude("GLFW/glfw3.h");
    @cInclude("GLFW/glfw3native.h");
});

/// Minimal Wayland window/context struct for Zig-native windowing
pub const NRIWindow = extern struct {
    display: ?*anyopaque = null,
    surface: ?*anyopaque = null,
};

pub const WaylandWindow = struct {
    handle: ?*anyopaque, // Use a generic pointer
    width: u32 = 800,
    height: u32 = 600,
    should_close: bool = false,
    nri_window: NRIWindow = NRIWindow{},

    /// Show the Wayland window (calls glfwShowWindow)
    pub fn showWindow(self: *WaylandWindow) void {
        if (self.handle != null) {
            c.glfwShowWindow(@ptrCast(self.handle));
        }
    }
};

/// Create a Wayland window, matching NRI SampleBase logic (hidden at first, then shown after init)
pub fn createWindow(width: u32, height: u32) !WaylandWindow {
    if (c.glfwInit() == 0) return error.FailedToInitGLFW;
    c.glfwDefaultWindowHints();
    c.glfwWindowHint(c.GLFW_CLIENT_API, c.GLFW_NO_API); // No OpenGL context
    c.glfwWindowHint(c.GLFW_VISIBLE, 0); // Start hidden, show after init
    c.glfwWindowHint(c.GLFW_DECORATED, 1); // Decorated by default
    c.glfwWindowHint(c.GLFW_RESIZABLE, 0); // Not resizable
    const window = c.glfwCreateWindow(@intCast(width), @intCast(height), "NRIFramework", null, null);
    if (window == null) {
        c.glfwTerminate();
        return error.FailedToCreateWindow;
    }
    // Set up the NRI window struct immediately (like SampleBase)
    return WaylandWindow{
        .handle = window,
        .width = width,
        .height = height,
        .should_close = false,
        .nri_window = NRIWindow{
            .display = c.glfwGetWaylandDisplay(),
            .surface = c.glfwGetWaylandWindow(window),
        },
    };
}

/// Poll Wayland events (stub)
pub fn pollEvents(win: *WaylandWindow) void {
    c.glfwPollEvents();
    if (win.handle != null and c.glfwWindowShouldClose(@ptrCast(win.handle)) == 1) {
        win.should_close = true;
    }
}

/// Destroy a Wayland window (stub)
pub fn destroyWindow(win: *WaylandWindow) void {
    if (win.handle != null) {
        c.glfwDestroyWindow(@ptrCast(win.handle));
        win.handle = null;
    }
    c.glfwTerminate();
}

pub fn setUserPointer(win: *WaylandWindow, ptr: ?*anyopaque) void {
    if (win.handle != null) {
        c.glfwSetWindowUserPointer(@ptrCast(win.handle), ptr);
    }
}
pub fn setKeyCallback(win: *WaylandWindow, cb: ?*const fn (?*anyopaque, c_int, c_int, c_int, c_int) callconv(.C) void) void {
    if (win.handle != null) {
        c.glfwSetKeyCallback(@ptrCast(win.handle), cb);
    }
}
pub fn setCharCallback(win: *WaylandWindow, cb: ?*const fn (?*anyopaque, c_uint) callconv(.C) void) void {
    if (win.handle != null) {
        c.glfwSetCharCallback(@ptrCast(win.handle), cb);
    }
}
pub fn setMouseButtonCallback(win: *WaylandWindow, cb: ?*const fn (?*anyopaque, c_int, c_int, c_int) callconv(.C) void) void {
    if (win.handle != null) {
        c.glfwSetMouseButtonCallback(@ptrCast(win.handle), cb);
    }
}
pub fn setCursorPosCallback(win: *WaylandWindow, cb: ?*const fn (?*anyopaque, f64, f64) callconv(.C) void) void {
    if (win.handle != null) {
        c.glfwSetCursorPosCallback(@ptrCast(win.handle), cb);
    }
}
pub fn setScrollCallback(win: *WaylandWindow, cb: ?*const fn (?*anyopaque, f64, f64) callconv(.C) void) void {
    if (win.handle != null) {
        c.glfwSetScrollCallback(@ptrCast(win.handle), cb);
    }
}
pub fn getFramebufferSize(win: *WaylandWindow) struct { width: u32, height: u32 } {
    // In a real implementation, query the actual framebuffer size (GLFW or Wayland)
    // For now, just return the stored width/height
    return .{ .width = win.width, .height = win.height };
}

pub fn isOpen(win: *WaylandWindow) bool {
    return !win.should_close;
}
