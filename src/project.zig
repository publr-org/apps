//! A project's own tab. A sidebar holds the project: its name and whether this Mac is in
//! step, a card for its Overview and one for each app (its site's preview, or a placeholder
//! of the same size), and the admin at its foot. Overview is drawn here, as Cloud's project
//! page is laid out: the header with the admin, the one thing that needs the person now (if
//! anything), the apps as cards, the details. An app's site and the admin open beside the
//! sidebar, in the tab's web view. Rare things wait in the header's "more" menu.
//! Layout and hit testing together, so what is drawn is what answers the mouse.

const std = @import("std");
const ui = @import("ui");
const icons = @import("publr_icons");
const home = @import("home.zig");
const Theme = @import("theme.zig").Theme;
const centred = @import("bar.zig").centred;

pub const sidebar_width: f32 = 272;
const side_pad: f32 = 14;
const side_head: f32 = 76;
/// A sidebar card's picture: the top of the site, wider than tall.
const side_thumb_ratio: f32 = 0.52;
const side_label: f32 = 38;
const side_gap: f32 = 12;
const side_foot: f32 = 52;

const content_max: f32 = 1080;
const pad: f32 = 40;
const button_height: f32 = 36;
const callout_height: f32 = 64;
const card_min: f32 = 260;
const card_gap: f32 = 20;
const card_thumb_ratio: f32 = 0.56;
const card_body: f32 = 76;
const card_foot: f32 = 40;
const row_height: f32 = 52;
const menu_width: f32 = 230;
const menu_item: f32 = 32;
const menu_pad: f32 = 6;

/// One app of the project, by its folder's `app.zon`.
pub const App = struct {
    name: []const u8,
    label: []const u8,
    /// Where its site is ("https://shop.publr.app/blog"), empty when it cannot be told.
    address: []const u8,
    /// Its mount: "/", "/blog", or the subdomain ("docs.").
    mount: []const u8 = "/",
};

/// What the tab shows beside the sidebar.
pub const Page = union(enum) {
    overview,
    admin,
    site,
    app: usize,
};

/// The rare things, in the "more" menu.
pub const Rare = enum {
    clone,
    local_copy,
    finder,
    deploy,
    dashboard,
    remove,

    fn label(r: Rare) []const u8 {
        return switch (r) {
            .clone => "Clone to this Mac",
            .local_copy => "Open copy on this Mac",
            .finder => "Show in Finder",
            .deploy => "Deploy to Cloud\u{2026}",
            .dashboard => "Open in Cloud dashboard",
            .remove => "Remove from this Mac",
        };
    }

    fn icon(r: Rare) []const u8 {
        return switch (r) {
            .clone => icons.device_desktop,
            .local_copy => icons.device_desktop,
            .finder => icons.folder,
            .deploy => icons.upload,
            .dashboard => icons.globe,
            .remove => icons.trash,
        };
    }
};

pub const Target = union(enum) {
    none,
    /// A sidebar card or row: the page it opens.
    side: Page,
    admin,
    site,
    /// The address in the header: opens the site too.
    address,
    more,
    /// "Clone to this Mac", for a project only on Cloud.
    clone,
    rare: Rare,
    /// Outside the open menu: closes it.
    outside,
    /// The callout's action: send the work, or open its review.
    callout,
    /// An app's card on Overview.
    app: usize,
    finder,
    /// Advanced, at the details' foot: fold or unfold it.
    advanced,
    /// Under Advanced: a build of Publr for this project, or its own version again.
    choose_build,
    use_pin,
};

/// What needs the person now, if anything.
pub const Callout = enum { none, unsent, waiting, failed };

pub const State = struct {
    /// Where the tab's content starts: under the tab bar.
    top: f32,
    width: f32,
    height: f32,
    name: []const u8,
    kind: home.Kind,
    /// "Up to date", "Running on this Mac", "Live on Cloud".
    status: []const u8,
    running: bool,
    changed: bool,
    callout: Callout,
    /// The project's address: live on Cloud, else this Mac's.
    address: []const u8,
    /// The Cloud space; empty when not on Cloud or not known.
    space: []const u8,
    /// The folder on this Mac, as people read it (`~/Publr/shop`); empty when none.
    folder: []const u8,
    /// The Publr version it pins ("0.6.4"); empty when unknown.
    pin: []const u8 = "",
    /// A build of Publr chosen for this project, and one chosen for every project, as people
    /// read them; empty when none.
    own_build: []const u8 = "",
    shared_build: []const u8 = "",
    /// Advanced is unfolded.
    advanced: bool = false,
    /// Being cloned to this Mac now.
    cloning: bool = false,
    /// Its apps are being asked of the Publr it lives on: placeholder cards meanwhile.
    apps_loading: bool = false,
    apps: []const App,
    /// Each app's picture in the `ui`, by the apps' order; null where there is none yet.
    app_thumbs: []const ?[]const u8,
    menu_open: bool,
    /// How far Overview is scrolled.
    scroll: f32,
    page: Page,
    hover: Target,
};

fn thumbOf(s: State, k: usize) ?[]const u8 {
    return if (k < s.app_thumbs.len) s.app_thumbs[k] else null;
}

fn same(a: Target, b: Target) bool {
    return std.meta.eql(a, b);
}

fn samePage(a: Page, b: Page) bool {
    return std.meta.eql(a, b);
}

const button_text: ui.TextStyle = .{
    .size = 13,
    .weight = 500,
};

// The sidebar.

