//! Native apps in Zig: windows, input, menus, frame timing, a GPU surface (WebGPU through
//! wgpu-native) and a web view host. What the app draws is its own; the platform gives
//! only the window around it. macOS, and a browser page (`web/`, for publr.app's guide);
//! Windows and Linux follow the same API.

const builtin = @import("builtin");

const backend = switch (builtin.os.tag) {
    .macos => @import("macos/app.zig"),
    .wasi => @import("web/app.zig"),
    else => @compileError("native: this platform is not supported yet"),
};

pub const event = @import("event.zig");
pub const Event = event.Event;
pub const Mods = event.Mods;
pub const Cursor = event.Cursor;
pub const Appearance = event.Appearance;
pub const KeyCode = event.KeyCode;

/// The app runs in a browser page (`web/`): frames are drawn on the CPU and go to its canvas.
pub const web = builtin.os.tag == .wasi;

pub const gpu = if (web) @import("web/gpu.zig") else @import("gpu.zig");

pub const Window = backend.Window;
pub const WebView = backend.WebView;
pub const Picture = backend.Picture;
pub const WindowOptions = backend.WindowOptions;
pub const Handler = backend.Handler;
pub const Content = backend.Content;
pub const Titlebar = backend.Titlebar;

/// Sets up the app and its menu bar; call once, before any window.
pub const init = backend.init;
/// Runs the event loop until the last window closes or `quit`.
pub const run = backend.run;
pub const quit = backend.quit;
/// App menus with items of the app's own: `setMenu`, chosen items to `onMenu`.
pub const MenuItem = backend.MenuItem;
pub const setMenu = backend.setMenu;
/// Items of the app's own in the app menu, under About (Settings…).
pub const setAppMenuItems = backend.setAppMenuItems;
pub const onMenu = backend.onMenu;
pub const openInBrowser = backend.openInBrowser;
/// Runs a function on the main thread (where windows live), from any thread.
pub const runOnMain = backend.runOnMain;
/// Light or dark, as the system is set; `.appearance` events say when it changes.
pub const appearance = backend.appearance;
pub const clipboardText = backend.clipboardText;
/// Brings the app to the front (after the person was sent to the browser).
pub const activate = backend.activate;
/// Secrets kept in the system's store (the macOS keychain).
pub const keychain = switch (builtin.os.tag) {
    .macos => @import("macos/keychain.zig"),
    .wasi => @import("web/keychain.zig"),
    else => @compileError("native: no keychain for this platform yet"),
};
pub const setClipboardText = backend.setClipboardText;

/// Work off the main thread: a thread of its own, left to finish (`runOnMain` brings its
/// results back). In a browser, where there is one thread, it runs before the next frame.
pub fn spawn(comptime function: anytype, args: anytype) !void {
    if (web) {
        return backend.spawn(function, args);
    } else {
        const thread = try @import("std").Thread.spawn(.{}, function, args);
        thread.detach();
    }
}
