//! Home: every project, in one list, each once. Laid out as PublrDesign's file browser (a
//! sidebar, the projects as pictures in a grid or as rows) and set as Publr's admin is: its
//! type, greys, sidebar, page title and buttons. The sidebar filters the one list (Recent,
//! All projects, On this Mac, On Cloud, each space when there are several; the account at
//! its foot), the bar (where you are, grid or list), the page's title with New project, the
//! projects, and a project's menu. A project on Cloud with its working copy on this Mac is
//! one card. Layout and hit testing together, so what is drawn is what answers the mouse.

const std = @import("std");
const ui = @import("ui");
const icons = @import("publr_icons");
const mark = @import("mark.zig");
const Theme = @import("theme.zig").Theme;
const i18n = @import("i18n.zig");
const translated = i18n.translated;
const translated_count = i18n.translated_count;
const centred = @import("bar.zig").centred;

pub const sidebar_width: f32 = 240;
const header_height: f32 = 48;
/// The page's title, its count and New project, under the bar.
const head_height: f32 = 100;
const pad: f32 = 24;
const gap: f32 = 20;
const card_min: f32 = 224;
const meta_height: f32 = 50;
const row_height: f32 = 56;
/// A sidebar row (28) and the 2 between rows.
const nav_step: f32 = 30;
const nav_row: f32 = 28;
/// A section's label ("CLOUD") with the room above it.
const label_height: f32 = 42;
const account_height: f32 = 56;
const menu_width: f32 = 220;
const menu_item: f32 = 30;
const menu_pad: f32 = 6;

pub const Kind = enum {
    /// Only on this Mac.
    local,
    /// Only on Cloud.
    cloud,
    /// On Cloud, its working copy on this Mac.
    both,
};

/// A pill on a card: an update is out, or Cloud's Publr cannot open the project.
pub const Badge = enum { none, update, local_only };

/// A project as Home shows it.
pub const Item = struct {
    name: []const u8,
    /// "Running", "ada.publr.app · Live", "Up to date": where it is shows as its marks.
    detail: []const u8,
    kind: Kind,
    running: bool,
    /// Work of its own waiting to reach Cloud: the dot says so.
    changed: bool = false,
    /// Its thumbnail's name in the `ui` (null: none yet).
    thumb: ?[]const u8 = null,
    /// Where it stands against the Publr Cloud runs, as a pill skimming the list catches.
    badge: Badge = .none,
    /// Where it is, as its section's label: the folder holding it ("~/Publr"), "On Cloud".
    /// Items of one group come together; labels show when there are two groups or more.
    group: []const u8 = "",
};

/// The filter on the one list.
pub const View = union(enum) {
    recents,
    all,
    local,
    cloud,
    /// One space's, listed when there are several.
    space: usize,
    /// One folder's sites on this Mac, listed when there are several.
    folder: usize,
    /// Not a filter: the Settings page beside the sidebar (`settings.zig` draws it).
    settings,
};

pub const Space = struct {
    name: []const u8,
    count: usize,
};

pub const Account = union(enum) {
    signed_out,
    /// The browser is open on Cloud's sign-in page.
    signing_in,
    signed_in: []const u8,
};

pub const Layout = enum {
    grid,
    list,
};

pub const MenuItem = struct {
    title: []const u8 = "",
    tag: u32 = 0,
    enabled: bool = true,
    separator: bool = false,
};

pub const Menu = struct {
    x: f32,
    /// Its top, or its bottom when it opens upward.
    y: f32,
    items: []const MenuItem,
    /// Opens upward from `y` (the account's menu, at the sidebar's foot).
    above: bool = false,
};

pub const Target = union(enum) {
    none,
    account,
    sign_in,
    recents,
    all,
    local,
    cloud,
    space: usize,
    folder: usize,
    settings,
    show_grid,
    show_list,
    /// Every site on this Mac and every Cloud project read again.
    refresh,
    new_site,
    item: usize,
    item_menu: usize,
    menu_item: usize,
    /// A click outside an open menu closes it.
    outside_menu,
};

pub const State = struct {
    /// Where Home starts (under the tab bar).
    top: f32,
    width: f32,
    height: f32,
    view: View,
    layout: Layout,
    items: []const Item,
    all_count: usize,
    local_count: usize,
    cloud_count: usize,
    spaces: []const Space,
    /// The folders sites on this Mac are in, as people read them (`~/Publr`), with their
    /// counts.
    folders: []const Space = &.{},
    account: Account,
    hover: Target,
    scroll: f32,
    menu: ?Menu,
    title: []const u8,
};

fn same(a: Target, b: Target) bool {
    return std.meta.eql(a, b);
}

// Layout.

