const std = @import("std");

pub const Timer = struct {
    start_time: u64 = 0,
    last_time: u64 = 0,
    elapsed_time: u64 = 0,
    running: bool = false,

    pub fn init() Timer {
        const now = std.time.nanoTimestamp();
        return Timer{
            .start_time = now,
            .last_time = now,
            .elapsed_time = 0,
            .running = true,
        };
    }

    pub fn reset(self: *Timer) void {
        const now = std.time.nanoTimestamp();
        self.start_time = now;
        self.last_time = now;
        self.elapsed_time = 0;
        self.running = true;
    }

    pub fn update(self: *Timer) void {
        if (!self.running) return;
        const now = std.time.nanoTimestamp();
        self.elapsed_time = now - self.start_time;
        self.last_time = now;
    }

    pub fn getElapsedTime(self: *Timer) u64 {
        return self.elapsed_time;
    }

    pub fn getDeltaTime(self: *Timer) f64 {
        const now = std.time.nanoTimestamp();
        defer self.last_time = now;
        return @as(f64, now - self.last_time) / 1_000_000_000.0;
    }

    pub fn stop(self: *Timer) void {
        self.running = false;
    }

    pub fn start(self: *Timer) void {
        if (!self.running) {
            self.running = true;
            self.last_time = std.time.nanoTimestamp();
        }
    }
};
