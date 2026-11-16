//! Publr Desktop: one window, a tab per open site. The bar and Home (every site, laid out
//! as PublrDesign's file browser) are drawn by Desktop itself with the native `ui`; each
//! tab is the site's admin, signed in, in the system's web view. Local sites, their
//! servers and the signed-in links come from the `publr` command's core (`publr_cli`), the
//! same folders the command lists (`.agents/specs/publr-cli.md`).

const std = @import("std");
const native = @import("native");
const ui = @import("ui");
const bar = @import("bar.zig");
const home = @import("home.zig");
const syncing = @import("sync.zig");
const project = @import("project.zig");
const themes = @import("theme.zig");
const core = @import("publr_cli");
const sites_module = @import("sites.zig");
const remote = @import("remote.zig");
const Sites = sites_module.Sites;
const Thumbs = @import("thumbs.zig").Thumbs;
const sheet = @import("sheet.zig");
const settings = @import("settings.zig");
const Cloud = @import("cloud.zig").Cloud;
const deploying = @import("deploy.zig");

const Io = std.Io;

const app_name = "Publr Desktop";

/// App menu tags.
const Tag = struct {
    const reload = 1;
    const open_in_browser = 2;
    const home = 3;
    const close_tab = 4;
    const refresh_sites = 5;
    const settings = 6;
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
    const send_changes = 10;
    const open_review = 15;
    const preview_changes = 14;
    // A Cloud project's.
    const open_project = 11;
    const view_live = 12;
    const project_dashboard = 13;
    // The account's.
    const open_dashboard = 21;
    const sign_out = 22;
    const settings = 23;
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
    /// A project's tab: its page under a strip (Overview, Admin, Site, its apps).
    project: ?*ProjectTab = null,
};

/// What a project's tab is: its folder on this Mac and its address on Cloud (either may be
/// empty), and what it shows.
const ProjectTab = struct {
    arena: std.heap.ArenaAllocator,
    folder: []const u8 = "",
    live: []const u8 = "",
    space: []const u8 = "",
    apps: []const project.App = &.{},
    page: project.Page = .overview,
    /// Signed in to its Cloud admin in this tab already (one sign-on a tab).
    signed: bool = false,
    /// Its "more" menu is open.
    menu_open: bool = false,
    /// How far its Overview is scrolled.
    scroll: f32 = 0,
    /// Its Advanced details are unfolded (for this run only).
    advanced: bool = false,
    /// Being cloned to this Mac now.
    cloning: bool = false,
    /// Its apps being asked of the Publr it lives on.
    apps_loading: bool = false,
    /// What the last clone said when it failed; shown in place of the status.
    note: []const u8 = "",
};

const Hover = union(enum) {
    none,
    bar: bar.Target,
    home: home.Target,
    project: project.Target,
    settings: settings.Target,
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
var view: home.View = .all;
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
    /// New project: on this Mac or on Cloud (`new_where`).
    new_project,
    deploy,
    /// The site is live: where, and its buttons.
    deployed,
    /// Settings' admin for new sites.
    admin,
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
/// Cloud's reason a project was not made, kept for `sheet_error`.
var problem_text: []const u8 = "";
var sheet_busy: ?[]const u8 = null;
var name_field: ui.TextField = undefined;
/// A new site's first admin (an email), and Settings' admin for new sites.
var admin_field: ui.TextField = undefined;
/// The admin set for new sites, read when a sheet opens that asks for one.
var saved_admin: []u8 = "";

fn loadSavedAdmin() void {
    if (saved_admin.len > 0) gpa.free(saved_admin);
    saved_admin = gpa.dupe(u8, sites.defaultAdmin(frame_arena.allocator())) catch "";
}

/// The default account email: the one set in Settings, else the Cloud account signed in;
/// empty leaves a new site's admin to its setup page.
fn defaultAccount() []const u8 {
    if (saved_admin.len > 0) return saved_admin;
    return if (cloud.status == .signed_in) cloud.account_email else "";
}
/// Site names, most recently opened first.
var recents: std.ArrayList([]const u8) = .empty;

var dirty = true;

/// The items Home shows, made each frame from the view (and the strings they point at).
var frame_arena: std.heap.ArenaAllocator = undefined;
var items: std.ArrayList(home.Item) = .empty;
var item_refs: std.ArrayList(Ref) = .empty;

var self_test = false;
/// `DESKTOP_TIMING=<site>`: opens the site, walks `timing_pages`, prints how long each
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
    timing_site = env.get("DESKTOP_TIMING");
    sites = .{
        .gpa = gpa,
        .io = io,
        .env = env,
        .command_path = sites_module.commandPath(gpa, io, env),
    };
    support_dir = try std.fs.path.join(gpa, &.{ home_dir, "Library/Application Support/Publr Desktop" });
    Io.Dir.cwd().createDirPath(io, support_dir) catch {};

    native.init(app_name);
    native.onMenu(null, onMenu);
    buildMenus();
    theme = themeFor(native.appearance());
    // `DESKTOP_THEME=light|dark`: one look whatever the system says (for screenshots).
    const forced = env.get("DESKTOP_THEME");
    if (forced) |f| theme = if (std.mem.eql(u8, f, "dark")) &themes.dark else &themes.light;
    theme_forced = forced != null;

    refreshSites();
    loadRecents();
    name_field = .init(gpa);
    address_field = .init(gpa);
    admin_field = .init(gpa);
    cloud = .init(gpa, io, env.get("DESKTOP_CLOUD") orelse "https://cloud.publr.app", cloudChanged);
    cloud.no_browser = env.get("DESKTOP_NO_BROWSER") != null;
    cloud.refresh();
    syncing.init(.{
        .gpa = gpa,
        .io = io,
        .env = env,
        .publr = sites.command_path,
        .sign_on = syncSignOn,
        .changed = syncChanged,
        .running = siteRunning,
    });
    u = try ui.Ui.create(gpa);
    gpu = try native.gpu.Gpu.init();
    window = try native.Window.create(.{
        .on_event = onEvent,
        .on_message = onMessage,
        .on_new_window = onNewWindow,
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
    if (env.get("DESKTOP_VIEW")) |v| if (std.mem.eql(u8, v, "list")) {
        layout = .list;
    };
    // The sites open last time, in their tabs; Home when there were none. `DESKTOP_HOME`:
    // Home alone, the saved tabs left as they are (for screenshots).
    if (env.get("DESKTOP_HOME") == null) reopenSites();
    if (tabs.items.len == 0) showHome();
    // `DESKTOP_OPEN=new-site[:text]`: the sheet open with that typed (for screenshots).
    if (env.get("DESKTOP_OPEN")) |o| {
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
                .of = .{
                    .item = .{
                        .local = gpa.dupe(u8, arg) catch arg,
                    },
                },
                .x = 900,
                .y = 420,
            };
        }
    }
    // `DESKTOP_VIEW=settings[-advanced]`: Home on its Settings page (for screenshots).
    if (env.get("DESKTOP_VIEW")) |v| if (std.mem.startsWith(u8, v, "settings")) {
        if (active == null) showHome();
        openSettings();
        settings_advanced = std.mem.endsWith(u8, v, "-advanced");
    };
    // `--open <folder>` (`publr desktop <name>`): that site's tab.
    if (openArg(init)) |folder| if (sites.atFolder(folder)) |s| openLocal(s.name);
    // `DESKTOP_OPEN_LIVE=<address>`: a project elsewhere opened, as a Cloud project is (tests).
    if (env.get("DESKTOP_OPEN_LIVE")) |live| {
        openProjectTab(hostOf(live), "", live, "");
        // `DESKTOP_VIEW=clone`: its Clone to this Mac pressed.
        if (env.get("DESKTOP_VIEW")) |v| if (std.mem.eql(u8, v, "clone")) {
            if (active) |i| if (tabs.items[i].project) |pt| startClone(pt);
        };
    }
    // `DESKTOP_VIEW=project-advanced`: the opened project's Advanced unfolded (screenshots).
    if (env.get("DESKTOP_VIEW")) |v| if (std.mem.eql(u8, v, "project-advanced")) {
        if (active) |i| if (tabs.items[i].project) |pt| {
            pt.advanced = true;
            pt.scroll = project.maxScroll(projectPage(i));
        };
    };
    if (env.get("DESKTOP_SIGN_IN") != null and cloud.status == .signed_out) cloud.signIn();
    if (self_test) std.debug.print("desktop: window {d}, {d} sites, {d} tabs\n", .{ window.number(), sites.list.items.len, tabs.items.len });
    native.run();
}

/// The folder after `--open` among Desktop's arguments, or null.
fn openArg(init: std.process.Init) ?[]const u8 {
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch return null;
    for (args, 0..) |arg, i| {
        if (std.mem.eql(u8, arg, "--open") and i + 1 < args.len) return args[i + 1];
    }
    return null;
}

fn themeFor(a: native.Appearance) *const themes.Theme {
    return if (a == .dark) &themes.dark else &themes.light;
}

fn buildMenus() void {
    native.setAppMenuItems(&.{
        .{
            .title = "Settings…",
            .key = ",",
            .tag = Tag.settings,
        },
    });
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

// What is drawn: the bar's and Home's states, made from Desktop's.

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
        .browser = if (active) |i| webShown(tabs.items[i]) else false,
    };
}

/// The projects the filter shows, as Home items, each once (rebuilt every call; valid until
/// the next). A folder on this Mac deployed to a Cloud project is one item with it.
fn viewItems() []const home.Item {
    _ = frame_arena.reset(.retain_capacity);
    const a = frame_arena.allocator();
    items.clearRetainingCapacity();
    item_refs.clearRetainingCapacity();
    switch (view) {
        .recents => for (recents.items) |name| {
            if (sites.find(name) != null) addLocal(a, name);
        },
        .all => {
            for (sites.list.items) |s| addLocal(a, s.name);
            addUnlinked(a, null);
            groupItems(a);
        },
        .local => {
            for (sites.list.items) |s| addLocal(a, s.name);
            groupItems(a);
        },
        .cloud => {
            for (sites.list.items) |s| if (linkedProject(s) != null) addLocal(a, s.name);
            addUnlinked(a, null);
        },
        .space => |i| {
            for (sites.list.items) |s| if (linkedProject(s)) |at| if (at.space == i) addLocal(a, s.name);
            addUnlinked(a, i);
        },
        .settings => {},
    }
    return items.items;
}

