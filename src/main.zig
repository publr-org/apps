//! Publr Studio: one window, a tab per open site. The bar and Home (every site, laid out
//! as PublrDesign's file browser) are drawn by Studio itself with the native `ui`; each
//! tab is the site's admin, signed in, in the system's web view. Local sites, their
//! servers and the signed-in links are `p`'s (`~/publr-sites`) until the `studio` plugin
//! takes them over (`.agents/specs/publr-studio.md`).

const std = @import("std");
const native = @import("native");
const ui = @import("ui");
const bar = @import("bar.zig");
const home = @import("home.zig");
const themes = @import("theme.zig");
const Sites = @import("sites.zig").Sites;
const Thumbs = @import("thumbs.zig").Thumbs;
const sheet = @import("sheet.zig");
const Cloud = @import("cloud.zig").Cloud;
const deploying = @import("deploy.zig");

const Io = std.Io;

const app_name = "Publr Studio";

/// App menu tags.
const Tag = struct {
    const reload = 1;
    const open_in_browser = 2;
    const home = 3;
    const close_tab = 4;
    const refresh_sites = 5;
    /// Command-1 to Command-9.
    const tab = 10;
};

/// A site's menu (on Home).
const Action = struct {
    const open = 1;
    const view_site = 2;
    const deploy = 3;
    const finder = 4;
    const stop = 5;
    const start = 6;
    const trash = 7;
    const view_live_local = 8;
    const cloud_admin = 9;
    const deploy_changes = 10;
    // A Cloud project's.
    const open_project = 11;
    const view_live = 12;
    const project_dashboard = 13;
    // The account's.
    const open_dashboard = 21;
    const sign_out = 22;
};

/// What a Home item is.
const Ref = union(enum) {
    local: []const u8,
    cloud: struct {
        space: usize,
        project: usize,
    },
};

const Tab = struct {
    name: []const u8,
    web: *native.WebView,
    /// A Cloud project's tab: its admin's address (a local site's tab signs in through `p`).
    url: ?[]const u8 = null,
};

const Hover = union(enum) {
    none,
    bar: bar.Target,
    home: home.Target,
};

var gpa: std.mem.Allocator = undefined;
var io: Io = undefined;
var sites: Sites = undefined;
var support_dir: []const u8 = "";

var window: *native.Window = undefined;
var gpu: native.gpu.Gpu = undefined;
var surface: native.gpu.Surface = undefined;
var u: *ui.Ui = undefined;
var thumbs: Thumbs = undefined;
var theme: *const themes.Theme = &themes.light;
var theme_forced = false;

var tabs: std.ArrayList(Tab) = .empty;
var active: ?usize = null;
var hover: Hover = .none;
var view: home.View = .local;
var layout: home.Layout = .grid;
var scroll: f32 = 0;
var cloud: Cloud = undefined;
/// The open menu: whose, and where it shows.
var menu: ?struct {
    of: union(enum) {
        item: Ref,
        account,
    },
    x: f32,
    y: f32,
} = null;
/// The sheet open over Home, if any.
var open_sheet: ?enum {
    new_site,
    deploy,
    /// The site is live: where, and its buttons.
    deployed,
} = null;
var deploy_progress: deploying.Progress = .{};
var auto_deploy = false;
var last_stage: ?deploying.Stage = null;
var deploy_job: ?*deploying.Job = null;
/// The live site's address once deployed (the sheet's last step).
var deployed_address: []const u8 = "";
var env_map: *const std.process.Environ.Map = undefined;
var home_dir: []const u8 = "";
/// Deploy: the site going up, its address field, and what Cloud said of the address.
var deploy_site: []const u8 = "";
var address_field: ui.TextField = undefined;
var availability: ?@import("cloud.zig").Availability = null;
/// The address last asked about, and when the field last changed (asked after a pause).
var checked_slug: std.ArrayList(u8) = .empty;
var address_changed_at: i64 = 0;
/// A site to deploy once the sign-in it started finishes.
var deploy_after_sign_in: ?[]const u8 = null;
var sheet_hover: sheet.Target = .none;
/// What the sheet's work said went wrong, or what it is doing.
var sheet_error: ?[]const u8 = null;
var sheet_busy: ?[]const u8 = null;
var name_field: ui.TextField = undefined;
/// Site names, most recently opened first.
var recents: std.ArrayList([]const u8) = .empty;

var dirty = true;

/// The items Home shows, made each frame from the view (and the strings they point at).
var frame_arena: std.heap.ArenaAllocator = undefined;
var items: std.ArrayList(home.Item) = .empty;
var item_refs: std.ArrayList(Ref) = .empty;

var self_test = false;
/// `STUDIO_TIMING=<site>`: opens the site, walks `timing_pages`, prints how long each
/// took in the web view and how long drawing Home takes; then quits.
var timing_site: ?[]const u8 = null;
var timing_step: usize = 0;
const timing_pages = [_][:0]const u8{ "/admin/content", "/admin/media", "/admin/content", "/admin" };
const timing_script =
    \\addEventListener('load', () => requestAnimationFrame(() => setTimeout(() => {
    \\  const n = performance.getEntriesByType('navigation')[0];
    \\  const fcp = performance.getEntriesByName('first-contentful-paint')[0];
    \\  const r = (v) => Math.round(v);
    \\  webkit.messageHandlers.native.postMessage(JSON.stringify({
    \\    page: location.pathname, request: r(n.requestStart), first_byte: r(n.responseStart),
    \\    html_done: r(n.responseEnd), interactive: r(n.domInteractive),
    \\    dom_ready: r(n.domContentLoadedEventEnd), loaded: r(n.loadEventEnd),
    \\    first_paint: fcp ? r(fcp.startTime) : null,
    \\    resources: performance.getEntriesByType('resource').length,
    \\  }));
    \\}, 0)));
;

