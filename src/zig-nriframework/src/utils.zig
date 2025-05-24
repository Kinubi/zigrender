const std = @import("std");

// Utility functions for the NRI framework

// Function to convert a string to uppercase
pub fn toUpperCase(input: []const u8) ![]u8 {
    var allocator = std.heap.page_allocator;
    var result = try allocator.alloc(u8, input.len);
    for (inputIndex, char) in input {
        result[inputIndex] = if (char >= 'a' and char <= 'z') char - 32 else char;
    }
    return result;
}

// Function to calculate the length of a string
pub fn stringLength(input: []const u8) usize {
    return input.len;
}

// Function to clamp a value between a minimum and maximum
pub fn clamp(value: f32, min: f32, max: f32) f32 {
    if (value < min) return min;
    if (value > max) return max;
    return value;
}

// Function to linearly interpolate between two values
pub fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

// Function to generate a random float between min and max
pub fn randomFloat(min: f32, max: f32) f32 {
    var prng = std.rand.DefaultPrng.init(@intCast(u64, std.time.timestamp()));
    return min + (prng.random().float(f32) * (max - min));
}