/// Each item's section: the folder its site is in (a folder of sites, or the folder that
/// holds a single site), Cloud's projects under On Cloud. The site list comes by folder
/// already, the default one first.
fn groupItems(a: std.mem.Allocator) void {
    for (items.items, item_refs.items) |*it, ref| switch (ref) {
        .local => |name| {
            const s = sites.find(name) orelse continue;
            const where = if (std.mem.eql(u8, s.entry, s.folder)) std.fs.path.dirname(s.folder) orelse s.folder else s.entry;
            it.group = shortFolder(a, where);
        },
        .cloud => it.group = "On Cloud",
    };
}

const ProjectAt = struct {
    space: usize,
    project: usize,
};

/// The Cloud project a folder on this Mac was deployed to: the one live at its address.
fn linkedProject(s: @import("sites.zig").Site) ?ProjectAt {
    if (s.live.len == 0) return null;
    for (cloud.spaces, 0..) |sp, i| for (sp.projects, 0..) |p, k| {
        if (std.mem.eql(u8, hostOf(p.address), hostOf(s.live))) return .{
            .space = i,
            .project = k,
        };
    };
    return null;
}

/// Whether a folder on this Mac is the working copy of the project.
fn hasLocalCopy(p: @import("cloud.zig").Project) bool {
    for (sites.list.items) |s| {
        if (s.live.len > 0 and std.mem.eql(u8, hostOf(s.live), hostOf(p.address))) return true;
    }
    return false;
}

/// Cloud's projects with no copy on this Mac: every space's, or one's.
fn addUnlinked(a: std.mem.Allocator, only: ?usize) void {
    for (cloud.spaces, 0..) |sp, i| {
        if (only) |o| if (o != i) continue;
        for (sp.projects, 0..) |p, k| if (!hasLocalCopy(p)) addProject(a, i, k);
    }
}

fn addLocal(a: std.mem.Allocator, name: []const u8) void {
    const s = sites.find(name) orelse return;
    // A folder linked to a Cloud project is that project: one card, marked as both, saying
    // whether this Mac is in sync with Cloud. `sync.zig` keeps the folder so.
    const linked = s.live.len > 0;
    var state: syncing.State = .checking;
    if (linked) {
        var db: [512]u8 = undefined;
        syncing.check(s.name, siteDir(&db, s.name), s.live, nowMs(), false);
        state = syncing.stateOf(s.name) orelse .checking;
    }
    const label_buf = a.alloc(u8, 128) catch return;
    const detail = if (linked) syncing.labelOf(s.name, state, label_buf) else if (s.running) "Running" else "Stopped";
    var kb: [256]u8 = undefined;
    const thumb = if (thumbs.key(&kb, s.name)) |k| a.dupe(u8, k) catch null else null;
    items.append(gpa, .{
        .name = s.name,
        .detail = detail,
        .kind = if (linked) .both else .local,
        .running = if (linked) state != .failed else s.running,
        .changed = linked and (state == .unsent or state == .waiting),
        .thumb = thumb,
    }) catch return;
    item_refs.append(gpa, .{
        .local = intern(s.name),
    }) catch {};
}

/// Site names kept for as long as Desktop runs: what a card or an open menu holds stays
/// valid when the site list is read again (which frees the list's own copies).
var interned: std.StringHashMapUnmanaged(void) = .empty;

fn intern(name: []const u8) []const u8 {
    if (interned.getKey(name)) |kept| return kept;
    const kept = gpa.dupe(u8, name) catch return "";
    interned.put(gpa, kept, {}) catch return kept;
    return kept;
}

/// The site's folder, copied into `buf` (the list's own copy is freed when it is read again).
fn siteDir(buf: []u8, name: []const u8) []const u8 {
    const folder = sites.folderOf(name);
    if (folder.len > buf.len) return "";
    @memcpy(buf[0..folder.len], folder);
    return buf[0..folder.len];
}

/// A folder as people read it (`~/Publr/shop`), in `a`.
/// A failure's reason as the project's callout says it: a capital first.
fn whyText(a: std.mem.Allocator, why: []const u8) []const u8 {
    if (why.len == 0) return "";
    const copy = a.dupe(u8, why) catch return why;
    copy[0] = std.ascii.toUpper(copy[0]);
    return copy;
}

fn shortFolder(a: std.mem.Allocator, folder: []const u8) []const u8 {
    var buf: [1024]u8 = undefined;
    return a.dupe(u8, sites_module.shortPath(&buf, home_dir, folder)) catch "";
}

/// A build's path as people read it; empty stays empty (no build chosen).
fn shortBuild(a: std.mem.Allocator, path: []const u8) []const u8 {
    return if (path.len == 0) "" else shortFolder(a, path);
}

/// The site's folder in the Finder.
fn showInFinder(name: []const u8) void {
    var buf: [1024]u8 = undefined;
    const folder = sites.folderOf(name);
    if (folder.len == 0) return;
    native.openInBrowser(std.fmt.bufPrintSentinel(&buf, "file://{s}", .{folder}, 0) catch return);
}

fn siteRunning(name: []const u8) bool {
    const s = sites.find(name) orelse return false;
    return s.running;
}

/// A folder's sync needs a sign-on token for its project; Cloud gives one when signed in.
fn syncSignOn(slug: []const u8) void {
    if (cloud.token == null) return syncing.signedOn(slug, null);
    cloud.signOnTo(slug, syncSignedOn);
}

fn syncSignedOn(signed: @import("cloud.zig").SignedOn) void {
    syncing.signedOn(signed.slug, if (signed.problem == null and signed.token.len > 0) signed.token else null);
}

fn syncChanged() void {
    refreshSites();
    redrawAll();
}

