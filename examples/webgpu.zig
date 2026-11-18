//! `zig build webgpu -- <file:// or http:// address>`: whether a page in the web view, as
//! Desktop makes it, gets WebGPU: an adapter, a device, and one frame drawn to a canvas.
//! Prints what the page says and quits.

const std = @import("std");
const native = @import("native");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) return error.NoAddress;

    native.init("WebGPU check");
    const win = try native.Window.create(.{
        .on_event = onEvent,
        .on_message = onMessage,
    }, .{
        .title = "WebGPU check",
        .width = 480,
        .height = 320,
        .content = .web,
    });
    const page = try win.addWebView();
    page.loadUrl(try init.arena.allocator().dupeSentinel(u8, args[1], 0));
    native.run();
}

fn onEvent(_: ?*anyopaque, _: *native.Window, _: native.Event) void {}

fn onMessage(_: ?*anyopaque, _: *native.WebView, text: []const u8) void {
    std.debug.print("{s}\n", .{text});
    if (std.mem.startsWith(u8, text, "done")) std.process.exit(0);
}
