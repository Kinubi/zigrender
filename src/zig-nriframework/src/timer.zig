const std = @import("std");

pub const Timer = struct {
    start_time: u64,
    elapsed_time: u64,

    pub fn init() Timer {
        return Timer{
            .start_time = std.time.milliTimestamp(),
            .elapsed_time = 0,
        };
    }

    pub fn reset(self: *Timer) void {
        self.start_time = std.time.milliTimestamp();
        self.elapsed_time = 0;
    }

    pub fn update(self: *Timer) void {
        self.elapsed_time = std.time.milliTimestamp() - self.start_time;
    }

    pub fn getElapsedTime(self: *Timer) u64 {
        return self.elapsed_time;
    }

    pub fn getFrameRate(self: *Timer, frame_count: u64) u64 {
        return frame_count * 1000 / self.elapsed_time;
    }
};