fn sideCardRect(s: State, k: usize) ui.Rect {
    const w = sidebar_width - 2 * side_pad;
    const h = w * side_thumb_ratio + side_label;
    return .{
        .x = side_pad,
        .y = s.top + side_head + (h + side_gap) * @as(f32, @floatFromInt(k)),
        .w = w,
        .h = h,
    };
}

/// The sidebar's cards: Overview, then each app.
fn sidePage(k: usize) Page {
    return if (k == 0) .overview else .{ .app = k - 1 };
}

fn adminRowRect(s: State) ui.Rect {
    return .{
        .x = side_pad - 4,
        .y = s.height - side_foot + 8,
        .w = sidebar_width - 2 * (side_pad - 4),
        .h = side_foot - 16,
    };
}

// Overview's layout, top to bottom, beside the sidebar.

fn contentX(s: State) f32 {
    const room = s.width - sidebar_width;
    return sidebar_width + @max(pad, (room - content_max) / 2);
}

fn contentWidth(s: State) f32 {
    return @min(content_max, s.width - sidebar_width - 2 * pad);
}

fn headTop(s: State) f32 {
    return s.top + 36 - s.scroll;
}

fn moreRect(s: State) ui.Rect {
    return .{
        .x = contentX(s) + contentWidth(s) - button_height,
        .y = headTop(s) + 4,
        .w = button_height,
        .h = button_height,
    };
}

fn adminRect(s: State, u: *ui.Ui) ui.Rect {
    const w = u.measure("Open admin", button_text) + 36;
    const more = moreRect(s);
    return .{
        .x = more.x - 8 - w,
        .y = more.y,
        .w = w,
        .h = button_height,
    };
}

fn siteLabel(s: State) []const u8 {
    return if (s.kind == .local) "View site" else "View live site";
}

fn siteRect(s: State, u: *ui.Ui) ui.Rect {
    const w = u.measure(siteLabel(s), button_text) + 32;
    const admin = adminRect(s, u);
    return .{
        .x = admin.x - 8 - w,
        .y = admin.y,
        .w = w,
        .h = button_height,
    };
}

fn cloneLabel(s: State) []const u8 {
    return if (s.cloning) "Cloning\u{2026}" else "Clone to this Mac";
}

fn cloneRect(s: State, u: *ui.Ui) ui.Rect {
    const w = u.measure(cloneLabel(s), button_text) + 32;
    const site = siteRect(s, u);
    return .{
        .x = site.x - 8 - w,
        .y = site.y,
        .w = w,
        .h = button_height,
    };
}

fn addressRect(s: State, u: *ui.Ui) ui.Rect {
    const after_status = if (s.callout == .none) 12 + u.measure(s.status, .{ .size = 13 }) + 22 else 0;
    const x = contentX(s) + after_status;
    return .{
        .x = x,
        .y = headTop(s) + 44,
        .w = u.measure(hostOf(s.address), .{ .size = 13 }),
        .h = 20,
    };
}

fn headBottom(s: State) f32 {
    return headTop(s) + 92;
}

fn calloutRect(s: State) ui.Rect {
    return .{
        .x = contentX(s),
        .y = headBottom(s),
        .w = contentWidth(s),
        .h = callout_height,
    };
}

fn appsTop(s: State) f32 {
    return headBottom(s) + (if (s.callout == .none) @as(f32, 0) else callout_height + 32);
}

fn columns(s: State) usize {
    const n: usize = @intFromFloat(@max(1, @floor((contentWidth(s) + card_gap) / (card_min + card_gap))));
    return @max(1, @min(n, 3));
}

fn cardWidth(s: State) f32 {
    const n: f32 = @floatFromInt(columns(s));
    return (contentWidth(s) - card_gap * (n - 1)) / n;
}

fn cardHeight(s: State) f32 {
    return cardWidth(s) * card_thumb_ratio + card_body + card_foot;
}

fn cardRect(s: State, k: usize) ui.Rect {
    const n = columns(s);
    const col: f32 = @floatFromInt(k % n);
    const line: f32 = @floatFromInt(k / n);
    return .{
        .x = contentX(s) + (cardWidth(s) + card_gap) * col,
        .y = appsTop(s) + 56 + (cardHeight(s) + card_gap) * line,
        .w = cardWidth(s),
        .h = cardHeight(s),
    };
}

/// Placeholder cards while a remote project's apps load.
const loading_cards = 3;

fn cardsShown(s: State) usize {
    return if (s.apps_loading) loading_cards else s.apps.len;
}

fn detailsTop(s: State) f32 {
    const lines = (@max(cardsShown(s), 1) + columns(s) - 1) / columns(s);
    return appsTop(s) + 56 + (cardHeight(s) + card_gap) * @as(f32, @floatFromInt(lines)) + 28;
}

fn detailRow(s: State, k: usize) ui.Rect {
    return .{
        .x = contentX(s),
        .y = detailsTop(s) + 56 + row_height * @as(f32, @floatFromInt(k)),
        .w = contentWidth(s),
        .h = row_height,
    };
}

const Detail = struct {
    label: []const u8,
    value: []const u8,
};

fn details(s: State, out: *[5]Detail) []const Detail {
    var n: usize = 0;
    out[n] = .{
        .label = "Name",
        .value = s.name,
    };
    n += 1;
    out[n] = .{
        .label = if (s.kind == .local) "Address" else "Live address",
        .value = hostOf(s.address),
    };
    n += 1;
    if (s.kind != .local) {
        out[n] = .{
            .label = "Cloud space",
            .value = if (s.space.len > 0) s.space else "\u{2014}",
        };
        n += 1;
    }
    if (s.folder.len > 0) {
        out[n] = .{
            .label = "On this Mac",
            .value = s.folder,
        };
        n += 1;
    }
    return out[0..n];
}

