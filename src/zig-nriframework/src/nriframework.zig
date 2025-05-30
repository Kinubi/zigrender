const std = @import("std");
const types = @import("types/index.zig");
const camera = @import("camera.zig");
const controls = @import("controls.zig");
const timer = @import("timer.zig");
const helper = @import("helper.zig");
const utils = @import("utils.zig");
const window_mod = @import("window.zig");

// Import all NRI and extension headers as in the C++ framework
pub const c = @cImport({
    @cDefine("GLFW_EXPOSE_NATIVE_WAYLAND", "1");
    @cInclude("GLFW/glfw3.h");
    @cInclude("GLFW/glfw3native.h");
    @cInclude("NRIDescs.h");
    @cInclude("NRI.h");
    @cInclude("Extensions/NRIDeviceCreation.h");
    @cInclude("Extensions/NRIHelper.h");
    @cInclude("Extensions/NRIImgui.h");
    @cInclude("Extensions/NRILowLatency.h");
    @cInclude("Extensions/NRIMeshShader.h");
    @cInclude("Extensions/NRIRayTracing.h");
    @cInclude("Extensions/NRIResourceAllocator.h");
    @cInclude("Extensions/NRIStreamer.h");
    @cInclude("Extensions/NRISwapChain.h");
    @cInclude("Extensions/NRIUpscaler.h");
    // Add any other required includes here
});

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
pub const Window = window_mod.Window;

// NRIInterface struct to hold all interfaces
pub const NRIInterface = struct {
    core: c.NriCoreInterface,
    swapchain: c.NriSwapChainInterface,
    helper: c.NriHelperInterface,
    raytracing: c.NriRayTracingInterface,
};

pub const NriTopLevelInstance = extern struct {
    transform: [3][4]f32,
    instanceId_mask: u32,
    sbtOffset_flags: u32,
    accelerationStructureHandle: u64,
};
pub const NRI_TOP_LEVEL_INSTANCE_SIZE = @sizeOf(NriTopLevelInstance);
/// Get all NRI interfaces for a device
pub fn getInterfaces(device: *c.NriDevice, out: *NRIInterface) !void {
    if (c.nriGetInterface(device, "nri::CoreInterface", @sizeOf(c.NriCoreInterface), &out.core) != c.NriResult_SUCCESS)
        return error.NRICoreInterfaceFailed;
    if (c.nriGetInterface(device, "nri::SwapChainInterface", @sizeOf(c.NriSwapChainInterface), &out.swapchain) != c.NriResult_SUCCESS)
        return error.NRISwapChainInterfaceFailed;
    if (c.nriGetInterface(device, "nri::HelperInterface", @sizeOf(c.NriHelperInterface), &out.helper) != c.NriResult_SUCCESS)
        return error.NRIHelperInterfaceFailed;
    if (c.nriGetInterface(device, "nri::RayTracingInterface", @sizeOf(c.NriRayTracingInterface), &out.raytracing) != c.NriResult_SUCCESS)
        return error.NRIRayTracingInterfaceFailed;
}