pub fn main(init: std.process.Init) !void {
    gpa = std.heap.c_allocator;
    io = init.io;
    frame_arena = .init(gpa);
    const env = init.environ_map;
    home_dir = env.get("HOME") orelse return error.NoHome;
    env_map = env;
    self_test = env.get("SELF_TEST") != null;
    timing_site = env.get("STUDIO_TIMING");
    sites = .{
        .gpa = gpa,
        .io = io,
        .env = env,
        .p_path = env.get("STUDIO_P") orelse try std.fs.path.join(gpa, &.{ home_dir, ".local/bin/p" }),
    };
    support_dir = try std.fs.path.join(gpa, &.{ home_dir, "Library/Application Support/Publr Studio" });
    Io.Dir.cwd().createDirPath(io, support_dir) catch {};

    native.init(app_name);
    native.onMenu(null, onMenu);
    buildMenus();
    theme = themeFor(native.appearance());
    // `STUDIO_THEME=light|dark`: one look whatever the system says (for screenshots).
    const forced = env.get("STUDIO_THEME");
    if (forced) |f| theme = if (std.mem.eql(u8, f, "dark")) &themes.dark else &themes.light;
    theme_forced = forced != null;

    sites.refresh();
    loadRecents();
    name_field = .init(gpa);
    address_field = .init(gpa);
    cloud = .init(gpa, io, env.get("STUDIO_CLOUD") orelse "https://cloud.publr.app", cloudChanged);
    cloud.no_browser = env.get("STUDIO_NO_BROWSER") != null;
    cloud.refresh();
    u = try ui.Ui.create(gpa);
    gpu = try native.gpu.Gpu.init();
    window = try native.Window.create(.{
        .on_event = onEvent,
        .on_message = onMessage,
    }, .{
        .title = app_name,
        .titlebar = .custom,
        .width = 1360,
        .height = 880,
        .content = .web,
        .bar_height = bar.height,
        .min_width = 720,
        .min_height = 480,
    });
    surface = try gpu.surface(window);
    try u.attachGpu(&gpu, surface.format);
    thumbs = try Thumbs.init(gpa, io, support_dir, window, u, redrawAll);
    var names: [256][]const u8 = undefined;
    const n = @min(sites.list.items.len, names.len);
    for (sites.list.items[0..n], 0..) |s, i| names[i] = s.name;
    thumbs.loadSaved(names[0..n]);
    for (sites.list.items) |s| if (s.running) thumbs.take(s.name, s.address);
    thumbs.loadSaved(cloudThumbNames());

    if (timing_site) |name| {
        timeHome();
        openSite(name);
        tabs.items[tabs.items.len - 1].web.addUserScript(timing_script);
        native.run();
        return;
    }
    if (env.get("STUDIO_VIEW")) |v| if (std.mem.eql(u8, v, "list")) {
        layout = .list;
    };
    // The sites open last time, in their tabs; Home when there were none. `STUDIO_HOME`:
    // Home alone, the saved tabs left as they are (for screenshots).
    if (env.get("STUDIO_HOME") == null) reopenSites();
    if (tabs.items.len == 0) showHome();
    // `STUDIO_OPEN=new-site[:text]`: the sheet open with that typed (for screenshots).
    if (env.get("STUDIO_OPEN")) |o| {
        const arg = if (std.mem.indexOfScalar(u8, o, ':')) |c| o[c + 1 ..] else "";
        if (std.mem.startsWith(u8, o, "new-site")) {
            openNewSite();
            name_field.set(arg);
        }
        // `deploy:<site>[:auto]`: the sheet once the listing is in (signed in already);
        // `auto` presses Deploy once the address is free and prints each step (tests).
        if (std.mem.startsWith(u8, o, "deploy")) {
            const site = if (std.mem.indexOfScalar(u8, arg, ':')) |c| arg[0..c] else arg;
            auto_deploy = std.mem.endsWith(u8, arg, ":auto");
            if (sites.find(site) != null) deploy_after_sign_in = gpa.dupe(u8, site) catch null;
        }
        // `menu:<site>`: the site card's menu open, as a right click opens it.
        if (std.mem.startsWith(u8, o, "menu")) {
            if (sites.find(arg) != null) menu = .{
                .of = .{ .item = .{ .local = gpa.dupe(u8, arg) catch arg } },
                .x = 900,
                .y = 420,
            };
        }
    }
    if (env.get("STUDIO_SIGN_IN") != null and cloud.status == .signed_out) cloud.signIn();
    if (self_test) std.debug.print("studio: window {d}, {d} sites, {d} tabs\n", .{ window.number(), sites.list.items.len, tabs.items.len });
    native.run();
}

fn themeFor(a: native.Appearance) *const themes.Theme {
    return if (a == .dark) &themes.dark else &themes.light;
}

fn buildMenus() void {
    native.setMenu("File", &.{
        .{
            .title = "Home",
            .key = "t",
            .tag = Tag.home,
        },
        .{
            .title = "Close Tab",
            .key = "w",
            .tag = Tag.close_tab,
        },
    });
    native.setMenu("View", &.{
        .{
            .title = "Reload",
            .key = "r",
            .tag = Tag.reload,
        },
        .{
            .title = "Open in Browser",
            .key = "B",
            .tag = Tag.open_in_browser,
        },
        .{
            .separator = true,
        },
        .{
            .title = "Refresh Sites",
            .tag = Tag.refresh_sites,
        },
    });
    var tab_items: [9]native.MenuItem = undefined;
    const digits = [_][:0]const u8{ "1", "2", "3", "4", "5", "6", "7", "8", "9" };
    const titles = [_][:0]const u8{ "Tab 1", "Tab 2", "Tab 3", "Tab 4", "Tab 5", "Tab 6", "Tab 7", "Tab 8", "Tab 9" };
    for (&tab_items, 0..) |*it, i| it.* = .{
        .title = titles[i],
        .key = digits[i],
        .tag = @intCast(Tag.tab + i),
    };
    native.setMenu("Tabs", &tab_items);
}

// What is drawn: the bar's and Home's states, made from Studio's.

fn barState(titles: *[64][]const u8) bar.State {
    const n = @min(tabs.items.len, titles.len);
    for (tabs.items[0..n], 0..) |t, i| titles[i] = t.name;
    return .{
        .titles = titles[0..n],
        .active = active,
        .hover = switch (hover) {
            .bar => |b| b,
            else => .none,
        },
        .width = @floatCast(window.size().w),
    };
}

/// The sites the view lists, as Home items (rebuilt every call; valid until the next).
fn viewItems() []const home.Item {
    _ = frame_arena.reset(.retain_capacity);
    const a = frame_arena.allocator();
    items.clearRetainingCapacity();
    item_refs.clearRetainingCapacity();
    switch (view) {
        .local => for (sites.list.items) |s| addLocal(a, s.name),
        .recents => for (recents.items) |name| {
            if (sites.find(name) != null) addLocal(a, name);
        },
        .space => |i| if (i < cloud.spaces.len) for (cloud.spaces[i].projects, 0..) |_, k| addProject(a, i, k),
    }
    return items.items;
}

