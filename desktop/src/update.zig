//! Desktop's own updates. Each start (and Settings' Check for updates) asks for the newest
//! release, off the main thread; one newer than this Desktop is downloaded, checked against
//! Publr's signed checksums (the key Publr's and the command's updates trust) and against
//! the Developer ID it is signed with, then laid beside the app and swapped in. The running
//! Desktop carries on as it was; the next start is the new one, or now with Restart to
//! update. Nothing here ever waits on the network on the main thread.
//!
//! A release is `Publr-Desktop-<version>-macos-<cpu>.dmg` with `SHA256SUMS` and
//! `SHA256SUMS.sig` beside it (`scripts/dmg.sh`). Where releases are asked for and fetched
//! from: `DESKTOP_RELEASES_LATEST` and `DESKTOP_RELEASES_URL` change it (for tests).
//!
//! An app Desktop cannot replace (in a folder this account cannot write, run from the disk
//! image, or moved aside by macOS) is told about the release and links to its download.

const std = @import("std");
const builtin = @import("builtin");
const native = @import("native");
const core = @import("publr_cli");
const build_info = @import("build_info");

pub const version = build_info.version;
pub const repository = "publr-org/desktop";
const latest_default = "https://api.github.com/repos/" ++ repository ++ "/releases/latest";
const downloads_default = "https://github.com/" ++ repository ++ "/releases/download";
const page_default = "https://github.com/" ++ repository ++ "/releases/latest";
/// The Developer ID team Desktop is signed by; an update signed by any other is refused.
const team = "8RHXG5NFYU";
const app_name = "Publr Desktop.app";
const image_bytes_max = 256 << 20;

pub const State = enum {
    /// Not asked yet, or this build has no updates (one built from source).
    idle,
    checking,
    up_to_date,
    downloading,
    /// The newer release is in place: the next start runs it.
    ready,
    /// A newer release is out, and this app cannot be replaced from here.
    available,
    failed,
};

pub const Updater = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    state: State = .idle,
    /// The newer release's version, once known.
    newer: []const u8 = "",
    /// What went wrong last, for the log.
    problem: []const u8 = "",
    /// This app's folder (`/Applications/Publr Desktop.app`); empty when not run as an app.
    bundle: []const u8 = "",
    /// Called on the main thread when the state changes.
    changed: *const fn () void,

    /// Finds this app's folder and clears what an earlier update left aside.
    pub fn init(self: *Updater) void {
        if (comptime builtin.os.tag != .macos) return;
        self.bundle = bundleOf(self.gpa, self.io) orelse "";
        if (self.bundle.len == 0) return;
        const aside = sibling(self.gpa, self.bundle, ".old") catch return;
        defer self.gpa.free(aside);
        std.Io.Dir.cwd().deleteTree(self.io, aside) catch {};
    }

    /// Whether this Desktop takes updates: a release build run as an app.
    pub fn enabled(self: *const Updater) bool {
        if (comptime builtin.os.tag != .macos) return false;
        return self.bundle.len > 0 and !std.mem.eql(u8, version, "0.0.0");
    }

    /// Asks for the newest release, and takes it when it is newer.
    pub fn check(self: *Updater) void {
        if (comptime builtin.os.tag != .macos) return;
        if (!self.enabled()) return;
        switch (self.state) {
            .checking, .downloading, .ready => return,
            else => {},
        }
        self.state = .checking;
        native.spawn(Job.run, .{self}) catch {
            self.state = .failed;
        };
    }

    /// Starts the new Desktop once this one has quit, then quits.
    pub fn restart(self: *Updater) void {
        if (comptime builtin.os.tag != .macos) return;
        if (self.state != .ready) return;
        var pid_buffer: [16]u8 = undefined;
        const pid = std.fmt.bufPrint(&pid_buffer, "{d}", .{std.c.getpid()}) catch return;
        // A shell of its own, in a process group of its own so it outlives this process
        // (and whatever started it): it waits for this one to end, then opens the app at the
        // same place.
        _ = std.process.spawn(self.io, .{
            .argv = &.{
                "/bin/sh",
                "-c",
                "while kill -0 \"$1\" 2>/dev/null; do sleep 0.1; done; exec /usr/bin/open \"$2\"",
                "sh",
                pid,
                self.bundle,
            },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
            .pgid = 0,
        }) catch return;
        native.quit();
    }

    /// Where the release can be downloaded by hand.
    pub fn page(self: *const Updater) []const u8 {
        return self.env.get("DESKTOP_RELEASES_PAGE") orelse page_default;
    }
};

