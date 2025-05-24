const std = @import("std");
const types = @import("types/index.zig");

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
        // Right-handed look-at view matrix
        const eye = self.position;
        const forward = types.float3{ .x = 0, .y = 0, .z = -1 }; // TODO: rotate by orientation
        const up = types.float3{ .x = 0, .y = 1, .z = 0 };
        const center = types.float3.add(eye, forward);
        return lookAtRH(eye, center, up);
    }

    pub fn get_projection_matrix(self: *Camera) types.float4x4 {
        return perspectiveRH(self.fov, self.aspect_ratio, self.near_clip, self.far_clip);
    }

    pub fn move_camera(self: *Camera, delta: types.float3) void {
        self.position = types.float3.add(self.position, delta);
    }

    pub fn rotate_camera(_: *Camera, _: types.float3) void {
        // TODO: Implement quaternion-based rotation logic
    }

    fn lookAtRH(eye: types.float3, center: types.float3, up: types.float3) types.float4x4 {
        const f = types.float3.normalize(types.float3.sub(center, eye));
        const s = types.float3.normalize(types.float3.cross(f, up));
        const u = types.float3.cross(s, f);
        return types.float4x4{ .m = .{
            .{ s.x, u.x, -f.x, 0 },
            .{ s.y, u.y, -f.y, 0 },
            .{ s.z, u.z, -f.z, 0 },
            .{ -types.float3.dot(s, eye), -types.float3.dot(u, eye), types.float3.dot(f, eye), 1 },
        } };
    }

    fn perspectiveRH(fov_y: f32, aspect: f32, near: f32, far: f32) types.float4x4 {
        const f = 1.0 / @tan(fov_y / 2.0);
        return types.float4x4{ .m = .{
            .{ f / aspect, 0, 0, 0 },
            .{ 0, f, 0, 0 },
            .{ 0, 0, (far + near) / (near - far), -1 },
            .{ 0, 0, (2 * far * near) / (near - far), 0 },
        } };
    }
};