fn contentRect(s: State) ui.Rect {
    const top = s.top + header_height + head_height;
    return .{
        .x = sidebar_width,
        .y = top,
        .w = s.width - sidebar_width,
        .h = s.height - top,
    };
}

fn columns(s: State) usize {
    const room = contentRect(s).w - 2 * pad;
    return @max(1, @as(usize, @intFromFloat(@floor((room + gap) / (card_min + gap)))));
}

fn cardWidth(s: State) f32 {
    const n: f32 = @floatFromInt(columns(s));
    return (contentRect(s).w - 2 * pad - gap * (n - 1)) / n;
}

/// Whether the items fall into sections: two groups or more among them.
fn grouped(s: State) bool {
    if (s.items.len == 0 or s.items[0].group.len == 0) return false;
    for (s.items[1..]) |it| if (!std.mem.eql(u8, it.group, s.items[0].group)) return true;
    return false;
}

/// Whether item `i` begins a section of its own.
fn startsSection(s: State, i: usize) bool {
    return i == 0 or !std.mem.eql(u8, s.items[i].group, s.items[i - 1].group);
}

/// How tall `n` items stand, without a label.
fn itemsHeight(s: State, n: usize) f32 {
    return switch (s.layout) {
        .grid => blk: {
            const h = cardWidth(s) * 3 / 4 + meta_height;
            const rows: f32 = @floatFromInt((n + columns(s) - 1) / columns(s));
            break :blk rows * (h + gap);
        },
        .list => row_height * @as(f32, @floatFromInt(n)),
    };
}

/// Where item `i`'s section's items start, under its label, and `i`'s place among them.
const Place = struct {
    y: f32,
    k: usize,
};

fn placeOf(s: State, i: usize) Place {
    if (!grouped(s)) return .{
        .y = 0,
        .k = i,
    };
    var y: f32 = label_height;
    var start: usize = 0;
    var j: usize = 1;
    while (j <= i) : (j += 1) if (startsSection(s, j)) {
        y += itemsHeight(s, j - start) + label_height;
        start = j;
    };
    return .{
        .y = y,
        .k = i - start,
    };
}

/// The item's whole place (thumbnail and text, or the row), scrolled.
pub fn itemRect(s: State, i: usize) ui.Rect {
    const c = contentRect(s);
    const at = placeOf(s, i);
    switch (s.layout) {
        .grid => {
            const w = cardWidth(s);
            const h = w * 3 / 4 + meta_height;
            const col: f32 = @floatFromInt(at.k % columns(s));
            const row: f32 = @floatFromInt(at.k / columns(s));
            return .{
                .x = c.x + pad + col * (w + gap),
                .y = c.y + pad + at.y + row * (h + gap) - s.scroll,
                .w = w,
                .h = h,
            };
        },
        .list => return .{
            .x = c.x + pad,
            .y = c.y + at.y + row_height * @as(f32, @floatFromInt(at.k)) - s.scroll,
            .w = c.w - 2 * pad,
            .h = row_height,
        },
    }
}

/// The label over the section item `i` begins: the folder as it is spelled (a path is never
/// set in capitals), in the sidebar label's grey.
fn drawSectionLabel(u: *ui.Ui, s: State, t: *const Theme, i: usize) !void {
    const r = itemRect(s, i);
    try u.text(.{
        .x = r.x,
        .y = r.y - 30,
        .w = contentRect(s).w - 2 * pad,
        .h = 18,
    }, s.items[i].group, .{
        .size = 12,
        .weight = 600,
        .color = t.text2,
    });
    if (s.layout == .list) try u.rect(.{
        .x = r.x,
        .y = r.y - 1,
        .w = r.w,
        .h = 1,
    }, t.border, 0);
}

fn thumbRect(s: State, i: usize) ui.Rect {
    const r = itemRect(s, i);
    return switch (s.layout) {
        .grid => .{
            .x = r.x,
            .y = r.y,
            .w = r.w,
            .h = r.w * 3 / 4,
        },
        .list => .{
            .x = r.x + 8,
            .y = r.y + 10,
            .w = 48,
            .h = 36,
        },
    };
}

fn itemMenuRect(s: State, i: usize) ui.Rect {
    return switch (s.layout) {
        .grid => blk: {
            const t = thumbRect(s, i);
            break :blk .{
                .x = t.x + t.w - 36,
                .y = t.y + 8,
                .w = 28,
                .h = 28,
            };
        },
        .list => blk: {
            const r = itemRect(s, i);
            break :blk .{
                .x = r.x + r.w - 36,
                .y = r.y + (r.h - 28) / 2,
                .w = 28,
                .h = 28,
            };
        },
    };
}