fn addLocal(a: std.mem.Allocator, name: []const u8) void {
    const s = sites.find(name) orelse return;
    const host = if (std.mem.indexOf(u8, s.address, "://")) |i| s.address[i + 3 ..] else s.address;
    // A deployed site shows where it is live.
    const where = if (s.live.len > 0) hostOf(s.live) else host;
    // No-break spaces: the line is cut at its end when the address is long, never wrapped
    // at the dot, which would leave only "Running ·…".
    const detail = std.fmt.allocPrint(a, "{s}\u{00a0}\u{00b7}\u{00a0}{s}", .{ if (s.running) "Running" else "Stopped", where }) catch return;
    var kb: [256]u8 = undefined;
    const thumb = if (thumbs.key(&kb, s.name)) |k| a.dupe(u8, k) catch null else null;
    items.append(gpa, .{
        .name = s.name,
        .detail = detail,
        .kind = .local,
        .running = s.running,
        .thumb = thumb,
    }) catch return;
    item_refs.append(gpa, .{ .local = s.name }) catch {};
}

fn hostOf(address: []const u8) []const u8 {
    const h = if (std.mem.indexOf(u8, address, "://")) |i| address[i + 3 ..] else address;
    return std.mem.trimEnd(u8, h, "/");
}

fn addProject(a: std.mem.Allocator, space: usize, k: usize) void {
    const p = cloud.spaces[space].projects[k];
    const detail = std.fmt.allocPrint(a, "{s}\u{00a0}\u{00b7}\u{00a0}{s}", .{ hostOf(p.address), if (p.preview) "Preview" else "Live" }) catch return;
    var kb: [256]u8 = undefined;
    var nb: [256]u8 = undefined;
    const tname = std.fmt.bufPrint(&nb, "cloud-{s}", .{p.slug}) catch return;
    const thumb = if (thumbs.key(&kb, tname)) |key| a.dupe(u8, key) catch null else null;
    items.append(gpa, .{
        .name = p.name,
        .detail = detail,
        .kind = .cloud,
        .running = std.mem.eql(u8, p.state, "ready"),
        .thumb = thumb,
    }) catch return;
    item_refs.append(gpa, .{ .cloud = .{
        .space = space,
        .project = k,
    } }) catch {};
}

/// Thumbnail names of the Cloud projects listed ("cloud-<slug>").
fn cloudThumbNames() []const []const u8 {
    const a = frame_arena.allocator();
    var names: std.ArrayList([]const u8) = .empty;
    for (cloud.spaces) |sp| for (sp.projects) |p| {
        names.append(a, std.fmt.allocPrint(a, "cloud-{s}", .{p.slug}) catch continue) catch {};
    };
    return names.items;
}

/// The Cloud listing changed (signed in or out, listed again).
fn cloudChanged() void {
    if (cloud.problem) |pr| std.debug.print("studio: cloud: {s}\n", .{pr});
    thumbs.loadSaved(cloudThumbNames());
    // Pictures of the live sites; previews are private.
    for (cloud.spaces) |sp| for (sp.projects) |p| if (!p.preview) {
        var nb: [256]u8 = undefined;
        thumbs.take(std.fmt.bufPrint(&nb, "cloud-{s}", .{p.slug}) catch continue, p.address);
    };
    if (view == .space and cloud.spaces.len == 0) view = .local;
    if (deploy_after_sign_in) |name| if (cloud.status != .signing_in) {
        deploy_after_sign_in = null;
        if (cloud.status == .signed_in) deploy(name);
        gpa.free(name);
    };
    redrawAll();
}

fn homeState() home.State {
    const size = window.size();
    const its = viewItems();
    var st: home.State = .{
        .top = bar.height,
        .width = @floatCast(size.w),
        .height = @floatCast(size.h),
        .view = view,
        .layout = layout,
        .items = its,
        .local_count = sites.list.items.len,
        .spaces = spaceList(),
        .account = switch (cloud.status) {
            .signed_out => .signed_out,
            .signing_in => .signing_in,
            .signed_in => .{ .signed_in = if (cloud.account.len > 0) cloud.account else "Publr Cloud" },
        },
        .hover = switch (hover) {
            .home => |h| h,
            else => .none,
        },
        .scroll = scroll,
        .menu = null,
        .title = switch (view) {
            .recents => "Recent",
            .local => "On this Mac",
            .space => |i| if (i < cloud.spaces.len) cloud.spaces[i].name else "Cloud",
        },
    };
    if (menu) |m| st.menu = .{
        .x = m.x,
        .y = if (m.of == .account) home.accountMenuBottom(st) else m.y,
        .items = menuItems(m.of),
        .above = m.of == .account,
    };
    return st;
}

var space_list: [32]home.Space = undefined;

fn spaceList() []const home.Space {
    const n = @min(cloud.spaces.len, space_list.len);
    for (cloud.spaces[0..n], 0..) |sp, i| space_list[i] = .{
        .name = sp.name,
        .count = sp.projects.len,
    };
    return space_list[0..n];
}

fn menuItems(of: @FieldType(@typeInfo(@TypeOf(menu)).optional.child, "of")) []const home.MenuItem {
    return switch (of) {
        .item => |r| switch (r) {
            .local => |name| siteMenu(name),
            .cloud => projectMenu(),
        },
        .account => accountMenu(),
    };
}

fn projectMenu() []const home.MenuItem {
    const list = [_]home.MenuItem{
        .{
            .title = "Open",
            .tag = Action.open_project,
        },
        .{
            .title = "View live site",
            .tag = Action.view_live,
        },
        .{
            .separator = true,
        },
        .{
            .title = "Open in dashboard",
            .tag = Action.project_dashboard,
        },
    };
    @memcpy(menu_items[0..list.len], &list);
    return menu_items[0..list.len];
}

fn accountMenu() []const home.MenuItem {
    const list = [_]home.MenuItem{
        .{
            .title = "Open dashboard",
            .tag = Action.open_dashboard,
        },
        .{
            .separator = true,
        },
        .{
            .title = "Sign out",
            .tag = Action.sign_out,
        },
    };
    @memcpy(menu_items[0..list.len], &list);
    return menu_items[0..list.len];
}

var menu_items: [12]home.MenuItem = undefined;

