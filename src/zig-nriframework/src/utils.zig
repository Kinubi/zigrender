const std = @import("std");

// Utility functions for the NRI framework

// Function to convert a string to uppercase
fn toUpperCase(input: []const u8) []u8 {
    var allocator = std.heap.page_allocator;
    var result = try allocator.alloc(u8, input.len);
    for (inputIndex, char) in input {
        result[inputIndex] = if (char >= 'a' and char <= 'z') {
            char - 32 // Convert to uppercase
        } else {
            char
        };
    }
    return result;
}

// Function to calculate the length of a string
fn stringLength(input: []const u8) usize {
    return input.len;
}

// Function to clamp a value between a minimum and maximum
fn clamp(value: f32, min: f32, max: f32) f32 {
    if (value < min) {
        return min;
    } else if (value > max) {
        return max;
    }
    return value;
}

// Function to generate a random float between min and max
fn randomFloat(min: f32, max: f32) f32 {
    const rng = std.rand.DefaultPrng.init(std.time.timestamp());
    return min + (rng.random() % (max - min));
}