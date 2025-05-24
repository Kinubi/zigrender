const std = @import("std");
const math = @import("std").math;
const types = @import("types.index.zig");

pub const Camera = struct {
    position: types.float3,
    orientation: types.quaternion,
    fov: f32,
    aspect_ratio: f32,
    near_clip: f32,
    far_clip: f32,

    pub fn init(position: types.float3, orientation: types.quaternion, fov: f32, aspect_ratio: f32, near_clip: f32, far_clip: f32) Camera {
        return Camera{
            .position = position,
            .orientation = orientation,
            .fov = fov,
            .aspect_ratio = aspect_ratio,
            .near_clip = near_clip,
            .far_clip = far_clip,
        };
    }

    pub fn get_view_matrix(self: *Camera) types.float4x4 {
        // Implement view matrix calculation based on position and orientation
        // Placeholder implementation
        return types.float4x4.identity();
    }

    pub fn get_projection_matrix(self: *Camera) types.float4x4 {
        // Implement projection matrix calculation based on FOV, aspect ratio, and clipping planes
        // Placeholder implementation
        return types.float4x4.identity();
    }

    pub fn move_camera(self: *Camera, delta: types.float3) void {
        self.position += delta;
    }

    pub fn rotate_camera(self: *Camera, delta: types.float3) void {
        // Implement rotation logic
    }
};