fn siteMenu(name: []const u8) []const home.MenuItem {
    const s = sites.find(name) orelse return &.{};
    if (s.live.len > 0) {
        // Deployed: the Cloud project is the site; this folder is its working copy.
        const linked = [_]home.MenuItem{
            .{
                .title = "Open",
                .tag = Action.open,
            },
            .{
                .title = "View site",
                .tag = Action.view_site,
            },
            .{
                .title = "View live site",
                .tag = Action.view_live_local,
            },
            .{
                .title = "Open Cloud admin",
                .tag = Action.cloud_admin,
            },
            .{
                .title = "Deploy changes (coming soon)",
                .tag = Action.deploy_changes,
                .enabled = false,
            },
            .{
                .separator = true,
            },
            .{
                .title = "Show in Finder",
                .tag = Action.finder,
            },
            if (s.running) .{
                .title = "Stop",
                .tag = Action.stop,
            } else .{
                .title = "Start",
                .tag = Action.start,
            },
            .{
                .separator = true,
            },
            .{
                .title = "Move to Trash",
                .tag = Action.trash,
            },
        };
        @memcpy(menu_items[0..linked.len], &linked);
        return menu_items[0..linked.len];
    }
    const list = [_]home.MenuItem{
        .{
            .title = "Open",
            .tag = Action.open,
        },
        .{
            .title = "View site",
            .tag = Action.view_site,
        },
        .{
            .title = "Deploy to Cloud",
            .tag = Action.deploy,
        },
        .{
            .separator = true,
        },
        .{
            .title = "Show in Finder",
            .tag = Action.finder,
        },
        if (s.running) .{
            .title = "Stop",
            .tag = Action.stop,
        } else .{
            .title = "Start",
            .tag = Action.start,
        },
        .{
            .separator = true,
        },
        .{
            .title = "Move to Trash",
            .tag = Action.trash,
        },
    };
    @memcpy(menu_items[0..list.len], &list);
    return menu_items[0..list.len];
}

// Events.

fn onEvent(_: ?*anyopaque, win: *native.Window, event: native.Event) void {
    if (open_sheet != null) switch (event) {
        .frame, .resize, .appearance => {},
        else => return sheetEvent(win, event),
    };
    switch (event) {
        .frame => {
            if (open_sheet == .deploy) askAboutAddress();
            // The deploy's progress moves on its own.
            if (deploy_job != null) {
                dirty = true;
                const st = deploy_progress.get();
                if (auto_deploy and last_stage != st) std.debug.print("studio: deploy {t} {s}\n", .{ st, deployBusyText() });
                last_stage = st;
            }
            if (dirty) draw();
        },
        .resize => redrawAll(),
        .appearance => |a| if (!theme_forced) {
            theme = themeFor(a);
            redrawAll();
        },
        .mouse_move => |m| setHover(win, hitAt(m.x, m.y)),
        .mouse_leave => setHover(win, .none),
        .scroll => |sc| if (active == null and menu == null) {
            const max = home.maxScroll(homeState());
            const dy: f32 = @floatCast(if (sc.precise) sc.dy else sc.dy * 10);
            const next = std.math.clamp(scroll - dy, 0, max);
            if (next != scroll) {
                scroll = next;
                redrawAll();
            }
        },
        .key_down => |k| if (k.code == .escape and menu != null) {
            menu = null;
            redrawAll();
        },
        .mouse_down => |m| click(win, m),
        else => {},
    }
}

fn hitAt(x: f64, y: f64) Hover {
    var titles: [64][]const u8 = undefined;
    if (y < bar.height and menu == null) {
        const t = bar.hit(barState(&titles), x, y);
        return if (t == .none) .none else .{ .bar = t };
    }
    if (active != null) return .none;
    const t = home.hit(homeState(), u, x, y);
    return if (t == .none) .none else .{ .home = t };
}

fn setHover(win: *native.Window, h: Hover) void {
    if (std.meta.eql(h, hover)) return;
    markHover(hover, h);
    hover = h;
    win.setCursor(switch (h) {
        .bar => |b| switch (b) {
            .home, .tab, .tab_close, .plus => .pointer,
            else => .arrow,
        },
        .home => |t| switch (t) {
            .none, .outside_menu => .arrow,
            else => .pointer,
        },
        .none => .arrow,
    });
}

fn click(win: *native.Window, m: native.event.Mouse) void {
    switch (hitAt(m.x, m.y)) {
        .none => if (m.y < bar.height) {
            // The bar's empty part (or the lights' corner).
            if (m.clicks == 2) win.titlebarDoubleClick() else win.dragWindow();
        },
        .bar => |b| switch (b) {
            .bar => if (m.clicks == 2) win.titlebarDoubleClick() else win.dragWindow(),
            .home, .plus => showHome(),
            .tab => |i| showTab(i),
            .tab_close => |i| closeTab(i),
            .none => {},
        },
        .home => |t| clickHome(t, m),
    }
}

fn clickHome(t: home.Target, m: native.event.Mouse) void {
    switch (t) {
        .outside_menu => menu = null,
        .menu_item => |k| {
            const of = menu.?.of;
            const tag = menuItems(of)[k].tag;
            menu = null;
            switch (of) {
                .item => |r| switch (r) {
                    .local => |name| act(name, tag),
                    .cloud => |c| actProject(c.space, c.project, tag),
                },
                .account => actAccount(tag),
            }
        },
        .recents => setView(.recents),
        .local => setView(.local),
        .space => |i| setView(.{ .space = i }),
        .show_grid => layout = .grid,
        .show_list => layout = .list,
        .item => |i| {
            const r = item_refs.items[i];
            if (m.button == .right) {
                menu = .{
                    .of = .{ .item = r },
                    .x = @floatCast(m.x),
                    .y = @floatCast(m.y),
                };
            } else switch (r) {
                .local => |name| openSite(name),
                .cloud => |c| openProject(c.space, c.project),
            }
        },
        .item_menu => |i| menu = .{
            .of = .{ .item = item_refs.items[i] },
            .x = @floatCast(m.x),
            .y = @floatCast(m.y + 8),
        },
        .new_site => openNewSite(),
        .sign_in => if (cloud.status == .signed_out) cloud.signIn(),
        .account => menu = .{
            .of = .account,
            .x = 8,
            .y = 0,
        },
        .none => {},
    }
    hover = .none;
    redrawAll();
}

fn actProject(space: usize, k: usize, tag: u32) void {
    if (space >= cloud.spaces.len or k >= cloud.spaces[space].projects.len) return;
    const p = cloud.spaces[space].projects[k];
    var buf: [512]u8 = undefined;
    switch (tag) {
        Action.open_project => openProject(space, k),
        Action.view_live => native.openInBrowser(std.fmt.bufPrintZ(&buf, "{s}", .{p.address}) catch return),
        Action.project_dashboard => native.openInBrowser(std.fmt.bufPrintZ(&buf, "{s}/projects/{s}", .{ cloud.base, p.slug }) catch return),
        else => {},
    }
}

fn actAccount(tag: u32) void {
    var buf: [512]u8 = undefined;
    switch (tag) {
        Action.open_dashboard => native.openInBrowser(std.fmt.bufPrintZ(&buf, "{s}", .{cloud.base}) catch return),
        Action.sign_out => {
            cloud.signOut();
            if (view == .space) view = .local;
        },
        else => {},
    }
}