/// How far the content scrolls at most.
pub fn maxScroll(s: State) f32 {
    if (s.items.len == 0) return 0;
    const last = itemRect(.{
        .top = s.top,
        .width = s.width,
        .height = s.height,
        .view = s.view,
        .layout = s.layout,
        .items = s.items,
        .all_count = s.all_count,
        .local_count = s.local_count,
        .cloud_count = s.cloud_count,
        .spaces = s.spaces,
        .folders = s.folders,
        .account = s.account,
        .hover = s.hover,
        .scroll = 0,
        .menu = null,
        .title = s.title,
    }, s.items.len - 1);
    const c = contentRect(s);
    return @max(0, last.y + last.h + pad - (c.y + c.h));
}

/// Settings, the sidebar's last row, just over the account.
fn settingsRect(s: State) ui.Rect {
    return .{
        .x = 8,
        .y = s.height - account_height - nav_step - 4,
        .w = sidebar_width - 16,
        .h = nav_row,
    };
}

/// The account at the sidebar's foot: you, or Sign in to Publr Cloud.
fn accountRect(s: State) ui.Rect {
    return .{
        .x = 8,
        .y = s.height - account_height + 10,
        .w = sidebar_width - 16,
        .h = account_height - 20,
    };
}

fn navRect(s: State, k: usize) ui.Rect {
    return .{
        .x = 8,
        .y = s.top + header_height + 8 + nav_step * @as(f32, @floatFromInt(k)),
        .w = sidebar_width - 16,
        .h = nav_row,
    };
}

/// Where the account's menu ends: just above the account.
pub fn accountMenuBottom(s: State) f32 {
    return accountRect(s).y - 4;
}

/// Folders are filters of their own only when there are several.
fn foldersListed(s: State) usize {
    return if (s.folders.len > 1) s.folders.len else 0;
}

/// A folder's row, under On this Mac, set in.
fn folderRect(s: State, i: usize) ui.Rect {
    var r = navRect(s, 3 + i);
    r.x += 16;
    r.w -= 16;
    return r;
}

/// The Cloud section's label, under Recent, All projects, On this Mac and its folders.
fn cloudLabelRect(s: State) ui.Rect {
    var r = navRect(s, 3 + foldersListed(s));
    r.h = label_height;
    return r;
}

/// The Cloud section's rows: On Cloud, then each space when there are several.
fn cloudRowRect(s: State, k: usize) ui.Rect {
    var r = navRect(s, 3 + foldersListed(s) + k);
    r.y += label_height;
    return r;
}

fn spaceRect(s: State, i: usize) ui.Rect {
    return cloudRowRect(s, 1 + i);
}

/// Spaces are filters of their own only when there are several.
fn spacesListed(s: State) usize {
    return if (s.spaces.len > 1) s.spaces.len else 0;
}

const button_text: ui.TextStyle = .{
    .size = 13,
    .weight = 500,
};

fn newLabel() []const u8 {
    return translated("New project");
}

fn newSiteRect(s: State, u: *ui.Ui) ui.Rect {
    const w = u.measure(newLabel(), button_text) + 28 + 22;
    return .{
        .x = s.width - pad - w,
        .y = s.top + header_height + 30,
        .w = w,
        .h = 36,
    };
}

fn layoutRect(s: State, which: Layout) ui.Rect {
    return .{
        .x = s.width - pad - 64 + @as(f32, if (which == .list) 32 else 0),
        .y = s.top + 9,
        .w = 32,
        .h = 30,
    };
}

/// Refresh, left of the grid and list button.
fn refreshRect(s: State) ui.Rect {
    return .{
        .x = s.width - pad - 64 - 8 - 32,
        .y = s.top + 9,
        .w = 32,
        .h = 30,
    };
}

fn menuItemHeight(it: MenuItem) f32 {
    return if (it.separator) 9 else menu_item;
}

pub fn menuRect(s: State) ?ui.Rect {
    const m = s.menu orelse return null;
    var h: f32 = 2 * menu_pad;
    for (m.items) |it| h += menuItemHeight(it);
    return .{
        .x = @min(m.x, s.width - menu_width - 8),
        .y = if (m.above) @max(s.top + 8, m.y - h) else @min(m.y, s.height - h - 8),
        .w = menu_width,
        .h = h,
    };
}

fn menuItemRect(s: State, k: usize) ui.Rect {
    const r = menuRect(s).?;
    var y = r.y + menu_pad;
    for (s.menu.?.items[0..k]) |it| y += menuItemHeight(it);
    return .{
        .x = r.x + menu_pad,
        .y = y,
        .w = r.w - 2 * menu_pad,
        .h = menuItemHeight(s.menu.?.items[k]),
    };
}

// Hit testing.

