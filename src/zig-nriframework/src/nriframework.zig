const std = @import("std");
const types = @import("types/index.zig");
const camera = @import("camera.zig");
const controls = @import("controls.zig");
const timer = @import("timer.zig");
const helper = @import("helper.zig");
const utils = @import("utils.zig");
const wayland = @import("wayland_window.zig");

// Platform detection
pub const Platform = enum {
    Windows,
    X11,
    Wayland,
    Cocoa,
};

pub fn detectPlatform() Platform {
    // Zig compile-time platform detection
    if (std.builtin.os.tag == .windows) return .Windows;
    if (std.builtin.os.tag == .macos) return .Cocoa;
    if (std.builtin.os.tag == .linux) {
        // No direct way to detect Wayland at compile time, use X11 as default
        return .X11;
    }
    @compileError("Unknown platform");
}

// Settings
pub const VKBindingOffsets = struct {
    cb: u32 = 0,
    sampler: u32 = 128,
    texture: u32 = 32,
    uav: u32 = 64,
};

pub const D3D11_COMMANDBUFFER_EMULATION = false;

// Placeholder types for NRI and 3rd party
pub const Fence = opaque {};
pub const Texture = opaque {};
pub const Descriptor = opaque {};
pub const Format = u32;
pub const Device = opaque {};
pub const CommandBuffer = opaque {};
pub const Streamer = opaque {};
pub const Imgui = opaque {};
pub const ImguiInterface = opaque {};
pub const Camera = opaque {};
pub const Timer = opaque {};
pub const Key = u8;
pub const Button = u8;
pub const float2 = struct { x: f32, y: f32 };
pub const uint2 = struct { x: u32, y: u32 };

// SwapChainTexture struct
pub const SwapChainTexture = struct {
    acquireSemaphore: ?*Fence,
    releaseSemaphore: ?*Fence,
    texture: ?*Texture,
    colorAttachment: ?*Descriptor,
    attachmentFormat: Format,
};

// "Virtual" function table for SampleBase
pub const SampleBaseVTable = struct {
    initialize: fn (*SampleBase, graphics_api: u32) bool,
    renderFrame: fn (*SampleBase, frame_index: u32) void,
    latencySleep: ?fn (*SampleBase, frame_index: u32) void = null,
    prepareFrame: ?fn (*SampleBase, frame_index: u32) void = null,
    appShouldClose: ?fn (*SampleBase) bool = null,
    deinit: ?fn (*SampleBase) void = null,
};

// SampleBase struct
pub const SampleBase = struct {
    vtable: *const SampleBaseVTable,
    allocationCallbacks: usize = 0, // Placeholder
    sceneFile: []const u8 = "ShaderBalls/ShaderBalls.gltf",
    window: ?*Window = null,
    camera: camera.Camera = undefined,
    timer: timer.Timer = timer.Timer.init(),
    controls: controls.Controls = controls.Controls.init(),
    outputResolution: uint2 = .{ .x = 1920, .y = 1080 },
    windowResolution: uint2 = .{ .x = 0, .y = 0 },
    vsyncInterval: u8 = 0,
    dpiMode: u32 = 0,
    rngState: u32 = 0,
    adapterIndex: u32 = 0,
    mouseSensitivity: f32 = 1.0,
    debugAPI: bool = false,
    debugNRI: bool = false,
    alwaysActive: bool = false,
    timeLimit: f64 = 1e38,
    frameNum: u32 = 0xFFFFFFFF,
    // Imgui integration
    imguiInterface: ImguiInterface = undefined,
    imguiRenderer: ?*Imgui = null,

    pub fn isKeyToggled(self: *SampleBase, key: Key) bool {
        return self.controls.keyToggled[@intFromEnum(key)];
    }
    pub fn isKeyPressed(self: *SampleBase, key: Key) bool {
        return self.controls.keyState[@intFromEnum(key)];
    }
    pub fn isButtonPressed(self: *SampleBase, button: Button) bool {
        return self.controls.buttonState[@intFromEnum(button)];
    }
    pub fn getMouseDelta(self: *SampleBase) float2 {
        return self.controls.mouseDelta;
    }
    pub fn getMouseWheel(self: *SampleBase) f32 {
        return self.controls.mouseWheel;
    }
    pub fn resetInputToggles(self: *SampleBase) void {
        self.controls.resetToggles();
    }
    pub fn getViewMatrix(self: *SampleBase) types.float4x4 {
        return self.camera.get_view_matrix();
    }
    pub fn getProjectionMatrix(self: *SampleBase) types.float4x4 {
        return self.camera.get_projection_matrix();
    }
    pub fn updateTimer(self: *SampleBase) void {
        self.timer.update();
    }
    pub fn getDeltaTime(self: *SampleBase) f64 {
        return self.timer.getDeltaTime();
    }
    pub fn logInfo(_: *SampleBase, msg: []const u8) void {
        helper.logInfo(msg);
    }
    pub fn handleError(_: *SampleBase, err: anyerror) void {
        helper.handleError(err);
    }
};

// Platform-specific Window type (now Wayland only)
pub const Window = wayland.WaylandWindow;

// Main entry point for a sample using the framework (Wayland only)
pub fn sampleMain(
    sampleType: type,
    _: u32, // unused
    _: []const u8, // unused
) !void {
    var sample = sampleType{};
    defer sample.vtable.deinit.?(sample);
    // Wayland window creation
    sample.nriWindow = try wayland.createWindow(1280, 720);
    // TODO: Add device creation, swapchain, and graphics API selection here
    if (sample.vtable.initialize(&sample, 0)) {
        // Main render loop
        while (!sample.nriWindow.should_close) {
            wayland.pollEvents(&sample.nriWindow);
            // TODO: Integrate input polling, timer update, and Imgui frame begin/end here
            // Imgui integration point (pseudo):
            // if (sample.imguiRenderer) |imgui| {
            //     imgui.beginFrame(...);
            //     // user UI code
            //     imgui.endFrame(...);
            // }
            sample.vtable.renderFrame(&sample, sample.frameNum);
            sample.frameNum += 1;
        }
    }
    // Wayland window destruction
    wayland.destroyWindow(&sample.nriWindow);
    // TODO: Add cleanup for device, swapchain, Imgui, and other resources
}