fn finderRect(s: State, u: *ui.Ui, list: []const Detail) ui.Rect {
    const r = detailRow(s, list.len - 1);
    const w = u.measure("Show in Finder", button_text) + 4;
    return .{
        .x = r.x + r.w - w,
        .y = r.y,
        .w = w,
        .h = r.h,
    };
}

// Advanced: a fold at the details' foot, for local projects; the build of Publr it runs.

fn lastDetailBottom(s: State) f32 {
    var list: [5]Detail = undefined;
    const last = detailRow(s, details(s, &list).len - 1);
    return last.y + last.h;
}

fn advancedRect(s: State) ui.Rect {
    return .{
        .x = contentX(s) - 8,
        .y = lastDetailBottom(s) + 16,
        .w = contentWidth(s) + 16,
        .h = 32,
    };
}

/// The fold's first line, under its row.
fn advancedTop(s: State) f32 {
    const a = advancedRect(s);
    return a.y + a.h + 8;
}

/// The chosen build's path box, when the fold says one.
fn buildRect(s: State) ui.Rect {
    return .{
        .x = contentX(s),
        .y = advancedTop(s) + 24,
        .w = contentWidth(s),
        .h = 32,
    };
}

/// The fold's buttons: under the path when a build is chosen, else under the version.
fn buttonsTop(s: State) f32 {
    if (s.own_build.len > 0 or s.shared_build.len > 0) {
        const b = buildRect(s);
        return b.y + b.h + 12;
    }
    return advancedTop(s) + 30;
}

const choose_build_label = "Choose build…";

fn chooseBuildRect(s: State, u: *ui.Ui) ui.Rect {
    return .{
        .x = contentX(s),
        .y = buttonsTop(s),
        .w = u.measure(choose_build_label, button_text) + 32,
        .h = 32,
    };
}

fn usePinRect(s: State, u: *ui.Ui, label: []const u8) ui.Rect {
    const choose = chooseBuildRect(s, u);
    return .{
        .x = choose.x + choose.w + 8,
        .y = choose.y,
        .w = u.measure(label, button_text) + 32,
        .h = 32,
    };
}

fn usePinLabel(s: State, buf: []u8) []const u8 {
    if (s.pin.len == 0) return "Use pinned version";
    return std.fmt.bufPrint(buf, "Use Publr {s}", .{s.pin}) catch "Use pinned version";
}

/// Where Overview's last line ends: the details' foot, or the open fold's buttons.
fn overviewBottom(s: State) f32 {
    if (s.folder.len == 0) return lastDetailBottom(s);
    if (!s.advanced) {
        const a = advancedRect(s);
        return a.y + a.h;
    }
    return buttonsTop(s) + 32;
}

/// How far Overview scrolls: to the last detail's foot.
pub fn maxScroll(s: State) f32 {
    var at_top = s;
    at_top.scroll = 0;
    return @max(0, overviewBottom(at_top) + pad - s.height);
}

fn rareList(s: State, out: *[6]Rare) []const Rare {
    var n: usize = 0;
    if (s.kind == .cloud and !s.cloning) {
        out[n] = .clone;
        n += 1;
    }
    if (s.kind == .both) {
        out[n] = .local_copy;
        n += 1;
    }
    if (s.kind != .cloud) {
        out[n] = .finder;
        n += 1;
    }
    if (s.kind == .local) {
        out[n] = .deploy;
        n += 1;
    }
    if (s.kind != .local) {
        out[n] = .dashboard;
        n += 1;
    }
    if (s.kind != .cloud) {
        out[n] = .remove;
        n += 1;
    }
    return out[0..n];
}

fn menuRect(s: State, count: usize) ui.Rect {
    const more = moreRect(s);
    const h = 2 * menu_pad + menu_item * @as(f32, @floatFromInt(count)) + 9;
    return .{
        .x = more.x + more.w - menu_width,
        .y = more.y + more.h + 6,
        .w = menu_width,
        .h = h,
    };
}

fn menuItemRect(s: State, list: []const Rare, k: usize) ui.Rect {
    const r = menuRect(s, list.len);
    const apart: f32 = if (list[k] == .remove) 9 else 0;
    return .{
        .x = r.x + menu_pad,
        .y = r.y + menu_pad + menu_item * @as(f32, @floatFromInt(k)) + apart,
        .w = r.w - 2 * menu_pad,
        .h = menu_item,
    };
}