pub fn hit(s: State, u: *ui.Ui, x: f64, y: f64) Target {
    if (s.menu) |m| {
        if (!menuRect(s).?.contains(x, y)) return .outside_menu;
        for (m.items, 0..) |it, k| {
            if (it.separator or !it.enabled) continue;
            if (menuItemRect(s, k).contains(x, y)) return .{ .menu_item = k };
        }
        return .none;
    }
    if (x < sidebar_width) {
        if (accountRect(s).contains(x, y)) return if (s.account == .signed_in) .account else .sign_in;
        if (settingsRect(s).contains(x, y)) return .settings;
        if (navRect(s, 0).contains(x, y)) return .recents;
        if (navRect(s, 1).contains(x, y)) return .all;
        if (navRect(s, 2).contains(x, y)) return .local;
        for (0..foldersListed(s)) |i| {
            if (folderRect(s, i).contains(x, y)) return .{ .folder = i };
        }
        if (s.account == .signed_in) {
            if (cloudRowRect(s, 0).contains(x, y)) return .cloud;
            for (0..spacesListed(s)) |i| {
                if (spaceRect(s, i).contains(x, y)) return .{ .space = i };
            }
        }
        return .none;
    }
    // The Settings page answers its own clicks.
    if (s.view == .settings) return .none;
    if (y < s.top + header_height) {
        if (layoutRect(s, .grid).contains(x, y)) return .show_grid;
        if (layoutRect(s, .list).contains(x, y)) return .show_list;
        if (refreshRect(s).contains(x, y)) return .refresh;
        return .none;
    }
    if (y < s.top + header_height + head_height) {
        if (newSiteRect(s, u).contains(x, y)) return .new_site;
        return .none;
    }
    if (!contentRect(s).contains(x, y)) return .none;
    for (0..s.items.len) |i| {
        if (!itemRect(s, i).contains(x, y)) continue;
        if (itemMenuRect(s, i).contains(x, y)) return .{ .item_menu = i };
        return .{ .item = i };
    }
    return .none;
}

/// What a hover on `t` changes on screen (null: nothing of its own, or a menu: redraw all).
pub fn targetRect(s: State, u: *ui.Ui, t: Target) ?ui.Rect {
    if (s.menu != null) return null;
    return switch (t) {
        .none, .outside_menu, .menu_item => null,
        .account, .sign_in => accountRect(s),
        .settings => settingsRect(s),
        .recents => navRect(s, 0),
        .all => navRect(s, 1),
        .local => navRect(s, 2),
        .folder => |i| folderRect(s, i),
        .cloud => cloudRowRect(s, 0),
        .space => |i| spaceRect(s, i),
        .show_grid => layoutRect(s, .grid),
        .show_list => layoutRect(s, .list),
        .refresh => refreshRect(s),
        .new_site => newSiteRect(s, u),
        // Clipped to the content: the item may be half scrolled out.
        .item, .item_menu => |i| clipTo(itemRect(s, i), contentRect(s)),
    };
}

fn clipTo(r: ui.Rect, c: ui.Rect) ?ui.Rect {
    const x0 = @max(r.x, c.x);
    const y0 = @max(r.y, c.y);
    const x1 = @min(r.x + r.w, c.x + c.w);
    const y1 = @min(r.y + r.h, c.y + c.h);
    if (x1 <= x0 or y1 <= y0) return null;
    return .{
        .x = x0,
        .y = y0,
        .w = x1 - x0,
        .h = y1 - y0,
    };
}

// Drawing.

pub fn draw(u: *ui.Ui, s: State, t: *const Theme) !void {
    try u.rect(.{
        .x = 0,
        .y = s.top,
        .w = s.width,
        .h = s.height - s.top,
    }, t.bg, 0);
    try drawSidebar(u, s, t);
    if (s.view == .settings) return;
    try drawHeader(u, s, t);
    try drawHead(u, s, t);
    try drawContent(u, s, t);
    if (s.menu != null) try drawMenu(u, s, t);
}