/// How many projects each filter holds, each once.
fn counts() struct {
    all: usize,
    local: usize,
    cloud: usize,
} {
    var unlinked: usize = 0;
    var on_cloud: usize = 0;
    for (cloud.spaces) |sp| for (sp.projects) |p| {
        on_cloud += 1;
        if (!hasLocalCopy(p)) unlinked += 1;
    };
    return .{
        .all = sites.list.items.len + unlinked,
        .local = sites.list.items.len,
        .cloud = on_cloud,
    };
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
    item_refs.append(gpa, .{
        .cloud = .{
            .space = space,
            .project = k,
        },
    }) catch {};
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
    if (cloud.problem) |pr| std.debug.print("desktop: cloud: {s}\n", .{pr});
    thumbs.loadSaved(cloudThumbNames());
    // Pictures of the live sites; previews are private.
    for (cloud.spaces) |sp| for (sp.projects) |p| if (!p.preview) {
        var nb: [256]u8 = undefined;
        thumbs.take(std.fmt.bufPrint(&nb, "cloud-{s}", .{p.slug}) catch continue, p.address);
    };
    // A filter that is no longer offered falls back to the whole list.
    switch (view) {
        .cloud => if (cloud.status != .signed_in) {
            view = .all;
        },
        .space => |i| if (cloud.spaces.len < 2 or i >= cloud.spaces.len) {
            view = if (cloud.status == .signed_in) .cloud else .all;
        },
        else => {},
    }
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
    const counted = counts();
    var st: home.State = .{
        .top = bar.height,
        .width = @floatCast(size.w),
        .height = @floatCast(size.h),
        .view = view,
        .layout = layout,
        .items = its,
        .all_count = counted.all,
        .local_count = counted.local,
        .cloud_count = counted.cloud,
        .spaces = spaceList(),
        .account = switch (cloud.status) {
            .signed_out => .signed_out,
            .signing_in => .signing_in,
            .signed_in => .{
                .signed_in = if (cloud.account.len > 0) cloud.account else "Publr Cloud",
            },
        },
        .hover = switch (hover) {
            .home => |h| h,
            else => .none,
        },
        .scroll = scroll,
        .menu = null,
        .title = switch (view) {
            .recents => "Recent",
            .all => "All projects",
            .local => "On this Mac",
            .cloud => "On Cloud",
            .space => |i| if (i < cloud.spaces.len) cloud.spaces[i].name else "On Cloud",
            .settings => "Settings",
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
            .title = "Settings…",
            .tag = Action.settings,
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
        // Linked: the Cloud project is the site; this folder is its working copy, kept in
        // step by Desktop. Work made here goes up when the person sends it.
        const state = syncing.stateOf(name) orelse .checking;
        const linked = [_]home.MenuItem{
            .{
                .title = "Open",
                .tag = Action.open,
            },
            .{
                .title = "Send changes to Cloud",
                .tag = Action.send_changes,
                .enabled = state == .unsent,
            },
            .{
                .title = "Open review",
                .tag = Action.open_review,
                .enabled = syncing.reviewOf(name) != null,
            },
            .{
                .title = "Open copy on this Mac",
                .tag = Action.preview_changes,
            },
            .{
                .title = "View live site",
                .tag = Action.view_live_local,
            },
            .{
                .separator = true,
            },
            .{
                .title = "Show in Finder",
                .tag = Action.finder,
            },
            .{
                .separator = true,
            },
            .{
                .title = "Remove from this Mac",
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
                if (auto_deploy and last_stage != st) std.debug.print("desktop: deploy {t} {s}\n", .{ st, deployBusyText() });
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
        .scroll => |sc| if (active) |i| {
            const pt = tabs.items[i].project orelse return;
            if (pt.page != .overview or pt.menu_open) return;
            const dy: f32 = @floatCast(if (sc.precise) sc.dy else sc.dy * 10);
            const next = std.math.clamp(pt.scroll - dy, 0, project.maxScroll(projectPage(i)));
            if (next != pt.scroll) {
                pt.scroll = next;
                redrawAll();
            }
        } else if (menu == null) {
            const max = home.maxScroll(homeState());
            const dy: f32 = @floatCast(if (sc.precise) sc.dy else sc.dy * 10);
            const next = std.math.clamp(scroll - dy, 0, max);
            if (next != scroll) {
                scroll = next;
                redrawAll();
            }
        },
        .key_down => |k| if (k.code == .escape) {
            if (active) |i| if (tabs.items[i].project) |pt| {
                pt.menu_open = false;
            };
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
        return if (t == .none) .none else .{
            .bar = t,
        };
    }
    if (active) |i| {
        if (tabs.items[i].project == null) return .none;
        const pt = project.hit(projectPage(i), u, x, y);
        return if (pt == .none) .none else .{
            .project = pt,
        };
    }
    if (view == .settings and x >= home.sidebar_width and menu == null) {
        const st = settings.hit(settingsState(), u, x, y);
        return if (st == .none) .none else .{
            .settings = st,
        };
    }
    const t = home.hit(homeState(), u, x, y);
    return if (t == .none) .none else .{
        .home = t,
    };
}

fn setHover(win: *native.Window, h: Hover) void {
    if (std.meta.eql(h, hover)) return;
    markHover(hover, h);
    hover = h;
    win.setCursor(switch (h) {
        .bar => |b| switch (b) {
            .home, .tab, .tab_close, .plus, .browser => .pointer,
            else => .arrow,
        },
        .home => |t| switch (t) {
            .none, .outside_menu => .arrow,
            else => .pointer,
        },
        .project, .settings => .pointer,
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
            .browser => if (active) |i| openInBrowser(tabs.items[i]),
            .tab => |i| showTab(i),
            .tab_close => |i| closeTab(i),
            .none => {},
        },
        .home => |t| clickHome(t, m),
        .project => |t| if (active) |i| clickProject(i, t),
        .settings => |t| clickSettings(t),
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
        .all => setView(.all),
        .local => setView(.local),
        .cloud => setView(.cloud),
        .space => |i| setView(.{
            .space = i,
        }),
        .settings => openSettings(),
        .show_grid => layout = .grid,
        .show_list => layout = .list,
        .refresh => refreshAll(),
        .item => |i| {
            const r = item_refs.items[i];
            if (m.button == .right) {
                menu = .{
                    .of = .{
                        .item = r,
                    },
                    .x = @floatCast(m.x),
                    .y = @floatCast(m.y),
                };
            } else switch (r) {
                .local => |name| openLocal(name),
                .cloud => |c| openProject(c.space, c.project),
            }
        },
        .item_menu => |i| menu = .{
            .of = .{
                .item = item_refs.items[i],
            },
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
        Action.view_live => native.openInBrowser(std.fmt.bufPrintSentinel(&buf, "{s}", .{p.address}, 0) catch return),
        Action.project_dashboard => native.openInBrowser(std.fmt.bufPrintSentinel(&buf, "{s}/projects/{s}", .{ cloud.base, p.slug }, 0) catch return),
        else => {},
    }
}

fn actAccount(tag: u32) void {
    var buf: [512]u8 = undefined;
    switch (tag) {
        Action.open_dashboard => native.openInBrowser(std.fmt.bufPrintSentinel(&buf, "{s}", .{cloud.base}, 0) catch return),
        Action.sign_out => {
            cloud.signOut();
            if (view == .space or view == .cloud) view = .all;
        },
        Action.settings => openSettings(),
        else => {},
    }
}

/// A Cloud project's own tab, on its Overview.
fn openProject(space: usize, k: usize) void {
    // The list may have been read again since Home was drawn.
    if (space >= cloud.spaces.len or k >= cloud.spaces[space].projects.len) return;
    const p = cloud.spaces[space].projects[k];
    var folder: []const u8 = "";
    for (sites.list.items) |s| if (s.live.len > 0 and std.mem.eql(u8, hostOf(s.live), hostOf(p.address))) {
        folder = s.name;
    };
    openProjectTab(p.name, folder, p.address, cloud.spaces[space].name);
}

/// A project's tab (its tab again when open), on its Overview: `folder` is its folder on
/// this Mac and `live` its Cloud address, either empty.
fn openProjectTab(name: []const u8, folder: []const u8, live: []const u8, space: []const u8) void {
    if (projectTabOf(folder, live)) |i| return showTab(i);
    const web = window.addWebView() catch return;
    const pt = gpa.create(ProjectTab) catch return;
    pt.* = .{
        .arena = .init(gpa),
    };
    const a = pt.arena.allocator();
    pt.folder = a.dupe(u8, folder) catch "";
    pt.live = a.dupe(u8, live) catch "";
    pt.space = a.dupe(u8, space) catch "";
    if (folder.len > 0) {
        var db: [512]u8 = undefined;
        const local = sites.find(folder);
        // The tab's own copies: the site list's are freed whenever it is read again.
        const base = if (pt.live.len > 0) pt.live else if (local) |s| a.dupe(u8, s.address) catch "" else "";
        pt.apps = project.readApps(io, a, siteDir(&db, folder), base);
        rememberRecent(folder);
        takeAppThumbs(folder, pt.apps);
    } else if (pt.live.len > 0) {
        pt.apps_loading = true;
        startRemote(.apps, pt.live, "");
    }
    tabs.append(gpa, .{
        .name = gpa.dupe(u8, name) catch return,
        .web = web,
        .url = if (live.len > 0) adminOf(live) else null,
        .project = pt,
    }) catch return;
    showTab(tabs.items.len - 1);
}

/// An app's picture's name: its project's folder and its own.
fn appThumbName(buf: []u8, folder: []const u8, app: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "app-{s}-{s}", .{ folder, app }) catch "";
}

/// Each app's picture: the one kept from before at once, a new one taken off screen.
fn takeAppThumbs(folder: []const u8, apps: []const project.App) void {
    var names: [32][]const u8 = undefined;
    var bufs: [32][256]u8 = undefined;
    const n = @min(apps.len, names.len);
    for (apps[0..n], 0..) |app, k| names[k] = appThumbName(&bufs[k], folder, app.name);
    thumbs.loadSaved(names[0..n]);
    for (apps[0..n], 0..) |app, k| if (app.address.len > 0) thumbs.take(names[k], app.address);
}

fn projectTabOf(folder: []const u8, live: []const u8) ?usize {
    for (tabs.items, 0..) |t, i| {
        const pt = t.project orelse continue;
        if (folder.len > 0 and std.mem.eql(u8, pt.folder, folder)) return i;
        if (live.len > 0 and pt.live.len > 0 and std.mem.eql(u8, hostOf(pt.live), hostOf(live))) return i;
    }
    return null;
}

/// A Cloud project's admin address: `<slug>--admin.<domain>/admin`.
fn adminOf(live: []const u8) ?[]const u8 {
    const host = hostOf(live);
    const dot = std.mem.indexOfScalar(u8, host, '.') orelse return null;
    const scheme = if (std.mem.startsWith(u8, live, "http://")) "http" else "https";
    return std.fmt.allocPrint(gpa, "{s}://{s}--admin{s}/admin", .{ scheme, host[0..dot], host[dot..] }) catch null;
}

/// A Cloud project's admin, its tab opened on it: kept for the places that name a project
/// by its address alone (a project just made).
fn openProjectAdmin(name: []const u8, address: []const u8) void {
    openProjectTab(name, "", address, "");
    if (active) |i| goTo(i, .admin);
}

/// The page where the folder's sent work is reviewed, in the project's tab, signed in.
fn openReview(name: []const u8, address: []const u8) void {
    const review = syncing.reviewOf(name) orelse return;
    openProjectTab(name, name, address, spaceOf(address));
    const i = active orelse return;
    adminAt(i, pathOf(review), review);
}

/// The tab `i` on `page`: Overview drawn here, the rest loaded in its web view.
fn goTo(i: usize, page: project.Page) void {
    const t = tabs.items[i];
    const pt = t.project orelse return;
    pt.page = page;
    switch (page) {
        .overview => {},
        .admin => adminAt(i, "/admin", null),
        .site => sitePageAt(i, siteOf(pt)),
        .app => |k| if (k < pt.apps.len) sitePageAt(i, pt.apps[k].address),
    }
    showTab(i);
}

fn siteOf(pt: *const ProjectTab) []const u8 {
    if (pt.live.len > 0) return pt.live;
    const s = sites.find(pt.folder) orelse return "";
    if (!s.running) sites.start(pt.folder);
    return s.address;
}

/// A page asks for a new window: a project's admin (a deploy's "Open admin", signed in once)
/// opens in that project's tab, as its Admin does; anything else goes to the browser.
fn onNewWindow(_: ?*anyopaque, _: *native.WebView, url: []const u8) bool {
    const host = hostOnly(url);
    if (host.len == 0) return false;
    if (openInProjectTab(url, host)) return true;
    // A deploy links its folder before its page's last seconds, while Desktop still waits
    // for the command to finish: the site list read again knows the project's admin.
    refreshSites();
    return openInProjectTab(url, host);
}

/// The project whose admin `host` is, opened in its tab: an admin page signed in afresh (a
/// page's own sign-on link is for one use and may be spent or stale by now); anything else
/// on the admin's host (its "View site", `/`) as it is, which takes it on to the site with
/// the person signed in there.
fn openInProjectTab(url: []const u8, host: []const u8) bool {
    const rest = url[std.mem.indexOf(u8, url, host).? + host.len ..];
    const admin_page = std.mem.startsWith(u8, rest, "/admin") or std.mem.startsWith(u8, rest, "/auth/");
    for (tabs.items, 0..) |t, i| {
        const pt = t.project orelse continue;
        const cloud_admin = if (t.url) |admin| std.mem.eql(u8, hostOnly(admin), host) else false;
        if (!cloud_admin and !isLocalAdmin(pt, host)) continue;
        if (!admin_page) {
            pt.page = .site;
            showTab(i);
            loadIn(t, url);
            redrawAll();
            return true;
        }
        if (cloud_admin) {
            pt.signed = false;
            adminAt(i, "/admin", null);
            redrawAll();
            return true;
        }
        if (!isLocalAdmin(pt, host)) continue;
        pt.page = .admin;
        showTab(i);
        const job = gpa.create(SignIn) catch return true;
        job.* = .{
            .name = t.name,
            .web = t.web,
        };
        const thread = std.Thread.spawn(.{}, SignIn.run, .{job}) catch return true;
        thread.detach();
        redrawAll();
        return true;
    }
    return false;
}

/// The host and port of an address, without its path or query.
fn hostOnly(url: []const u8) []const u8 {
    const rest = if (std.mem.indexOf(u8, url, "://")) |at| url[at + 3 ..] else return "";
    return rest[0 .. std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len];
}

/// Whether `host` is the admin of the tab's site on this Mac (`admin.localhost:<port>`).
fn isLocalAdmin(pt: *const ProjectTab, host: []const u8) bool {
    if (pt.folder.len == 0) return false;
    const s = sites.find(pt.folder) orelse return false;
    const own = hostOnly(s.address);
    const port = own[(std.mem.lastIndexOfScalar(u8, own, ':') orelse return false)..];
    return std.mem.startsWith(u8, host, "admin.localhost") and std.mem.eql(u8, host["admin.localhost".len..], port);
}

fn loadIn(t: Tab, address: []const u8) void {
    if (address.len == 0) return;
    t.web.loadUrl(frame_arena.allocator().dupeSentinel(u8, address, 0) catch return);
}

/// A page of the project's site in its tab, through a sign-in that lands there: Publr then
/// shows its toolbar, the way to the admin and back. A page on a host other than the site's
/// own is loaded as it is.
fn sitePageAt(i: usize, address: []const u8) void {
    const t = tabs.items[i];
    const pt = t.project orelse return;
    const own = if (pt.live.len > 0) pt.live else if (sites.find(pt.folder)) |s| s.address else "";
    if (address.len == 0 or own.len == 0 or !std.mem.eql(u8, hostOnly(address), hostOnly(own))) return loadIn(t, address);
    const rest = address[std.mem.indexOf(u8, address, "://").? + 3 ..];
    const path = if (std.mem.indexOfScalar(u8, rest, '/')) |at| rest[at..] else "/";
    if (pt.live.len == 0) {
        const job = gpa.create(SignIn) catch return;
        job.* = .{
            .name = t.name,
            .web = t.web,
            .path = gpa.dupe(u8, path) catch return gpa.destroy(job),
            .owns_path = true,
        };
        const thread = std.Thread.spawn(.{}, SignIn.run, .{job}) catch return;
        return thread.detach();
    }
    // Cloud: a one-time sign-on each time, landing on the page.
    if (cloud.token == null) return loadIn(t, address);
    if (sign_on_return) |old| gpa.free(old);
    sign_on_return = gpa.dupe(u8, path) catch null;
    cloud.signOnTo(syncing.slugOf(pt.live), signedOn);
}

/// The project's admin in its tab at `path`: Cloud's signed in through a one-time sign-on
/// the first time (then `direct`, or the admin's own address); a local one through `p`.
fn adminAt(i: usize, path: []const u8, direct: ?[]const u8) void {
    const t = tabs.items[i];
    const pt = t.project orelse return;
    pt.page = .admin;
    showTab(i);
    if (pt.live.len == 0) {
        const job = gpa.create(SignIn) catch return;
        job.* = .{
            .name = t.name,
            .web = t.web,
            .path = path,
        };
        const thread = std.Thread.spawn(.{}, SignIn.run, .{job}) catch return;
        return thread.detach();
    }
    const admin = t.url orelse return;
    // Signed out of Cloud: the admin's own sign-in.
    if (cloud.token == null) return loadIn(t, admin);
    if (pt.signed) {
        const at = std.mem.indexOf(u8, admin, "/admin") orelse admin.len;
        const url = direct orelse std.fmt.allocPrint(frame_arena.allocator(), "{s}{s}", .{ admin[0..at], path }) catch return;
        return loadIn(t, url);
    }
    pt.signed = true;
    if (!std.mem.eql(u8, path, "/admin")) sign_on_return = gpa.dupe(u8, path) catch null;
    cloud.signOnTo(syncing.slugOf(pt.live), signedOn);
}

fn spaceOf(live: []const u8) []const u8 {
    if (live.len == 0) return "";
    for (cloud.spaces) |sp| for (sp.projects) |p| {
        if (std.mem.eql(u8, hostOf(p.address), hostOf(live))) return sp.name;
    };
    return "";
}

fn pathOf(url: []const u8) []const u8 {
    const host_at = if (std.mem.indexOf(u8, url, "://")) |i| i + 3 else 0;
    const slash = std.mem.indexOfScalarPos(u8, url, host_at, '/') orelse return "/admin";
    return url[slash..];
}

/// The project's tab, signed in: its sign-on address, or its admin when Cloud gave none
/// (which asks for the dashboard's sign-in).
fn signedOn(signed: @import("cloud.zig").SignedOn) void {
    for (tabs.items) |t| {
        const url = t.url orelse continue;
        const host = hostOf(url);
        const at = std.mem.indexOf(u8, host, "--admin") orelse continue;
        if (!std.mem.eql(u8, host[0..at], signed.slug)) continue;
        if (signed.problem) |pr| std.debug.print("desktop: signing in to {s}: {s}\n", .{ signed.slug, pr });
        const admin = frame_arena.allocator().dupeSentinel(u8, url, 0) catch return;
        t.web.loadUrl(if (signed.problem == null) withReturn(signed.url) else admin);
        return;
    }
}

/// Where the next sign-on lands instead of the admin's home (`openReview`).
var sign_on_return: ?[]u8 = null;

/// `url` (a sign-on address) landing on `sign_on_return`, which it uses up.
fn withReturn(url: [:0]const u8) [:0]const u8 {
    const path = sign_on_return orelse return url;
    defer {
        gpa.free(path);
        sign_on_return = null;
    }
    const at = std.mem.indexOf(u8, url, "&return=") orelse return url;
    const a = frame_arena.allocator();
    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(a, url[0 .. at + "&return=".len]) catch return url;
    for (path) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.') {
            out.append(a, c) catch return url;
        } else {
            out.print(a, "%{X:0>2}", .{c}) catch return url;
        }
    }
    return out.toOwnedSliceSentinel(a, 0) catch url;
}

fn setView(v: home.View) void {
    view = v;
    scroll = 0;
    refreshSites();
}

/// A folder on Home opened: a linked one is its Cloud project, opened in Cloud's admin
/// (this Mac keeps the folder in sync); any other its own admin.
fn openLocal(name: []const u8) void {
    const s = sites.find(name) orelse return;
    openProjectTab(name, name, s.live, spaceOf(s.live));
}

fn act(name: []const u8, tag: u32) void {
    const s = sites.find(name) orelse return;
    switch (tag) {
        Action.open => openLocal(name),
        Action.send_changes => syncing.send(name),
        Action.open_review => openReview(name, s.live),
        Action.preview_changes => openSite(name),
        Action.view_site => {
            var buf: [256]u8 = undefined;
            native.openInBrowser(std.fmt.bufPrintSentinel(&buf, "{s}", .{s.address}, 0) catch return);
        },
        Action.finder => showInFinder(name),
        Action.deploy => return deploy(name),
        Action.view_live_local => {
            var buf: [512]u8 = undefined;
            native.openInBrowser(std.fmt.bufPrintSentinel(&buf, "{s}", .{s.live}, 0) catch return);
        },
        Action.stop => sites.stop(name),
        Action.start => sites.start(name),
        Action.trash => {
            for (tabs.items, 0..) |t, i| if (t.url == null and t.project == null and std.mem.eql(u8, t.name, name)) {
                closeTab(i);
                break;
            };
            sites.remove(name);
        },
        else => {},
    }
    refreshSites();
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
    const url = std.fmt.bufPrintSentinel(&buf, "http://admin.{s}{s}", .{ host, timing_pages[timing_step] }, 0) catch return;
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
    // Home clears the frame's memory as it lists its cards; a tab's page clears it here.
    if (active != null) _ = frame_arena.reset(.retain_capacity);
    u.begin();
    var titles: [64][]const u8 = undefined;
    if (active == null) home.draw(u, homeState(), theme) catch |e| return std.debug.print("desktop: home: {}\n", .{e});
    if (active) |i| if (tabs.items[i].project != null) project.draw(u, projectPage(i), theme) catch |e| return std.debug.print("desktop: project: {}\n", .{e});
    bar.draw(u, barState(&titles), theme) catch |e| return std.debug.print("desktop: bar: {}\n", .{e});
    if (active == null and view == .settings) settings.draw(u, settingsState(), theme) catch |e| return std.debug.print("desktop: settings: {}\n", .{e});
    if (open_sheet != null) {
        var fields: [1]sheet.Field = undefined;
        sheet.draw(u, sheetState(&fields), theme, 0, window) catch |e| return std.debug.print("desktop: sheet: {}\n", .{e});
    }
    surface.configure(w, h);
    const frame = surface.acquire() orelse return;
    // True while text or layers are still arriving: the next refreshes finish the frame.
    const again = u.draw(frame.view, w, h, @floatCast(scale), theme.bg) catch |e| return std.debug.print("desktop: draw: {}\n", .{e});
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
        const next: Hover = .{
            .home = .{
                .item = i,
            },
        };
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

/// Where New project makes the project.
var new_where: enum {
    local,
    cloud,
} = .local;

/// Cloud is offered when signed in with a space to make projects in.
fn cloudOffered() bool {
    return cloud.status == .signed_in and cloud.spaces.len > 0;
}

/// The space New project makes a Cloud project in: the one the filter shows, else the first.
fn targetSpace() usize {
    return switch (view) {
        .space => |i| if (i < cloud.spaces.len) i else 0,
        else => 0,
    };
}

fn openNewSite() void {
    if (active != null) showHome();
    open_sheet = .new_project;
    // On the Cloud filters it starts on Cloud; anywhere else on this Mac.
    const on_cloud = view == .cloud or view == .space;
    new_where = if (cloudOffered() and on_cloud) .cloud else .local;
    name_field.set("");
    sheet_error = null;
    sheet_busy = null;
    window.setTextInput(true);
    redrawAll();
}

/// Settings' admin for new sites, in a sheet of its own.
fn openAdminSheet() void {
    open_sheet = .admin;
    loadSavedAdmin();
    admin_field.set(saved_admin);
    sheet_error = null;
    sheet_busy = null;
    window.setTextInput(true);
    redrawAll();
}

fn adminState(fields: *[1]sheet.Field) sheet.State {
    const size = window.size();
    const problem = adminProblem(admin_field.value());
    fields[0] = .{
        .label = "Email",
        .field = &admin_field,
        .placeholder = "you@example.com",
        .note = if (sheet_error) |e| .{
            .text = e,
            .kind = .bad,
        } else if (problem) |pr| .{
            .text = pr,
            .kind = .bad,
        } else null,
    };
    return .{
        .title = "Default account email",
        .description = "",
        .fields = fields[0..1],
        .primary = "Save",
        .primary_enabled = problem == null,
        .hover = sheet_hover,
        .window_width = @floatCast(size.w),
        .window_height = @floatCast(size.h),
    };
}

fn saveAdmin() void {
    if (adminProblem(admin_field.value()) != null) return;
    if (!sites.setDefaultAdmin(admin_field.value())) {
        sheet_error = "The setting could not be saved.";
        return redrawAll();
    }
    closeSheet();
    loadSettings();
    redrawAll();
}

fn closeSheet() void {
    open_sheet = null;
    sheet_hover = .none;
    window.setTextInput(false);
    redrawAll();
}

/// Why `name` cannot be a site's name (the command's rule, `valid_name`: a folder name and a
/// hostname label), or null. The reasons say which part of the rule it breaks.
fn nameProblem(name: []const u8) ?[]const u8 {
    if (name.len == 0) return "";
    if (name.len > 40) return "At most 40 characters.";
    if (!std.ascii.isLower(name[0])) return "Start with a lowercase letter.";
    for (name) |ch| if (!std.ascii.isLower(ch) and !std.ascii.isDigit(ch) and ch != '-') return "Lowercase letters, numbers and dashes only.";
    if (name[name.len - 1] == '-' or std.mem.indexOf(u8, name, "--") != null) return "No dash at the end, and no two in a row.";
    if (!core.sites.valid_name(name)) return "Lowercase letters, numbers and dashes only.";
    if (sites.find(name) != null) return "A site with this name is on this Mac already.";
    return null;
}

fn adminProblem(email: []const u8) ?[]const u8 {
    if (email.len == 0) return null;
    const at = std.mem.indexOfScalar(u8, email, '@') orelse return "Not an email address.";
    if (at == 0 or at == email.len - 1 or std.mem.indexOfAny(u8, email, " \t") != null) return "Not an email address.";
    return null;
}

fn sheetState(fields: *[1]sheet.Field) sheet.State {
    if (open_sheet == .admin) return adminState(fields);
    if (open_sheet == .deploy) return deployState(fields);
    if (open_sheet == .deployed) return deployedState();
    var state = if (new_where == .cloud and cloudOffered()) projectState(fields) else localState(fields);
    if (cloudOffered()) state.choice = .{
        .label = "Where",
        .options = &.{ "On this Mac", "On Cloud" },
        .selected = @backingInt(new_where),
    };
    return state;
}

fn localState(fields: *[1]sheet.Field) sheet.State {
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
        .title = "New project",
        .description = "A project on this Mac, with the starter page. Deploy it to Publr Cloud whenever you like.",
        .fields = fields[0..1],
        .primary = "Create project",
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
                    .primary, .cancel, .option => .pointer,
                    .field => .text,
                    .none => .arrow,
                });
                redrawAll();
            }
        },
        .mouse_down => |m| switch (sheet.hit(sheetState(&fields), u, m.x, m.y)) {
            .primary => primaryAction(),
            .cancel => if (deploy_job == null) closeSheet(),
            .option => |i| {
                new_where = if (i == 1) .cloud else .local;
                sheet_error = null;
                redrawAll();
            },
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
    if (open_sheet == .deploy) return &address_field;
    if (open_sheet == .admin) return &admin_field;
    return &name_field;
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
        .new_project => if (new_where == .cloud and cloudOffered()) createProject() else createSite(),
        .admin => saveAdmin(),
        .deploy => startDeploy(),
        .deployed => {
            var buf: [512]u8 = undefined;
            native.openInBrowser(std.fmt.bufPrintSentinel(&buf, "{s}", .{deployed_address}, 0) catch return);
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
        native.openInBrowser(std.fmt.bufPrintSentinel(&buf, "{s}/welcome", .{cloud.base}, 0) catch return);
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
    if (auto_deploy) std.debug.print("desktop: address {s}: {t}\n", .{ slug, answer });
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
        .progress = &deploy_progress,
        .arena = .init(gpa),
        .done = deployFinished,
        .shown = deployPageShown,
    };
    const a = job.arena.allocator();
    // `publr deploy` in the site's folder: the command Desktop carries.
    job.publr = sites.command_path;
    job.site_dir = a.dupe(u8, sites.folderOf(deploy_site)) catch return;
    if (job.site_dir.len == 0) return;
    job.token = a.dupe(u8, token) catch return;
    job.space = a.dupe(u8, cloud.spaces[0].slug) catch return;
    job.name = a.dupe(u8, deploy_site) catch return;
    job.slug = a.dupe(u8, address_field.value()) catch return;
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

/// The deploy's progress page, named by the command: the sheet closes and the site's own tab
/// shows the page, as Clone to this Mac does.
fn deployPageShown(job: *deploying.Job) void {
    if (open_sheet == .deploy) closeSheet();
    sheet_busy = null;
    openLocal(job.name);
    for (tabs.items, 0..) |t, i| {
        const pt = t.project orelse continue;
        if (!std.mem.eql(u8, pt.folder, job.name)) continue;
        pt.page = .admin;
        showTab(i);
        loadIn(t, job.page);
        break;
    }
    redrawAll();
}

fn deployFinished(job: *deploying.Job) void {
    defer {
        job.arena.deinit();
        gpa.destroy(job);
        deploy_job = null;
    }
    sheet_busy = null;
    if (auto_deploy) std.debug.print("desktop: deploy finished: {s}{s}\n", .{ job.problem orelse "live at ", if (job.problem == null) job.address else "" });
    // Its page showed how it ended: the card becomes the linked project, nothing more to say.
    if (job.page.len > 0) {
        refreshSites();
        cloud.refresh();
        if (job.problem == null) {
            if (sites.find(job.name)) |s| thumbs.take(s.name, s.address);
        }
        return redrawAll();
    }
    if (job.problem) |pr| {
        sheet_error = pr;
        window.setTextInput(true);
        return redrawAll();
    }
    if (deployed_address.len > 0) gpa.free(deployed_address);
    deployed_address = gpa.dupe(u8, job.address) catch "";
    open_sheet = .deployed;
    refreshSites();
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
    // The default account email from Settings; none leaves the admin to the site's setup page.
    loadSavedAdmin();
    const job = gpa.create(NewSite) catch return;
    job.* = .{
        .name = gpa.dupe(u8, name_field.value()) catch return,
        .admin = gpa.dupe(u8, defaultAccount()) catch return,
    };
    sheet_busy = "Making the site…";
    redrawAll();
    const thread = std.Thread.spawn(.{}, NewSite.run, .{job}) catch return;
    thread.detach();
}

// New project.

/// A project's name as the dashboard takes it: 1 to 60 characters.
fn projectNameProblem(name: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, name, " ");
    if (trimmed.len == 0) return "";
    if (trimmed.len > 60) return "At most 60 characters.";
    return null;
}

