const std = @import("std");
const nriframework = @import("nriframework.zig");
const types = @import("types/index.zig");

/// Swapchain abstraction for NRI. Manages per-frame semaphores, fences, and swapchain textures.
pub const Swapchain = struct {
    nri: nriframework.NRIInterface,
    device: *nriframework.c.NriDevice, // device pointer for resource creation
    swapchain: *nriframework.c.NriSwapChain,
    textures: []types.SwapChainTexture,
    image_count: usize,
    acquire_semaphores: []?*nriframework.c.NriFence,
    release_semaphores: []?*nriframework.c.NriFence,
    frame_fence: ?*nriframework.c.NriFence,
    current_image: usize = 0,

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
        var acquire_semaphores = try allocator.alloc(?*nriframework.c.NriFence, texture_num);
        var release_semaphores = try allocator.alloc(?*nriframework.c.NriFence, texture_num);
        for (textures.ptr[0..texture_num], 0..) |*tex, i| {
            // Create per-image semaphores
            var acquire: ?*nriframework.c.NriFence = null;
            var release: ?*nriframework.c.NriFence = null;
            _ = nri.core.CreateFence.?(device, nriframework.c.NRI_SWAPCHAIN_SEMAPHORE, &acquire);
            _ = nri.core.CreateFence.?(device, nriframework.c.NRI_SWAPCHAIN_SEMAPHORE, &release);
            acquire_semaphores[i] = acquire;
            release_semaphores[i] = release;
            tex.* = types.SwapChainTexture{
                .acquireSemaphore = @ptrCast(acquire),
                .releaseSemaphore = @ptrCast(release),
                .frame_fence = null,
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
            .acquire_semaphores = acquire_semaphores,
            .release_semaphores = release_semaphores,
            .frame_fence = frame_fence,
        };
    }

    pub fn deinit(self: *Swapchain, allocator: std.mem.Allocator) void {
        for (self.acquire_semaphores) |sem| if (sem) |s| self.nri.core.DestroyFence.?(s);
        for (self.release_semaphores) |sem| if (sem) |s| self.nri.core.DestroyFence.?(s);
        allocator.free(self.textures);
        allocator.free(self.acquire_semaphores);
        allocator.free(self.release_semaphores);
    }

    pub fn acquireNextImage(self: *Swapchain) !u32 {
        var image_index: u32 = 0;
        const result = self.nri.swapchain.AcquireNextTexture.?(self.swapchain, self.acquire_semaphores[image_index], &image_index);
        if (result != nriframework.c.NriResult_SUCCESS) return error.NRIAcquireNextImageFailed;
        self.current_image = image_index;
        return image_index;
    }

    pub fn present(self: *Swapchain) !void {
        const result = self.nri.swapchain.QueuePresent.?(self.swapchain, self.release_semaphores[self.current_image]);
        if (result != nriframework.c.NriResult_SUCCESS) return error.NRIPresentFailed;
    }

    pub fn getCurrentTexture(self: *Swapchain) *types.SwapChainTexture {
        return &self.textures[self.current_image];
    }
};
