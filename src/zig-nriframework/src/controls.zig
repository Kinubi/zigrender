const std = @import("std");

const Key = enum {
    Up,
    Down,
    Left,
    Right,
    Space,
    Escape,
    NUM,
};

const Button = enum {
    Left,
    Right,
    Middle,
    NUM,
};

pub const Controls = struct {
    keyState: [Key.NUM]bool,
    keyToggled: [Key.NUM]bool,
    buttonState: [Button.NUM]bool,
    mouseDelta: f32,
    mouseWheel: f32,

    pub fn init() Controls {
        return Controls{
            .keyState = undefined,
            .keyToggled = undefined,
            .buttonState = undefined,
            .mouseDelta = 0.0,
            .mouseWheel = 0.0,
        };
    }

    pub fn updateKeyState(self: *Controls, key: Key, pressed: bool) void {
        self.keyState[key] = pressed;
        if (pressed) {
            self.keyToggled[key] = true;
        }
    }

    pub fn updateButtonState(self: *Controls, button: Button, pressed: bool) void {
        self.buttonState[button] = pressed;
    }

    pub fn getMouseDelta(self: *Controls) f32 {
        return self.mouseDelta;
    }

    pub fn getMouseWheel(self: *Controls) f32 {
        return self.mouseWheel;
    }

    pub fn resetToggles(self: *Controls) void {
        for (key in Key) {
            self.keyToggled[key] = false;
        }
    }
};