fn projectState(fields: *[1]sheet.Field) sheet.State {
    const size = window.size();
    const a = frame_arena.allocator();
    const space = cloud.spaces[targetSpace()].name;
    const problem = projectNameProblem(name_field.value());
    const usual: sheet.Note = .{
        .text = "Its address is made from the name, with six random characters.",
    };
    fields[0] = .{
        .label = "Name",
        .field = &name_field,
        .placeholder = "My project",
        .note = if (sheet_error) |e| .{
            .text = e,
            .kind = .bad,
        } else if (problem) |pr| (if (pr.len > 0) sheet.Note{
            .text = pr,
            .kind = .bad,
        } else usual) else usual,
    };
    return .{
        .title = "New project",
        .description = std.fmt.allocPrint(a, "A project on Publr Cloud, in {s}, with the starter page.", .{space}) catch "",
        .fields = fields[0..1],
        .primary = "Create project",
        .primary_enabled = problem == null,
        .busy = sheet_busy,
        .hover = sheet_hover,
        .window_width = @floatCast(size.w),
        .window_height = @floatCast(size.h),
    };
}

fn createProject() void {
    if (sheet_busy != null or projectNameProblem(name_field.value()) != null) return;
    if (!cloudOffered()) return;
    const i = targetSpace();
    sheet_busy = "Making the project…";
    redrawAll();
    cloud.createProject(cloud.spaces[i].slug, std.mem.trim(u8, name_field.value(), " "), projectMade);
}

