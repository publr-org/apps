//! `zig build uicheck`: a Home-like UI (1360 x 880 points at 2x) drawn on the GPU
//! (`Ui.draw`) and on the CPU (`Ui.render`, the oracle), with how many pixels agree within
//! 2/255; then frames as a person scrolls the list and hovers its cards, timed on both.
//! Headless: no window.

const std = @import("std");
const platform = @import("platform");
const ui_mod = @import("ui");
const engine = @import("publr_engine");

const c = platform.gpu.c;
const Ui = ui_mod.Ui;
const hex = ui_mod.hex;
const host = ui_mod.host;

const width_pt = 1360;
const height_pt = 880;
const scale: f32 = 2;
const background = hex(0x1e1e1e);

const icon_home =
    \\<svg viewBox="0 0 24 24"><path d="M3 10.5L12 3l9 7.5V20C21 20.6 20.6 21 20 21H15v-6H9v6H4C3.4 21 3 20.6 3 20Z" stroke="currentColor"/></svg>
;
const icon_plus =
    \\<svg viewBox="0 0 24 24"><path d="M12 5v14M5 12h14" stroke="currentColor"/></svg>
;
const icon_search =
    \\<svg viewBox="0 0 24 24"><path d="M11 4C14.866 4 18 7.134 18 11C18 14.866 14.866 18 11 18C7.134 18 4 14.866 4 11C4 7.134 7.134 4 11 4ZM20 20L16 16" stroke="currentColor"/></svg>
;

const HomeOptions = struct {
    shadows: bool = true,
};

/// The frame: a bar, a sidebar, a toolbar, and a scrolled grid of site cards.
fn home(u: *Ui, scroll: f32, hover: ?usize, options: HomeOptions) !void {
    u.begin();
    try u.rect(.{
        .x = 0,
        .y = 0,
        .w = width_pt,
        .h = 38,
    }, hex(0x2c2c2c), 0);
    try u.text(.{
        .x = 80,
        .y = 0,
        .w = 200,
        .h = 38,
    }, "Publr Desktop", .{
        .size = 13,
        .weight = 500,
    });
    try u.rect(.{
        .x = 0,
        .y = 38,
        .w = 240,
        .h = height_pt - 38,
    }, hex(0x252525), 0);
    const items = [_][]const u8{ "Home", "Sites", "Cloud projects", "Self-hosted", "Settings", "Help" };
    for (items, 0..) |name, i| {
        const y: f32 = 54 + @as(f32, @floatFromInt(i)) * 32;
        if (i == 0) try u.rect(.{
            .x = 8,
            .y = y,
            .w = 224,
            .h = 28,
        }, hex(0x3a3a3a), 6);
        try u.icon(.{
            .x = 18,
            .y = y + 6,
            .w = 16,
            .h = 16,
        }, if (i == 0) icon_home else icon_search, hex(0xcccccc));
        try u.text(.{
            .x = 44,
            .y = y,
            .w = 180,
            .h = 28,
        }, name, .{
            .size = 13,
            .color = hex(0xdddddd),
        });
    }
    try u.box(.{
        .x = 264,
        .y = 54,
        .w = 360,
        .h = 32,
    }, .{
        .fill = hex(0x2a2a2a),
        .border = hex(0x444444),
        .radius = 8,
    });
    try u.icon(.{
        .x = 274,
        .y = 62,
        .w = 16,
        .h = 16,
    }, icon_search, hex(0x999999));
    try u.text(.{
        .x = 298,
        .y = 54,
        .w = 300,
        .h = 32,
    }, "Search sites", .{
        .size = 13,
        .color = hex(0x888888),
    });
    try u.box(.{
        .x = width_pt - 160,
        .y = 54,
        .w = 136,
        .h = 32,
    }, .{
        .fill = hex(0x0d99ff),
        .radius = 8,
    });
    try u.icon(.{
        .x = width_pt - 148,
        .y = 62,
        .w = 16,
        .h = 16,
    }, icon_plus, hex(0xffffff));
    try u.text(.{
        .x = width_pt - 126,
        .y = 54,
        .w = 100,
        .h = 32,
    }, "New site", .{
        .size = 13,
        .weight = 500,
    });

    // The list scrolls inside its clip.
    try u.beginClip(.{
        .x = 240,
        .y = 100,
        .w = width_pt - 240,
        .h = height_pt - 100,
    });
    const names = [_][]const u8{ "Caraway", "Rho", "Bookshop", "publr.app", "Smarthost", "Courses", "Sklep", "Docs" };
    for (0..24) |i| {
        const col: f32 = @floatFromInt(i % 4);
        const row: f32 = @floatFromInt(i / 4);
        const x = 264 + col * 268;
        const y = 116 + row * 236 - scroll;
        const hovered = hover != null and hover.? == i;
        try u.box(.{
            .x = x,
            .y = y,
            .w = 252,
            .h = 220,
        }, .{
            .fill = hex(0x2a2a2a),
            .border = if (hovered) hex(0x0d99ff) else hex(0x3a3a3a),
            .border_width = if (hovered) 2 else 1,
            .radius = 10,
            .shadow = if (!options.shadows) null else .{
                .color = .{
                    .r = 0,
                    .g = 0,
                    .b = 0,
                    .a = 0.35,
                },
                .y = 4,
                .blur = 12,
            },
        });
        try u.image(.{
            .x = x + 8,
            .y = y + 8,
            .w = 236,
            .h = 140,
        }, if (i % 2 == 0) "thumb-a" else "thumb-b", 6);
        try u.text(.{
            .x = x + 12,
            .y = y + 156,
            .w = 228,
            .h = 24,
        }, names[i % names.len], .{
            .size = 14,
            .weight = 500,
        });
        try u.text(.{
            .x = x + 12,
            .y = y + 180,
            .w = 228,
            .h = 20,
        }, "Local site, edited 2 hours ago", .{
            .size = 12,
            .color = hex(0x999999),
        });
    }
    try u.endClip();
}

