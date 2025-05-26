const std = @import("std");
const nriframework = @import("nriframework.zig");
const types = @import("types/index.zig");
const raytracing_mod = @import("raytracing.zig");

const NUM_SWAPCHAIN_IMAGES: u32 = 3; // Number of swapchain images, can be adjusted based on requirements

/// Swapchain abstraction for NRI. Manages per-frame semaphores, fences, and swapchain textures.
pub const Swapchain = struct {
    nri: nriframework.NRIInterface,
    device: *nriframework.c.NriDevice, // device pointer for resource creation
    graphics_queue: *nriframework.c.NriQueue, // add graphics queue as a member
    swapchain: *nriframework.c.NriSwapChain,
    textures: []types.SwapChainTexture,
    image_count: usize,
    frame_fence: ?*nriframework.c.NriFence,
    current_image: u32 = 0,

    /// Initializes the swapchain, allocates per-image semaphores/fences, and queries swapchain textures.
    pub fn init(
        nri: nriframework.NRIInterface,
        device: *nriframework.c.NriDevice,
        graphics_queue: *nriframework.c.NriQueue,
        swapchain: *nriframework.c.NriSwapChain,
        frame_fence: ?*nriframework.c.NriFence,
        allocator: std.mem.Allocator,
    ) !Swapchain {
        var texture_num: u32 = 0;
        const textures_ptr = nri.swapchain.GetSwapChainTextures.?(swapchain, &texture_num);
        if (textures_ptr == null or texture_num == 0) return error.NRISwapChainTexturesFailed;
        var textures = try allocator.alloc(types.SwapChainTexture, texture_num);
        for (textures.ptr[0..texture_num], 0..) |*tex, i| {
            // Create per-image semaphores
            var acquire: ?*nriframework.c.NriFence = null;
            var release: ?*nriframework.c.NriFence = null;
            _ = nri.core.CreateFence.?(device, nriframework.c.NRI_SWAPCHAIN_SEMAPHORE, &acquire);
            _ = nri.core.CreateFence.?(device, nriframework.c.NRI_SWAPCHAIN_SEMAPHORE, &release);
            tex.* = types.SwapChainTexture{
                .acquireSemaphore = acquire,
                .releaseSemaphore = release,
                .texture = textures_ptr[i],
                .colorAttachment = null,
                .attachmentFormat = 0,
            };
        }
        return Swapchain{
            .nri = nri,
            .device = device,
            .graphics_queue = graphics_queue,
            .swapchain = swapchain,
            .textures = textures,
            .image_count = texture_num,
            .frame_fence = frame_fence,
            .current_image = 0,
        };
    }

    pub fn deinit(self: *Swapchain, allocator: std.mem.Allocator) void {
        for (self.textures) |tex| {
            if (tex.acquireSemaphore) |s| self.nri.core.DestroyFence.?(s);
            if (tex.releaseSemaphore) |s| self.nri.core.DestroyFence.?(s);
        }
        allocator.free(self.textures);
    }

    pub fn acquireNextImage(self: *Swapchain, frame_index: u32) !void {
        if (self.textures.len == 0) return error.NoSwapchainTextures;
        if (self.textures[frame_index].acquireSemaphore == null) {
            std.debug.print("[ERROR] acquireNextImage: acquireSemaphore is null for frame {}\n", .{frame_index});
            return error.NullAcquireSemaphore;
        }
        var image_index: u32 = 0;
        const result = self.nri.swapchain.AcquireNextTexture.?(self.swapchain, self.textures[frame_index].acquireSemaphore, &image_index);
        if (result == nriframework.c.NriResult_OUT_OF_DATE) {
            std.debug.print("[WARN] acquireNextImage: Swapchain out of date\n", .{});
            return error.SwapchainOutOfDate;
        } else if (result != nriframework.c.NriResult_SUCCESS) {
            std.debug.print("[ERROR] acquireNextImage: NRI error {}\n", .{result});
            return error.NRIAcquireNextImageFailed;
        }
        self.current_image = image_index;
    }

    pub fn present(self: *Swapchain) !void {
        if (self.textures.len == 0) return error.NoSwapchainTextures;
        if (self.textures[self.current_image].releaseSemaphore == null) {
            std.debug.print("[ERROR] present: releaseSemaphore is null for image {}\n", .{self.current_image});
            return error.NullReleaseSemaphore;
        }
        const result = self.nri.swapchain.QueuePresent.?(self.swapchain, self.textures[self.current_image].releaseSemaphore);
        if (result != nriframework.c.NriResult_SUCCESS) {
            std.debug.print("[ERROR] present: NRI error {}\n", .{result});
            return error.NRIPresentFailed;
        }
    }

    pub fn getCurrentTexture(self: *Swapchain) *types.SwapChainTexture {
        return &self.textures[self.current_image];
    }

    /// Record and submit a frame: handles all per-frame command buffer logic, barriers, ray dispatch, and submission.
    pub fn record_and_submit(
        self: *Swapchain,
        raytracing: *raytracing_mod.Raytracing,
        frame_index: *u32,
    ) !void {
        if (self.textures.len == 0) return error.NoSwapchainTextures;
        if (self.textures[self.current_image].acquireSemaphore == null or self.textures[self.current_image].releaseSemaphore == null) {
            std.debug.print("[ERROR] record_and_submit: Null semaphore for image {}\n", .{self.current_image});
            return error.NullSemaphore;
        }
        if (raytracing.raytracing_output == null) {
            std.debug.print("[ERROR] record_and_submit: raytracing_output is null\n", .{});
            return error.NullOutputTexture;
        }
        if (raytracing.pipeline == null or raytracing.pipeline_layout == null or raytracing.descriptor_set == null) {
            std.debug.print("[ERROR] record_and_submit: pipeline, pipeline_layout, or descriptor_set is null\n", .{});
            return error.NullPipelineOrDescriptor;
        }
        std.debug.print("Acquired image index: {}, with current frame {}\n", .{ self.current_image, frame_index.* });
        // --- Semaphore/Fence/Frame logic: match C++ sample ---
        const queued_frame_num = nriframework.getQueuedFrameNum(true); // TODO: pass actual vsync status if available
        const recycled_semaphore_index = frame_index.* % self.textures.len;
        var frame = &raytracing.frames[frame_index.* % queued_frame_num];
        // Use acquire/release semaphores as in C++
        const acquire_semaphore = self.textures[recycled_semaphore_index].acquireSemaphore;
        const release_semaphore = self.textures[self.current_image].releaseSemaphore;
        const swapchain_tex = &self.textures[self.current_image];
        // Defensive checks
        if (acquire_semaphore == null) return error.NullAcquireSemaphore;
        if (release_semaphore == null) return error.NullReleaseSemaphore;
        // Reset command allocator for this frame
        self.nri.core.ResetCommandAllocator.?(frame.command_allocator);
        if (self.nri.core.BeginCommandBuffer.?(frame.command_buffer, raytracing.descriptor_pool) != nriframework.c.NriResult_SUCCESS)
            return error.NRIBeginCommandBufferFailed;
        // Barriers: swapchain to COPY_DEST, raytracing output to GENERAL
        const barrier_swapchain_to_copy_dst = nriframework.c.NriTextureBarrierDesc{
            .texture = swapchain_tex.texture,
            .before = nriframework.c.NriAccessLayoutStage{
                .access = nriframework.c.NriAccessBits_UNKNOWN,
                .layout = nriframework.c.NriLayout_UNKNOWN,
            },
            .after = nriframework.c.NriAccessLayoutStage{
                .access = nriframework.c.NriAccessBits_COPY_DESTINATION,
                .layout = nriframework.c.NriLayout_COPY_DESTINATION,
            },
            .mipNum = 1,
            .mipOffset = 0,
        };
        var barrier_desc1 = nriframework.c.NriBarrierGroupDesc{
            .textureNum = 1,
            .textures = &barrier_swapchain_to_copy_dst,
            .bufferNum = 0,
            .buffers = null,
        };
        self.nri.core.CmdBarrier.?(frame.command_buffer, &barrier_desc1);
        // Raytracing output barrier
        const rt_output_before = if (frame_index.* == 0)
            nriframework.c.NriAccessLayoutStage{
                .access = nriframework.c.NriAccessBits_UNKNOWN,
                .layout = nriframework.c.NriLayout_UNKNOWN,
            }
        else
            nriframework.c.NriAccessLayoutStage{
                .access = nriframework.c.NriAccessBits_COPY_SOURCE,
                .layout = nriframework.c.NriLayout_COPY_SOURCE,
            };
        const barrier_rt_output_to_general = nriframework.c.NriTextureBarrierDesc{
            .texture = raytracing.raytracing_output,
            .before = rt_output_before,
            .after = nriframework.c.NriAccessLayoutStage{
                .access = nriframework.c.NriAccessBits_SHADER_RESOURCE_STORAGE,
                .layout = nriframework.c.NriLayout_SHADER_RESOURCE_STORAGE,
            },
            .mipNum = 1,
            .mipOffset = 0,
        };
        var barrier_desc2 = nriframework.c.NriBarrierGroupDesc{
            .textureNum = 1,
            .textures = &barrier_rt_output_to_general,
            .bufferNum = 0,
            .buffers = null,
        };
        self.nri.core.CmdBarrier.?(frame.command_buffer, &barrier_desc2);
        // Bind pipeline, layout, descriptor set
        self.nri.core.CmdSetPipelineLayout.?(frame.command_buffer, raytracing.pipeline_layout);
        self.nri.core.CmdSetPipeline.?(frame.command_buffer, raytracing.pipeline);
        self.nri.core.CmdSetDescriptorSet.?(frame.command_buffer, 0, raytracing.descriptor_set, null);
        // Dispatch rays
        const identifier_size = raytracing.shader_table_stride;
        var dispatch_desc = nriframework.c.NriDispatchRaysDesc{
            .raygenShader = .{
                .buffer = raytracing.shader_table,
                .offset = raytracing.shader_table_raygen_offset,
                .size = identifier_size,
                .stride = identifier_size,
            },
            .missShaders = .{
                .buffer = raytracing.shader_table,
                .offset = raytracing.shader_table_miss_offset,
                .size = identifier_size,
                .stride = identifier_size,
            },
            .hitShaderGroups = .{
                .buffer = raytracing.shader_table,
                .offset = raytracing.shader_table_hit_offset,
                .size = identifier_size,
                .stride = identifier_size,
            },
            .x = 800, // fallback to static size, or replace with raytracing.get_dispatch_width() if available
            .y = 600, // fallback to static size, or replace with raytracing.get_dispatch_height() if available
            .z = 1,
        };
        self.nri.raytracing.CmdDispatchRays.?(frame.command_buffer, &dispatch_desc);
        // Raytracing output to COPY_SRC
        const barrier_rt_output_to_copy_src = nriframework.c.NriTextureBarrierDesc{
            .texture = raytracing.raytracing_output,
            .before = nriframework.c.NriAccessLayoutStage{
                .access = nriframework.c.NriAccessBits_SHADER_RESOURCE_STORAGE,
                .layout = nriframework.c.NriLayout_SHADER_RESOURCE_STORAGE,
            },
            .after = nriframework.c.NriAccessLayoutStage{
                .layout = nriframework.c.NriLayout_COPY_SOURCE,
            },
            .mipNum = 1,
            .mipOffset = 0,
        };
        var barrier_desc3 = nriframework.c.NriBarrierGroupDesc{
            .textureNum = 1,
            .textures = &barrier_rt_output_to_copy_src,
            .bufferNum = 0,
            .buffers = null,
        };
        self.nri.core.CmdBarrier.?(frame.command_buffer, &barrier_desc3);
        // Copy raytracing output to swapchain
        self.nri.core.CmdCopyTexture.?(frame.command_buffer, swapchain_tex.texture, null, raytracing.raytracing_output, null);
        // Swapchain to PRESENT
        const barrier_swapchain_to_present = nriframework.c.NriTextureBarrierDesc{
            .texture = swapchain_tex.texture,
            .before = nriframework.c.NriAccessLayoutStage{
                .layout = nriframework.c.NriLayout_COPY_DESTINATION,
            },
            .after = nriframework.c.NriAccessLayoutStage{
                .layout = nriframework.c.NriLayout_PRESENT,
            },
            .mipNum = 1,
            .mipOffset = 0,
        };
        var barrier_desc4 = nriframework.c.NriBarrierGroupDesc{
            .textureNum = 1,
            .textures = &barrier_swapchain_to_present,
            .bufferNum = 0,
            .buffers = null,
        };
        self.nri.core.CmdBarrier.?(frame.command_buffer, &barrier_desc4);
        if (self.nri.core.EndCommandBuffer.?(frame.command_buffer) != nriframework.c.NriResult_SUCCESS)
            return error.NRIEndCommandBufferFailed;
        // Submit: match C++
        var texture_acquired_fence = nriframework.c.NriFenceSubmitDesc{
            .fence = acquire_semaphore,
            .stages = nriframework.c.NriStageBits_ALL,
        };
        const rendering_finished_fence = nriframework.c.NriFenceSubmitDesc{
            .fence = release_semaphore,
        };
        const frame_fence_desc = nriframework.c.NriFenceSubmitDesc{
            .fence = self.frame_fence,
            .value = 1 + frame_index.*,
        };
        var signal_fences = [_]nriframework.c.NriFenceSubmitDesc{ rendering_finished_fence, frame_fence_desc };
        var submit_desc = nriframework.c.NriQueueSubmitDesc{
            .commandBuffers = &frame.command_buffer,
            .commandBufferNum = 1,
            .waitFences = &texture_acquired_fence,
            .waitFenceNum = 1,
            .signalFences = &signal_fences,
            .signalFenceNum = 2,
        };
        self.nri.core.QueueSubmit.?(self.graphics_queue, &submit_desc);
        // Present: always use the release semaphore for the current image
        try self.present();
        // Advance frame index
        frame_index.* = (frame_index.* + 1) % queued_frame_num;
    }
};
