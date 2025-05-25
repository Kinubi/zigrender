const std = @import("std");
const nriframework = @import("../nriframework.zig");

// Type aliases for framework compatibility
pub const Fence = opaque {};
pub const Texture = opaque {};
pub const Descriptor = opaque {};
pub const Format = u32;

pub const Key = enum {
    A,
    B,
    C,
    D,
    E,
    F,
    G,
    H,
    I,
    J,
    K,
    L,
    M,
    N,
    O,
    P,
    Q,
    R,
    S,
    T,
    U,
    V,
    W,
    X,
    Y,
    Z,
    NUM,
};

pub const Button = enum {
    Left,
    Right,
    Middle,
    NUM,
};

pub const float2 = struct {
    x: f32,
    y: f32,
};

pub const uint2 = struct {
    x: u32,
    y: u32,
};

pub const SwapChainTexture = struct {
    acquireSemaphore: ?*Fence,
    releaseSemaphore: ?*Fence,
    frame_fence: ?*Fence, // Per-image fence for CPU-GPU sync
    texture: ?*Texture,
    colorAttachment: ?*Descriptor,
    attachmentFormat: Format,
    // Optionally, track last known layout for this image if needed
};

pub const VKBindingOffsets = struct {
    uniform: u32,
    storage: u32,
    sampler: u32,
    image: u32,
};

pub const float3 = struct {
    x: f32,
    y: f32,
    z: f32,
    pub fn add(a: float3, b: float3) float3 {
        return float3{ .x = a.x + b.x, .y = a.y + b.y, .z = a.z + b.z };
    }
    pub fn sub(a: float3, b: float3) float3 {
        return float3{ .x = a.x - b.x, .y = a.y - b.y, .z = a.z - b.z };
    }
    pub fn scale(a: float3, s: f32) float3 {
        return float3{ .x = a.x * s, .y = a.y * s, .z = a.z * s };
    }
    pub fn dot(a: float3, b: float3) f32 {
        return a.x * b.x + a.y * b.y + a.z * b.z;
    }
    pub fn cross(a: float3, b: float3) float3 {
        return float3{
            .x = a.y * b.z - a.z * b.y,
            .y = a.z * b.x - a.x * b.z,
            .z = a.x * b.y - a.y * b.x,
        };
    }
    pub fn length(a: float3) f32 {
        return @sqrt(a.x * a.x + a.y * a.y + a.z * a.z);
    }
    pub fn normalize(a: float3) float3 {
        const len = float3.length(a);
        return if (len > 0.0) float3.scale(a, 1.0 / len) else a;
    }
};

pub const float4 = struct {
    x: f32,
    y: f32,
    z: f32,
    w: f32,
};

pub const quaternion = struct {
    x: f32,
    y: f32,
    z: f32,
    w: f32,
    pub fn identity() quaternion {
        return quaternion{ .x = 0, .y = 0, .z = 0, .w = 1 };
    }
    // TODO: Add quaternion math (from axis/angle, multiply, rotate)
};

pub const float4x4 = struct {
    m: [4][4]f32,
    pub fn identity() float4x4 {
        return float4x4{ .m = .{
            .{ 1, 0, 0, 0 },
            .{ 0, 1, 0, 0 },
            .{ 0, 0, 1, 0 },
            .{ 0, 0, 0, 1 },
        } };
    }
    // TODO: Add lookAtRH, perspectiveRH, multiply, etc.
};

pub const QueuedFrame = struct {
    command_allocator: ?*nriframework.c.NriCommandAllocator = null,
    command_buffer: ?*nriframework.c.NriCommandBuffer = null,
    // Add more fields as needed for per-frame resources
};

pub const FrameData = struct {
    // Add fields as needed for per-frame data
    // Example:
    command_allocator: ?*nriframework.c.NriCommandAllocator = null,
    command_buffer: ?*nriframework.c.NriCommandBuffer = null,
};