fn thumbnail(gpa: std.mem.Allocator, w: u32, h: u32, tint: [3]u8) !engine.Image {
    const px = try gpa.alloc(u8, w * h * 4);
    for (0..h) |y| for (0..w) |x| {
        const o = (y * w + x) * 4;
        const fx: f32 = @as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(w));
        const fy: f32 = @as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(h));
        px[o] = @intFromFloat(@as(f32, @floatFromInt(tint[0])) * (0.5 + 0.5 * fx));
        px[o + 1] = @intFromFloat(@as(f32, @floatFromInt(tint[1])) * (0.5 + 0.5 * fy));
        px[o + 2] = tint[2];
        px[o + 3] = 255;
    };
    return .{
        .width = w,
        .height = h,
        .pixels = px,
    };
}

/// Draws the frame on the GPU into `tex` and reads it back (RGBA8, premultiplied:
/// opaque here), drawing again while the frame says something is still coming.
fn gpuPixels(gpa: std.mem.Allocator, u: *Ui, device: c.WGPUDevice, tex: c.WGPUTexture, view: c.WGPUTextureView, w: u32, h: u32) ![]u8 {
    var rounds: u32 = 0;
    while (try u.draw(view, w, h, scale, background) and rounds < 100) rounds += 1;
    const bpr = std.mem.alignForward(u32, w * 4, 256);
    const buf = host.createBuffer(device, @as(u64, bpr) * h, c.WGPUBufferUsage_CopyDst | c.WGPUBufferUsage_MapRead);
    defer c.wgpuBufferRelease(buf);
    const enc = c.wgpuDeviceCreateCommandEncoder(device, null);
    host.copyTextureToBuffer(enc, tex, buf, bpr, w, h);
    const cmd = c.wgpuCommandEncoderFinish(enc, null);
    c.wgpuQueueSubmit(c.wgpuDeviceGetQueue(device), 1, &cmd);
    const raw = try host.mapRead(device, buf, @as(u64, bpr) * h);
    defer c.wgpuBufferUnmap(buf);
    const out = try gpa.alloc(u8, @as(usize, w) * h * 4);
    for (0..h) |y| @memcpy(out[y * w * 4 ..][0 .. w * 4], raw[y * bpr ..][0 .. w * 4]);
    return out;
}

