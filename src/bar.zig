//! The tab bar: the traffic lights' corner, Home, a tab per open site, and + (Home).
//! Layout and hit testing together, so what is drawn is what answers the mouse.

const std = @import("std");
const ui = @import("ui");
const icons = @import("publr_icons");
const Theme = @import("theme.zig").Theme;

pub const height: f32 = 38;
/// Where the traffic lights sit.
const lights_width: f32 = 78;
const home_width: f32 = 44;
const tab_max: f32 = 200;
const tab_min: f32 = 96;
const plus_width: f32 = 36;
const browser_width: f32 = 40;
const close_size: f32 = 20;

pub const Target = union(enum) {
    none,
    /// Empty bar: moves the window.
    bar,
    home,
    tab: usize,
    tab_close: usize,
    plus,
    /// The page the tab shows, opened in the person's browser.
    browser,
};

pub const State = struct {
    titles: []const []const u8,
    /// The tab shown; null: Home.
    active: ?usize,
    hover: Target,
    width: f32,
    /// The tab shows a web page, which the bar offers to open in the browser.
    browser: bool = false,
};

fn tabWidth(s: State) f32 {
    const room = s.width - lights_width - home_width - plus_width - browser_width - 8;
    const n: f32 = @floatFromInt(@max(s.titles.len, 1));
    return std.math.clamp(room / n, tab_min, tab_max);
}

pub fn tabRect(s: State, i: usize) ui.Rect {
    const w = tabWidth(s);
    return .{
        .x = lights_width + home_width + w * @as(f32, @floatFromInt(i)),
        .y = 0,
        .w = w,
        .h = height,
    };
}

pub fn closeRect(tab: ui.Rect) ui.Rect {
    return .{
        .x = tab.x + tab.w - close_size - 8,
        .y = (height - close_size) / 2,
        .w = close_size,
        .h = close_size,
    };
}

pub fn homeRect() ui.Rect {
    return .{
        .x = lights_width,
        .y = 0,
        .w = home_width,
        .h = height,
    };
}

pub fn plusRect(s: State) ui.Rect {
    const last = tabRect(s, s.titles.len);
    return .{
        .x = last.x,
        .y = 0,
        .w = plus_width,
        .h = height,
    };
}

/// Open in browser, at the bar's right end.
pub fn browserRect(s: State) ui.Rect {
    return .{
        .x = s.width - browser_width - 8,
        .y = 0,
        .w = browser_width,
        .h = height,
    };
}

pub fn hit(s: State, x: f64, y: f64) Target {
    if (y >= height) return .none;
    if (homeRect().contains(x, y)) return .home;
    for (0..s.titles.len) |i| {
        const r = tabRect(s, i);
        if (!r.contains(x, y)) continue;
        if (closeRect(r).contains(x, y)) return .{ .tab_close = i };
        return .{ .tab = i };
    }
    if (plusRect(s).contains(x, y)) return .plus;
    if (s.browser and browserRect(s).contains(x, y)) return .browser;
    return .bar;
}

/// What a hover on `t` changes on screen.
pub fn targetRect(s: State, t: Target) ?ui.Rect {
    return switch (t) {
        .none, .bar => null,
        .home => homeRect(),
        .tab, .tab_close => |i| if (i < s.titles.len) tabRect(s, i) else null,
        .plus => plusRect(s),
        .browser => browserRect(s),
    };
}

fn same(a: Target, b: Target) bool {
    return std.meta.eql(a, b);
}

pub fn draw(u: *ui.Ui, s: State, t: *const Theme) !void {
    try u.rect(.{
        .x = 0,
        .y = 0,
        .w = s.width,
        .h = height,
    }, t.bar, 0);

    const home = homeRect();
    if (s.active == null) try u.rect(home, t.tab_active, 0) else if (same(s.hover, .home)) try u.rect(home, t.tab_hover, 0);
    try u.icon(centred(home, 16), icons.home, if (s.active == null) t.text else t.text2);
    try separator(u, home.x + home.w, t);

    for (s.titles, 0..) |title, i| {
        const r = tabRect(s, i);
        const active = s.active == i;
        const hovered = same(s.hover, .{ .tab = i }) or same(s.hover, .{ .tab_close = i });
        if (active) try u.rect(r, t.tab_active, 0) else if (hovered) try u.rect(r, t.tab_hover, 0);
        try u.text(.{
            .x = r.x + 14,
            .y = 0,
            .w = r.w - 14 - close_size - 14,
            .h = height,
        }, title, .{
            .size = 13,
            .weight = if (active) 500 else 400,
            .color = if (active) t.text else t.text2,
        });
        if (active or hovered) {
            const cr = closeRect(r);
            if (same(s.hover, .{ .tab_close = i })) try u.rect(cr, t.hover, 4);
            try u.icon(centred(cr, 14), icons.x_close, if (active) t.text else t.text2);
        }
        try separator(u, r.x + r.w, t);
    }

    const plus = plusRect(s);
    if (same(s.hover, .plus)) try u.rect(.{
        .x = plus.x + 6,
        .y = 7,
        .w = plus.w - 12,
        .h = height - 14,
    }, t.tab_hover, 4);
    try u.icon(centred(plus, 16), icons.plus, t.text2);

    if (s.browser) {
        const browser = browserRect(s);
        const hovered = same(s.hover, .browser);
        if (hovered) try u.rect(.{
            .x = browser.x + 6,
            .y = 7,
            .w = browser.w - 12,
            .h = height - 14,
        }, t.tab_hover, 4);
        try u.icon(centred(browser, 16), icons.external, if (hovered) t.text else t.text2);
    }

    // The line between the bar and what is under it.
    try u.rect(.{
        .x = 0,
        .y = height - 1,
        .w = s.width,
        .h = 1,
    }, t.border, 0);
}

fn separator(u: *ui.Ui, x: f32, t: *const Theme) !void {
    try u.rect(.{
        .x = x - 1,
        .y = 0,
        .w = 1,
        .h = height,
    }, t.border, 0);
}

pub fn centred(r: ui.Rect, size: f32) ui.Rect {
    return .{
        .x = r.x + (r.w - size) / 2,
        .y = r.y + (r.h - size) / 2,
        .w = size,
        .h = size,
    };
}

test "the bar answers the mouse where it draws" {
    const titles = [_][]const u8{ "sklep", "bulk-test" };
    const s: State = .{
        .titles = &titles,
        .active = 0,
        .hover = .none,
        .width = 1200,
    };
    const t = std.testing;
    // The traffic lights' corner and the empty bar move the window.
    try t.expect(std.meta.eql(hit(s, 30, 19), Target.bar));
    try t.expect(std.meta.eql(hit(s, 1100, 19), Target.bar));
    try t.expect(std.meta.eql(hit(s, 100, 19), Target.home));
    try t.expect(std.meta.eql(hit(s, 140, 19), Target{ .tab = 0 }));
    const first = tabRect(s, 0);
    try t.expect(std.meta.eql(hit(s, first.x + first.w - 18, 19), Target{ .tab_close = 0 }));
    try t.expect(std.meta.eql(hit(s, tabRect(s, 1).x + 10, 19), Target{ .tab = 1 }));
    try t.expect(std.meta.eql(hit(s, plusRect(s).x + 10, 19), Target.plus));
    try t.expect(std.meta.eql(hit(s, 300, 300), Target.none));
}
