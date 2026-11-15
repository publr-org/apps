//! The SVG the Publr icons are written in, read into vector networks for the engine: the
//! elements `path`, `rect` (rounded), `circle`, `ellipse`, `line`, `polyline`, `polygon`,
//! with `fill`, `stroke` and `stroke-width` on them or on a `g` around them. Paths take
//! M L H V C S Q A Z, absolute and relative.

const std = @import("std");
const engine = @import("publr_engine");

const m = engine.model;
const geom = engine.geom;
const Vec2 = geom.Vec2;

/// One element: its outline, and whether it is filled, stroked and how wide.
pub const Shape = struct {
    net: m.Network,
    fill: bool,
    stroke: bool,
    width: f32,
};

const Style = struct {
    fill: bool = false,
    stroke: bool = false,
    width: f32 = 1.5,
};

/// Every shape in `svg`, in drawing order.
pub fn shapes(a: std.mem.Allocator, svg: []const u8) ![]Shape {
    var out: std.ArrayList(Shape) = .empty;
    var styles: std.ArrayList(Style) = .empty;
    try styles.append(a, .{});
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, svg, i, '<')) |lt| {
        const gt = std.mem.indexOfScalarPos(u8, svg, lt, '>') orelse break;
        const tag = svg[lt + 1 .. gt];
        i = gt + 1;
        if (tag.len == 0) continue;
        if (tag[0] == '/') {
            if (std.mem.startsWith(u8, tag, "/g") and styles.items.len > 1) _ = styles.pop();
            continue;
        }
        const name_end = std.mem.indexOfAny(u8, tag, " \t\n/") orelse tag.len;
        const name = tag[0..name_end];
        const closed = tag[tag.len - 1] == '/';
        var style = styles.items[styles.items.len - 1];
        if (attr(tag, "fill")) |v| style.fill = paints(v);
        if (attr(tag, "stroke")) |v| style.stroke = paints(v);
        if (attr(tag, "stroke-width")) |v| style.width = std.fmt.parseFloat(f32, v) catch style.width;
        if (std.mem.eql(u8, name, "g")) {
            if (!closed) try styles.append(a, style);
            continue;
        }
        const d = try pathOf(a, name, tag) orelse continue;
        var b: Builder = .{
            .a = a,
        };
        try b.path(d);
        try out.append(a, .{
            .net = try b.network(style.fill),
            .fill = style.fill,
            .stroke = style.stroke,
            .width = style.width,
        });
    }
    return out.items;
}

fn paints(v: []const u8) bool {
    return !std.mem.eql(u8, v, "none") and !std.mem.eql(u8, v, "transparent");
}

/// The value of attribute `name` in a tag (`name="value"`).
fn attr(tag: []const u8, name: []const u8) ?[]const u8 {
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, tag, at, name)) |p| {
        at = p + name.len;
        const before_ok = p > 0 and (tag[p - 1] == ' ' or tag[p - 1] == '\t' or tag[p - 1] == '\n');
        if (!before_ok or at + 1 >= tag.len or tag[at] != '=' or tag[at + 1] != '"') continue;
        const end = std.mem.indexOfScalarPos(u8, tag, at + 2, '"') orelse return null;
        return tag[at + 2 .. end];
    }
    return null;
}

fn num(tag: []const u8, name: []const u8) f32 {
    const v = attr(tag, name) orelse return 0;
    return std.fmt.parseFloat(f32, v) catch 0;
}