pub fn main() !void {
    const gpa = std.heap.c_allocator;
    var gpu = try platform.gpu.Gpu.init();
    const u = try Ui.create(gpa);
    try u.attachGpu(&gpu, c.WGPUTextureFormat_RGBA8Unorm);
    var a = try thumbnail(gpa, 472, 280, .{ 230, 120, 80 });
    try u.setImage("thumb-a", &a);
    var b = try thumbnail(gpa, 472, 280, .{ 80, 160, 230 });
    try u.setImage("thumb-b", &b);

    const w: u32 = @intFromFloat(width_pt * scale);
    const h: u32 = @intFromFloat(height_pt * scale);
    const tex = host.createTexture(gpu.device, w, h, 1, c.WGPUTextureFormat_RGBA8Unorm, c.WGPUTextureUsage_RenderAttachment | c.WGPUTextureUsage_CopySrc, 1, 1);
    const view = c.wgpuTextureCreateView(tex, null);

    // The same frames on both, compared: still, scrolled, hovered.
    var ok = true;
    for ([_]struct {
        f32,
        ?usize,
    }{ .{ 0, null }, .{ 137.5, 5 }, .{ 0, null } }) |st| {
        try home(u, st[0], st[1], .{});
        var px = try u.render(w, h, scale, background);
        defer px.deinit(gpa);
        const cpu = try px.toRgba8(gpa, px.rect);
        defer gpa.free(cpu);
        const g = try gpuPixels(gpa, u, gpu.device, tex, view, w, h);
        defer gpa.free(g);
        var off: u64 = 0;
        var max: u8 = 0;
        var i: usize = 0;
        while (i < g.len) : (i += 4) {
            var d: u8 = 0;
            for (0..4) |k| d = @max(d, if (g[i + k] > cpu[i + k]) g[i + k] - cpu[i + k] else cpu[i + k] - g[i + k]);
            if (d > 2) off += 1;
            max = @max(max, d);
        }
        const pct = 100 * (1 - @as(f64, @floatFromInt(off)) / @as(f64, @floatFromInt(w * h)));
        std.debug.print("scroll {d:>6.1}, hover {?}: GPU vs CPU {d:.3}% within 2/255 (max {d}), {d} prims\n", .{ st[0], st[1], pct, max, u.gpu.?.host.stats.prims });
        if (pct < 99.9) ok = false;
    }

    // A line whose words change in place (a progress line, right aligned, drawn through a
    // CPU layer): the second frame must show the new words, not the kept picture.
    for ([_][]const u8{ "Packing the site…", "Uploading… 12.3 of 25.1 MB" }, 0..) |words, k| {
        u.begin();
        try u.rect(.{
            .x = 0,
            .y = 0,
            .w = width_pt,
            .h = height_pt,
        }, ui_mod.hex(0xffffff), 0);
        try u.text(.{
            .x = 40,
            .y = 40,
            .w = 400,
            .h = 28,
        }, words, .{
            .size = 12,
            .color = ui_mod.hex(0x222222),
            .@"align" = .right,
        });
        var px = try u.render(w, h, scale, background);
        defer px.deinit(gpa);
        const cpu = try px.toRgba8(gpa, px.rect);
        defer gpa.free(cpu);
        const g = try gpuPixels(gpa, u, gpu.device, tex, view, w, h);
        defer gpa.free(g);
        var off: u64 = 0;
        var i: usize = 0;
        while (i < g.len) : (i += 4) {
            for (0..4) |q| if ((if (g[i + q] > cpu[i + q]) g[i + q] - cpu[i + q] else cpu[i + q] - g[i + q]) > 2) {
                off += 1;
                break;
            };
        }
        const pct = 100 * (1 - @as(f64, @floatFromInt(off)) / @as(f64, @floatFromInt(w * h)));
        std.debug.print("changing right-aligned line, frame {d}: GPU vs CPU {d:.3}%\n", .{ k + 1, pct });
        if (pct < 99.9) ok = false;
    }

    // Frames as the list scrolls (a trackpad: a few points a frame) and the pointer
    // crosses cards; GPU frames waited for, so the time is the whole frame.
    var gpu_ms: [180]f64 = undefined;
    var cpu_side: [180]f64 = undefined;
    for (&gpu_ms, &cpu_side, 0..) |*t, *cs, i| {
        const fi: f32 = @floatFromInt(i);
        try home(u, fi * 3.5, (i / 20) % 8, .{});
        var timer = host.Timer.start();
        _ = try u.draw(view, w, h, scale, background);
        cs.* = timer.lap();
        _ = c.wgpuDevicePoll(gpu.device, 1, null);
        t.* = cs.* + timer.lap();
    }
    var cpu_ms: [20]f64 = undefined;
    for (&cpu_ms, 0..) |*t, i| {
        try home(u, @as(f32, @floatFromInt(i)) * 3.5, null, .{});
        var timer = host.Timer.start();
        var px = try u.render(w, h, scale, background);
        px.deinit(gpa);
        t.* = timer.lap();
    }
    var cpu_plain: [20]f64 = undefined;
    for (&cpu_plain, 0..) |*t, i| {
        try home(u, @as(f32, @floatFromInt(i)) * 3.5, null, .{
            .shadows = false,
        });
        var timer = host.Timer.start();
        var px = try u.render(w, h, scale, background);
        px.deinit(gpa);
        t.* = timer.lap();
    }
    report("GPU frame (build + encode + GPU)", &gpu_ms);
    report("  of which on the CPU (build + encode)", &cpu_side);
    report("CPU render (the old path)", &cpu_ms);
    report("CPU render without the 24 card shadows", &cpu_plain);
    if (!ok) std.process.exit(1);
}

fn report(name: []const u8, ms: []f64) void {
    std.mem.sort(f64, ms, {}, std.sort.asc(f64));
    var sum: f64 = 0;
    for (ms) |v| sum += v;
    std.debug.print("{s}: avg {d:.2} ms, p95 {d:.2} ms ({d} frames)\n", .{ name, sum / @as(f64, @floatFromInt(ms.len)), ms[@min(ms.len - 1, ms.len * 95 / 100)], ms.len });
}
