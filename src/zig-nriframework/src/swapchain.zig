const std = @import("std");
const nriframework = @import("nriframework.zig");
const types = @import("types/index.zig");
const raytracing_mod = @import("raytracing.zig");

/// Swapchain abstraction for NRI. Manages per-frame semaphores, fences, and swapchain textures.
pub const Swapchain = struct {
    nri: nriframework.NRIInterface,
    device: *nriframework.c.NriDevice, // device pointer for resource creation
    swapchain: *nriframework.c.NriSwapChain,
    textures: []types.SwapChainTexture,
    image_count: usize,
    frame_fence: ?*nriframework.c.NriFence,
    current_image: u32 = 0,

    /// Initializes the swapchain, allocates per-image semaphores/fences, and queries swapchain textures.
    pub fn init(
        nri: nriframework.NRIInterface,
        device: *nriframework.c.NriDevice,
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
                .acquireSemaphore = @ptrCast(acquire),
                .releaseSemaphore = @ptrCast(release),

                .texture = @ptrCast(textures_ptr[i]),
                .colorAttachment = null,
                .attachmentFormat = 0,
            };
        }
        return Swapchain{
            .nri = nri,
            .device = device,
            .swapchain = swapchain,
            .textures = textures,
            .image_count = texture_num,
            .frame_fence = frame_fence,
            .current_image = 0,
        };
    }

    pub fn deinit(self: *Swapchain, allocator: std.mem.Allocator) void {
        for (self.textures) |tex| {
            if (tex.acquireSemaphore) |s| self.nri.core.DestroyFence.?(@ptrCast(s));
            if (tex.releaseSemaphore) |s| self.nri.core.DestroyFence.?(@ptrCast(s));
        }
        allocator.free(self.textures);
    }

    pub fn acquireNextImage(self: *Swapchain) !u32 {
        var image_index: u32 = 0;
        // Use the correct acquireSemaphore for the image being acquired
        // Vulkan expects the semaphore to be valid and unique per image
        // Use the image index as returned by AcquireNextTexture
        // Pass a valid semaphore for each image
        const result = self.nri.swapchain.AcquireNextTexture.?(self.swapchain, self.textures[self.current_image].acquireSemaphore, &image_index);
        if (result == nriframework.c.NriResult_OUT_OF_DATE) {
            return error.SwapchainOutOfDate;
        } else if (result != nriframework.c.NriResult_SUCCESS) {
            return error.NRIAcquireNextImageFailed;
        }
        self.current_image = image_index;
        return image_index;
    }

    pub fn present(self: *Swapchain) !void {
        const result = self.nri.swapchain.QueuePresent.?(self.swapchain, self.textures[self.current_image].releaseSemaphore);
        if (result != nriframework.c.NriResult_SUCCESS) return error.NRIPresentFailed;
    }

    pub fn getCurrentTexture(self: *Swapchain) *types.SwapChainTexture {
        return &self.textures[self.current_image];
    }

    /// Record and submit a frame: handles all per-frame command buffer logic, barriers, ray dispatch, and submission.
    pub fn record_and_submit(self: *Swapchain, raytracing: *raytracing_mod.Raytracing, frame_index: u32, image_index: u32) !void {
        // Get frame and command buffer from raytracing
        var frame = &raytracing.frames[frame_index % raytracing.frames.len];
        self.nri.core.ResetCommandAllocator.?(frame.command_allocator);
        if (self.nri.core.BeginCommandBuffer.?(frame.command_buffer, raytracing.descriptor_pool) != nriframework.c.NriResult_SUCCESS)
            return error.NRIBeginCommandBufferFailed;
        // Barriers: swapchain to COPY_DEST, raytracing output to GENERAL
        const swapchain_tex = &self.textures[image_index];
        const barrier_swapchain_to_copy_dst = nriframework.c.NriTextureBarrierDesc{
            .texture = @ptrCast(swapchain_tex.texture),
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
        const rt_output_before = if (frame_index == 0)
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
        self.nri.core.CmdCopyTexture.?(frame.command_buffer, @ptrCast(swapchain_tex.texture), null, raytracing.raytracing_output, null);
        // Swapchain to PRESENT
        const barrier_swapchain_to_present = nriframework.c.NriTextureBarrierDesc{
            .texture = @ptrCast(swapchain_tex.texture),
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
        // Submit
        if (swapchain_tex.acquireSemaphore == null)
            return error.NullAcquireSemaphore;
        if (swapchain_tex.releaseSemaphore == null)
            return error.NullReleaseSemaphore;
        // Prepare submit descs
        var texture_acquired_fence = nriframework.c.NriFenceSubmitDesc{
            .fence = swapchain_tex.acquireSemaphore,
            .stages = nriframework.c.NriStageBits_ALL,
        };
        const rendering_finished_fence = nriframework.c.NriFenceSubmitDesc{
            .fence = swapchain_tex.releaseSemaphore,
        };
        const frame_fence_desc = nriframework.c.NriFenceSubmitDesc{
            .fence = self.frame_fence,
            .value = 1 + frame_index,
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
        self.nri.core.QueueSubmit.?(raytracing.queue, &submit_desc);
    }
};