pub fn hit(s: State, u: *ui.Ui, x: f64, y: f64) Target {
    if (y < s.top) return .none;
    if (s.menu_open and s.page == .overview) {
        var list: [6]Rare = undefined;
        const rare = rareList(s, &list);
        for (rare, 0..) |r, k| if (menuItemRect(s, rare, k).contains(x, y)) return .{ .rare = r };
        if (menuRect(s, rare.len).contains(x, y)) return .none;
        return .outside;
    }
    if (x < sidebar_width) {
        for (0..s.apps.len + 1) |k| if (sideCardRect(s, k).contains(x, y)) return .{ .side = sidePage(k) };
        if (adminRowRect(s).contains(x, y)) return .{ .side = .admin };
        return .none;
    }
    if (s.page != .overview) return .none;
    if (moreRect(s).contains(x, y)) return .more;
    if (adminRect(s, u).contains(x, y)) return .admin;
    if (siteRect(s, u).contains(x, y)) return .site;
    if (s.kind == .cloud and !s.cloning and cloneRect(s, u).contains(x, y)) return .clone;
    if (addressRect(s, u).contains(x, y)) return .address;
    if (s.callout == .unsent or s.callout == .waiting) {
        if (calloutButton(s, u).contains(x, y)) return .callout;
    }
    for (0..s.apps.len) |k| if (cardRect(s, k).contains(x, y)) return .{ .app = k };
    var list: [5]Detail = undefined;
    const shown = details(s, &list);
    if (s.folder.len > 0 and finderRect(s, u, shown).contains(x, y)) return .finder;
    if (s.folder.len == 0) return .none;
    if (advancedRect(s).contains(x, y)) return .advanced;
    if (!s.advanced) return .none;
    if (chooseBuildRect(s, u).contains(x, y)) return .choose_build;
    var buf: [64]u8 = undefined;
    if (s.own_build.len > 0 and usePinRect(s, u, usePinLabel(s, &buf)).contains(x, y)) return .use_pin;
    return .none;
}

pub fn draw(u: *ui.Ui, s: State, t: *const Theme) !void {
    if (s.page == .overview) try drawOverview(u, s, t);
    try drawSidebar(u, s, t);
}

// The sidebar.

fn drawSidebar(u: *ui.Ui, s: State, t: *const Theme) !void {
    const r: ui.Rect = .{
        .x = 0,
        .y = s.top,
        .w = sidebar_width,
        .h = s.height - s.top,
    };
    try u.rect(r, t.sidebar, 0);
    try u.rect(.{
        .x = sidebar_width - 1,
        .y = s.top,
        .w = 1,
        .h = r.h,
    }, t.border, 0);

    try u.text(.{
        .x = side_pad + 2,
        .y = s.top + 18,
        .w = sidebar_width - 2 * side_pad,
        .h = 22,
    }, s.name, .{
        .size = 15,
        .weight = 600,
        .color = t.text,
    });
    try statusLine(u, t, side_pad + 2, s.top + 42, sidebar_width - 2 * side_pad, s);

    try u.beginClip(.{
        .x = 0,
        .y = s.top + side_head - 4,
        .w = sidebar_width,
        .h = s.height - s.top - side_head - side_foot + 4,
    });
    for (0..s.apps.len + 1) |k| try sideCard(u, s, t, k);
    try u.endClip();

    try u.rect(.{
        .x = 0,
        .y = s.height - side_foot,
        .w = sidebar_width,
        .h = 1,
    }, t.border, 0);
    const admin = adminRowRect(s);
    const on = s.page == .admin;
    if (on) try u.rect(admin, t.selected, 8) else if (same(s.hover, .{ .side = .admin })) try u.rect(admin, t.hover, 8);
    try u.icon(.{
        .x = admin.x + 10,
        .y = admin.y + (admin.h - 16) / 2,
        .w = 16,
        .h = 16,
    }, icons.settings, if (on) t.text else t.text2);
    try u.text(.{
        .x = admin.x + 36,
        .y = admin.y,
        .w = admin.w - 46,
        .h = admin.h,
    }, "Admin", .{
        .size = 13,
        .weight = 500,
        .color = if (on) t.text else t.text2,
    });
}

/// A dot and the state in words.
fn statusLine(u: *ui.Ui, t: *const Theme, x: f32, y: f32, w: f32, s: State) !void {
    try u.rect(.{
        .x = x,
        .y = y + 7,
        .w = 6,
        .h = 6,
    }, if (s.changed) t.preview else if (s.running) t.running else t.stopped, 3);
    try u.text(.{
        .x = x + 12,
        .y = y,
        .w = w - 12,
        .h = 20,
    }, s.status, .{
        .size = 13,
        .color = t.text2,
    });
}

fn sideCard(u: *ui.Ui, s: State, t: *const Theme, k: usize) !void {
    const r = sideCardRect(s, k);
    const page = sidePage(k);
    const on = samePage(s.page, page);
    const hovered = same(s.hover, .{ .side = page });
    try u.box(r, .{
        .fill = t.bg,
        .border = if (on) t.text2 else if (hovered) t.input else t.border,
        .radius = 10,
    });
    const thumb: ui.Rect = .{
        .x = r.x + 5,
        .y = r.y + 5,
        .w = r.w - 10,
        .h = r.h - side_label - 5,
    };
    if (k == 0) {
        try overviewArt(u, t, thumb);
    } else {
        try picture(u, t, thumb, thumbOf(s, k - 1), 6, false);
    }
    const label = if (k == 0) "Overview" else s.apps[k - 1].label;
    try u.text(.{
        .x = r.x + 12,
        .y = r.y + r.h - side_label,
        .w = r.w - 24,
        .h = side_label,
    }, label, .{
        .size = 13,
        .weight = if (on) 600 else 500,
        .color = if (on or hovered) t.text else t.text2,
    });
    if (k > 0) try u.text(.{
        .x = r.x + 12,
        .y = r.y + r.h - side_label,
        .w = r.w - 24,
        .h = side_label,
    }, s.apps[k - 1].mount, .{
        .size = 12,
        .color = t.text3,
        .@"align" = .right,
    });
}