const Job = struct {
    fn run(self: *Updater) void {
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const outcome = take(self, arena.allocator()) catch |e| blk: {
            self.problem = @errorName(e);
            std.debug.print("desktop: update: {t}\n", .{e});
            break :blk State.failed;
        };
        Done.post(self, outcome);
    }
};

/// The state handed back on the main thread.
const Done = struct {
    updater: *Updater,
    state: State,

    fn post(updater: *Updater, state: State) void {
        const done = updater.gpa.create(Done) catch return;
        done.* = .{
            .updater = updater,
            .state = state,
        };
        native.runOnMain(done, finish);
    }

    fn finish(ctx: ?*anyopaque) callconv(.c) void {
        const self: *Done = @ptrCast(@alignCast(ctx));
        defer self.updater.gpa.destroy(self);
        self.updater.state = self.state;
        self.updater.changed();
    }
};

/// The newest release, and when newer: in place (`ready`), or only told of (`available`).
fn take(self: *Updater, arena: std.mem.Allocator) !State {
    const newest = try latest(self, arena);
    const mine = try std.SemanticVersion.parse(version);
    const theirs = std.SemanticVersion.parse(newest) catch return error.BadRelease;
    if (theirs.order(mine) != .gt) return .up_to_date;

    // Read on the main thread only once the state says so.
    self.newer = try self.gpa.dupe(u8, newest);
    if (!replaceable(self)) return .available;
    Done.post(self, .downloading);

    const name = try std.fmt.allocPrint(arena, "Publr-Desktop-{s}-macos-{s}.dmg", .{ newest, cpu() });
    const base = self.env.get("DESKTOP_RELEASES_URL") orelse downloads_default;
    var files: [3][]const u8 = undefined;
    for ([_][]const u8{ name, "SHA256SUMS", "SHA256SUMS.sig" }, 0..) |file, i| {
        const url = try std.fmt.allocPrint(arena, "{s}/v{s}/{s}", .{ base, newest, file });
        var body: std.Io.Writer.Allocating = .init(arena);
        try core.versions.get(self.io, url, &body.writer);
        if (body.written().len > image_bytes_max) return error.TooBig;
        files[i] = body.written();
    }
    if (core.versions.verified_file(files[0], name, files[1], files[2])) |problem| {
        std.debug.print("desktop: update {s} refused: {s}\n", .{ newest, problem });
        return error.NotVerified;
    }

    try install(self, arena, files[0]);
    return .ready;
}

/// The newest release's version, from where releases are listed.
fn latest(self: *Updater, arena: std.mem.Allocator) ![]const u8 {
    const url = self.env.get("DESKTOP_RELEASES_LATEST") orelse latest_default;
    var body: std.Io.Writer.Allocating = .init(arena);
    try core.versions.get(self.io, url, &body.writer);
    const Latest = struct {
        tag_name: []const u8,
    };
    const found = std.json.parseFromSliceLeaky(Latest, arena, body.written(), .{
        .ignore_unknown_fields = true,
    }) catch return error.BadRelease;
    const tag = found.tag_name;
    return if (tag.len > 0 and tag[0] == 'v') tag[1..] else tag;
}

