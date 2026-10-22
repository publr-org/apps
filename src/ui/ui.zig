//! Our own-drawn UI: boxes, text and icons laid out by the app and drawn by PublrEngine,
//! the same renderer as PublrDesign's canvas, so it looks the same on every platform.
//! Immediate: each frame the app says what is where (`begin`, `rect`, `text`, `icon`) and
//! `render` draws it; the app keeps its own state and hit regions.

const std = @import("std");
const engine = @import("publr_engine");

const m = engine.model;
const geom = engine.geom;
const Pixmap = engine.pixmap.Pixmap;

pub const Blit = @import("blit.zig").Blit;
pub const TextField = @import("field.zig").TextField;
const svg = @import("svg.zig");
/// PublrEngine's GPU frame drawn with WebGPU: what `draw` uses, and PublrDesign's canvas.
pub const host = @import("host.zig");
const draw_mod = @import("draw.zig");
const native = @import("native");

pub const Color = m.Color;

/// `0xRRGGBB` as a colour.
pub fn hex(rgb: u24) Color {
    return .{
        .r = @as(f32, @floatFromInt((rgb >> 16) & 0xff)) / 255,
        .g = @as(f32, @floatFromInt((rgb >> 8) & 0xff)) / 255,
        .b = @as(f32, @floatFromInt(rgb & 0xff)) / 255,
        .a = 1,
    };
}

/// A box in points from the surface's top left.
pub const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,

    pub fn contains(r: Rect, x: f64, y: f64) bool {
        return x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h;
    }
};

/// A box's look: any of fill, border and shadow, with rounded corners.
pub const Box = struct {
    fill: ?Color = null,
    /// A border drawn inside the box.
    border: ?Color = null,
    border_width: f32 = 1,
    radius: f32 = 0,
    shadow: ?Shadow = null,
};

/// A drop shadow (Figma's): offset, blur radius, spread.
pub const Shadow = struct {
    color: Color,
    x: f32 = 0,
    y: f32 = 0,
    blur: f32 = 0,
    spread: f32 = 0,
};

pub const TextStyle = struct {
    size: f32 = 12,
    weight: u16 = 400,
    color: Color = hex(0xffffff),
    @"align": m.TextAlign = .left,
    /// One line, cut with an ellipsis where it does not fit.
    truncate: bool = true,
    /// Extra space between letters, in points (negative: tighter).
    tracking: f32 = 0,
    /// Set in capitals (the source text unchanged).
    upper: bool = false,
};

fn modelStyle(style: TextStyle) m.TextStyle {
    return .{
        .family = family,
        .weight = style.weight,
        .size = style.size,
        .letter_spacing = .{
            .px = style.tracking,
        },
        .case = if (style.upper) .upper else null,
    };
}

/// The UI's typeface: Inter (SIL OFL 1.1, `fonts/Inter-LICENSE.txt`), set as Publr's admin
/// sets it: the single-storey a (`cv11`) and open digits (`ss01`).
const family = "Inter";
const font_files = [_][]const u8{
    @embedFile("fonts/Inter-Regular.ttf"),
    @embedFile("fonts/Inter-Medium.ttf"),
    @embedFile("fonts/Inter-SemiBold.ttf"),
};
const font_features = [_][4]u8{ "cv11".*, "ss01".* };

const Clip = struct {
    frame: m.Node,
    nodes: std.ArrayList(m.Node) = .empty,
};