fn projectMade(made: @import("cloud.zig").Made) void {
    sheet_busy = null;
    if (made.problem) |pr| {
        // The message outlives this call: Cloud's words are in the job's memory.
        if (problem_text.len > 0) gpa.free(problem_text);
        problem_text = gpa.dupe(u8, pr) catch "";
        sheet_error = problem_text;
        return redrawAll();
    }
    closeSheet();
    cloud.refresh();
    openProjectAdmin(made.name, made.address);
}

/// `p new` makes the site with the starter page and starts it: off the main thread.
const NewSite = struct {
    name: []const u8,
    admin: []const u8,
    ok: bool = false,

    fn run(self: *NewSite) void {
        self.ok = sites.make(self.name, self.admin);
        native.runOnMain(self, done);
    }

    fn done(ctx: ?*anyopaque) callconv(.c) void {
        const self: *NewSite = @ptrCast(@alignCast(ctx));
        defer {
            gpa.free(self.name);
            gpa.free(self.admin);
            gpa.destroy(self);
        }
        sheet_busy = null;
        if (!self.ok) {
            sheet_error = "The site could not be made. See Console for p's message.";
            return redrawAll();
        }
        closeSheet();
        refreshSites();
        view = .local;
        openLocal(self.name);
        if (sites.find(self.name)) |s| thumbs.take(s.name, s.address);
    }
};

// Tabs.

fn showHome() void {
    if (active) |i| if (i < tabs.items.len) tabs.items[i].web.setVisible(false);
    active = null;
    refreshSites();
    window.setBarHeight(window.size().h + 10_000); // the whole window
    window.focusApp();
    redrawAll();
}

fn showTab(i: usize) void {
    if (i >= tabs.items.len) return;
    menu = null;
    for (tabs.items, 0..) |t, k| t.web.setVisible(k == i and webShown(t));
    active = i;
    const t = tabs.items[i];
    // A project's Overview is drawn here, over the whole window; its other pages sit under
    // the strip.
    if (t.project) |pt| {
        // A project's Overview and sidebar are drawn here; its other pages lie beside them.
        if (pt.page == .overview) window.setBarHeight(window.size().h + 10_000) else window.setWebArea(project.sidebar_width, bar.height);
    } else window.setBarHeight(bar.height);
    redrawAll();
}