/// An element as path data (null: not a shape).
fn pathOf(a: std.mem.Allocator, name: []const u8, tag: []const u8) !?[]const u8 {
    if (std.mem.eql(u8, name, "path")) return attr(tag, "d");
    if (std.mem.eql(u8, name, "rect")) {
        const x = num(tag, "x");
        const y = num(tag, "y");
        const w = num(tag, "width");
        const h = num(tag, "height");
        var rx = num(tag, "rx");
        var ry = num(tag, "ry");
        if (attr(tag, "ry") == null) ry = rx;
        if (attr(tag, "rx") == null) rx = ry;
        rx = @min(rx, w / 2);
        ry = @min(ry, h / 2);
        if (rx <= 0 or ry <= 0) return try std.fmt.allocPrint(a, "M{d} {d}H{d}V{d}H{d}Z", .{ x, y, x + w, y + h, x });
        return try std.fmt.allocPrint(a, "M{d} {d}H{d}A{d} {d} 0 0 1 {d} {d}V{d}A{d} {d} 0 0 1 {d} {d}H{d}A{d} {d} 0 0 1 {d} {d}V{d}A{d} {d} 0 0 1 {d} {d}Z", .{
            x + rx,     y,  x + w - rx, rx,         ry,    x + w,  y + ry,
            y + h - ry, rx, ry,         x + w - rx, y + h, x + rx, rx,
            ry,         x,  y + h - ry, y + ry,     rx,    ry,     x + rx,
            y,
        });
    }
    if (std.mem.eql(u8, name, "circle") or std.mem.eql(u8, name, "ellipse")) {
        const cx = num(tag, "cx");
        const cy = num(tag, "cy");
        const rx = if (attr(tag, "r") != null) num(tag, "r") else num(tag, "rx");
        const ry = if (attr(tag, "r") != null) num(tag, "r") else num(tag, "ry");
        return try std.fmt.allocPrint(a, "M{d} {d}A{d} {d} 0 1 0 {d} {d}A{d} {d} 0 1 0 {d} {d}Z", .{ cx - rx, cy, rx, ry, cx + rx, cy, rx, ry, cx - rx, cy });
    }
    if (std.mem.eql(u8, name, "line")) {
        return try std.fmt.allocPrint(a, "M{d} {d}L{d} {d}", .{ num(tag, "x1"), num(tag, "y1"), num(tag, "x2"), num(tag, "y2") });
    }
    if (std.mem.eql(u8, name, "polyline") or std.mem.eql(u8, name, "polygon")) {
        const pts = attr(tag, "points") orelse return null;
        const z = if (std.mem.eql(u8, name, "polygon")) "Z" else "";
        return try std.fmt.allocPrint(a, "M{s}{s}", .{ pts, z });
    }
    return null;
}