// Main entry point for a sample using the framework (Wayland only)
pub fn sampleMain(
    sampleType: type,
    _: u32, // unused
    _: []const u8, // unused
) !void {
    var sample = sampleType{};
    defer sample.vtable.deinit.?(sample);
    // Wayland window creation
    sample.nriWindow = try window_mod.createWindow(1280, 720);
    // TODO: Add device creation, swapchain, and graphics API selection here
    if (sample.vtable.initialize(&sample, 0)) {
        // Main render loop
        while (!sample.nriWindow.should_close) {
            window_mod.pollEvents(&sample.nriWindow);
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
    window_mod.destroyWindow(&sample.nriWindow);
    // TODO: Add cleanup for device, swapchain, Imgui, and other resources
}

pub fn createDevice(adapter_index: u32, enable_api_validation: bool, enable_nri_validation: bool) !*c.NriDevice {
    var adapterDescs: [8]c.NriAdapterDesc = undefined;
    var adapterDescNum: u32 = 8;
    if (c.nriEnumerateAdapters(&adapterDescs, &adapterDescNum) != c.NriResult_SUCCESS or adapterDescNum == 0)
        return error.NRIAdapterEnumerationFailed;
    var device: ?*c.NriDevice = null;
    var deviceDesc = c.NriDeviceCreationDesc{
        .graphicsAPI = c.NriGraphicsAPI_VK,
        .enableGraphicsAPIValidation = enable_api_validation,
        .enableNRIValidation = enable_nri_validation,
        .adapterDesc = &adapterDescs[adapter_index],
        .vkBindingOffsets = c.NriVKBindingOffsets{},
    };
    if (c.nriCreateDevice(&deviceDesc, &device) != c.NriResult_SUCCESS or device == null)
        return error.NRIDeviceCreationFailed;
    return device.?;
}

pub fn createSwapChain(
    iface: *const c.NriSwapChainInterface,
    device: *c.NriDevice,
    win: *window_mod.Window,
    queue: ?*c.NriQueue,
    width: u32,
    height: u32,
    format: u32,
    vsync: u32, // ignored, always use FIFO
) !*c.NriSwapChain {
    if (win.handle == null) return error.InvalidWindowHandle;
    var c_window: c.struct_NriWindow = undefined;
    c_window.wayland.display = win.nri_window.display;
    c_window.wayland.surface = win.nri_window.surface;
    var queue_frame_count: u32 = 2; // Default to 2 frames in flight
    if (vsync == 0) {
        queue_frame_count = 2;
    } else {
        queue_frame_count = 3;
    }
    var swapChainDesc = c.NriSwapChainDesc{
        .window = c_window,
        .queue = queue,
        .width = @intCast(width),
        .height = @intCast(height),
        .verticalSyncInterval = @intCast(vsync), // Always use FIFO present mode for robust support
        .format = @intCast(format),
        .textureNum = 3,
        .queuedFrameNum = @intCast(queue_frame_count),
        .waitable = false,
        .allowLowLatency = false,
    };
    var swapChain: ?*c.NriSwapChain = null;
    if (iface.CreateSwapChain.?(device, &swapChainDesc, &swapChain) != c.NriResult_SUCCESS or swapChain == null)
        return error.NRISwapChainCreationFailed;
    return swapChain.?;
}

pub fn getQueue(core: *const c.NriCoreInterface, device: *c.NriDevice, queue_type: u32, queue_index: u32) !*c.NriQueue {
    var queue: ?*c.NriQueue = null;
    if (core.GetQueue.?(device, @intCast(queue_type), queue_index, &queue) != c.NriResult_SUCCESS or queue == null)
        return error.NRIQueueCreationFailed;
    return queue.?;
}

pub fn createFence(core: *const c.NriCoreInterface, device: *c.NriDevice, initial_value: u64) !*c.NriFence {
    var fence: ?*c.NriFence = null;
    if (core.CreateFence.?(device, initial_value, &fence) != c.NriResult_SUCCESS or fence == null)
        return error.NRIFenceCreationFailed;
    return fence.?;
}

pub fn acquireNextTexture(swapchain: *const c.NriSwapChainInterface, swap_chain: *c.NriSwapChain, acquire_semaphore: ?*c.NriFence, out_index: *u32) !void {
    std.debug.print("AcquireNextTexture ptr: {any}\n", .{swapchain.AcquireNextTexture});
    std.debug.print("swap_chain ptr: {any}\n", .{swap_chain});
    std.debug.print("acquire_semaphore ptr: {any}\n", .{acquire_semaphore});
    std.debug.print("out_index: {any}\n", .{out_index.*});
    if (swapchain.AcquireNextTexture.?(swap_chain, acquire_semaphore, out_index) != c.NriResult_SUCCESS)
        return error.NRIAcquireNextTextureFailed;
    std.debug.print("out_index: {any}\n", .{out_index.*});
}

pub fn queuePresent(
    swapchain: *const c.NriSwapChainInterface,
    swap_chain: *c.NriSwapChain,
    release_semaphore: ?*c.NriFence,
) !void {
    if (swapchain.QueuePresent.?(swap_chain, release_semaphore) != c.NriResult_SUCCESS)
        return error.NRIQueuePresentFailed;
}

pub fn getQueuedFrameNum(vsync_enabled: bool) u32 {
    // Match NRIFramework: 2 for vsync, 3 for no vsync (triple buffering)
    return if (vsync_enabled) 2 else 3;
}