/// A Cloud project's admin in a tab of its own: `<slug>--admin.<domain>/admin`, where the
/// person signs in to it (Cloud's sign-on for Studio comes later).
fn openProject(space: usize, k: usize) void {
    const p = cloud.spaces[space].projects[k];
    for (tabs.items, 0..) |t, i| if (t.url != null and std.mem.eql(u8, t.name, p.name)) return showTab(i);
    const host = hostOf(p.address);
    const dot = std.mem.indexOfScalar(u8, host, '.') orelse return;
    const scheme = if (std.mem.startsWith(u8, p.address, "http://")) "http" else "https";
    const url = std.fmt.allocPrintSentinel(gpa, "{s}://{s}--admin{s}/admin", .{ scheme, host[0..dot], host[dot..] }, 0) catch return;
    const web = window.addWebView() catch return;
    web.loadUrl(url);
    tabs.append(gpa, .{
        .name = gpa.dupe(u8, p.name) catch return,
        .web = web,
        .url = url,
    }) catch return;
    showTab(tabs.items.len - 1);
}

fn setView(v: home.View) void {
    view = v;
    scroll = 0;
    if (v == .local or v == .recents) sites.refresh();
}

fn act(name: []const u8, tag: u32) void {
    const s = sites.find(name) orelse return;
    switch (tag) {
        Action.open => openSite(name),
        Action.view_site => {
            var buf: [256]u8 = undefined;
            native.openInBrowser(std.fmt.bufPrintZ(&buf, "{s}", .{s.address}) catch return);
        },
        Action.finder => {
            var buf: [512]u8 = undefined;
            native.openInBrowser(std.fmt.bufPrintZ(&buf, "file://{s}/publr-sites/{s}", .{ sites.env.get("HOME") orelse "", name }) catch return);
        },
        Action.deploy => return deploy(name),
        Action.view_live_local => {
            var buf: [512]u8 = undefined;
            native.openInBrowser(std.fmt.bufPrintZ(&buf, "{s}", .{s.live}) catch return);
        },
        Action.cloud_admin => {
            var buf: [512]u8 = undefined;
            native.openInBrowser(std.fmt.bufPrintZ(&buf, "{s}", .{s.live_admin}) catch return);
        },
        Action.stop => sites.command(&.{ "stop", name }),
        Action.start => sites.command(&.{ "start", name }),
        Action.trash => {
            for (tabs.items, 0..) |t, i| if (std.mem.eql(u8, t.name, name)) {
                closeTab(i);
                break;
            };
            sites.command(&.{ "rm", name, "--yes" });
        },
        else => {},
    }
    sites.refresh();
}

/// The page sent a message (only the timing mode's pages do).
fn onMessage(_: ?*anyopaque, web: *native.WebView, text: []const u8) void {
    if (thumbs.onMessage(web, text)) return;
    if (timing_site == null) return;
    std.debug.print("page {s}\n", .{text});
    // The sign-in link lands on /admin first; then each page in turn.
    if (timing_step == timing_pages.len) return native.quit();
    var buf: [512]u8 = undefined;
    const site = sites.find(timing_site.?) orelse return;
    const host = if (std.mem.indexOf(u8, site.address, "://")) |i| site.address[i + 3 ..] else site.address;
    const url = std.fmt.bufPrintZ(&buf, "http://admin.{s}{s}", .{ host, timing_pages[timing_step] }) catch return;
    timing_step += 1;
    web.loadUrl(url);
}

// Drawing.

/// Everything is drawn again at the next frame.
fn redrawAll() void {
    dirty = true;
}

/// A hover moved: the frame is drawn again (whole frames are cheap on the GPU).
fn markHover(from: Hover, to: Hover) void {
    _ = from;
    _ = to;
    dirty = true;
}

fn draw() void {
    const size = window.size();
    const scale = window.scale();
    const w: u32 = @intFromFloat(@round(size.w * scale));
    const h: u32 = @intFromFloat(@round(size.h * scale));
    if (w == 0 or h == 0) return;
    const t0 = std.Io.Timestamp.now(io, .awake);
    u.begin();
    var titles: [64][]const u8 = undefined;
    if (active == null) home.draw(u, homeState(), theme) catch |e| return std.debug.print("studio: home: {}\n", .{e});
    bar.draw(u, barState(&titles), theme) catch |e| return std.debug.print("studio: bar: {}\n", .{e});
    if (open_sheet != null) {
        var fields: [1]sheet.Field = undefined;
        sheet.draw(u, sheetState(&fields), theme, 0, window) catch |e| return std.debug.print("studio: sheet: {}\n", .{e});
    }
    surface.configure(w, h);
    const frame = surface.acquire() orelse return;
    // True while text or layers are still arriving: the next refreshes finish the frame.
    const again = u.draw(frame.view, w, h, @floatCast(scale), theme.bg) catch |e| return std.debug.print("studio: draw: {}\n", .{e});
    surface.present(frame);
    dirty = again;
    if (timing_site != null) std.debug.print("  draw: {d} us\n", .{@divTrunc(t0.untilNow(io, .awake).nanoseconds, 1000)});
}

/// Draws Home with the hover on each card in turn, as moving the mouse over them does.
fn timeHome() void {
    showHome();
    redrawAll();
    draw();
    const n = @max(sites.list.items.len, 1);
    var total: i64 = 0;
    var worst: i64 = 0;
    for (0..n) |i| {
        const next: Hover = .{ .home = .{ .item = i } };
        markHover(hover, next);
        hover = next;
        const t0 = std.Io.Timestamp.now(io, .awake);
        draw();
        const ms: i64 = @intCast(@divTrunc(t0.untilNow(io, .awake).nanoseconds, std.time.ns_per_ms));
        total += ms;
        worst = @max(worst, ms);
    }
    hover = .none;
    std.debug.print("home: {d} hover moves, {d} ms each on average, {d} ms at worst\n", .{ n, @divTrunc(total, @as(i64, @intCast(n))), worst });
}

// New site.

fn openNewSite() void {
    if (active != null) showHome();
    open_sheet = .new_site;
    name_field.set("");
    sheet_error = null;
    sheet_busy = null;
    window.setTextInput(true);
    redrawAll();
}

fn closeSheet() void {
    open_sheet = null;
    sheet_hover = .none;
    window.setTextInput(false);
    redrawAll();
}

