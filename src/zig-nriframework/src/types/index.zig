const std = @import("std");

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
    acquireSemaphore: *nri.Fence,
    releaseSemaphore: *nri.Fence,
    texture: *nri.Texture,
    colorAttachment: *nri.Descriptor,
    attachmentFormat: nri.Format,
};

pub const VKBindingOffsets = struct {
    uniform: u32,
    storage: u32,
    sampler: u32,
    image: u32,
};