fn drawSidebar(u: *ui.Ui, s: State, t: *const Theme) !void {
    try u.rect(.{
        .x = 0,
        .y = s.top,
        .w = sidebar_width,
        .h = s.height - s.top,
    }, t.sidebar, 0);
    try u.rect(.{
        .x = sidebar_width - 1,
        .y = s.top,
        .w = 1,
        .h = s.height - s.top,
    }, t.border, 0);

    // Publr's logo heads the sidebar, level with the bar: the mark and the name.
    const mark_size: f32 = 22;
    const art = mark_size * 24 / mark.units;
    try u.icon(.{
        .x = 16,
        .y = s.top + (header_height - mark_size) / 2,
        .w = art,
        .h = art,
    }, mark.markup, t.text);
    try u.text(.{
        .x = 16 + mark_size + 9,
        .y = s.top,
        .w = sidebar_width - 64,
        .h = header_height,
    }, "Publr", .{
        .size = 17,
        .weight = 600,
        .color = t.text,
        .tracking = -0.2,
    });
    try u.rect(.{
        .x = 0,
        .y = s.top + header_height - 1,
        .w = sidebar_width - 1,
        .h = 1,
    }, t.border, 0);

    var buf: [16]u8 = undefined;
    var all_buf: [16]u8 = undefined;
    try navItem(u, t, navRect(s, 0), icons.clock_rewind, translated("Recent"), null, s.view == .recents, same(s.hover, .recents));
    try navItem(u, t, navRect(s, 1), icons.layout_grid, translated("All projects"), std.fmt.bufPrint(&all_buf, "{d}", .{s.all_count}) catch null, s.view == .all, same(s.hover, .all));
    try navItem(u, t, navRect(s, 2), icons.device_desktop, translated("On this Mac"), std.fmt.bufPrint(&buf, "{d}", .{s.local_count}) catch null, s.view == .local, same(s.hover, .local));
    for (s.folders[0..foldersListed(s)], 0..) |f, i| {
        var fb: [16]u8 = undefined;
        const selected = switch (s.view) {
            .folder => |k| k == i,
            else => false,
        };
        try navItem(u, t, folderRect(s, i), icons.folder, f.name, std.fmt.bufPrint(&fb, "{d}", .{f.count}) catch null, selected, same(s.hover, .{ .folder = i }));
    }

    const label = cloudLabelRect(s);
    try u.text(.{
        .x = label.x + 10,
        .y = label.y + 20,
        .w = label.w - 20,
        .h = 16,
    }, translated("Cloud"), .{
        .size = 10,
        .weight = 600,
        .color = t.text2,
        .tracking = 1,
        .upper = true,
    });
    if (s.account == .signed_in) {
        var on_cloud: [16]u8 = undefined;
        try navItem(u, t, cloudRowRect(s, 0), icons.globe, translated("On Cloud"), std.fmt.bufPrint(&on_cloud, "{d}", .{s.cloud_count}) catch null, s.view == .cloud, same(s.hover, .cloud));
        for (s.spaces[0..spacesListed(s)], 0..) |sp, i| {
            var cb: [16]u8 = undefined;
            const selected = switch (s.view) {
                .space => |k| k == i,
                else => false,
            };
            try navItem(u, t, spaceRect(s, i), icons.folder, sp.name, std.fmt.bufPrint(&cb, "{d}", .{sp.count}) catch null, selected, same(s.hover, .{ .space = i }));
        }
    } else {
        const r = cloudRowRect(s, 0);
        try u.text(.{
            .x = r.x + 10,
            .y = r.y,
            .w = r.w - 20,
            .h = r.h,
        }, translated("Sign in to see your Cloud projects"), .{
            .size = 12,
            .color = t.text2,
        });
    }
    try navItem(u, t, settingsRect(s), icons.settings, translated("Settings"), null, s.view == .settings, same(s.hover, .settings));
    try drawAccount(u, s, t);
}

/// The sidebar's foot, as the admin keeps the account at its rail's foot.
fn drawAccount(u: *ui.Ui, s: State, t: *const Theme) !void {
    try u.rect(.{
        .x = 0,
        .y = s.height - account_height,
        .w = sidebar_width - 1,
        .h = 1,
    }, t.border, 0);
    const a = accountRect(s);
    switch (s.account) {
        .signed_in => |name| {
            if (same(s.hover, .account)) try u.rect(a, t.hover, 8);
            const dot: ui.Rect = .{
                .x = a.x + 8,
                .y = a.y + (a.h - 24) / 2,
                .w = 24,
                .h = 24,
            };
            try u.rect(dot, t.primary, 12);
            const initial = if (name.len > 0) name[0..@min(name.len, std.unicode.utf8ByteSequenceLength(name[0]) catch 1)] else "?";
            try u.text(dot, initial, .{
                .size = 11,
                .weight = 600,
                .color = t.on_primary,
                .@"align" = .center,
                .upper = true,
            });
            try u.text(.{
                .x = a.x + 42,
                .y = a.y,
                .w = a.w - 42 - 28,
                .h = a.h,
            }, name, .{
                .size = 13,
                .color = t.text,
            });
            try u.icon(.{
                .x = a.x + a.w - 24,
                .y = a.y + (a.h - 16) / 2,
                .w = 16,
                .h = 16,
            }, icons.chevron_up, t.text2);
        },
        .signed_out => try secondaryButton(u, t, a, translated("Sign in to Publr Cloud"), same(s.hover, .sign_in)),
        .signing_in => try u.text(a, translated("Signing in in your browser…"), .{
            .size = 12,
            .color = t.text2,
            .@"align" = .center,
        }),
    }
}