/// Why `name` cannot be a site's name (p's rule: a folder name with no surprises), or null.
fn nameProblem(name: []const u8) ?[]const u8 {
    if (name.len == 0) return "";
    if (name.len > 40) return "At most 40 characters.";
    if (!std.ascii.isLower(name[0])) return "Start with a lowercase letter.";
    for (name) |ch| if (!std.ascii.isLower(ch) and !std.ascii.isDigit(ch) and ch != '-') return "Lowercase letters, numbers and dashes only.";
    if (name[name.len - 1] == '-' or std.mem.indexOf(u8, name, "--") != null) return "No dash at the end, and no two in a row.";
    if (sites.find(name) != null) return "A site with this name is on this Mac already.";
    return null;
}

fn sheetState(fields: *[1]sheet.Field) sheet.State {
    if (open_sheet == .deploy) return deployState(fields);
    if (open_sheet == .deployed) return deployedState();
    const size = window.size();
    const name = name_field.value();
    const problem = nameProblem(name);
    fields[0] = .{
        .label = "Name",
        .field = &name_field,
        .placeholder = "my-site",
        .note = if (sheet_error) |e| .{
            .text = e,
            .kind = .bad,
        } else if (problem) |pr| (if (pr.len > 0) sheet.Note{
            .text = pr,
            .kind = .bad,
        } else sheet.Note{
            .text = "Lowercase letters, numbers and dashes. It is also the folder's name.",
        }) else sheet.Note{
            .text = "Lowercase letters, numbers and dashes. It is also the folder's name.",
        },
    };
    return .{
        .title = "New site",
        .description = "A Publr site on this Mac, with the starter page. Deploy it to Publr Cloud whenever you like.",
        .fields = fields[0..1],
        .primary = "Create site",
        .primary_enabled = problem == null,
        .busy = sheet_busy,
        .hover = sheet_hover,
        .window_width = @floatCast(size.w),
        .window_height = @floatCast(size.h),
    };
}

fn sheetEvent(win: *native.Window, event: native.Event) void {
    var fields: [1]sheet.Field = undefined;
    switch (event) {
        .mouse_move => |m| {
            const h = sheet.hit(sheetState(&fields), u, m.x, m.y);
            if (!std.meta.eql(h, sheet_hover)) {
                sheet_hover = h;
                win.setCursor(switch (h) {
                    .primary, .cancel => .pointer,
                    .field => .text,
                    .none => .arrow,
                });
                redrawAll();
            }
        },
        .mouse_down => |m| switch (sheet.hit(sheetState(&fields), u, m.x, m.y)) {
            .primary => primaryAction(),
            .cancel => if (deploy_job == null) closeSheet(),
            else => {},
        },
        .text_command => |c| switch (c) {
            .enter => primaryAction(),
            .escape => if (sheet_busy == null and deploy_job == null) closeSheet(),
            else => if (sheetTypes() and sheetField().handle(event)) fieldChanged(),
        },
        .text => if (sheetTypes() and sheetField().handle(event)) fieldChanged(),
        else => {},
    }
}

fn sheetField() *ui.TextField {
    return if (open_sheet == .deploy) &address_field else &name_field;
}

/// The sheet takes typing (the deployed sheet has no field).
fn sheetTypes() bool {
    return open_sheet != .deployed and sheet_busy == null and deploy_job == null;
}

fn fieldChanged() void {
    sheet_error = null;
    if (open_sheet == .deploy) {
        availability = null;
        address_changed_at = nowMs();
    }
    redrawAll();
}

fn primaryAction() void {
    switch (open_sheet orelse return) {
        .new_site => createSite(),
        .deploy => startDeploy(),
        .deployed => {
            var buf: [512]u8 = undefined;
            native.openInBrowser(std.fmt.bufPrintZ(&buf, "{s}", .{deployed_address}) catch return);
            closeSheet();
        },
    }
}

fn nowMs() i64 {
    return @intCast(@divTrunc(std.Io.Timestamp.now(io, .awake).nanoseconds, std.time.ns_per_ms));
}

// Deploy to Cloud.

/// Deploy, from a local site's menu: signed out, the browser's sign-in first, then the
/// sheet; a new account without a space finishes setting up in the browser first.
fn deploy(name: []const u8) void {
    if (cloud.status != .signed_in) {
        if (deploy_after_sign_in) |old| gpa.free(old);
        deploy_after_sign_in = gpa.dupe(u8, name) catch return;
        if (cloud.status == .signed_out) cloud.signIn();
        return redrawAll();
    }
    if (cloud.spaces.len == 0) {
        var buf: [512]u8 = undefined;
        native.openInBrowser(std.fmt.bufPrintZ(&buf, "{s}/welcome", .{cloud.base}) catch return);
        return;
    }
    if (active != null) showHome();
    // Owned: the list's names go when it is read again (after a deploy, say).
    const chosen = gpa.dupe(u8, sites.find(name).?.name) catch return;
    if (deploy_site.len > 0) gpa.free(deploy_site);
    deploy_site = chosen;
    open_sheet = .deploy;
    address_field.set(name);
    availability = null;
    checked_slug.clearRetainingCapacity();
    address_changed_at = 0;
    sheet_error = null;
    sheet_busy = null;
    window.setTextInput(true);
    redrawAll();
}

/// Asks Cloud about the address once the person stopped typing for a moment.
fn askAboutAddress() void {
    const slug = address_field.value();
    if (slug.len == 0 or std.mem.eql(u8, slug, checked_slug.items)) return;
    if (nowMs() - address_changed_at < 300) return;
    checked_slug.clearRetainingCapacity();
    checked_slug.appendSlice(gpa, slug) catch return;
    cloud.checkAddress(slug, addressAnswered);
}

fn addressAnswered(slug: []const u8, answer: @import("cloud.zig").Availability) void {
    // An answer about what the field said before is no answer.
    if (!std.mem.eql(u8, slug, address_field.value())) return;
    availability = answer;
    if (auto_deploy) std.debug.print("studio: address {s}: {t}\n", .{ slug, answer });
    if (auto_deploy and answer == .available) startDeploy();
    redrawAll();
}

