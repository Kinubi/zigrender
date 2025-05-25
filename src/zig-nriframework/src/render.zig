const std = @import("std");
const nriframework = @import("nriframework.zig");
const swapchain_mod = @import("swapchain.zig");
const raytracing_mod = @import("raytracing.zig");
const types = @import("types/index.zig");
const WindowAbstraction = @import("window.zig");

/// Main render loop. Handles window events, swapchain presentation, and per-frame raytracing dispatch.
pub fn main_loop(
    allocator: std.mem.Allocator,
    nri: nriframework.NRIInterface,
    swapchain: *swapchain_mod.Swapchain,
    raytracing: *raytracing_mod.Raytracing,
    frame_fence: ?*nriframework.c.NriFence,
    window: *WindowAbstraction.Window,
) !void {
    var last_extent = WindowAbstraction.getFramebufferSize(window);
    while (WindowAbstraction.isOpen(window)) {
        WindowAbstraction.pollEvents(window);
        const extent = WindowAbstraction.getFramebufferSize(window);
        if (extent.width != last_extent.width or extent.height != last_extent.height) {
            // Wait for device idle or all fences
            if (frame_fence != null) _ = nri.core.Wait.?(frame_fence, 0);
            // Recreate swapchain
            swapchain.deinit(allocator);
            swapchain.* = try swapchain_mod.Swapchain.init(
                nri,
                swapchain.device,
                swapchain.swapchain, // If needed, re-create the underlying NRI swapchain here
                frame_fence,
                allocator,
            );
            // Fully recreate raytracing output and descriptor resources
            try raytracing.create_raytracing_output();
            try raytracing.create_descriptor_set();
            try raytracing.create_shader_table();
            raytracing.update_dispatch_dimensions(extent.width, extent.height);
            last_extent = extent;
        }

        const image_index = swapchain.acquireNextImage() catch |err| {
            if (err == error.SwapchainOutOfDate) {
                std.debug.print("Swapchain out of date, recreating...\n", .{});
                // Wait for device idle or all fences before recreating
                if (frame_fence != null) _ = nri.core.Wait.?(frame_fence, 1);
                swapchain.deinit(allocator);
                swapchain.* = try swapchain_mod.Swapchain.init(
                    nri,
                    swapchain.device,
                    swapchain.swapchain,
                    frame_fence,
                    allocator,
                );
                try raytracing.create_raytracing_output();
                try raytracing.create_descriptor_set();
                try raytracing.create_shader_table();
                raytracing.update_dispatch_dimensions(extent.width, extent.height);
                last_extent = extent;
                continue;
            }
            std.debug.print("acquireNextImage failed: {any}\n", .{err});
            return err;
        };
        try swapchain.record_and_submit(raytracing, 0, image_index);
        try swapchain.present();
    }
    if (frame_fence != null) _ = nri.core.Wait.?(frame_fence, 1);
}