/// Overview's card: the project's parts drawn as tiles, the size of a site's picture.
fn overviewArt(u: *ui.Ui, t: *const Theme, r: ui.Rect) !void {
    try u.rect(r, t.hover, 6);
    const gap: f32 = 6;
    const inner: ui.Rect = .{
        .x = r.x + 14,
        .y = r.y + 14,
        .w = r.w - 28,
        .h = r.h - 28,
    };
    const half_w = (inner.w - gap) / 2;
    const half_h = (inner.h - gap) / 2;
    try u.rect(.{
        .x = inner.x,
        .y = inner.y,
        .w = half_w,
        .h = inner.h,
    }, t.bg, 5);
    try u.rect(.{
        .x = inner.x + half_w + gap,
        .y = inner.y,
        .w = half_w,
        .h = half_h,
    }, t.bg, 5);
    try u.rect(.{
        .x = inner.x + half_w + gap,
        .y = inner.y + half_h + gap,
        .w = half_w,
        .h = half_h,
    }, t.bg, 5);
}

/// A site's picture, its top shown; a placeholder of the same size when there is none.
/// Rounded at the top by `radius`; at the bottom too unless `open_bottom` (a card's picture
/// running into the card's body).
fn picture(u: *ui.Ui, t: *const Theme, r: ui.Rect, key: ?[]const u8, radius: f32, open_bottom: bool) !void {
    // Drawn taller and cut at the picture's foot: rounded corners only where they show.
    const extra: f32 = if (open_bottom) radius else 0;
    try u.beginClip(r);
    try u.rect(.{
        .x = r.x,
        .y = r.y,
        .w = r.w,
        .h = r.h + extra,
    }, t.hover, radius);
    if (key) |k| {
        try u.image(.{
            .x = r.x,
            .y = r.y,
            .w = r.w,
            .h = @max(r.w * 0.75, r.h + extra),
        }, k, radius);
    }
    try u.endClip();
    if (key == null) try u.icon(centred(r, 22), icons.globe, t.text3);
}

// Overview.

fn drawOverview(u: *ui.Ui, s: State, t: *const Theme) !void {
    const page: ui.Rect = .{
        .x = sidebar_width,
        .y = s.top,
        .w = s.width - sidebar_width,
        .h = s.height - s.top,
    };
    try u.rect(page, t.bg, 0);
    try u.beginClip(page);
    try drawHead(u, s, t);
    if (s.callout != .none) try drawCallout(u, s, t);
    try drawApps(u, s, t);
    try drawDetails(u, s, t);
    if (s.menu_open) try drawMenu(u, s, t);
    try u.endClip();
}

fn drawHead(u: *ui.Ui, s: State, t: *const Theme) !void {
    const x = contentX(s);
    const site = if (s.kind == .cloud) cloneRect(s, u) else siteRect(s, u);
    try u.text(.{
        .x = x,
        .y = headTop(s),
        .w = site.x - x - 16,
        .h = 40,
    }, s.name, .{
        .size = 30,
        .weight = 600,
        .color = t.text,
        .tracking = -0.7,
    });
    // The callout says the state at length when there is one; the line keeps the address.
    const address = addressRect(s, u);
    if (s.callout == .none) {
        try statusLine(u, t, x, headTop(s) + 44, u.measure(s.status, .{ .size = 13 }) + 14, s);
        try u.text(.{
            .x = address.x - 14,
            .y = address.y,
            .w = 10,
            .h = address.h,
        }, "\u{00b7}", .{
            .size = 13,
            .color = t.text3,
        });
    }
    const over = same(s.hover, .address);
    try u.text(address, hostOf(s.address), .{
        .size = 13,
        .color = if (over) t.text else t.text2,
    });
    if (over) try u.rect(.{
        .x = address.x,
        .y = address.y + address.h - 2,
        .w = address.w,
        .h = 1,
    }, t.text2, 0);

    if (s.kind == .cloud) try secondary(u, t, site, cloneLabel(s), same(s.hover, .clone));
    try secondary(u, t, siteRect(s, u), siteLabel(s), same(s.hover, .site));
    const admin = adminRect(s, u);
    var fill = t.primary;
    if (same(s.hover, .admin)) fill.a = 0.86;
    try u.rect(admin, fill, 8);
    try u.text(admin, "Open admin", .{
        .size = button_text.size,
        .weight = button_text.weight,
        .color = t.on_primary,
        .@"align" = .center,
    });
    const more = moreRect(s);
    try u.box(more, .{
        .fill = if (same(s.hover, .more) or s.menu_open) t.hover else t.bg,
        .border = t.input,
        .radius = 8,
    });
    try u.icon(centred(more, 16), icons.more, t.text);
}

fn secondary(u: *ui.Ui, t: *const Theme, r: ui.Rect, label: []const u8, hovered: bool) !void {
    try u.box(r, .{
        .fill = if (hovered) t.hover else t.bg,
        .border = t.input,
        .radius = 8,
    });
    try u.text(r, label, .{
        .size = button_text.size,
        .weight = button_text.weight,
        .color = t.text,
        .@"align" = .center,
    });
}

fn calloutLabel(c: Callout) []const u8 {
    return switch (c) {
        .unsent => "Send to Cloud",
        .waiting => "Open review",
        .failed, .none => "",
    };
}

fn calloutButton(s: State, u: *ui.Ui) ui.Rect {
    const r = calloutRect(s);
    const w = u.measure(calloutLabel(s.callout), button_text) + 32;
    return .{
        .x = r.x + r.w - 14 - w,
        .y = r.y + (r.h - 32) / 2,
        .w = w,
        .h = 32,
    };
}

