//! `zig build demo`: a GPU window cleared to a colour that follows the mouse, and a web
//! window whose button messages the app. Prints what it gets. `NATIVE_DEMO_EXIT=1` quits
//! after a few frames and says whether the GPU presented.

const std = @import("std");
const platform = @import("platform");
const c = platform.gpu.c;

var gpu: platform.gpu.Gpu = undefined;
var surface: platform.gpu.Surface = undefined;
var hue: f64 = 0.6;
var frames: u32 = 0;
var exit_after = false;

pub fn main(init: std.process.Init) !void {
    exit_after = init.environ_map.get("NATIVE_DEMO_EXIT") != null;
    platform.init("Native Demo");
    gpu = try platform.gpu.Gpu.init();
    const win = try platform.Window.create(.{
        .on_event = onEvent,
    }, .{
        .title = "platform: GPU window",
        .titlebar = .custom,
        .width = 640,
        .height = 420,
    });
    surface = try gpu.surface(win);
    const web = try platform.Window.create(.{
        .on_event = onWebEvent,
        .on_message = onMessage,
    }, .{
        .title = "platform: web window",
        .titlebar = .custom,
        .width = 720,
        .height = 360,
        .content = .web,
    });
    const page = try web.addWebView();
    page.loadHtml(
        \\<body style="margin:0;font:13px -apple-system;background:#2c2c2c;color:#eee">
        \\<div data-window-drag style="height:38px;display:flex;align-items:stretch;padding-left:78px;background:#1e1e1e;border-bottom:1px solid #000">
        \\  <div style="width:44px;display:grid;place-items:center;border-left:1px solid #333;border-right:1px solid #333">&#8962;</div>
        \\  <button style="all:unset;padding:0 16px;color:#aaa">Untitled</button>
        \\  <button style="all:unset;padding:0 16px;background:#2c2c2c">2024 Caraway Month &nbsp;&times;</button>
        \\  <div style="padding:0 12px;display:grid;place-items:center;color:#aaa">+</div>
        \\</div>
        \\<div style="padding:16px"><button onclick="webkit.messageHandlers.native.postMessage('hello from the page')">Message the app</button>
        \\<p><input placeholder="Copy and paste work here"></p></div>
    );
    // For screenshots of each window: `screencapture -o -l<number>`.
    std.debug.print("windows: gpu {d}, web {d}\n", .{ win.number(), web.number() });
    platform.run();
}

fn onEvent(_: ?*anyopaque, win: *platform.Window, event: platform.Event) void {
    switch (event) {
        .frame => draw(win),
        .mouse_move => |m| hue = @mod(m.x / 640.0, 1.0),
        .mouse_down => |m| {
            // The top 38 points are this window's bar: they move it.
            if (m.y < 38) return if (m.clicks == 2) win.titlebarDoubleClick() else win.dragWindow();
            std.debug.print("mouse down {d:.0},{d:.0} {s} x{d}\n", .{ m.x, m.y, @tagName(m.button), m.clicks });
        },
        .scroll => |s| std.debug.print("scroll {d:.1},{d:.1} precise={}\n", .{ s.dx, s.dy, s.precise }),
        .magnify => |g| std.debug.print("magnify {d:.3}\n", .{g.amount}),
        .key_down => |k| std.debug.print("key {s} '{s}' cmd={}\n", .{ @tagName(k.code), k.text(), k.mods.command }),
        .resize => |r| std.debug.print("resize {d:.0}x{d:.0} @{d}x\n", .{ r.width, r.height, r.scale }),
        else => {},
    }
}

fn onWebEvent(_: ?*anyopaque, _: *platform.Window, _: platform.Event) void {}

fn onMessage(_: ?*anyopaque, _: *platform.WebView, text: []const u8) void {
    std.debug.print("page says: {s}\n", .{text});
}

fn draw(win: *platform.Window) void {
    const size = win.size();
    const s = win.scale();
    surface.configure(@intFromFloat(size.w * s), @intFromFloat(size.h * s));
    const frame = surface.acquire() orelse return;
    const enc = c.wgpuDeviceCreateCommandEncoder(gpu.device, null);
    var att = std.mem.zeroes(c.WGPURenderPassColorAttachment);
    att.view = frame.view;
    att.depthSlice = c.WGPU_DEPTH_SLICE_UNDEFINED;
    att.loadOp = c.WGPULoadOp_Clear;
    att.storeOp = c.WGPUStoreOp_Store;
    att.clearValue = .{
        .r = 0.3 + 0.5 * hue,
        .g = 0.5,
        .b = 0.9 - 0.5 * hue,
        .a = 1,
    };
    var pass_desc = std.mem.zeroes(c.WGPURenderPassDescriptor);
    pass_desc.colorAttachmentCount = 1;
    pass_desc.colorAttachments = &att;
    const pass = c.wgpuCommandEncoderBeginRenderPass(enc, &pass_desc);
    c.wgpuRenderPassEncoderEnd(pass);
    c.wgpuRenderPassEncoderRelease(pass);
    const cmd = c.wgpuCommandEncoderFinish(enc, null);
    c.wgpuQueueSubmit(gpu.queue, 1, &cmd);
    c.wgpuCommandBufferRelease(cmd);
    c.wgpuCommandEncoderRelease(enc);
    surface.present(frame);
    frames += 1;
    if (exit_after and frames == 120) {
        std.debug.print("demo: {d} frames presented at {d}x{d}\n", .{ frames, surface.width, surface.height });
        platform.quit();
    }
}
