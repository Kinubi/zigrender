const std = @import("std");
const types = @import("types/index.zig");

pub const Controls = struct {
    keyState: [types.Key.NUM]bool = [_]bool{false} ** @intFromEnum(types.Key.NUM),
    keyToggled: [types.Key.NUM]bool = [_]bool{false} ** @intFromEnum(types.Key.NUM),
    buttonState: [types.Button.NUM]bool = [_]bool{false} ** @intFromEnum(types.Button.NUM),
    mouseDelta: types.float2 = .{ .x = 0, .y = 0 },
    mouseWheel: f32 = 0.0,

    pub fn init() Controls {
        return Controls{};
    }

    pub fn updateKeyState(self: *Controls, key: types.Key, pressed: bool) void {
        const idx = @intFromEnum(key);
        if (pressed and !self.keyState[idx]) {
            self.keyToggled[idx] = true;
        }
        self.keyState[idx] = pressed;
    }

    pub fn updateButtonState(self: *Controls, button: types.Button, pressed: bool) void {
        const idx = @intFromEnum(button);
        self.buttonState[idx] = pressed;
    }

    pub fn getMouseDelta(self: *Controls) types.float2 {
        return self.mouseDelta;
    }

    pub fn getMouseWheel(self: *Controls) f32 {
        return self.mouseWheel;
    }

    pub fn resetToggles(self: *Controls) void {
        for (self.keyToggled) |*toggled| {
            toggled.* = false;
        }
    }
};