fn drawCallout(u: *ui.Ui, s: State, t: *const Theme) !void {
    const r = calloutRect(s);
    try u.box(r, .{
        .fill = t.sidebar,
        .border = t.border,
        .radius = 10,
    });
    const glyph = switch (s.callout) {
        .unsent => icons.upload,
        .waiting => icons.branch,
        .failed, .none => icons.alert_triangle,
    };
    const icon_box: ui.Rect = .{
        .x = r.x + 16,
        .y = r.y + (r.h - 32) / 2,
        .w = 32,
        .h = 32,
    };
    try u.box(icon_box, .{
        .fill = t.bg,
        .border = t.border,
        .radius = 8,
    });
    try u.icon(centred(icon_box, 16), glyph, if (s.callout == .failed) t.danger else t.text);
    const title = switch (s.callout) {
        .unsent => "Changes not on Cloud",
        .waiting => "Waiting for review",
        .failed, .none => "Can\u{2019}t reach Cloud",
    };
    const text_x = icon_box.x + icon_box.w + 14;
    const text_w = (if (s.callout == .failed) r.x + r.w else calloutButton(s, u).x) - text_x - 16;
    try u.text(.{
        .x = text_x,
        .y = r.y + (r.h - 20) / 2,
        .w = text_w,
        .h = 20,
    }, title, .{
        .size = 13,
        .weight = 600,
        .color = t.text,
    });
    if (s.callout == .failed) return;
    try secondary(u, t, calloutButton(s, u), calloutLabel(s.callout), same(s.hover, .callout));
}

/// A section's title with its count, and the line above it.
fn sectionHead(u: *ui.Ui, s: State, t: *const Theme, y: f32, title: []const u8, count: ?usize) !void {
    const x = contentX(s);
    try u.rect(.{
        .x = x,
        .y = y,
        .w = contentWidth(s),
        .h = 1,
    }, t.border, 0);
    const style: ui.TextStyle = .{
        .size = 16,
        .weight = 600,
        .color = t.text,
    };
    try u.text(.{
        .x = x,
        .y = y + 18,
        .w = contentWidth(s),
        .h = 24,
    }, title, style);
    const n = count orelse return;
    var buf: [16]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d}", .{n}) catch return;
    const badge: ui.Rect = .{
        .x = x + u.measure(title, style) + 10,
        .y = y + 20,
        .w = u.measure(text, .{ .size = 12 }) + 12,
        .h = 20,
    };
    try u.box(badge, .{
        .border = t.border,
        .radius = 6,
    });
    try u.text(badge, text, .{
        .size = 12,
        .color = t.text2,
        .@"align" = .center,
    });
}

fn drawApps(u: *ui.Ui, s: State, t: *const Theme) !void {
    // A remote project's count shows once its apps are known; none known says nothing.
    const known = s.folder.len > 0 or s.apps.len > 0;
    try sectionHead(u, s, t, appsTop(s), "Apps", if (known and !s.apps_loading) s.apps.len else null);
    if (s.apps_loading) {
        for (0..loading_cards) |k| try loadingCard(u, s, t, k);
        return;
    }
    if (s.apps.len == 0) {
        if (s.folder.len > 0) try u.text(.{
            .x = contentX(s),
            .y = appsTop(s) + 56,
            .w = contentWidth(s),
            .h = 20,
        }, "No apps yet.", .{
            .size = 13,
            .color = t.text2,
        });
        return;
    }
    for (s.apps, 0..) |app, k| try appCard(u, s, t, app, k);
}

/// A card's shape while the apps load: the picture's place and two grey bars.
fn loadingCard(u: *ui.Ui, s: State, t: *const Theme, k: usize) !void {
    const r = cardRect(s, k);
    const radius: f32 = 12;
    try u.rect(r, t.bg, radius);
    const thumb_h = r.w * card_thumb_ratio;
    try picture(u, t, .{
        .x = r.x,
        .y = r.y,
        .w = r.w,
        .h = thumb_h,
    }, null, radius, true);
    try u.rect(.{
        .x = r.x + 18,
        .y = r.y + thumb_h + 20,
        .w = r.w * 0.4,
        .h = 12,
    }, t.hover, 4);
    try u.rect(.{
        .x = r.x + 18,
        .y = r.y + thumb_h + 46,
        .w = r.w * 0.25,
        .h = 10,
    }, t.hover, 4);
    try u.box(r, .{
        .border = t.border,
        .radius = radius,
    });
}

