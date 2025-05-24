const std = @import("std");
const nriframework = @import("nriframework");
const camera = @import("camera");
const controls = @import("controls");
const timer = @import("timer");
const utils = @import("utils");

pub fn main() !void {
    // Initialize the NRI framework
    try nriframework.init();

    // Set up the main loop
    var frame_num: u32 = 0;
    while (true) {
        // Handle application lifecycle events
        if (try nriframework.shouldClose()) {
            break;
        }

        // Prepare frame
        try nriframework.prepareFrame(frame_num);

        // Render frame
        try nriframework.renderFrame(frame_num);

        // Update frame number
        frame_num += 1;

        // Sleep to maintain frame rate
        timer.sleep(16); // Approx 60 FPS
    }

    // Clean up resources
    nriframework.cleanup();
}