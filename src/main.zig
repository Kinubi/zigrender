const std = @import("std");
const nriframework = @import("zig-nriframework/src/nriframework.zig");
const swapchain_mod = @import("zig-nriframework/src/swapchain.zig");
const raytracing_mod = @import("zig-nriframework/src/raytracing.zig");
const render_mod = @import("zig-nriframework/src/render.zig");
const types = @import("zig-nriframework/src/types/index.zig");
const WindowAbstraction = @import("zig-nriframework/src/window.zig");

/// Entry point for the application. Sets up window, NRI device, swapchain, raytracing, and main render loop.
pub fn main() !void {
    const allocator = std.heap.page_allocator;
    // Initialize window abstraction (must provide getFramebufferSize, pollEvents, isOpen)
    var window = try WindowAbstraction.createWindow(1280, 720);
    const window_ptr = &window;

    // Initialize NRI device and interfaces
    const nri_device = try nriframework.createDevice(0, false, false);
    var nri: nriframework.NRIInterface = undefined;
    try nriframework.getInterfaces(nri_device, &nri);
    const nri_queue = try nriframework.getQueue(&nri.core, nri_device, nriframework.c.NriQueueType_GRAPHICS, 0);

    // Create a frame fence for CPU-GPU sync (must not be null!)
    var frame_fence: ?*nriframework.c.NriFence = null;
    if (nri.core.CreateFence.?(nri_device, 0, &frame_fence) != nriframework.c.NriResult_SUCCESS or frame_fence == null) {
        std.debug.print("Failed to create frame fence!\n", .{});
        return error.NRICreateFrameFenceFailed;
    }

    // Create the NRI swapchain using the interface and device
    // You must call createSwapChain from nriframework.zig, not use nri.swapchain directly
    // Use the abstraction function, not a struct method
    const fb_size = WindowAbstraction.getFramebufferSize(window_ptr);
    const swapchain_ptr = try nriframework.createSwapChain(
        &nri.swapchain,
        nri_device,
        window_ptr,
        nri_queue, // pass the queue pointer
        fb_size.width,
        fb_size.height,
        0, // format (choose appropriate format)
        1, // vsync
    );
    var swapchain = try swapchain_mod.Swapchain.init(
        nri,
        nri_device,
        nri_queue, // pass the graphics queue
        swapchain_ptr,
        frame_fence,
        allocator,
    );

    // Initialize Raytracing
    // Get vsync status (verticalSyncInterval) from swapchain or config
    const vsync_enabled = true; // TODO: query from config or swapchain if dynamic
    const queued_frame_num = nriframework.getQueuedFrameNum(vsync_enabled);
    var queued_frames = try allocator.alloc(types.QueuedFrame, queued_frame_num);
    for (queued_frames) |*qf| qf.* = .{};
    _ = &queued_frames; // Mark as used to avoid 'never mutated' warning
    const rgen_spv = @embedFile("shaders/RayTracingTriangle.rgen.hlsl.spv");
    const rmiss_spv = @embedFile("shaders/RayTracingTriangle.rmiss.hlsl.spv");
    const rchit_spv = @embedFile("shaders/RayTracingTriangle.rchit.hlsl.spv");
    // Construct Raytracing only via init, and use the returned value
    var raytracing = try raytracing_mod.Raytracing.init(
        allocator,
        &swapchain, // pass the abstracted Swapchain
        frame_fence,
        swapchain.textures,
        queued_frames,
        rgen_spv,
        rmiss_spv,
        rchit_spv,
    );
    // You may need to call create_blas_tlas with your scene's instance array here

    // Main render loop
    try render_mod.main_loop(
        allocator,
        nri,
        &swapchain,
        &raytracing,
        frame_fence,
        window_ptr,
    );

    // Cleanup
    swapchain.deinit(allocator);
    WindowAbstraction.destroyWindow(window_ptr);
}
