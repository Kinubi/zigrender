const std = @import("std");
const wayland = @import("zig-nriframework/src/wayland_window.zig");
const nriframework = @import("zig-nriframework/src/nriframework.zig");

const MAX_FRAMES_IN_FLIGHT = 2;
const SWAPCHAIN_TEXTURE_NUM = 2;

const QueuedFrame = struct {
    command_allocator: ?*nriframework.c.NriCommandAllocator = null,
    command_buffer: ?*nriframework.c.NriCommandBuffer = null,
};

const SwapChainTexture = struct {
    acquire_semaphore: ?*nriframework.c.NriFence = null,
    release_semaphore: ?*nriframework.c.NriFence = null,
    texture: ?*nriframework.c.NriTexture = null,
    // ... add more as needed ...
};

const Sample = struct {
    device: *nriframework.c.NriDevice,
    nri: nriframework.NRIInterface,
    window: wayland.WaylandWindow,
    queue: *nriframework.c.NriQueue,
    swapchain: *nriframework.c.NriSwapChain,
    fence: *nriframework.c.NriFence,
    // Raytracing resources
    frames: [MAX_FRAMES_IN_FLIGHT]QueuedFrame = undefined,
    swapchain_textures: [SWAPCHAIN_TEXTURE_NUM]SwapChainTexture = undefined,
    pipeline: ?*nriframework.c.NriPipeline = null,
    pipeline_layout: ?*nriframework.c.NriPipelineLayout = null,
    descriptor_pool: ?*nriframework.c.NriDescriptorPool = null,
    descriptor_set: ?*nriframework.c.NriDescriptorSet = null,
    raytracing_output: ?*nriframework.c.NriTexture = null,
    raytracing_output_view: ?*nriframework.c.NriDescriptor = null,
    blas: ?*nriframework.c.NriAccelerationStructure = null,
    tlas: ?*nriframework.c.NriAccelerationStructure = null,
    tlas_descriptor: ?*nriframework.c.NriDescriptor = null,
    shader_table: ?*nriframework.c.NriBuffer = null,
    shader_table_memory: ?*nriframework.c.NriMemory = null,
    // ... add more as needed ...
};

fn create_resources(sample: *Sample) !void {
    // Command allocators and buffers for frames in flight
    var i: usize = 0;
    while (i < MAX_FRAMES_IN_FLIGHT) : (i += 1) {
        var cmd_alloc: ?*nriframework.c.NriCommandAllocator = null;
        if (sample.nri.core.CreateCommandAllocator.?(sample.queue, &cmd_alloc) != nriframework.c.NriResult_SUCCESS or cmd_alloc == null)
            return error.NRICommandAllocatorFailed;
        sample.frames[i].command_allocator = cmd_alloc;
        var cmd_buf: ?*nriframework.c.NriCommandBuffer = null;
        if (sample.nri.core.CreateCommandBuffer.?(cmd_alloc, &cmd_buf) != nriframework.c.NriResult_SUCCESS or cmd_buf == null)
            return error.NRICommandBufferFailed;
        sample.frames[i].command_buffer = cmd_buf;
    }
    // TODO: Create pipeline layout, pipeline, descriptor pool, sets, output texture/view, BLAS, TLAS, shader table, etc.
    // See C++ sample for the order and details of each step.
}

fn record_and_submit(sample: *Sample, frame_index: u32, image_index: u32) !void {
    _ = image_index;
    const frame = &sample.frames[frame_index % MAX_FRAMES_IN_FLIGHT];
    // Begin command buffer
    if (sample.nri.core.BeginCommandBuffer.?(frame.command_buffer, null) != nriframework.c.NriResult_SUCCESS)
        return error.NRIBeginCommandBufferFailed;
    // TODO: Resource barriers, CmdDispatchRays, CmdCopyTexture, CmdBarrier, etc.
    // End command buffer
    if (sample.nri.core.EndCommandBuffer.?(frame.command_buffer) != nriframework.c.NriResult_SUCCESS)
        return error.NRIEndCommandBufferFailed;
    // Submit
    var submit_desc = nriframework.c.NriQueueSubmitDesc{
        .commandBuffers = &frame.command_buffer,
        .commandBufferNum = 1,
        .waitFences = null,
        .waitFenceNum = 0,
        .signalFences = null,
        .signalFenceNum = 0,
    };
    sample.nri.core.QueueSubmit.?(sample.queue, &submit_desc);
}

pub fn main() !void {
    // 1. Create the window
    var window = try wayland.createWindow(800, 600);
    defer wayland.destroyWindow(&window);

    // 2. Create device
    const device = try nriframework.createDevice(0, true, true);
    defer nriframework.c.nriDestroyDevice(device);

    // 3. Get all NRI interfaces
    var nri: nriframework.NRIInterface = undefined;
    try nriframework.getInterfaces(device, &nri);

    // 4. Get graphics queue
    const queue = try nriframework.getQueue(&nri.core, device, nriframework.c.NriQueueType_GRAPHICS, 0);

    // 5. Create swapchain
    const swapchain = try nriframework.createSwapChain(&nri.swapchain, device, &window, queue, window.width, window.height, nriframework.c.NriSwapChainFormat_BT709_G22_8BIT, 0);
    defer nri.swapchain.DestroySwapChain.?(swapchain);

    // 6. Create fence
    const fence = try nriframework.createFence(&nri.core, device, 0);
    defer nri.core.DestroyFence.?(fence);

    // 7. Sample struct
    var sample = Sample{
        .device = device,
        .nri = nri,
        .window = window,
        .queue = queue,
        .swapchain = swapchain,
        .fence = fence,
    };
    try create_resources(&sample);
    std.debug.print("NRI device, interfaces, queue, swapchain, fence, and resources created!\n", .{});
    var frame_index: u32 = 0;
    while (!sample.window.should_close) {
        wayland.pollEvents(&sample.window);
        var image_index: u32 = 0;
        try nriframework.acquireNextTexture(&sample.nri.swapchain, sample.swapchain, null, &image_index);
        try record_and_submit(&sample, frame_index, image_index);
        try nriframework.queuePresent(&sample.nri.swapchain, sample.swapchain, null);
        frame_index += 1;
        std.time.sleep(16_000_000); // ~60 FPS
    }
    std.debug.print("Window closed.\n", .{});
}