/// A vector network made from path data: vertices, segments (with the curves' tangents),
/// and for a filled shape a region of its closed subpaths.
const Builder = struct {
    a: std.mem.Allocator,
    vertices: std.ArrayList(Vec2) = .empty,
    segments: std.ArrayList(m.Segment) = .empty,
    loops: std.ArrayList([]u32) = .empty,
    /// The current subpath's segments.
    open: std.ArrayList(u32) = .empty,
    cur: Vec2 = .{},
    start: Vec2 = .{},
    cur_v: u32 = 0,
    start_v: u32 = 0,

    fn moveTo(b: *Builder, p: Vec2) !void {
        try b.endSubpath(false);
        b.cur = p;
        b.start = p;
        b.cur_v = @intCast(b.vertices.items.len);
        b.start_v = b.cur_v;
        try b.vertices.append(b.a, p);
    }

    fn curveTo(b: *Builder, c1: Vec2, c2: Vec2, p: Vec2) !void {
        const v: u32 = @intCast(b.vertices.items.len);
        try b.vertices.append(b.a, p);
        try b.segments.append(b.a, .{
            .from = b.cur_v,
            .to = v,
            .t0 = .{
                .x = c1.x - b.cur.x,
                .y = c1.y - b.cur.y,
            },
            .t1 = .{
                .x = c2.x - p.x,
                .y = c2.y - p.y,
            },
        });
        try b.open.append(b.a, @intCast(b.segments.items.len - 1));
        b.cur = p;
        b.cur_v = v;
    }

    fn lineTo(b: *Builder, p: Vec2) !void {
        try b.curveTo(b.cur, p, p);
    }

    fn close(b: *Builder) !void {
        if (b.cur.x != b.start.x or b.cur.y != b.start.y) {
            try b.segments.append(b.a, .{
                .from = b.cur_v,
                .to = b.start_v,
            });
            try b.open.append(b.a, @intCast(b.segments.items.len - 1));
        } else if (b.open.items.len > 0) {
            // The last segment already ends on the start: end it on the start's vertex.
            b.segments.items[b.open.items[b.open.items.len - 1]].to = b.start_v;
        }
        b.cur = b.start;
        b.cur_v = b.start_v;
        try b.endSubpath(true);
    }

    fn endSubpath(b: *Builder, closed: bool) !void {
        if (closed and b.open.items.len > 0) try b.loops.append(b.a, try b.a.dupe(u32, b.open.items));
        b.open.clearRetainingCapacity();
    }

    fn network(b: *Builder, filled: bool) !m.Network {
        try b.endSubpath(false);
        var regions: []m.Region = &.{};
        if (filled and b.loops.items.len > 0) {
            regions = try b.a.alloc(m.Region, 1);
            regions[0] = .{
                .loops = b.loops.items,
            };
        }
        return .{
            .vertices = b.vertices.items,
            .segments = b.segments.items,
            .regions = regions,
        };
    }

    fn path(b: *Builder, d: []const u8) !void {
        var i: usize = 0;
        var cmd: u8 = 'M';
        // The last curve's control point, for S (and T): reflected; null after other commands.
        var last_c2: ?Vec2 = null;
        while (true) {
            skip(d, &i);
            if (i >= d.len) break;
            if (std.ascii.isAlphabetic(d[i])) {
                cmd = d[i];
                i += 1;
                if (cmd == 'Z' or cmd == 'z') {
                    try b.close();
                    last_c2 = null;
                    continue;
                }
            }
            const rel = std.ascii.isLower(cmd);
            const o: Vec2 = if (rel) b.cur else .{};
            const up = std.ascii.toUpper(cmd);
            switch (up) {
                'M' => {
                    try b.moveTo(try point(d, &i, o));
                    // Pairs after a move are lines.
                    cmd = if (rel) 'l' else 'L';
                    last_c2 = null;
                },
                'L' => {
                    try b.lineTo(try point(d, &i, o));
                    last_c2 = null;
                },
                'H' => {
                    try b.lineTo(.{
                        .x = o.x + try number(d, &i),
                        .y = b.cur.y,
                    });
                    last_c2 = null;
                },
                'V' => {
                    try b.lineTo(.{
                        .x = b.cur.x,
                        .y = o.y + try number(d, &i),
                    });
                    last_c2 = null;
                },
                'C', 'S' => {
                    const c1: Vec2 = if (up == 'C') try point(d, &i, o) else if (last_c2) |l| .{
                        .x = 2 * b.cur.x - l.x,
                        .y = 2 * b.cur.y - l.y,
                    } else b.cur;
                    const c2 = try point(d, &i, o);
                    const p = try point(d, &i, o);
                    try b.curveTo(c1, c2, p);
                    last_c2 = c2;
                },
                'Q' => {
                    const q = try point(d, &i, o);
                    const p = try point(d, &i, o);
                    // The quadratic as a cubic: control points two thirds of the way to q.
                    try b.curveTo(.{
                        .x = b.cur.x + (q.x - b.cur.x) * 2 / 3,
                        .y = b.cur.y + (q.y - b.cur.y) * 2 / 3,
                    }, .{
                        .x = p.x + (q.x - p.x) * 2 / 3,
                        .y = p.y + (q.y - p.y) * 2 / 3,
                    }, p);
                    last_c2 = null;
                },
                'A' => {
                    const rx = @abs(try number(d, &i));
                    const ry = @abs(try number(d, &i));
                    const rot = try number(d, &i);
                    const large = try flag(d, &i);
                    const sweep = try flag(d, &i);
                    const p = try point(d, &i, o);
                    try b.arcTo(rx, ry, rot, large, sweep, p);
                    last_c2 = null;
                },
                else => return error.UnsupportedPathCommand,
            }
        }
    }

    /// An elliptical arc as cubic curves of at most a quarter turn each (SVG's endpoint
    /// parameters turned into a centre, as the SVG spec's appendix does).
    fn arcTo(b: *Builder, rx_in: f32, ry_in: f32, rot_deg: f32, large: bool, sweep: bool, p: Vec2) !void {
        const p0 = b.cur;
        if (rx_in == 0 or ry_in == 0 or (p0.x == p.x and p0.y == p.y)) return b.lineTo(p);
        const phi = rot_deg * std.math.pi / 180;
        const cos = @cos(phi);
        const sin = @sin(phi);
        const dx = (p0.x - p.x) / 2;
        const dy = (p0.y - p.y) / 2;
        const x1 = cos * dx + sin * dy;
        const y1 = -sin * dx + cos * dy;
        var rx = rx_in;
        var ry = ry_in;
        const lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry);
        if (lambda > 1) {
            rx *= @sqrt(lambda);
            ry *= @sqrt(lambda);
        }
        const num_ = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1;
        const den = rx * rx * y1 * y1 + ry * ry * x1 * x1;
        var co = @sqrt(@max(0, num_ / den));
        if (large == sweep) co = -co;
        const cxp = co * rx * y1 / ry;
        const cyp = -co * ry * x1 / rx;
        const cx = cos * cxp - sin * cyp + (p0.x + p.x) / 2;
        const cy = sin * cxp + cos * cyp + (p0.y + p.y) / 2;
        const t1 = angle(1, 0, (x1 - cxp) / rx, (y1 - cyp) / ry);
        var dt = angle((x1 - cxp) / rx, (y1 - cyp) / ry, (-x1 - cxp) / rx, (-y1 - cyp) / ry);
        if (!sweep and dt > 0) dt -= 2 * std.math.pi;
        if (sweep and dt < 0) dt += 2 * std.math.pi;
        const n: usize = @intFromFloat(@ceil(@abs(dt) / (std.math.pi / 2.0)));
        const step = dt / @as(f32, @floatFromInt(@max(n, 1)));
        const k = 4.0 / 3.0 * @tan(step / 4);
        var a0 = t1;
        for (0..@max(n, 1)) |s| {
            const a1 = a0 + step;
            const e0 = ellipsePoint(cx, cy, rx, ry, cos, sin, a0);
            const e1 = ellipsePoint(cx, cy, rx, ry, cos, sin, a1);
            const d0 = ellipseTangent(rx, ry, cos, sin, a0);
            const d1 = ellipseTangent(rx, ry, cos, sin, a1);
            // The last piece ends exactly where the arc does.
            const end = if (s + 1 == @max(n, 1)) p else e1;
            try b.curveTo(.{
                .x = e0.x + k * d0.x,
                .y = e0.y + k * d0.y,
            }, .{
                .x = e1.x - k * d1.x,
                .y = e1.y - k * d1.y,
            }, end);
            a0 = a1;
        }
    }
};