/// An app's card: its picture, its name and the way in, its address in the foot; the edge
/// drawn last, over all of it, so its corners stay round.
fn appCard(u: *ui.Ui, s: State, t: *const Theme, app: App, k: usize) !void {
    const r = cardRect(s, k);
    const radius: f32 = 12;
    const hovered = same(s.hover, .{ .app = k });
    try u.rect(r, t.bg, radius);
    const thumb_h = r.w * card_thumb_ratio;
    try picture(u, t, .{
        .x = r.x,
        .y = r.y,
        .w = r.w,
        .h = thumb_h,
    }, thumbOf(s, k), radius, true);
    try u.rect(.{
        .x = r.x + 1,
        .y = r.y + thumb_h,
        .w = r.w - 2,
        .h = 1,
    }, t.border, 0);
    try u.text(.{
        .x = r.x + 18,
        .y = r.y + thumb_h + 16,
        .w = r.w - 36,
        .h = 22,
    }, app.label, .{
        .size = 15,
        .weight = 600,
        .color = t.text,
    });
    try u.text(.{
        .x = r.x + 18,
        .y = r.y + thumb_h + 42,
        .w = r.w - 36,
        .h = 18,
    }, "Open app", .{
        .size = 12,
        .color = if (hovered) t.text else t.text2,
    });
    try u.icon(.{
        .x = r.x + r.w - 32,
        .y = r.y + thumb_h + 44,
        .w = 14,
        .h = 14,
    }, icons.arrow_up_right, if (hovered) t.text else t.text2);

    // The foot: square where it meets the body, rounded with the card below.
    const foot: ui.Rect = .{
        .x = r.x,
        .y = r.y + r.h - card_foot,
        .w = r.w,
        .h = card_foot,
    };
    try u.rect(foot, t.sidebar, radius);
    try u.rect(.{
        .x = foot.x,
        .y = foot.y,
        .w = foot.w,
        .h = radius,
    }, t.sidebar, 0);
    try u.rect(.{
        .x = r.x + 1,
        .y = foot.y,
        .w = r.w - 2,
        .h = 1,
    }, t.border, 0);
    try u.text(.{
        .x = foot.x + 18,
        .y = foot.y,
        .w = foot.w - 36,
        .h = foot.h,
    }, if (app.address.len > 0) hostOf(app.address) else app.mount, .{
        .size = 12,
        .color = t.text2,
    });
    try u.box(r, .{
        .border = if (hovered) t.input else t.border,
        .radius = radius,
    });
}

fn drawDetails(u: *ui.Ui, s: State, t: *const Theme) !void {
    try sectionHead(u, s, t, detailsTop(s), "Project details", null);
    var list: [5]Detail = undefined;
    const shown = details(s, &list);
    for (shown, 0..) |d, k| {
        const r = detailRow(s, k);
        try u.rect(.{
            .x = r.x,
            .y = r.y,
            .w = r.w,
            .h = 1,
        }, t.border, 0);
        try u.text(.{
            .x = r.x,
            .y = r.y,
            .w = 200,
            .h = r.h,
        }, d.label, .{
            .size = 13,
            .color = t.text2,
        });
        try u.text(.{
            .x = r.x + 220,
            .y = r.y,
            // Room for the row's text button: Show in Finder.
            .w = r.w - 220 - 140,
            .h = r.h,
        }, d.value, .{
            .size = 13,
            .color = t.text,
        });
    }
    if (s.folder.len == 0) return;
    const f = finderRect(s, u, shown);
    try u.text(f, "Show in Finder", .{
        .size = button_text.size,
        .weight = button_text.weight,
        .color = if (same(s.hover, .finder)) t.text else t.text2,
        .@"align" = .right,
    });
    try drawAdvanced(u, s, t);
}

/// Advanced, folded by default: the version of Publr the project runs, or the build chosen
/// instead, and how to change it.
fn drawAdvanced(u: *ui.Ui, s: State, t: *const Theme) !void {
    const a = advancedRect(s);
    if (same(s.hover, .advanced)) try u.rect(a, t.hover, 8);
    try u.icon(.{
        .x = a.x + 8,
        .y = a.y + (a.h - 16) / 2,
        .w = 16,
        .h = 16,
    }, if (s.advanced) icons.chevron_down else icons.chevron_right, t.text2);
    try u.text(.{
        .x = a.x + 32,
        .y = a.y,
        .w = a.w - 40,
        .h = a.h,
    }, "Advanced", .{
        .size = 13,
        .weight = 600,
        .color = t.text,
    });
    if (!s.advanced) return;

    const x = contentX(s);
    const w = contentWidth(s);
    const line: ui.Rect = .{
        .x = x,
        .y = advancedTop(s),
        .w = w,
        .h = 20,
    };
    var vb: [64]u8 = undefined;
    const build = if (s.own_build.len > 0) s.own_build else s.shared_build;
    if (build.len > 0) {
        try u.text(line, if (s.own_build.len > 0) "Build:" else "Build (all projects):", .{
            .size = 13,
            .color = t.text,
        });
        const b = buildRect(s);
        try u.box(b, .{
            .fill = t.hover,
            .radius = 8,
        });
        try u.text(.{
            .x = b.x + 10,
            .y = b.y,
            .w = b.w - 20,
            .h = b.h,
        }, build, .{
            .size = 13,
            .color = t.text,
        });
    } else {
        const said = if (s.pin.len > 0) std.fmt.bufPrint(&vb, "Publr {s}", .{s.pin}) catch "Publr" else "Publr";
        try u.text(line, said, .{
            .size = 13,
            .color = t.text,
        });
    }
    try outlined(u, t, chooseBuildRect(s, u), choose_build_label, same(s.hover, .choose_build));
    if (s.own_build.len > 0) {
        var pb: [64]u8 = undefined;
        const label = usePinLabel(s, &pb);
        try outlined(u, t, usePinRect(s, u, label), label, same(s.hover, .use_pin));
    }
}

fn outlined(u: *ui.Ui, t: *const Theme, r: ui.Rect, label: []const u8, hovered: bool) !void {
    try u.box(r, .{
        .fill = if (hovered) t.hover else t.bg,
        .border = t.input,
        .radius = 8,
    });
    try u.text(r, label, .{
        .size = button_text.size,
        .weight = button_text.weight,
        .color = t.text,
        .@"align" = .center,
    });
}