fn webShown(t: Tab) bool {
    const pt = t.project orelse return true;
    return pt.page != .overview;
}

/// The project tab `i` as its page draws it.
fn projectPage(i: usize) project.State {
    const t = tabs.items[i];
    const pt = t.project.?;
    const size = window.size();
    const local = if (pt.folder.len > 0) sites.find(pt.folder) else null;
    const kind: home.Kind = if (local != null and pt.live.len > 0) .both else if (local != null) .local else .cloud;
    var state: syncing.State = .checking;
    if (kind == .both) {
        var db: [512]u8 = undefined;
        syncing.check(pt.folder, siteDir(&db, pt.folder), pt.live, nowMs(), false);
        state = syncing.stateOf(pt.folder) orelse .checking;
    }
    const a = frame_arena.allocator();
    var none: [0]?[]const u8 = .{};
    const app_thumbs: []?[]const u8 = a.alloc(?[]const u8, pt.apps.len) catch &none;
    for (pt.apps, app_thumbs) |app, *thumb| {
        var kb: [256]u8 = undefined;
        var nb: [256]u8 = undefined;
        const key = thumbs.key(&kb, appThumbName(&nb, pt.folder, app.name));
        thumb.* = if (key) |k| a.dupe(u8, k) catch null else null;
    }
    const waiting = kind == .both and state == .waiting and syncing.reviewOf(pt.folder) != null;
    return .{
        .top = bar.height,
        .width = @floatCast(size.w),
        .height = @floatCast(size.h),
        .name = t.name,
        .kind = kind,
        .status = if (pt.note.len > 0) pt.note else switch (kind) {
            .both => syncing.labelOf(pt.folder, state, a.alloc(u8, 128) catch &.{}),
            .local => if (local.?.running) "Running on this Mac" else "Stopped",
            .cloud => "Live on Cloud",
        },
        .running = if (kind == .local) local.?.running else state != .failed,
        .changed = kind == .both and (state == .unsent or state == .waiting),
        .callout = if (kind != .both) .none else switch (state) {
            .unsent => .unsent,
            .waiting => if (waiting) .waiting else .none,
            .failed => .failed,
            else => .none,
        },
        .failed_why = whyText(a, syncing.whyOf(pt.folder)),
        .address = if (pt.live.len > 0) pt.live else if (local) |s| s.address else "",
        .folder = if (local) |s| shortFolder(a, s.folder) else "",
        .pin = if (local) |s| s.pin else "",
        .own_build = if (local) |s| shortBuild(a, s.own_build) else "",
        .shared_build = if (local) |s| shortBuild(a, s.shared_build) else "",
        .advanced = pt.advanced,
        .cloning = pt.cloning,
        .apps_loading = pt.apps_loading,
        .app_thumbs = app_thumbs,
        .space = if (pt.space.len > 0) pt.space else spaceOf(pt.live),
        .apps = pt.apps,
        .menu_open = pt.menu_open,
        .scroll = pt.scroll,
        .page = pt.page,
        .hover = switch (hover) {
            .project => |h| h,
            else => .none,
        },
    };
}

fn clickProject(i: usize, target: project.Target) void {
    const t = tabs.items[i];
    const pt = t.project orelse return;
    const was_open = pt.menu_open;
    pt.menu_open = false;
    switch (target) {
        .none, .outside => {},
        .more => pt.menu_open = !was_open,
        .clone => startClone(pt),
        .side => |pg| goTo(i, pg),
        .finder => showInFinder(pt.folder),
        .advanced => pt.advanced = !pt.advanced,
        .choose_build => choosePublr(pt.folder, false),
        .use_pin => choosePublr(pt.folder, true),
        .admin => goTo(i, .admin),
        .site, .address => goTo(i, .site),
        .app => |k| goTo(i, .{
            .app = k,
        }),
        .callout => if (syncing.reviewOf(pt.folder) != null) openReview(pt.folder, pt.live) else syncing.send(pt.folder),
        .rare => |r| switch (r) {
            .clone => startClone(pt),
            .local_copy => openSite(pt.folder),
            .finder => showInFinder(pt.folder),
            .deploy => deploy(pt.folder),
            .dashboard => {
                var buf: [512]u8 = undefined;
                native.openInBrowser(std.fmt.bufPrintSentinel(&buf, "{s}/projects/{s}", .{ cloud.base, syncing.slugOf(pt.live) }, 0) catch return);
            },
            .remove => {
                const folder = gpa.dupe(u8, pt.folder) catch return;
                defer gpa.free(folder);
                closeTab(i);
                act(folder, Action.trash);
            },
        },
    }
    redrawAll();
}

