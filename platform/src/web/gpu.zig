//! `platform.gpu` in a browser: the same names, but the UI draws its frames on the CPU and the
//! window puts them on the page's canvas (`Window.present`). A surface's frame is the window.

const std = @import("std");
const app = @import("app.zig");

pub const c = struct {
    pub const WGPUTextureFormat = u32;
    pub const WGPUTextureView = *app.Window;
};

pub const Error = error{
    NoAdapter,
    NoDevice,
    NoSurface,
};

pub const Gpu = struct {
    pub fn init() Error!Gpu {
        return .{};
    }

    pub fn surface(self: *Gpu, window: *app.Window) Error!Surface {
        _ = self;
        return .{
            .window = window,
        };
    }
};

pub const Surface = struct {
    window: *app.Window,
    format: c.WGPUTextureFormat = 0,

    pub fn configure(self: *Surface, width: u32, height: u32) void {
        _ = self;
        _ = width;
        _ = height;
    }

    pub fn acquire(self: *Surface) ?Frame {
        return .{
            .view = self.window,
        };
    }

    /// The frame went to the canvas when the UI drew it.
    pub fn present(self: *Surface, frame: Frame) void {
        _ = self;
        _ = frame;
    }
};

pub const Frame = struct {
    view: c.WGPUTextureView,
};