pub const Ui = struct {
    gpa: std.mem.Allocator,
    /// What `begin` .. `render` describe; freed at the next `begin`.
    frame: std.heap.ArenaAllocator,
    nodes: std.ArrayList(m.Node) = .empty,
    /// Open clip groups, innermost last: their frame and the nodes put in them so far.
    clips: std.ArrayList(Clip) = .empty,
    /// The fonts, the pictures and the renderer, as PublrDesign's documents have them: the
    /// frame's nodes are this session's page when drawn on the GPU (`draw`).
    session: *engine.session.Session,
    /// The GPU path, once `attachGpu` gave it a device.
    gpu: ?*draw_mod.Gpu = null,
    next_id: u32 = 0,

    /// A UI on the heap (the GPU path points into it, so it must not move).
    pub fn create(gpa: std.mem.Allocator) !*Ui {
        const self = try gpa.create(Ui);
        self.* = .{
            .gpa = gpa,
            .frame = .init(gpa),
            .session = try engine.session.Session.create(gpa),
        };
        for (font_files) |bytes| _ = try self.session.addFont(bytes, .face);
        for (self.session.fonts.faces.items) |*f| f.font.features = &font_features;
        return self;
    }

    pub fn destroy(self: *Ui) void {
        if (self.gpu) |g| g.destroy();
        self.session.destroy();
        self.nodes.deinit(self.gpa);
        self.clips.deinit(self.gpa);
        self.frame.deinit();
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    /// Starts describing a frame: what the last one said is dropped.
    pub fn begin(self: *Ui) void {
        self.nodes.clearRetainingCapacity();
        self.clips.clearRetainingCapacity();
        _ = self.frame.reset(.retain_capacity);
        self.next_id = 0;
    }

    /// Where nodes go now: the innermost open clip group, or the top.
    fn target(self: *Ui) *std.ArrayList(m.Node) {
        return if (self.clips.items.len > 0) &self.clips.items[self.clips.items.len - 1].nodes else &self.nodes;
    }

    /// What is put until `endClip` shows only inside `r` (a scrolled list, a panel).
    pub fn beginClip(self: *Ui, r: Rect) !void {
        try self.clips.append(self.gpa, .{
            .frame = .{
                .id = try std.fmt.allocPrint(self.frame.allocator(), "ui:{d}", .{self.next_id}),
                .kind = .frame,
                .transform = .translate(r.x, r.y),
                .size = .{
                    .x = r.w,
                    .y = r.h,
                },
                .clip = true,
            },
        });
        self.next_id += 1;
    }

    pub fn endClip(self: *Ui) !void {
        var c = self.clips.pop() orelse return;
        defer c.nodes.deinit(self.gpa);
        // The nodes were placed on the surface; inside the frame they are placed from its
        // corner.
        const ox = c.frame.transform.e;
        const oy = c.frame.transform.f;
        for (c.nodes.items) |*n| {
            n.transform.e -= ox;
            n.transform.f -= oy;
        }
        c.frame.children = try self.frame.allocator().dupe(m.Node, c.nodes.items);
        try self.target().append(self.gpa, c.frame);
    }

    fn node(self: *Ui, kind: m.Kind, r: Rect) !*m.Node {
        const a = self.frame.allocator();
        const n = try self.target().addOne(self.gpa);
        n.* = .{
            .id = try std.fmt.allocPrint(a, "ui:{d}", .{self.next_id}),
            .kind = kind,
            .transform = .translate(r.x, r.y),
            .size = .{
                .x = r.w,
                .y = r.h,
            },
        };
        self.next_id += 1;
        return n;
    }

    fn solid(self: *Ui, color: Color) ![]m.Paint {
        const fills = try self.frame.allocator().alloc(m.Paint, 1);
        fills[0] = .{
            .kind = .solid,
            .color = color,
        };
        return fills;
    }

    /// A filled box, its corners rounded by `radius` points.
    pub fn rect(self: *Ui, r: Rect, color: Color, radius: f32) !void {
        const n = try self.node(.rectangle, r);
        n.fills = try self.solid(color);
        n.radius = .{ radius, radius, radius, radius };
    }

    /// A box with any of fill, border and shadow.
    pub fn box(self: *Ui, r: Rect, look: Box) !void {
        const n = try self.node(.rectangle, r);
        if (look.fill) |c| n.fills = try self.solid(c);
        if (look.border) |c| {
            n.strokes = try self.solid(c);
            n.stroke = .{
                .weight = look.border_width,
                .@"align" = .inside,
            };
        }
        n.radius = .{ look.radius, look.radius, look.radius, look.radius };
        if (look.shadow) |sh| {
            const fx = try self.frame.allocator().alloc(m.Effect, 1);
            fx[0] = .{
                .kind = .drop_shadow,
                .color = sh.color,
                .offset = .{
                    .x = sh.x,
                    .y = sh.y,
                },
                .radius = sh.blur,
                .spread = sh.spread,
            };
            n.effects = fx;
        }
    }

    /// Keeps `img` (RGBA, straight alpha; taken over) as the picture named `key`, for
    /// `image`; a picture already under that name is replaced.
    pub fn setImage(self: *Ui, key: []const u8, img: *engine.Image) !void {
        const replaced = self.session.images.contains(key);
        try self.session.addImage(key, img);
        // The GPU's copy of the old picture goes.
        if (replaced) if (self.gpu) |g| g.host.forgetImage(key);
    }

    pub fn hasImage(self: *const Ui, key: []const u8) bool {
        return self.session.images.contains(key);
    }

    /// The picture named `key` filling `r` (cropped to its shape, as CSS `cover`), its
    /// corners rounded by `radius`.
    pub fn image(self: *Ui, r: Rect, key: []const u8, radius: f32) !void {
        if (!self.session.images.contains(key)) return;
        const n = try self.node(.rectangle, r);
        const fills = try self.frame.allocator().alloc(m.Paint, 1);
        fills[0] = .{
            .kind = .image,
            .asset = key,
            .scale = .fill,
        };
        n.fills = fills;
        n.radius = .{ radius, radius, radius, radius };
    }

    /// How wide `s` is set in `style`, in points.
    pub fn measure(self: *Ui, s: []const u8, style: TextStyle) f32 {
        const t: m.Text = .{
            .text = s,
            .style = modelStyle(style),
            .resize = .width_and_height,
        };
        var lay = engine.layout.layout(self.gpa, &t, .{}, &self.session.fonts, .{}) catch return 0;
        defer lay.deinit(self.gpa);
        var w: f32 = 0;
        for (lay.lines.items) |l| w = @max(w, l.width - l.trail);
        return w;
    }

    /// One line of text in `r`, centred vertically.
    pub fn text(self: *Ui, r: Rect, s: []const u8, style: TextStyle) !void {
        const n = try self.node(.text, r);
        n.fills = try self.solid(style.color);
        n.text = .{
            .text = try self.frame.allocator().dupe(u8, s),
            .style = modelStyle(style),
            .@"align" = style.@"align",
            .valign = .center,
            .truncation = if (style.truncate) .ending else .none,
            .max_lines = if (style.truncate) 1 else null,
        };
    }

    /// An icon from the Publr set (SVG markup on a 24-unit grid) drawn in the square `r` in
    /// `color`: each shape filled and stroked as the icon says.
    pub fn icon(self: *Ui, r: Rect, markup: []const u8, color: Color) !void {
        const a = self.frame.allocator();
        // An icon this cannot read is left out, not the whole frame.
        const list = svg.shapes(a, markup) catch |e| switch (e) {
            error.OutOfMemory => return e,
            else => return,
        };
        const k = r.w / 24;
        for (list) |shape| {
            for (shape.net.vertices) |*v| v.* = .{
                .x = v.x * k,
                .y = v.y * k,
            };
            for (shape.net.segments) |*s| {
                s.t0 = .{
                    .x = s.t0.x * k,
                    .y = s.t0.y * k,
                };
                s.t1 = .{
                    .x = s.t1.x * k,
                    .y = s.t1.y * k,
                };
            }
            const n = try self.node(.vector, r);
            n.network = shape.net;
            if (shape.fill) n.fills = try self.solid(color);
            if (shape.stroke) {
                n.strokes = try self.solid(color);
                n.stroke = .{
                    .weight = shape.width * k,
                    .@"align" = .center,
                    .cap = .round,
                    .join = .round,
                };
            }
        }
    }

    /// Draws the frame into a `width` x `height` pixmap at `scale` device pixels per point,
    /// over `background`.
    pub fn render(self: *Ui, width: u32, height: u32, scale: f32, background: Color) !Pixmap {
        return self.renderRegion(.{
            .x1 = @intCast(width),
            .y1 = @intCast(height),
        }, scale, background);
    }

    /// Draws only `region` (device pixels) of the frame: what changed, for `Blit.upload` to
    /// put in place. Nodes outside it are skipped.
    pub fn renderRegion(self: *Ui, region: engine.mask.IRect, scale: f32, background: Color) !Pixmap {
        var px = try Pixmap.init(self.gpa, region);
        errdefer px.deinit(self.gpa);
        @memset(px.data, engine.pixmap.premultiply(background.r, background.g, background.b, background.a));
        const ctm = geom.Affine.scaling(scale, scale);
        const r = &self.session.renderer;
        for (self.nodes.items) |*n| {
            const at = ctm.mul(n.transform);
            if (engine.mask.IRect.around(engine.render.cullBounds(n, at)).intersect(region).isEmpty()) continue;
            try r.drawNode(n, at, &px);
        }
        _ = r.frame.reset(.retain_capacity);
        return px;
    }

    /// Gives the UI the GPU path: frames drawn with `draw` on `gpu`'s device, into
    /// targets of `format` (a window's surface format).
    pub fn attachGpu(self: *Ui, gpu: *native.gpu.Gpu, format: native.gpu.c.WGPUTextureFormat) !void {
        if (self.gpu != null) return;
        self.gpu = try draw_mod.Gpu.create(self.gpa, gpu, format);
    }

    /// Draws the frame on the GPU into `view` (a texture view of the format `attachGpu` was
    /// given), `width` x `height` device pixels at `scale` per point, over `background`,
    /// and submits it. Answers whether to draw again soon: something of this frame is
    /// still coming (glyph masks over the per-frame budget).
    pub fn draw(self: *Ui, view: native.gpu.c.WGPUTextureView, width: u32, height: u32, scale: f32, background: Color) !bool {
        const g = self.gpu orelse return error.NoGpu;
        return g.draw(self, view, width, height, scale, background);
    }

    /// `r` in device pixels at `scale`, grown to whole pixels (and one more for
    /// anti-aliasing), within `width` x `height`.
    pub fn deviceRect(r: Rect, scale: f32, width: u32, height: u32) engine.mask.IRect {
        return .{
            .x0 = @max(0, @as(i32, @intFromFloat(@floor(r.x * scale))) - 1),
            .y0 = @max(0, @as(i32, @intFromFloat(@floor(r.y * scale))) - 1),
            .x1 = @min(@as(i32, @intCast(width)), @as(i32, @intFromFloat(@ceil((r.x + r.w) * scale))) + 1),
            .y1 = @min(@as(i32, @intCast(height)), @as(i32, @intFromFloat(@ceil((r.y + r.h) * scale))) + 1),
        };
    }
};

test {
    _ = @import("field.zig");
    _ = svg;
}