fn openSite(name: []const u8) void {
    rememberRecent(name);
    // A folder linked to Cloud has two tabs of the same name: this one is the local admin's.
    for (tabs.items, 0..) |t, i| if (t.url == null and t.project == null and std.mem.eql(u8, t.name, name)) return showTab(i);
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
    if (t.project) |pt| {
        pt.arena.deinit();
        gpa.destroy(pt);
    }
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

// A project elsewhere: its apps listed, or the project cloned here, off the main thread.
// Without a device token for it, a Cloud project is signed in first (Cloud's sign-on token
// redeemed by `publr login --sign-on`), as sync does.

const RemoteKind = enum { apps, clone };

const RemoteJob = struct {
    kind: RemoteKind,
    live: []const u8,
    /// Cloud's one-time sign-on token, when the job signs in first; empty when it need not.
    sign_on: []const u8,
    arena: std.heap.ArenaAllocator,
    apps: []const project.App = &.{},
    /// No device token for the project, and none asked for yet.
    needs_sign_in: bool = false,
    ok: bool = false,
    /// What a failed clone said last.
    line: []const u8 = "",

    fn run(self: *RemoteJob) void {
        const a = self.arena.allocator();
        if (self.sign_on.len > 0) {
            _ = std.process.run(a, io, .{
                .argv = &.{ sites.command_path, "login", self.live, "--sign-on", self.sign_on },
            }) catch {};
        }
        const token = remote.tokenFor(io, a, env_map, self.live);
        if (token == null and self.sign_on.len == 0 and cloud.token != null) {
            self.needs_sign_in = true;
            return native.runOnMain(self, finished);
        }
        switch (self.kind) {
            .apps => if (token) |t| {
                self.apps = remote.apps(io, a, self.live, t);
            },
            .clone => self.clone(a),
        }
        native.runOnMain(self, finished);
    }

    /// `publr clone`, its progress page opened in the tab the moment the command prints it;
    /// the page asks what comes down.
    fn clone(self: *RemoteJob, a: std.mem.Allocator) void {
        var child = std.process.spawn(io, .{
            .argv = &.{ sites.command_path, "clone", self.live, "--no-open" },
            .stdout = .pipe,
            .stderr = .pipe,
        }) catch |e| {
            self.line = @errorName(e);
            return;
        };
        var buffer: [4096]u8 = undefined;
        var reader = child.stdout.?.readerStreaming(io, &buffer);
        var last: []const u8 = "";
        while (reader.interface.takeDelimiter('\n') catch null) |line| {
            last = a.dupe(u8, line) catch last;
            const marker = "Follow it at ";
            const at = std.mem.indexOf(u8, line, marker) orelse continue;
            const url = std.mem.trim(u8, line[at + marker.len ..], " \r");
            const opened = gpa.create(PageOpened) catch continue;
            opened.* = .{
                .live = gpa.dupe(u8, self.live) catch continue,
                .url = gpa.dupeSentinel(u8, url, 0) catch continue,
            };
            native.runOnMain(opened, PageOpened.load);
        }
        var errors: [4096]u8 = undefined;
        var err_reader = child.stderr.?.readerStreaming(io, &errors);
        const said = err_reader.interface.allocRemaining(a, .limited(1 << 16)) catch "";
        const term = child.wait(io) catch {
            self.line = "Clone failed";
            return;
        };
        self.ok = term == .exited and term.exited == 0;
        if (!self.ok) {
            const told = remote.lastLine(said);
            self.line = if (told.len > 0) told else last;
        }
    }

    fn finished(ctx: ?*anyopaque) callconv(.c) void {
        const self: *RemoteJob = @ptrCast(@alignCast(ctx));
        defer {
            self.arena.deinit();
            gpa.free(self.live);
            gpa.free(self.sign_on);
            gpa.destroy(self);
        }
        if (self.needs_sign_in) {
            const live = gpa.dupe(u8, self.live) catch return;
            remote_pending.append(gpa, .{
                .kind = self.kind,
                .live = live,
            }) catch return gpa.free(live);
            cloud.signOnTo(syncing.slugOf(live), remoteSignedOn);
            return;
        }
        const pt = remoteTab(self.live) orelse return;
        switch (self.kind) {
            .apps => {
                const a = pt.arena.allocator();
                const copy = a.alloc(project.App, self.apps.len) catch return;
                for (self.apps, copy) |app, *to| to.* = .{
                    .name = a.dupe(u8, app.name) catch "",
                    .label = a.dupe(u8, app.label) catch "",
                    .address = a.dupe(u8, app.address) catch "",
                    .mount = a.dupe(u8, app.mount) catch "/",
                };
                if (pt.folder.len == 0) pt.apps = copy;
                pt.apps_loading = false;
            },
            .clone => {
                pt.cloning = false;
                if (!self.ok) {
                    pt.note = pt.arena.allocator().dupe(u8, if (self.line.len > 0) self.line else "Clone failed") catch "";
                } else {
                    pt.note = "";
                    refreshSites();
                    becameLocal(pt);
                    // A project on Cloud and on this Mac shows Cloud's copy: on into its admin
                    // there, past the page's own way into the copy here.
                    for (tabs.items, 0..) |t, i| if (t.project == pt) {
                        pt.signed = false;
                        adminAt(i, "/admin", null);
                        break;
                    };
                }
            },
        }
        redrawAll();
    }
};

/// A clone's progress page, opened in its project's tab as the admin is.
const PageOpened = struct {
    live: []u8,
    url: [:0]u8,

    fn load(ctx: ?*anyopaque) callconv(.c) void {
        const self: *PageOpened = @ptrCast(@alignCast(ctx));
        defer {
            gpa.free(self.live);
            gpa.free(self.url);
            gpa.destroy(self);
        }
        for (tabs.items, 0..) |t, i| {
            const pt = t.project orelse continue;
            if (pt.live.len == 0 or !std.mem.eql(u8, hostOf(pt.live), hostOf(self.live))) continue;
            pt.page = .admin;
            showTab(i);
            return loadIn(t, self.url);
        }
    }
};

var remote_pending: std.ArrayList(struct {
    kind: RemoteKind,
    live: []const u8,
}) = .empty;

fn startRemote(kind: RemoteKind, live: []const u8, sign_on: []const u8) void {
    const job = gpa.create(RemoteJob) catch return;
    job.* = .{
        .kind = kind,
        .live = gpa.dupe(u8, live) catch return gpa.destroy(job),
        .sign_on = gpa.dupe(u8, sign_on) catch return gpa.destroy(job),
        .arena = .init(gpa),
    };
    const thread = std.Thread.spawn(.{}, RemoteJob.run, .{job}) catch return;
    thread.detach();
}

/// Cloud's sign-on token for a project a job waited on: the job again, signing in first.
fn remoteSignedOn(signed: @import("cloud.zig").SignedOn) void {
    var k: usize = 0;
    while (k < remote_pending.items.len) {
        const waiting = remote_pending.items[k];
        if (!std.mem.eql(u8, syncing.slugOf(waiting.live), signed.slug)) {
            k += 1;
            continue;
        }
        _ = remote_pending.orderedRemove(k);
        defer gpa.free(waiting.live);
        if (signed.problem == null and signed.token.len > 0) {
            startRemote(waiting.kind, waiting.live, signed.token);
        } else if (remoteTab(waiting.live)) |pt| {
            pt.cloning = false;
            pt.apps_loading = false;
            if (waiting.kind == .clone) pt.note = "Sign-in failed";
        }
    }
    redrawAll();
}

/// The open tab of the project live at `live`, if any.
fn remoteTab(live: []const u8) ?*ProjectTab {
    for (tabs.items) |t| {
        const pt = t.project orelse continue;
        if (pt.live.len > 0 and std.mem.eql(u8, hostOf(pt.live), hostOf(live))) return pt;
    }
    return null;
}

fn startClone(pt: *ProjectTab) void {
    if (pt.cloning or pt.live.len == 0 or pt.folder.len > 0) return;
    pt.cloning = true;
    pt.note = "";
    startRemote(.clone, pt.live, "");
}

/// Home's refresh, Command-R where Desktop draws: the sites on this Mac and the Cloud projects
/// read again (a project made on Cloud since shows).
fn refreshAll() void {
    refreshSites();
    if (cloud.token != null) cloud.refresh();
    redrawAll();
}

/// The site list read again, and every open tab told what changed in it.
fn refreshSites() void {
    sites.refresh();
    syncTabs();
}

/// Each open project's tab as the site list now has it: a folder that went to Cloud (by
/// Desktop or by `publr deploy`) carries its live address, a link taken away leaves it, and a
/// Cloud project that came to this Mac gets its folder.
fn syncTabs() void {
    for (tabs.items) |*t| {
        const pt = t.project orelse continue;
        if (pt.folder.len == 0) {
            if (pt.live.len > 0) becameLocal(pt);
            continue;
        }
        const s = sites.find(pt.folder) orelse continue;
        if (std.mem.eql(u8, s.live, pt.live)) continue;
        const a = pt.arena.allocator();
        pt.live = a.dupe(u8, s.live) catch continue;
        if (t.url) |old| gpa.free(old);
        t.url = if (pt.live.len > 0) adminOf(pt.live) else null;
        pt.signed = false;
        var db: [512]u8 = undefined;
        const base = if (pt.live.len > 0) pt.live else s.address;
        pt.apps = project.readApps(io, a, siteDir(&db, pt.folder), base);
        takeAppThumbs(pt.folder, pt.apps);
    }
}

/// A cloned project's tab, now its copy on this Mac: the folder and its own apps.
fn becameLocal(pt: *ProjectTab) void {
    for (sites.list.items) |s| {
        if (s.live.len == 0 or !std.mem.eql(u8, hostOf(s.live), hostOf(pt.live))) continue;
        const a = pt.arena.allocator();
        // Tabs know a local project by its name, as the site list does.
        pt.folder = a.dupe(u8, s.name) catch return;
        var db: [512]u8 = undefined;
        pt.apps = project.readApps(io, a, siteDir(&db, pt.folder), pt.live);
        takeAppThumbs(pt.folder, pt.apps);
        return;
    }
}

const SignIn = struct {
    name: []const u8,
    web: *native.WebView,
    /// The page it opens on: the admin's, or the site's.
    path: []const u8 = "/admin",
    /// `path` is the job's own copy, freed with it.
    owns_path: bool = false,
    link: ?[:0]u8 = null,

    fn run(self: *SignIn) void {
        self.link = sites.signInLink(self.name, self.path) catch |e| blk: {
            std.debug.print("desktop: signing in to {s} failed: {}\n", .{ self.name, e });
            break :blk null;
        };
        native.runOnMain(self, load);
    }

    fn load(ctx: ?*anyopaque) callconv(.c) void {
        const self: *SignIn = @ptrCast(@alignCast(ctx));
        defer gpa.destroy(self);
        defer if (self.owns_path) gpa.free(self.path);
        const link = self.link orelse return;
        defer gpa.free(link);
        // The tab may have closed while the server started.
        for (tabs.items) |t| if (t.web == self.web) return self.web.loadUrl(link);
    }
};

fn onMenu(_: ?*anyopaque, tag: u32) void {
    switch (tag) {
        // A page in a web view loads again; anything Desktop draws (Home, an Overview) reads
        // the sites and the Cloud projects again.
        Tag.reload => {
            if (active) |i| if (webShown(tabs.items[i])) return tabs.items[i].web.reload();
            refreshAll();
        },
        Tag.open_in_browser => if (active) |i| openInBrowser(tabs.items[i]),
        Tag.home => showHome(),
        Tag.close_tab => if (active) |i| closeTab(i) else window.close(),
        Tag.refresh_sites => refreshAll(),
        Tag.settings => openSettings(),
        else => if (tag >= Tag.tab and tag < Tag.tab + 9) showTab(tag - Tag.tab),
    }
}

/// The page the tab shows, in the browser, signed in there too (the tab's session is its
/// own).
/// The same page, on the same copy: a project on Cloud signs in there through a one-time
/// sign-on landing on it; a site on this Mac through the command's link. A page of the
/// admin stays the admin's, a page of the site the site's (the sign-on takes it on there).
fn openInBrowser(t: Tab) void {
    const address = t.web.address();
    var path: []const u8 = "/";
    if (std.mem.indexOf(u8, address, "://")) |scheme| {
        if (std.mem.indexOfScalarPos(u8, address, scheme + 3, '/')) |slash| path = address[slash..];
    }
    // A sign-on link is for one use: the admin itself instead.
    if (std.mem.startsWith(u8, path, "/auth/")) path = "/admin";
    const pt = t.project orelse return sites.openInBrowser(t.name, path);
    if (pt.live.len == 0) return sites.openInBrowser(if (pt.folder.len > 0) pt.folder else t.name, path);
    if (cloud.token == null) {
        var buf: [2048]u8 = undefined;
        return native.openInBrowser(std.fmt.bufPrintSentinel(&buf, "{s}", .{address}, 0) catch return);
    }
    if (sign_on_return) |old| gpa.free(old);
    sign_on_return = gpa.dupe(u8, path) catch null;
    cloud.signOnTo(syncing.slugOf(pt.live), browserSignedOn);
}

/// A Cloud project's page in the browser, signed in there by the one-time sign-on.
fn browserSignedOn(signed: @import("cloud.zig").SignedOn) void {
    if (signed.problem) |pr| {
        std.debug.print("desktop: signing in to {s} for the browser: {s}\n", .{ signed.slug, pr });
        return;
    }
    native.openInBrowser(withReturn(signed.url));
}

// What Desktop keeps between starts.

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
    // Only local sites' tabs come back as they were; a Cloud tab needs a fresh sign-on.
    for (tabs.items) |t| {
        if (t.url != null or t.project != null) continue;
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
    _ = deploying;
    _ = bar;
    _ = home;
    _ = project;
    _ = sites_module;
    _ = settings;
}

// Settings: where sites live, the command in Terminal, and the build every project runs.
// Read from the command's config each time the page opens, written back at once on every
// change.

/// What the Settings page shows: copies in their own arena, made again on every change.
var settings_arena: std.heap.ArenaAllocator = undefined;
var settings_ready = false;
var settings_folder: []const u8 = "";
/// The other folders, absolute (what `remove` is given) and as people read them.
var settings_folders: []const []const u8 = &.{};
var settings_shown: []const []const u8 = &.{};
/// The Publr every site runs, as people read it; null when each runs its own release.
var settings_publr: ?[]const u8 = null;
/// The admin set for new sites (`publr config admin`); empty when none is.
var settings_admin: []const u8 = "";
var settings_command: settings.Command = .missing;
/// Advanced is unfolded (for this run only).
var settings_advanced = false;
var settings_busy: ?[]const u8 = null;
var settings_problem: ?[]const u8 = null;

/// Where Terminal's `publr` goes: the place editors put their commands.
const command_link = "/usr/local/bin/publr";

/// Home on its Settings page, read from the config afresh.
fn openSettings() void {
    menu = null;
    if (active != null) showHome();
    view = .settings;
    scroll = 0;
    loadSettings();
    settings_problem = null;
    hover = .none;
    redrawAll();
}

fn loadSettings() void {
    if (!settings_ready) {
        settings_arena = .init(gpa);
        settings_ready = true;
    }
    _ = settings_arena.reset(.retain_capacity);
    const a = settings_arena.allocator();
    const config = core.Config.load(io, a, env_map) catch |e| {
        settings_problem = "The settings could not be read.";
        return std.debug.print("desktop: settings: {t}\n", .{e});
    };
    settings_folder = shortFolder(a, config.folder);
    settings_folders = config.folders;
    const shown = a.alloc([]const u8, config.folders.len) catch return;
    for (config.folders, shown) |f, *out| out.* = shortFolder(a, f);
    settings_shown = shown;
    settings_publr = if (config.publr.len > 0) shortFolder(a, config.publr) else null;
    settings_admin = config.admin;
    settings_command = commandState(a);
}

/// Whether Terminal's `publr` is Desktop's, another, or none.
fn commandState(a: std.mem.Allocator) settings.Command {
    var buf: [1024]u8 = undefined;
    if (Io.Dir.cwd().readLink(io, command_link, &buf)) |n| {
        if (std.mem.eql(u8, buf[0..n], sites.command_path)) return .installed;
    } else |_| {}
    const found = sites_module.onPath(a, io, env_map) orelse {
        Io.Dir.cwd().access(io, command_link, .{}) catch return .missing;
        return .{
            .other = command_link,
        };
    };
    if (std.mem.eql(u8, found, sites.command_path)) return .installed;
    return .{
        .other = found,
    };
}

/// Settings' admin for new sites, as people read it.
fn settingsAdmin() []const u8 {
    if (settings_admin.len > 0) return settings_admin;
    if (cloud.status == .signed_in and cloud.account_email.len > 0) return cloud.account_email;
    return "Not set";
}

fn settingsState() settings.State {
    const size = window.size();
    return .{
        .top = bar.height,
        .left = home.sidebar_width,
        .width = @floatCast(size.w),
        .height = @floatCast(size.h),
        .folder = settings_folder,
        .folders = settings_shown,
        .publr = settings_publr,
        .admin = settingsAdmin(),
        .command = settings_command,
        .advanced = settings_advanced,
        .busy = settings_busy,
        .problem = settings_problem,
        .hover = switch (hover) {
            .settings => |h| h,
            else => .none,
        },
    };
}

fn clickSettings(t: settings.Target) void {
    switch (t) {
        .change_folder => chooseFolder(.default),
        .change_admin => openAdminSheet(),
        .add_folder => chooseFolder(.add),
        .remove_folder => |i| removeFolder(i),
        .install => installCommand(),
        .advanced => settings_advanced = !settings_advanced,
        .choose_publr => choosePublr(null, false),
        .clear_publr => choosePublr(null, true),
        .none => {},
    }
    hover = .none;
    redrawAll();
}

/// The config read, changed by `change` and written, then the sheet and Home again.
fn changeConfig(change: *const fn (*core.Config) anyerror!void) void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var config = core.Config.load(io, arena.allocator(), env_map) catch {
        settings_problem = "The settings could not be read.";
        return redrawAll();
    };
    change(&config) catch |e| {
        settings_problem = switch (e) {
            error.TooManyFolders => "That is as many folders as Desktop lists.",
            else => "The settings could not be saved.",
        };
        return redrawAll();
    };
    config.save() catch {
        settings_problem = "The settings could not be saved.";
        return redrawAll();
    };
    settings_problem = null;
    loadSettings();
    refreshSites();
    redrawAll();
}

