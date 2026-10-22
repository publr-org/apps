//! The local sites, through `p` (`~/publr-sites`): listing them and signed-in links to their
//! admins. The `studio` plugin takes this over (`.agents/specs/publr-studio.md`).

const std = @import("std");

pub const Site = struct {
    name: []const u8,
    running: bool,
    /// The site's address ("http://localhost:8103").
    address: []const u8,
    /// Deployed: the live site's and its Cloud admin's addresses (the folder's `cloud.json`).
    live: []const u8 = "",
    live_admin: []const u8 = "",
};

pub const Sites = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    /// Where `p` is: started from the Finder there is no shell PATH.
    p_path: []const u8,
    list: std.ArrayList(Site) = .empty,

    /// Lists the sites again.
    pub fn refresh(self: *Sites) void {
        for (self.list.items) |s| {
            self.gpa.free(s.name);
            self.gpa.free(s.address);
            if (s.live.len > 0) self.gpa.free(s.live);
            if (s.live_admin.len > 0) self.gpa.free(s.live_admin);
        }
        self.list.clearRetainingCapacity();
        const out = self.run(&.{"ls"}) catch |e| {
            std.debug.print("studio: p ls failed: {}\n", .{e});
            return;
        };
        defer self.gpa.free(out);
        var lines = std.mem.tokenizeScalar(u8, out, '\n');
        _ = lines.next(); // NAME STATUS SITE ADMIN
        while (lines.next()) |line| {
            var cols = std.mem.tokenizeScalar(u8, line, ' ');
            const name = cols.next() orelse continue;
            const status = cols.next() orelse continue;
            const address = cols.next() orelse "";
            var site: Site = .{
                .name = self.gpa.dupe(u8, name) catch continue,
                .running = std.mem.eql(u8, status, "running"),
                .address = self.gpa.dupe(u8, address) catch continue,
            };
            self.readLink(&site);
            self.list.append(self.gpa, site) catch {};
        }
    }

    /// The folder's Cloud link, if it was deployed (`cloud.json`, as `publr cloud deploy`
    /// and Studio write it).
    fn readLink(self: *Sites, site: *Site) void {
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const home = self.env.get("HOME") orelse return;
        const path = std.fs.path.join(a, &.{ home, "publr-sites", site.name, "cloud.json" }) catch return;
        const bytes = std.Io.Dir.cwd().readFileAlloc(self.io, path, a, .limited(64 * 1024)) catch return;
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

    pub fn find(self: *const Sites, name: []const u8) ?Site {
        for (self.list.items) |s| if (std.mem.eql(u8, s.name, name)) return s;
        return null;
    }

    /// A one-use link that signs into the site's admin at `path`, starting the site's
    /// server when it is stopped (which takes a moment: call it off the main thread).
    pub fn signInLink(self: *Sites, name: []const u8, path: []const u8) ![:0]u8 {
        const out = try self.run(&.{ "open", name, path, "--print" });
        defer self.gpa.free(out);
        return self.gpa.dupeZ(u8, std.mem.trim(u8, out, " \r\n"));
    }

    /// Opens the site's admin at `path` in the person's browser, signed in there.
    pub fn openInBrowser(self: *Sites, name: []const u8, path: []const u8) void {
        const out = self.run(&.{ "open", name, path }) catch return;
        self.gpa.free(out);
    }

    /// Makes a site on this Mac with the starter page and starts it; false when `p` failed.
    pub fn make(self: *Sites, name: []const u8) bool {
        const out = self.run(&.{ "new", name }) catch return false;
        self.gpa.free(out);
        return true;
    }

    /// Runs `p` with `args` (start, stop, rm), its output dropped.
    pub fn command(self: *Sites, args: []const []const u8) void {
        const out = self.run(args) catch return;
        self.gpa.free(out);
    }

    fn run(self: *Sites, args: []const []const u8) ![]u8 {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(self.gpa);
        try argv.append(self.gpa, self.p_path);
        try argv.appendSlice(self.gpa, args);
        const result = try std.process.run(self.gpa, self.io, .{
            .argv = argv.items,
            .environ_map = self.env,
        });
        defer self.gpa.free(result.stderr);
        if (result.term != .exited or result.term.exited != 0) {
            std.debug.print("studio: p {s}: {s}\n", .{ args[0], result.stderr });
            self.gpa.free(result.stdout);
            return error.PFailed;
        }
        return result.stdout;
    }
};
