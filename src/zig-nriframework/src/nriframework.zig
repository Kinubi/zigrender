const std = @import("std");

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
pub const Window = opaque {};
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
    camera: Camera = undefined,
    timer: Timer = undefined,
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
    keyState: [256]bool = [_]bool{false} ** 256,
    keyToggled: [256]bool = [_]bool{false} ** 256,
    buttonState: [8]bool = [_]bool{false} ** 8,
    mouseDelta: float2 = .{ .x = 0, .y = 0 },
    mousePosPrev: float2 = .{ .x = 0, .y = 0 },
    mouseWheel: f32 = 0.0,
    imguiInterface: ImguiInterface = undefined,
    imguiRenderer: ?*Imgui = null,
    mouseCursors: [8]?*anyopaque = [_]?*anyopaque{null} ** 8,
    nriWindow: Window = undefined,
    timeLimit: f64 = 1e38,
    frameNum: u32 = 0xFFFFFFFF,

    pub fn isKeyToggled(self: *SampleBase, key: Key) bool {
        const idx = @intCast(usize, key);
        const state = self.keyToggled[idx];
        self.keyToggled[idx] = false;
        return state;
    }

    pub fn isKeyPressed(self: *SampleBase, key: Key) bool {
        return self.keyState[@intCast(usize, key)];
    }

    pub fn isButtonPressed(self: *SampleBase, button: Button) bool {
        return self.buttonState[@intCast(usize, button)];
    }

    pub fn getMouseDelta(self: *SampleBase) float2 {
        return self.mouseDelta;
    }

    pub fn getMouseWheel(self: *SampleBase) f32 {
        return self.mouseWheel;
    }

    pub fn getWindowResolution(self: *SampleBase) uint2 {
        return self.windowResolution;
    }

    pub fn getOutputResolution(self: *SampleBase) uint2 {
        return self.outputResolution;
    }

    pub fn getWindow(self: *SampleBase) *Window {
        return self.nriWindow;
    }

    pub fn getQueuedFrameNum(self: *SampleBase) u8 {
        return if (self.vsyncInterval != 0) 2 else 3;
    }

    pub fn getOptimalSwapChainTextureNum(self: *SampleBase) u8 {
        return self.getQueuedFrameNum() + 1;
    }

    pub fn hasUserInterface(self: *SampleBase) bool {
        return self.imguiRenderer != null;
    }
};

// Example of a main entry macro
pub fn sampleMain(
    sampleType: type,
    memoryAllocationIndexForBreak: u32,
    projectName: []const u8,
) !void {
    var sample = sampleType{};
    defer sample.vtable.deinit.?(sample);
    // TODO: Parse args, create window, etc.
    if (sample.vtable.initialize(&sample, 0)) {
        // TODO: Render loop
    }
}