fn deployState(fields: *[1]sheet.Field) sheet.State {
    const size = window.size();
    var db: [128]u8 = undefined;
    const domain = cloud.projectDomain(&db);
    const suffix = std.fmt.allocPrint(frame_arena.allocator(), ".{s}", .{domain}) catch ".publr.app";
    const space_name = if (cloud.spaces.len > 0) cloud.spaces[0].name else "";
    const in_space = std.fmt.allocPrint(frame_arena.allocator(), "In {s}.", .{space_name}) catch "";
    const note: sheet.Note = if (sheet_error) |e| .{
        .text = e,
        .kind = .bad,
    } else if (availability) |av| switch (av) {
        .available => .{
            .text = "Available.",
            .kind = .good,
        },
        .taken => .{
            .text = "Taken. Try another address.",
            .kind = .bad,
        },
        .reserved => .{
            .text = "Reserved by Publr. Try another address.",
            .kind = .bad,
        },
        .invalid => .{
            .text = "Lowercase letters, numbers and dashes, at least 3.",
            .kind = .bad,
        },
        .unknown => .{
            .text = "Publr Cloud could not be asked. Check your connection.",
            .kind = .bad,
        },
    } else .{
        .text = if (address_field.value().len == 0) "The address your site will be live at." else "Checking…",
    };
    fields[0] = .{
        .label = "Address",
        .field = &address_field,
        .placeholder = "my-site",
        .suffix = suffix,
        .note = note,
    };
    const title = std.fmt.allocPrint(frame_arena.allocator(), "Deploy \u{201c}{s}\u{201d} to Publr Cloud", .{deploy_site}) catch "Deploy to Publr Cloud";
    const desc = std.fmt.allocPrint(frame_arena.allocator(), "The site goes live at the address below. This Mac keeps it as its working copy. {s}", .{in_space}) catch "";
    return .{
        .title = title,
        .description = desc,
        .fields = fields[0..1],
        .primary = "Deploy",
        .primary_enabled = availability == .available,
        .busy = if (deploy_job != null) deployBusyText() else sheet_busy,
        .hover = sheet_hover,
        .window_width = @floatCast(size.w),
        .window_height = @floatCast(size.h),
    };
}

/// The Publr that packs sites: `$STUDIO_PUBLR`, the one inside Studio's app (shipped with
/// it), or the one `p` runs the sites with.
fn publrPath(a: std.mem.Allocator) []const u8 {
    if (env_map.get("STUDIO_PUBLR")) |p| return p;
    if (std.process.executableDirPathAlloc(io, a)) |dir| {
        const beside = std.fs.path.join(a, &.{ dir, "publr" }) catch "";
        if (Io.Dir.cwd().access(io, beside, .{})) |_| return beside else |_| {}
    } else |_| {}
    return std.fs.path.join(a, &.{ home_dir, "publr-sites/.bin/bin/publr" }) catch "publr";
}

fn startDeploy() void {
    if (sheet_busy != null or deploy_job != null or availability != .available) return;
    const token = cloud.token orelse return;
    if (cloud.spaces.len == 0) return;
    const job = gpa.create(deploying.Job) catch return;
    job.* = .{
        .gpa = gpa,
        .io = io,
        .env = env_map,
        .publr = "",
        .site_dir = "",
        .base = cloud.base,
        .token = "",
        .space = "",
        .name = "",
        .slug = "",
        .bundle_path = "",
        .progress = &deploy_progress,
        .arena = .init(gpa),
        .done = deployFinished,
    };
    const a = job.arena.allocator();
    const deploys = std.fs.path.join(a, &.{ support_dir, "deploys" }) catch return;
    Io.Dir.cwd().createDirPath(io, deploys) catch {};
    job.publr = publrPath(a);
    job.site_dir = std.fs.path.join(a, &.{ home_dir, "publr-sites", deploy_site }) catch return;
    job.token = a.dupe(u8, token) catch return;
    job.space = a.dupe(u8, cloud.spaces[0].slug) catch return;
    job.name = a.dupe(u8, deploy_site) catch return;
    job.slug = a.dupe(u8, address_field.value()) catch return;
    job.bundle_path = std.fmt.allocPrint(a, "{s}/{s}.site.tar.gz", .{ deploys, deploy_site }) catch return;
    deploy_progress = .{};
    deploy_job = job;
    sheet_error = null;
    sheet_busy = "Packing the site…";
    window.setTextInput(false);
    job.start() catch {
        deploy_job = null;
        sheet_busy = null;
    };
    redrawAll();
}

/// What the sheet says while the deploy runs.
fn deployBusyText() []const u8 {
    const a = frame_arena.allocator();
    return switch (deploy_progress.get()) {
        .packing => "Packing the site…",
        .uploading => std.fmt.allocPrint(a, "Uploading… {d:.1} of {d:.1} MB", .{
            @as(f64, @floatFromInt(deploy_progress.sent.load(.acquire))) / 1e6,
            @as(f64, @floatFromInt(deploy_progress.total.load(.acquire))) / 1e6,
        }) catch "Uploading…",
        .starting => "Starting it on Publr Cloud…",
        .done, .failed => "",
    };
}

fn deployFinished(job: *deploying.Job) void {
    defer {
        job.arena.deinit();
        gpa.destroy(job);
        deploy_job = null;
    }
    sheet_busy = null;
    if (auto_deploy) std.debug.print("studio: deploy finished: {s}{s}\n", .{ job.problem orelse "live at ", if (job.problem == null) job.address else "" });
    if (job.problem) |pr| {
        sheet_error = pr;
        window.setTextInput(true);
        return redrawAll();
    }
    if (deployed_address.len > 0) gpa.free(deployed_address);
    deployed_address = gpa.dupe(u8, job.address) catch "";
    open_sheet = .deployed;
    sites.refresh();
    cloud.refresh();
    if (sites.find(job.name)) |s| thumbs.take(s.name, s.address);
    redrawAll();
}

fn deployedState() sheet.State {
    const size = window.size();
    const a = frame_arena.allocator();
    return .{
        .title = std.fmt.allocPrint(a, "{s} is live", .{deploy_site}) catch "Live",
        .description = std.fmt.allocPrint(a, "At {s}. This Mac keeps the site as its working copy; a domain of your own can be connected in the dashboard.", .{deployed_address}) catch "",
        .fields = &.{},
        .primary = "View live site",
        .primary_enabled = true,
        .secondary = "Close",
        .hover = sheet_hover,
        .window_width = @floatCast(size.w),
        .window_height = @floatCast(size.h),
    };
}

fn createSite() void {
    if (sheet_busy != null or nameProblem(name_field.value()) != null) return;
    const job = gpa.create(NewSite) catch return;
    job.* = .{
        .name = gpa.dupe(u8, name_field.value()) catch return,
    };
    sheet_busy = "Making the site…";
    redrawAll();
    const thread = std.Thread.spawn(.{}, NewSite.run, .{job}) catch return;
    thread.detach();
}