const FolderFor = enum {
    default,
    add,
};

/// The system's folder chooser, off the main thread: AppleScript's `choose folder`, the
/// same panel apps open.
const ChooseFolder = struct {
    purpose: FolderFor,
    chosen: []u8 = &.{},

    fn run(job: *ChooseFolder) void {
        const prompt = if (job.purpose == .default) "Where new sites go" else "A folder of sites, or a site's folder";
        const script = std.fmt.allocPrint(gpa, "POSIX path of (choose folder with prompt \"{s}\")", .{prompt}) catch return native.runOnMain(job, finish);
        defer gpa.free(script);
        const result = std.process.run(gpa, io, .{
            .argv = &.{ "osascript", "-e", script },
        }) catch return native.runOnMain(job, finish);
        defer gpa.free(result.stderr);
        const ok = result.term == .exited and result.term.exited == 0;
        if (ok) {
            const path = std.mem.trimEnd(u8, std.mem.trim(u8, result.stdout, " \r\n"), "/");
            job.chosen = gpa.dupe(u8, path) catch &.{};
        }
        gpa.free(result.stdout);
        native.runOnMain(job, finish);
    }

    fn finish(ctx: ?*anyopaque) callconv(.c) void {
        const job: *ChooseFolder = @ptrCast(@alignCast(ctx));
        defer {
            gpa.free(job.chosen);
            gpa.destroy(job);
        }
        settings_busy = null;
        if (job.chosen.len == 0) return redrawAll();
        chosen_folder = job.chosen;
        changeConfig(switch (job.purpose) {
            .default => setDefaultFolder,
            .add => addFolder,
        });
        chosen_folder = "";
    }
};

/// The folder just chosen, for `changeConfig`'s change.
var chosen_folder: []const u8 = "";

fn setDefaultFolder(config: *core.Config) anyerror!void {
    config.folder = chosen_folder;
    try Io.Dir.cwd().createDirPath(io, chosen_folder);
}

fn addFolder(config: *core.Config) anyerror!void {
    _ = try config.add(chosen_folder);
}

fn chooseFolder(purpose: FolderFor) void {
    if (settings_busy != null) return;
    const job = gpa.create(ChooseFolder) catch return;
    job.* = .{
        .purpose = purpose,
    };
    settings_busy = "Choosing a folder…";
    redrawAll();
    const thread = std.Thread.spawn(.{}, ChooseFolder.run, .{job}) catch {
        settings_busy = null;
        gpa.destroy(job);
        return;
    };
    thread.detach();
}

var removing: usize = 0;

fn removeFolder(i: usize) void {
    if (i >= settings_folders.len) return;
    removing = i;
    changeConfig(removeChosen);
}

fn removeChosen(config: *core.Config) anyerror!void {
    _ = try config.remove(settings_folders[removing]);
}

/// The Publr a project (or, with no name, every site) runs: a binary chosen in the system's
/// file panel, or (`clear`) its own release again. Off the main thread: the panel waits for
/// the person, and a running site restarts on the new Publr.
const ChoosePublr = struct {
    /// The project's site; null for every site.
    name: ?[]u8,
    clear: bool,
    failed: bool = false,

    fn run(job: *ChoosePublr) void {
        defer native.runOnMain(job, finish);
        var path: []u8 = &.{};
        defer gpa.free(path);
        if (!job.clear) {
            const result = std.process.run(gpa, io, .{
                .argv = &.{ "osascript", "-e", "POSIX path of (choose file with prompt \"Choose a publr binary\")" },
            }) catch return;
            defer gpa.free(result.stderr);
            defer gpa.free(result.stdout);
            // Cancelled: nothing changes.
            if (result.term != .exited or result.term.exited != 0) return;
            path = gpa.dupe(u8, std.mem.trim(u8, result.stdout, " \r\n")) catch return;
            if (path.len == 0) return;
        }
        sites.choosePublr(job.name, path) catch |e| {
            job.failed = true;
            std.debug.print("desktop: choosing the Publr: {t}\n", .{e});
        };
    }

    fn finish(ctx: ?*anyopaque) callconv(.c) void {
        const job: *ChoosePublr = @ptrCast(@alignCast(ctx));
        defer {
            if (job.name) |n| gpa.free(n);
            gpa.destroy(job);
        }
        if (job.name == null) {
            settings_busy = null;
            settings_problem = if (job.failed) "That Publr could not be used." else null;
            loadSettings();
        }
        refreshSites();
        redrawAll();
    }
};

fn choosePublr(name: ?[]const u8, clear: bool) void {
    if (name == null and settings_busy != null) return;
    const job = gpa.create(ChoosePublr) catch return;
    job.* = .{
        .name = if (name) |n| gpa.dupe(u8, n) catch return gpa.destroy(job) else null,
        .clear = clear,
    };
    if (name == null) {
        settings_busy = if (clear) "Going back to each site's release…" else "Choosing a Publr…";
        redrawAll();
    }
    const thread = std.Thread.spawn(.{}, ChoosePublr.run, .{job}) catch {
        if (name == null) settings_busy = null;
        if (job.name) |n| gpa.free(n);
        gpa.destroy(job);
        return;
    };
    thread.detach();
}

/// `/usr/local/bin/publr` made a link to the command inside Desktop: directly when the folder
/// lets this user write, else through the system's administrator prompt.
const Install = struct {
    ok: bool = false,

    fn run(job: *Install) void {
        job.ok = link() or linkAsAdmin();
        native.runOnMain(job, finish);
    }

    fn link() bool {
        const cwd = Io.Dir.cwd();
        cwd.createDirPath(io, "/usr/local/bin") catch return false;
        cwd.deleteFile(io, command_link) catch |e| if (e != error.FileNotFound) return false;
        cwd.symLink(io, sites.command_path, command_link, .{}) catch return false;
        return true;
    }

    fn linkAsAdmin() bool {
        const script = std.fmt.allocPrint(gpa, "do shell script \"mkdir -p /usr/local/bin && ln -sf '{s}' {s}\" with administrator privileges", .{ sites.command_path, command_link }) catch return false;
        defer gpa.free(script);
        const result = std.process.run(gpa, io, .{
            .argv = &.{ "osascript", "-e", script },
        }) catch return false;
        gpa.free(result.stdout);
        gpa.free(result.stderr);
        return result.term == .exited and result.term.exited == 0;
    }

    fn finish(ctx: ?*anyopaque) callconv(.c) void {
        const job: *Install = @ptrCast(@alignCast(ctx));
        defer gpa.destroy(job);
        settings_busy = null;
        settings_problem = if (job.ok) null else "publr was not installed.";
        loadSettings();
        redrawAll();
    }
};

fn installCommand() void {
    if (settings_busy != null or settings_command != .missing) return;
    // `DESKTOP_NO_INSTALL`: the button is pressed without touching /usr/local/bin (tests).
    if (env_map.get("DESKTOP_NO_INSTALL") != null) {
        std.debug.print("desktop: would link {s} to {s}\n", .{ command_link, sites.command_path });
        return;
    }
    const job = gpa.create(Install) catch return;
    job.* = .{};
    settings_busy = "Installing publr…";
    redrawAll();
    const thread = std.Thread.spawn(.{}, Install.run, .{job}) catch {
        settings_busy = null;
        gpa.destroy(job);
        return;
    };
    thread.detach();
}