fn drawMenu(u: *ui.Ui, s: State, t: *const Theme) !void {
    var list: [6]Rare = undefined;
    const rare = rareList(s, &list);
    const r = menuRect(s, rare.len);
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
    for (rare, 0..) |item, k| {
        const ir = menuItemRect(s, rare, k);
        if (item == .remove) try u.rect(.{
            .x = r.x + 1,
            .y = ir.y - 5,
            .w = r.w - 2,
            .h = 1,
        }, t.border, 0);
        if (same(s.hover, .{ .rare = item })) try u.rect(ir, t.selected, 6);
        const color = if (item == .remove) t.danger else t.text;
        try u.icon(.{
            .x = ir.x + 10,
            .y = ir.y + (ir.h - 15) / 2,
            .w = 15,
            .h = 15,
        }, item.icon(), color);
        try u.text(.{
            .x = ir.x + 34,
            .y = ir.y,
            .w = ir.w - 44,
            .h = ir.h,
        }, item.label(), .{
            .size = 13,
            .color = color,
        });
    }
}

fn hostOf(address: []const u8) []const u8 {
    const after = if (std.mem.indexOf(u8, address, "://")) |i| address[i + 3 ..] else address;
    return std.mem.trimEnd(u8, after, "/");
}

/// The project's apps from its folder: each `apps/<name>/app.zon`'s label and mount, its
/// address made from `base` (the project's address). Allocated in `arena`.
pub fn readApps(io: std.Io, arena: std.mem.Allocator, folder: []const u8, base: []const u8) []const App {
    var list: std.ArrayList(App) = .empty;
    const apps_dir = std.fs.path.join(arena, &.{ folder, "apps" }) catch return &.{};
    var dir = std.Io.Dir.cwd().openDir(io, apps_dir, .{ .iterate = true }) catch return &.{};
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .directory or entry.name[0] == '.') continue;
        const zon_path = std.fs.path.join(arena, &.{ apps_dir, entry.name, "app.zon" }) catch continue;
        const text = std.Io.Dir.cwd().readFileAlloc(io, zon_path, arena, .limited(64 << 10)) catch continue;
        const name = arena.dupe(u8, entry.name) catch continue;
        list.append(arena, appOf(arena, name, text, base)) catch return list.items;
    }
    sortApps(list.items);
    return list.items;
}

/// An app as its `app.zon` (`text`) says, on a project at `base`.
pub fn appOf(arena: std.mem.Allocator, name: []const u8, text: []const u8, base: []const u8) App {
    return .{
        .name = name,
        .label = field(text, ".label") orelse name,
        .address = addressOf(arena, base, text),
        .mount = mountOf(arena, text),
    };
}

/// By mount: the root app first.
pub fn sortApps(apps: []App) void {
    std.mem.sort(App, apps, {}, struct {
        fn before(_: void, a: App, b: App) bool {
            return std.mem.lessThan(u8, a.mount, b.mount);
        }
    }.before);
}

/// A string field's value in a `.zon` text (`.label = "Shop"`), as written.
fn field(text: []const u8, name: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, text, name) orelse return null;
    const open = std.mem.indexOfScalarPos(u8, text, at + name.len, '"') orelse return null;
    const close = std.mem.indexOfScalarPos(u8, text, open + 1, '"') orelse return null;
    return text[open + 1 .. close];
}

/// An app's mount as people read it: its path, or its subdomain with a dot.
fn mountOf(arena: std.mem.Allocator, text: []const u8) []const u8 {
    const mount = std.mem.indexOf(u8, text, ".mount") orelse return "/";
    const rest = text[mount..];
    if (std.mem.indexOf(u8, rest, ".subdomain")) |_| {
        const sub = field(rest, ".subdomain") orelse return "/";
        return std.fmt.allocPrint(arena, "{s}.", .{sub}) catch "/";
    }
    return field(rest, ".path") orelse "/";
}

/// An app's address: the project's with its mount's path, or its subdomain before the host.
fn addressOf(arena: std.mem.Allocator, base: []const u8, text: []const u8) []const u8 {
    if (base.len == 0) return "";
    const trimmed = std.mem.trimEnd(u8, base, "/");
    const mount = std.mem.indexOf(u8, text, ".mount") orelse return trimmed;
    const rest = text[mount..];
    if (std.mem.indexOf(u8, rest, ".subdomain")) |_| {
        const sub = field(rest, ".subdomain") orelse return trimmed;
        const scheme_end = (std.mem.indexOf(u8, trimmed, "://") orelse return trimmed) + 3;
        return std.fmt.allocPrint(arena, "{s}{s}.{s}", .{ trimmed[0..scheme_end], sub, trimmed[scheme_end..] }) catch trimmed;
    }
    const path = field(rest, ".path") orelse return trimmed;
    if (std.mem.eql(u8, path, "/")) return trimmed;
    return std.fmt.allocPrint(arena, "{s}{s}", .{ trimmed, path }) catch trimmed;
}

test "an app's address and mount come from its app.zon" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const base = "https://shop.publr.app";
    try std.testing.expectEqualStrings(base, addressOf(a, base, ".{ .mount = .{ .path = \"/\" } }"));
    try std.testing.expectEqualStrings("https://shop.publr.app/blog", addressOf(a, base, ".{ .mount = .{ .path = \"/blog\" } }"));
    try std.testing.expectEqualStrings("https://docs.shop.publr.app", addressOf(a, base, ".{ .mount = .{ .subdomain = \"docs\" } }"));
    try std.testing.expectEqualStrings("/blog", mountOf(a, ".{ .mount = .{ .path = \"/blog\" } }"));
    try std.testing.expectEqualStrings("docs.", mountOf(a, ".{ .mount = .{ .subdomain = \"docs\" } }"));
    try std.testing.expectEqualStrings("Sklep", field(".{ .name = \"site\", .label = \"Sklep\" }", ".label").?);
}