/// `p new` makes the site with the starter page and starts it: off the main thread.
const NewSite = struct {
    name: []const u8,
    ok: bool = false,

    fn run(self: *NewSite) void {
        self.ok = sites.make(self.name);
        native.runOnMain(self, done);
    }

    fn done(ctx: ?*anyopaque) callconv(.c) void {
        const self: *NewSite = @ptrCast(@alignCast(ctx));
        defer {
            gpa.free(self.name);
            gpa.destroy(self);
        }
        sheet_busy = null;
        if (!self.ok) {
            sheet_error = "The site could not be made. See Console for p's message.";
            return redrawAll();
        }
        closeSheet();
        sites.refresh();
        view = .local;
        openSite(self.name);
        if (sites.find(self.name)) |s| thumbs.take(s.name, s.address);
    }
};

// Tabs.

fn showHome() void {
    if (active) |i| if (i < tabs.items.len) tabs.items[i].web.setVisible(false);
    active = null;
    sites.refresh();
    window.setBarHeight(window.size().h + 10_000); // the whole window
    window.focusApp();
    redrawAll();
}

fn showTab(i: usize) void {
    if (i >= tabs.items.len) return;
    menu = null;
    for (tabs.items, 0..) |t, k| t.web.setVisible(k == i);
    active = i;
    window.setBarHeight(bar.height);
    redrawAll();
}

fn openSite(name: []const u8) void {
    rememberRecent(name);
    for (tabs.items, 0..) |t, i| if (std.mem.eql(u8, t.name, name)) return showTab(i);
    const web = window.addWebView() catch return;
    web.loadHtml(starting_page);
    const owned = gpa.dupe(u8, name) catch return;
    tabs.append(gpa, .{
        .name = owned,
        .web = web,
    }) catch return;
    showTab(tabs.items.len - 1);
    saveOpenSites();

    // `p open` starts the server when it is stopped: off the main thread, then back to it.
    const job = gpa.create(SignIn) catch return;
    job.* = .{
        .name = owned,
        .web = web,
    };
    const thread = std.Thread.spawn(.{}, SignIn.run, .{job}) catch return;
    thread.detach();
}

fn closeTab(i: usize) void {
    const t = tabs.orderedRemove(i);
    t.web.destroy();
    gpa.free(t.name);
    if (t.url) |url| gpa.free(url);
    saveOpenSites();
    // `active` still counts the removed tab: put it right before showing anything.
    const was = active;
    active = null;
    if (tabs.items.len == 0) return showHome();
    if (was) |a| {
        if (a == i) return showTab(@min(i, tabs.items.len - 1));
        active = if (a > i) a - 1 else a;
    }
    redrawAll();
}

const starting_page =
    \\<!doctype html><meta charset=utf-8>
    \\<body style="margin:0;height:100vh;display:grid;place-items:center;font:13px -apple-system,sans-serif;color:#888;background:#fff">
    \\<p>Starting the site…</p>
;

const SignIn = struct {
    name: []const u8,
    web: *native.WebView,
    link: ?[:0]u8 = null,

    fn run(self: *SignIn) void {
        self.link = sites.signInLink(self.name, "/admin") catch |e| blk: {
            std.debug.print("studio: signing in to {s} failed: {}\n", .{ self.name, e });
            break :blk null;
        };
        native.runOnMain(self, load);
    }

    fn load(ctx: ?*anyopaque) callconv(.c) void {
        const self: *SignIn = @ptrCast(@alignCast(ctx));
        defer gpa.destroy(self);
        const link = self.link orelse return;
        defer gpa.free(link);
        // The tab may have closed while the server started.
        for (tabs.items) |t| if (t.web == self.web) return self.web.loadUrl(link);
    }
};

fn onMenu(_: ?*anyopaque, tag: u32) void {
    switch (tag) {
        Tag.reload => if (active) |i| tabs.items[i].web.reload(),
        Tag.open_in_browser => if (active) |i| openInBrowser(tabs.items[i]),
        Tag.home => showHome(),
        Tag.close_tab => if (active) |i| closeTab(i) else window.close(),
        Tag.refresh_sites => {
            sites.refresh();
            redrawAll();
        },
        else => if (tag >= Tag.tab and tag < Tag.tab + 9) showTab(tag - Tag.tab),
    }
}

/// The page the tab shows, in the browser, signed in there too (the tab's session is its
/// own).
fn openInBrowser(t: Tab) void {
    const address = t.web.address();
    var path: []const u8 = "/admin";
    if (std.mem.indexOf(u8, address, "://")) |scheme| {
        if (std.mem.indexOfScalarPos(u8, address, scheme + 3, '/')) |slash| path = address[slash..];
    }
    // A sign-on link is for one use: the admin itself instead.
    if (!std.mem.startsWith(u8, path, "/admin")) path = "/admin";
    sites.openInBrowser(t.name, path);
}

// What Studio keeps between starts.

fn statePath(buf: []u8, name: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ support_dir, name }) catch "";
}

fn reopenSites() void {
    var pb: [1024]u8 = undefined;
    const saved = Io.Dir.cwd().readFileAlloc(io, statePath(&pb, "open-sites"), gpa, .limited(64 * 1024)) catch return;
    defer gpa.free(saved);
    var it = std.mem.tokenizeScalar(u8, saved, '\n');
    while (it.next()) |name| if (sites.find(name) != null) openSite(name);
}

fn saveOpenSites() void {
    // A timing run's tab is not the person's.
    if (timing_site != null) return;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    for (tabs.items) |t| {
        out.appendSlice(gpa, t.name) catch return;
        out.append(gpa, '\n') catch return;
    }
    var pb: [1024]u8 = undefined;
    Io.Dir.cwd().writeFile(io, .{
        .sub_path = statePath(&pb, "open-sites"),
        .data = out.items,
    }) catch {};
}

fn loadRecents() void {
    var pb: [1024]u8 = undefined;
    const saved = Io.Dir.cwd().readFileAlloc(io, statePath(&pb, "recents"), gpa, .limited(64 * 1024)) catch return;
    defer gpa.free(saved);
    var it = std.mem.tokenizeScalar(u8, saved, '\n');
    while (it.next()) |name| recents.append(gpa, gpa.dupe(u8, name) catch return) catch return;
}

fn rememberRecent(name: []const u8) void {
    for (recents.items, 0..) |r, i| if (std.mem.eql(u8, r, name)) {
        gpa.free(recents.orderedRemove(i));
        break;
    };
    recents.insert(gpa, 0, gpa.dupe(u8, name) catch return) catch return;
    if (recents.items.len > 50) gpa.free(recents.pop().?);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    for (recents.items) |r| {
        out.appendSlice(gpa, r) catch return;
        out.append(gpa, '\n') catch return;
    }
    var pb: [1024]u8 = undefined;
    Io.Dir.cwd().writeFile(io, .{
        .sub_path = statePath(&pb, "recents"),
        .data = out.items,
    }) catch {};
}

test {
    _ = bar;
    _ = home;
}