fn navItem(u: *ui.Ui, t: *const Theme, r: ui.Rect, icon: []const u8, label: []const u8, count: ?[]const u8, selected: bool, hovered: bool) !void {
    if (selected) try u.rect(r, t.selected, 8) else if (hovered) try u.rect(r, t.hover, 8);
    try u.icon(.{
        .x = r.x + 10,
        .y = r.y + 6,
        .w = 16,
        .h = 16,
    }, icon, t.text);
    try u.text(.{
        .x = r.x + 34,
        .y = r.y,
        .w = r.w - 34 - 36,
        .h = r.h,
    }, label, .{
        .size = 13,
        .color = t.text,
    });
    if (count) |c| try u.text(.{
        .x = r.x + r.w - 42,
        .y = r.y,
        .w = 32,
        .h = r.h,
    }, c, .{
        .size = 12,
        .color = t.text2,
        .@"align" = .right,
    });
}

/// The admin's white button with a grey edge.
fn secondaryButton(u: *ui.Ui, t: *const Theme, r: ui.Rect, label: []const u8, hovered: bool) !void {
    try u.box(r, .{
        .fill = if (hovered) t.hover else t.bg,
        .border = t.input,
        .radius = 8,
    });
    try u.text(r, label, .{
        .size = 13,
        .weight = 500,
        .color = t.text,
        .@"align" = .center,
    });
}

/// The bar: where you are ("Projects / On this Mac"), and grid or list.
fn drawHeader(u: *ui.Ui, s: State, t: *const Theme) !void {
    try u.rect(.{
        .x = sidebar_width,
        .y = s.top + header_height - 1,
        .w = s.width - sidebar_width,
        .h = 1,
    }, t.border, 0);
    const crumb: ui.TextStyle = .{
        .size = 13,
        .color = t.text2,
    };
    const projects = translated("Projects");
    const first = u.measure(projects, crumb);
    const slash = u.measure("/", crumb);
    var x = sidebar_width + pad;
    try u.text(.{
        .x = x,
        .y = s.top,
        .w = first,
        .h = header_height,
    }, projects, crumb);
    x += first + 8;
    try u.text(.{
        .x = x,
        .y = s.top,
        .w = slash,
        .h = header_height,
    }, "/", crumb);
    x += slash + 8;
    try u.text(.{
        .x = x,
        .y = s.top,
        .w = @max(0, s.width - x - pad - 80),
        .h = header_height,
    }, s.title, .{
        .size = 13,
        .weight = 500,
        .color = t.text,
    });

    // Refresh: an icon button of its own.
    const refresh = refreshRect(s);
    const refresh_hovered = same(s.hover, Target.refresh);
    try u.box(refresh, .{
        .fill = if (refresh_hovered) t.hover else t.bg,
        .border = t.input,
        .radius = 8,
    });
    try u.icon(centred(refresh, 16), icons.sync, if (refresh_hovered) t.text else t.text2);
    // Grid or list: two halves of one bordered button.
    const g = layoutRect(s, .grid);
    try u.box(.{
        .x = g.x,
        .y = g.y,
        .w = 64,
        .h = g.h,
    }, .{
        .fill = t.bg,
        .border = t.input,
        .radius = 8,
    });
    for ([_]Layout{ .grid, .list }) |which| {
        const r = layoutRect(s, which);
        const on = s.layout == which;
        const hovered = same(s.hover, if (which == .grid) Target.show_grid else Target.show_list);
        const inner: ui.Rect = .{
            .x = r.x + 3,
            .y = r.y + 3,
            .w = r.w - 6,
            .h = r.h - 6,
        };
        if (on) try u.rect(inner, t.selected, 6) else if (hovered) try u.rect(inner, t.hover, 6);
        try u.icon(centred(r, 16), if (which == .grid) icons.layout_grid else icons.list, if (on or hovered) t.text else t.text2);
    }
}

/// The page's title and how many projects it holds, with New project: the admin's page head.
fn drawHead(u: *ui.Ui, s: State, t: *const Theme) !void {
    const x = sidebar_width + pad;
    const w = @max(0, newSiteRect(s, u).x - x - 16);
    try u.text(.{
        .x = x,
        .y = s.top + header_height + 24,
        .w = w,
        .h = 34,
    }, s.title, .{
        .size = 28,
        .weight = 600,
        .color = t.text,
        .tracking = -0.56,
    });
    var buf: [64]u8 = undefined;
    const count_text = i18n.fill(&buf, translated_count("{count} project", "{count} projects", s.items.len), .{ .count = s.items.len });
    try u.text(.{
        .x = x,
        .y = s.top + header_height + 60,
        .w = w,
        .h = 20,
    }, count_text, .{
        .size = 14,
        .color = t.text2,
    });

    const n = newSiteRect(s, u);
    var fill = t.primary;
    if (same(s.hover, .new_site)) fill.a = 0.86;
    try u.rect(n, fill, 8);
    try u.icon(.{
        .x = n.x + 14,
        .y = n.y + 10,
        .w = 16,
        .h = 16,
    }, icons.plus, t.on_primary);
    try u.text(.{
        .x = n.x + 36,
        .y = n.y,
        .w = n.w - 36 - 14,
        .h = n.h,
    }, newLabel(), .{
        .size = button_text.size,
        .weight = button_text.weight,
        .color = t.on_primary,
    });
}

