//! The sites on this Mac, through the `publr` command's core (`publr_cli`): every listed
//! folder's sites, their servers, signed-in links to their admins, new sites. Studio and the
//! command read the same folders and config, so a site made by either is in both lists.

const std = @import("std");
const core = @import("publr_cli");

pub const Site = struct {
    name: []const u8,
    running: bool,
    /// The site's address ("http://localhost:8103"); empty until it first started.
    address: []const u8,
    /// Its folder, wherever it is.
    folder: []const u8,
    /// The entry of the list it was found under: a folder of sites, or its own folder.
    entry: []const u8,
    /// Deployed: the live site's and its Cloud admin's addresses (the folder's `cloud.json`).
    live: []const u8 = "",
    live_admin: []const u8 = "",
    /// The Publr version its `publr.zon` pins ("0.6.4"); empty when none or unreadable.
    pin: []const u8 = "",
    /// A build the project runs instead (`publr config publr <path> <name>`); empty: none.
    own_build: []const u8 = "",
    /// A build every project runs instead (`publr config publr <path>`); empty: none.
    shared_build: []const u8 = "",
};

pub const Sites = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    /// The `publr` command Studio runs: beside its executable, `$STUDIO_PUBLR`, or on the
    /// PATH (started from the Finder there is no shell PATH, so the bundled one comes first).
    command_path: []const u8,
    list: std.ArrayList(Site) = .empty,
    /// The default folder, where New project puts sites.
    folder: []const u8 = "",

    /// Lists the sites again.
    pub fn refresh(self: *Sites) void {
        for (self.list.items) |s| self.free(s);
        self.list.clearRetainingCapacity();
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var config = core.Config.load(self.io, a, self.env) catch |e| {
            std.debug.print("studio: the command's config: {t}\n", .{e});
            return;
        };
        if (self.folder.len > 0) self.gpa.free(self.folder);
        self.folder = self.gpa.dupe(u8, config.folder) catch "";
        const found = core.Sites.find(&config) catch |e| {
            std.debug.print("studio: listing sites: {t}\n", .{e});
            return;
        };
        for (found.all) |s| {
            const port = s.local.port;
            var site: Site = .{
                .name = self.gpa.dupe(u8, s.name) catch continue,
                .running = core.server.running(self.io, s),
                .address = self.gpa.dupe(u8, if (port > 0) core.server.site_url(a, s) catch "" else "") catch continue,
                .folder = self.gpa.dupe(u8, s.folder) catch continue,
                .entry = self.gpa.dupe(u8, s.entry) catch continue,
                .pin = self.gpa.dupe(u8, pinOf(&config, s)) catch continue,
                .own_build = self.gpa.dupe(u8, s.local.publr) catch continue,
                .shared_build = self.gpa.dupe(u8, config.publr) catch continue,
            };
            readLink(self, a, &site);
            self.list.append(self.gpa, site) catch {};
        }
    }

    fn free(self: *Sites, s: Site) void {
        self.gpa.free(s.name);
        self.gpa.free(s.address);
        self.gpa.free(s.folder);
        self.gpa.free(s.entry);
        self.gpa.free(s.pin);
        self.gpa.free(s.own_build);
        self.gpa.free(s.shared_build);
        if (s.live.len > 0) self.gpa.free(s.live);
        if (s.live_admin.len > 0) self.gpa.free(s.live_admin);
    }

    /// The folder's Cloud link, if it was deployed (`cloud.json`, as `publr deploy` and
    /// Studio write it), else the site it was cloned from (`.publr/clone.json`).
    fn readLink(self: *Sites, a: std.mem.Allocator, site: *Site) void {
        const path = std.fs.path.join(a, &.{ site.folder, "cloud.json" }) catch return;
        const bytes = std.Io.Dir.cwd().readFileAlloc(self.io, path, a, .limited(64 * 1024)) catch {
            return self.readClone(a, site);
        };
        const Link = struct {
            address: []const u8 = "",
            admin: []const u8 = "",
        };
        const link = std.json.parseFromSliceLeaky(Link, a, bytes, .{
            .ignore_unknown_fields = true,
        }) catch return;
        site.live = self.gpa.dupe(u8, link.address) catch "";
        site.live_admin = self.gpa.dupe(u8, link.admin) catch "";
    }

    /// A folder cloned from a site (`publr clone`) is that site's working copy too.
    fn readClone(self: *Sites, a: std.mem.Allocator, site: *Site) void {
        const path = std.fs.path.join(a, &.{ site.folder, ".publr", "clone.json" }) catch return;
        const bytes = std.Io.Dir.cwd().readFileAlloc(self.io, path, a, .limited(64 * 1024)) catch return;
        const Link = struct {
            site: []const u8 = "",
        };
        const link = std.json.parseFromSliceLeaky(Link, a, bytes, .{
            .ignore_unknown_fields = true,
        }) catch return;
        if (link.site.len > 0) site.live = self.gpa.dupe(u8, link.site) catch "";
    }

    /// The site named `name`. Two folders may hold sites of one name; the first listed wins.
    pub fn find(self: *const Sites, name: []const u8) ?Site {
        for (self.list.items) |s| if (std.mem.eql(u8, s.name, name)) return s;
        return null;
    }

    /// The site whose folder is `folder`.
    pub fn atFolder(self: *const Sites, folder: []const u8) ?Site {
        const clean = std.mem.trimEnd(u8, folder, "/");
        for (self.list.items) |s| if (std.mem.eql(u8, s.folder, clean)) return s;
        return null;
    }

    /// The site's folder; empty when there is no such site.
    pub fn folderOf(self: *const Sites, name: []const u8) []const u8 {
        const s = self.find(name) orelse return "";
        return s.folder;
    }

    /// A one-use link that signs into the site's admin at `path`, starting the site's
    /// server when it is stopped (which takes a moment: call it off the main thread). Reads
    /// the list from disk, not `list`, so it is safe beside a refresh.
    pub fn signInLink(self: *Sites, name: []const u8, path: []const u8) ![:0]u8 {
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const config = try core.Config.load(self.io, arena.allocator(), self.env);
        var site = try locate(&config, name);
        const publr = try core.versions.binary_for(&config, site);
        try core.server.start(&config, &site, publr);
        try core.helper.ensure(&config, self.command_path);
        return self.gpa.dupeZ(u8, try core.sign_on.entry(&config, &site, publr, path));
    }

    /// Opens the site's admin at `path` in the person's browser, signed in there.
    pub fn openInBrowser(self: *Sites, name: []const u8, path: []const u8) void {
        const link = self.signInLink(name, path) catch |e| {
            std.debug.print("studio: signing in to {s}: {t}\n", .{ name, e });
            return;
        };
        defer self.gpa.free(link);
        var child = std.process.spawn(self.io, .{
            .argv = &.{ "open", link },
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch return;
        _ = child.wait(self.io) catch {};
    }

    /// Makes a site in the default folder, set up and started, on the newest Publr
    /// (fetched when this Mac has none yet); false when it failed.
    pub fn make(self: *Sites, name: []const u8) bool {
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        var config = core.Config.load(self.io, arena.allocator(), self.env) catch return false;
        _ = core.project.new(&config, name, self.command_path, .{}) catch |e| {
            std.debug.print("studio: new site {s}: {t}\n", .{ name, e });
            return false;
        };
        return true;
    }

    /// The site's server started (its Publr fetched first when missing).
    pub fn start(self: *Sites, name: []const u8) void {
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const config = core.Config.load(self.io, arena.allocator(), self.env) catch return;
        var site = locate(&config, name) catch return;
        const publr = core.versions.binary_for(&config, site) catch |e| {
            return std.debug.print("studio: {s}'s Publr: {t}\n", .{ name, e });
        };
        core.server.start(&config, &site, publr) catch |e| std.debug.print("studio: starting {s}: {t}\n", .{ name, e });
        core.helper.ensure(&config, self.command_path) catch {};
    }

    pub fn stop(self: *Sites, name: []const u8) void {
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const config = core.Config.load(self.io, arena.allocator(), self.env) catch return;
        var site = locate(&config, name) catch return;
        core.server.stop(&config, &site) catch |e| std.debug.print("studio: stopping {s}: {t}\n", .{ name, e });
    }

    /// The Publr `name` runs (or every site, when `name` is null) set to the binary at `path`;
    /// an empty `path` goes back to the site's own release (or each site's). A running site
    /// restarts on it at once; others pick it up when they next start. Reads and writes the
    /// config on disk, not `list`: call it off the main thread.
    pub fn choosePublr(self: *Sites, name: ?[]const u8, path: []const u8) !void {
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        var config = try core.Config.load(self.io, arena.allocator(), self.env);
        const chosen = if (path.len > 0) try core.versions.resolve(&config, path) else "";
        const named = name orelse {
            config.publr = chosen;
            return config.save();
        };
        var site = try locate(&config, named);
        const running = core.server.running(self.io, site);
        if (running) try core.server.stop(&config, &site);
        site.local.publr = chosen;
        try core.sites.save(&config, site);
        if (running) {
            try core.server.start(&config, &site, try core.versions.binary_for(&config, site));
            try core.helper.ensure(&config, self.command_path);
        }
    }

    /// Stopped and moved to its folder's `.trash`, as `publr rm` does; a single site's own
    /// entry goes off the list with it.
    pub fn remove(self: *Sites, name: []const u8) void {
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var config = core.Config.load(self.io, a, self.env) catch return;
        var site = locate(&config, name) catch return;
        core.server.stop(&config, &site) catch {};
        const parent = std.fs.path.dirname(site.folder) orelse return;
        const trash = std.fs.path.join(a, &.{ parent, ".trash" }) catch return;
        const kept = std.fmt.allocPrint(a, "{s}-{d}", .{ site.name, core.server.now_ms(self.io) }) catch return;
        const cwd = std.Io.Dir.cwd();
        cwd.createDirPath(self.io, trash) catch return;
        cwd.rename(site.folder, cwd, std.fs.path.join(a, &.{ trash, kept }) catch return, self.io) catch |e| {
            return std.debug.print("studio: removing {s}: {t}\n", .{ name, e });
        };
        if (std.mem.eql(u8, site.entry, site.folder) and (config.remove(site.folder) catch false)) config.save() catch {};
    }
};

/// What Publr `site` runs, in words: its own choice, the one for every site, else its pin.
fn pinOf(config: *const core.Config, site: core.Site) []const u8 {
    const pin = core.versions.pin_of(config, site.folder) catch return "";
    return pin orelse "";
}

/// The site named `name` as the core lists it; the first of that name, as `find` picks.
fn locate(config: *const core.Config, name: []const u8) !core.Site {
    const found = try core.Sites.find(config);
    for (found.all) |s| if (std.mem.eql(u8, s.name, name)) return s;
    return error.NoSuchSite;
}

/// The `publr` command for Studio to run: beside its own executable (inside the app,
/// `Contents/MacOS/publr`), `$STUDIO_PUBLR`, or the first on the PATH.
pub fn commandPath(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) []const u8 {
    const cwd = std.Io.Dir.cwd();
    if (std.process.executableDirPathAlloc(io, gpa)) |dir| {
        const beside = std.fs.path.join(gpa, &.{ dir, "publr" }) catch "";
        gpa.free(dir);
        if (beside.len > 0) {
            if (cwd.access(io, beside, .{})) |_| return beside else |_| gpa.free(beside);
        }
    } else |_| {}
    if (env.get("STUDIO_PUBLR")) |given| return given;
    return onPath(gpa, io, env) orelse "publr";
}

/// The first `publr` on the PATH, or null.
pub fn onPath(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) ?[]const u8 {
    const path = env.get("PATH") orelse return null;
    var dirs = std.mem.tokenizeScalar(u8, path, ':');
    while (dirs.next()) |dir| {
        const candidate = std.fs.path.join(gpa, &.{ dir, "publr" }) catch continue;
        if (std.Io.Dir.cwd().access(io, candidate, .{})) |_| return candidate else |_| gpa.free(candidate);
    }
    return null;
}

/// A folder as people read it: the home folder as `~`.
pub fn shortPath(buf: []u8, home: []const u8, folder: []const u8) []const u8 {
    if (home.len > 0 and std.mem.startsWith(u8, folder, home) and
        (folder.len == home.len or folder[home.len] == '/'))
    {
        return std.fmt.bufPrint(buf, "~{s}", .{folder[home.len..]}) catch folder;
    }
    return folder;
}

test "folders read with the home folder as ~" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("~/Publr", shortPath(&buf, "/Users/a", "/Users/a/Publr"));
    try std.testing.expectEqualStrings("/srv/sites", shortPath(&buf, "/Users/a", "/srv/sites"));
    try std.testing.expectEqualStrings("/Users/ab", shortPath(&buf, "/Users/a", "/Users/ab"));
}