/// The disk image's app laid beside this one, its signature checked, then swapped in: this
/// app moved aside (cleared at the next start), the new one renamed into its place.
fn install(self: *Updater, arena: std.mem.Allocator, image: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    const work = try sibling(arena, self.bundle, ".update");
    try cwd.deleteTree(self.io, work);
    try cwd.createDirPath(self.io, work);
    defer cwd.deleteTree(self.io, work) catch {};

    const dmg = try std.fs.path.join(arena, &.{ work, "update.dmg" });
    try cwd.writeFile(self.io, .{
        .sub_path = dmg,
        .data = image,
    });
    const mount = try std.fs.path.join(arena, &.{ work, "mount" });
    try cwd.createDirPath(self.io, mount);
    try runChecked(self.io, &.{ "/usr/bin/hdiutil", "attach", "-quiet", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount, dmg });
    const fresh = try sibling(arena, self.bundle, ".new");
    try cwd.deleteTree(self.io, fresh);
    const copied = runChecked(self.io, &.{ "/usr/bin/ditto", try std.fs.path.join(arena, &.{ mount, app_name }), fresh });
    runChecked(self.io, &.{ "/usr/bin/hdiutil", "detach", "-quiet", "-force", mount }) catch {};
    try copied;
    errdefer cwd.deleteTree(self.io, fresh) catch {};

    // Signed by Publr's Developer ID, every part of it, or not taken.
    try runChecked(self.io, &.{
        "/usr/bin/codesign",                                                             "--verify", "--deep", "--strict",
        "-R=anchor apple generic and certificate leaf[subject.OU] = \"" ++ team ++ "\"", fresh,
    });

    const aside = try sibling(arena, self.bundle, ".old");
    try cwd.deleteTree(self.io, aside);
    try cwd.rename(self.bundle, cwd, aside, self.io);
    cwd.rename(fresh, cwd, self.bundle, self.io) catch |e| {
        // Put back as it was.
        cwd.rename(aside, cwd, self.bundle, self.io) catch {};
        return e;
    };
}

/// Whether this app's folder can be swapped: its parent writable, not on the disk image.
fn replaceable(self: *Updater) bool {
    const parent = std.fs.path.dirname(self.bundle) orelse return false;
    // Run from the disk image, or moved aside by macOS (App Translocation): read-only.
    if (std.mem.startsWith(u8, parent, "/Volumes/") or std.mem.indexOf(u8, parent, "/AppTranslocation/") != null) return false;
    std.Io.Dir.cwd().access(self.io, parent, .{
        .write = true,
    }) catch return false;
    return true;
}

/// `/Applications/.Publr Desktop<suffix>.app` for `/Applications/Publr Desktop.app`: hidden,
/// on the same disk, so a rename swaps it.
fn sibling(gpa: std.mem.Allocator, bundle: []const u8, suffix: []const u8) ![]const u8 {
    const parent = std.fs.path.dirname(bundle) orelse return error.NoBundle;
    const base = std.fs.path.basename(bundle);
    const stem = if (std.mem.endsWith(u8, base, ".app")) base[0 .. base.len - 4] else base;
    return std.fmt.allocPrint(gpa, "{s}/.{s}{s}.app", .{ parent, stem, suffix });
}

/// The app folder this executable is in (`…/Publr Desktop.app/Contents/MacOS/…`), or null.
fn bundleOf(gpa: std.mem.Allocator, io: std.Io) ?[]const u8 {
    const dir = std.process.executableDirPathAlloc(io, gpa) catch return null;
    defer gpa.free(dir);
    const suffix = "/Contents/MacOS";
    if (!std.mem.endsWith(u8, dir, suffix)) return null;
    const bundle = dir[0 .. dir.len - suffix.len];
    if (!std.mem.endsWith(u8, bundle, ".app")) return null;
    return gpa.dupe(u8, bundle) catch null;
}

fn cpu() []const u8 {
    return switch (builtin.cpu.arch) {
        .aarch64 => "aarch64",
        .x86_64 => "x86_64",
        else => "unsupported",
    };
}

fn runChecked(io: std.Io, argv: []const []const u8) !void {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .inherit,
    });
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code != 0) return error.CommandFailed,
        else => return error.CommandFailed,
    }
}

test sibling {
    const gpa = std.testing.allocator;
    const got = try sibling(gpa, "/Applications/Publr Desktop.app", ".new");
    defer gpa.free(got);
    try std.testing.expectEqualStrings("/Applications/.Publr Desktop.new.app", got);
}