fn drawContent(u: *ui.Ui, s: State, t: *const Theme) !void {
    const c = contentRect(s);
    if (s.items.len == 0) {
        const empty = switch (s.view) {
            .recents => translated("Projects you open show up here."),
            .all => translated("No projects yet. New project makes one."),
            .local => translated("No projects on this Mac yet. New project makes one."),
            .folder => translated("No projects in this folder yet."),
            .cloud => translated("No projects on Cloud yet. New project makes one there."),
            .space => translated("No projects in this space yet. New project makes one."),
            .settings => "",
        };
        try u.text(.{
            .x = c.x + pad,
            .y = c.y + 8,
            .w = c.w - 2 * pad,
            .h = 20,
        }, empty, .{
            .size = 13,
            .color = t.text2,
        });
        return;
    }
    try u.beginClip(c);
    const sections = grouped(s);
    if (s.layout == .list and !sections) try u.rect(.{
        .x = c.x + pad,
        .y = c.y - s.scroll,
        .w = c.w - 2 * pad,
        .h = 1,
    }, t.border, 0);
    for (s.items, 0..) |it, i| {
        const r = itemRect(s, i);
        if (sections and startsSection(s, i) and r.y - label_height < c.y + c.h and r.y + r.h > c.y) {
            try drawSectionLabel(u, s, t, i);
        }
        if (r.y + r.h < c.y or r.y > c.y + c.h) continue;
        const hovered = same(s.hover, .{ .item = i }) or same(s.hover, .{ .item_menu = i });
        switch (s.layout) {
            .grid => try drawCard(u, s, t, i, it, hovered),
            .list => try drawRow(u, s, t, i, it, hovered),
        }
    }
    try u.endClip();
}

fn drawThumb(u: *ui.Ui, t: *const Theme, r: ui.Rect, it: Item, hovered: bool, radius: f32) !void {
    try u.box(r, .{
        .fill = t.hover,
        .radius = radius,
    });
    if (it.thumb) |key| try u.image(r, key, radius) else try u.icon(centred(r, @min(28, r.h / 2)), if (it.kind == .local) icons.device_desktop else icons.globe, t.text3);
    try u.box(r, .{
        .border = if (hovered) t.input else t.border,
        .radius = radius,
    });
    if (r.h >= 60) try drawMarks(u, t, r.x + 8, r.y + r.h - marks_size - 8, it.kind);
}

const pill_height: f32 = 20;
const pill_text: ui.TextStyle = .{
    .size = 11,
    .weight = 600,
    .color = ui.hex(0xffffff),
};

fn pillLabel(badge: Badge) []const u8 {
    return switch (badge) {
        .none => "",
        .update => translated("Update"),
        .local_only => translated("Local only"),
    };
}

pub fn pillWidth(u: *ui.Ui, badge: Badge) f32 {
    return if (badge == .none) 0 else u.measure(pillLabel(badge), pill_text) + 16;
}

/// The badge as a pill at `x`, `y`: red for local only, amber for an update.
pub fn drawPill(u: *ui.Ui, t: *const Theme, x: f32, y: f32, badge: Badge) !void {
    if (badge == .none) return;
    const r: ui.Rect = .{
        .x = x,
        .y = y,
        .w = pillWidth(u, badge),
        .h = pill_height,
    };
    try u.box(r, .{
        .fill = if (badge == .local_only) t.danger else t.preview,
        .radius = pill_height / 2,
    });
    try u.text(r, pillLabel(badge), .{
        .size = pill_text.size,
        .weight = pill_text.weight,
        .color = pill_text.color,
        .@"align" = .center,
    });
}

const marks_size: f32 = 22;

fn marksOf(kind: Kind) []const []const u8 {
    return switch (kind) {
        .local => &.{icons.device_desktop},
        .cloud => &.{icons.globe},
        .both => &.{ icons.globe, icons.device_desktop },
    };
}

pub fn marksWidth(kind: Kind) f32 {
    return 6 + marks_size * @as(f32, @floatFromInt(marksOf(kind).len));
}

