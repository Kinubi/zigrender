const std = @import("std");
const c = @cImport({
    @cInclude("GLFW/glfw3.h");
});

/// Minimal Wayland window/context struct for Zig-native windowing
pub const WaylandWindow = struct {
    handle: ?*c.GLFWwindow = null,
    width: u32 = 800,
    height: u32 = 600,
    should_close: bool = false,
};

/// Create a Wayland window (stub, needs real implementation)
pub fn createWindow(width: u32, height: u32) !WaylandWindow {
    if (c.glfwInit() == 0) return error.FailedToInitGLFW;
    c.glfwWindowHint(c.GLFW_CLIENT_API, c.GLFW_NO_API); // No OpenGL context
    const window = c.glfwCreateWindow(@as(c_int, width), @as(c_int, height), "NRIFramework", null, null);
    if (window == null) return error.FailedToCreateWindow;
    return WaylandWindow{
        .handle = window,
        .width = width,
        .height = height,
        .should_close = false,
    };
}

/// Poll Wayland events (stub)
pub fn pollEvents(win: *WaylandWindow) void {
    c.glfwPollEvents();
    if (win.handle != null and c.glfwWindowShouldClose(win.handle)) {
        win.should_close = true;
    }
}

/// Destroy a Wayland window (stub)
pub fn destroyWindow(win: *WaylandWindow) void {
    if (win.handle != null) {
        c.glfwDestroyWindow(win.handle);
        win.handle = null;
    }
    c.glfwTerminate();
}