fn angle(ux: f32, uy: f32, vx: f32, vy: f32) f32 {
    const a = std.math.atan2(uy, ux);
    const b = std.math.atan2(vy, vx);
    var d = b - a;
    while (d > std.math.pi) d -= 2 * std.math.pi;
    while (d < -std.math.pi) d += 2 * std.math.pi;
    return d;
}

fn ellipsePoint(cx: f32, cy: f32, rx: f32, ry: f32, cos: f32, sin: f32, t: f32) Vec2 {
    const x = rx * @cos(t);
    const y = ry * @sin(t);
    return .{
        .x = cx + cos * x - sin * y,
        .y = cy + sin * x + cos * y,
    };
}

fn ellipseTangent(rx: f32, ry: f32, cos: f32, sin: f32, t: f32) Vec2 {
    const x = -rx * @sin(t);
    const y = ry * @cos(t);
    return .{
        .x = cos * x - sin * y,
        .y = sin * x + cos * y,
    };
}

fn skip(d: []const u8, i: *usize) void {
    while (i.* < d.len and (d[i.*] == ' ' or d[i.*] == ',' or d[i.*] == '\n' or d[i.*] == '\t')) i.* += 1;
}

fn point(d: []const u8, i: *usize, o: Vec2) !Vec2 {
    return .{
        .x = o.x + try number(d, i),
        .y = o.y + try number(d, i),
    };
}

/// An arc's flag: one digit, which SVG lets run into what follows ("0 0110 10").
fn flag(d: []const u8, i: *usize) !bool {
    skip(d, i);
    if (i.* >= d.len or (d[i.*] != '0' and d[i.*] != '1')) return error.BadPathNumber;
    i.* += 1;
    return d[i.* - 1] == '1';
}

fn number(d: []const u8, i: *usize) !f32 {
    skip(d, i);
    const from = i.*;
    if (i.* < d.len and (d[i.*] == '-' or d[i.*] == '+')) i.* += 1;
    var dot = false;
    while (i.* < d.len) : (i.* += 1) {
        const ch = d[i.*];
        if (std.ascii.isDigit(ch)) continue;
        if (ch == '.' and !dot) {
            dot = true;
            continue;
        }
        if ((ch == 'e' or ch == 'E') and i.* + 1 < d.len) {
            i.* += 1;
            continue;
        }
        break;
    }
    if (i.* == from) return error.BadPathNumber;
    return std.fmt.parseFloat(f32, d[from..i.*]);
}

test "a path's strokes become segments" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const s = try shapes(arena.allocator(),
        \\<path d="M18 6L6 18M6 6l12 12" stroke="currentColor"/>
    );
    try std.testing.expectEqual(@as(usize, 1), s.len);
    try std.testing.expectEqual(@as(usize, 4), s[0].net.vertices.len);
    try std.testing.expectEqual(@as(usize, 2), s[0].net.segments.len);
    try std.testing.expect(s[0].stroke and !s[0].fill);
}

test "a filled rounded rect is one closed region" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const s = try shapes(arena.allocator(),
        \\<g fill="none" stroke="currentColor" stroke-width="2"><rect x="7" y="6" width="2.5" height="10" rx="1" fill="currentColor"/></g>
    );
    try std.testing.expectEqual(@as(usize, 1), s.len);
    try std.testing.expect(s[0].fill and s[0].stroke);
    try std.testing.expectEqual(@as(f32, 2), s[0].width);
    try std.testing.expectEqual(@as(usize, 1), s[0].net.regions.len);
    try std.testing.expectEqual(@as(usize, 1), s[0].net.regions[0].loops.len);
}

test "every Publr icon can be read" {
    const icons = @import("publr_icons");
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    inline for (@typeInfo(icons).@"struct".decl_names) |d_name| {
        const v = @field(icons, d_name);
        if (@TypeOf(v) == []const u8 and std.mem.indexOfScalar(u8, v, '<') != null) {
            const s = shapes(arena.allocator(), v) catch |e| {
                std.debug.print("icon {s}: {}\n", .{ d_name, e });
                return e;
            };
            if (s.len == 0) {
                std.debug.print("icon {s}: no shapes\n", .{d_name});
                return error.NoShapes;
            }
        }
    }
}