/// Where a project is: Cloud, this Mac, or both, in a small box at `x`, `y`.
pub fn drawMarks(u: *ui.Ui, t: *const Theme, x: f32, y: f32, kind: Kind) !void {
    const marks = marksOf(kind);
    const size = marks_size;
    const box: ui.Rect = .{
        .x = x,
        .y = y,
        .w = marksWidth(kind),
        .h = size,
    };
    try u.box(box, .{
        .fill = t.bg,
        .border = t.border,
        .radius = 6,
    });
    for (marks, 0..) |glyph, k| try u.icon(centred(.{
        .x = box.x + 3 + size * @as(f32, @floatFromInt(k)),
        .y = box.y,
        .w = size,
        .h = size,
    }, 14), glyph, t.text2);
}

fn drawStatus(u: *ui.Ui, t: *const Theme, x: f32, y: f32, w: f32, it: Item) !void {
    try u.rect(.{
        .x = x,
        .y = y + 6,
        .w = 6,
        .h = 6,
    }, if (it.changed) t.preview else if (it.running) t.running else t.stopped, 3);
    try u.text(.{
        .x = x + 12,
        .y = y,
        .w = w - 12,
        .h = 18,
    }, it.detail, .{
        .size = 12,
        .color = t.text2,
    });
}

fn drawCard(u: *ui.Ui, s: State, t: *const Theme, i: usize, it: Item, hovered: bool) !void {
    const th = thumbRect(s, i);
    try drawThumb(u, t, th, it, hovered, 8);
    try drawPill(u, t, th.x + 8, th.y + 8, it.badge);
    try u.text(.{
        .x = th.x + 1,
        .y = th.y + th.h + 10,
        .w = th.w - 2,
        .h = 18,
    }, it.name, .{
        .size = 13,
        .weight = 500,
        .color = t.text,
    });
    try drawStatus(u, t, th.x + 1, th.y + th.h + 30, th.w - 2, it);
    if (hovered) try menuButton(u, s, t, i, true);
}

/// A row as the admin's tables have them: a line under each.
fn drawRow(u: *ui.Ui, s: State, t: *const Theme, i: usize, it: Item, hovered: bool) !void {
    const r = itemRect(s, i);
    if (hovered) try u.rect(r, t.hover, 0);
    try u.rect(.{
        .x = r.x,
        .y = r.y + r.h - 1,
        .w = r.w,
        .h = 1,
    }, t.border, 0);
    const th = thumbRect(s, i);
    try drawThumb(u, t, th, it, false, 6);
    try u.text(.{
        .x = th.x + th.w + 14,
        .y = r.y + 9,
        .w = r.w - th.w - 80,
        .h = 18,
    }, it.name, .{
        .size = 13,
        .weight = 500,
        .color = t.text,
    });
    try drawPill(u, t, th.x + th.w + 14 + u.measure(it.name, .{
        .size = 13,
        .weight = 500,
    }) + 10, r.y + 8, it.badge);
    try drawStatus(u, t, th.x + th.w + 14, r.y + 29, r.w - th.w - 80 - marksWidth(it.kind), it);
    try drawMarks(u, t, r.x + r.w - 56 - marksWidth(it.kind), r.y + (r.h - marks_size) / 2, it.kind);
    if (hovered) try menuButton(u, s, t, i, false);
}

fn menuButton(u: *ui.Ui, s: State, t: *const Theme, i: usize, on_thumb: bool) !void {
    const m = itemMenuRect(s, i);
    const over = same(s.hover, .{ .item_menu = i });
    try u.box(m, .{
        .fill = if (over) t.hover else if (on_thumb) t.bg else null,
        .border = if (on_thumb) t.input else null,
        .radius = 8,
    });
    try u.icon(centred(m, 16), icons.more, t.text);
}

/// The admin's dropdown: white, a grey edge, the chosen row's blue-grey under the pointer.
fn drawMenu(u: *ui.Ui, s: State, t: *const Theme) !void {
    const r = menuRect(s).?;
    try u.box(r, .{
        .fill = t.bg,
        .border = t.border,
        .radius = 10,
        .shadow = .{
            .color = t.shadow,
            .y = 8,
            .blur = 24,
        },
    });
    for (s.menu.?.items, 0..) |it, k| {
        const ir = menuItemRect(s, k);
        if (it.separator) {
            try u.rect(.{
                .x = r.x + 1,
                .y = ir.y + 4,
                .w = r.w - 2,
                .h = 1,
            }, t.border, 0);
            continue;
        }
        const over = it.enabled and same(s.hover, .{ .menu_item = k });
        if (over) try u.rect(ir, t.selected, 6);
        try u.text(.{
            .x = ir.x + 10,
            .y = ir.y,
            .w = ir.w - 20,
            .h = ir.h,
        }, it.title, .{
            .size = 13,
            .color = if (it.enabled) t.text else t.text3,
        });
    }
}
