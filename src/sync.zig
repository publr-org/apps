//! Keeping each folder on this Mac in sync with its Cloud project, off the main thread. The
//! folder's Publr says where it is (`publr pull --check`); one with no work of its own that
//! Cloud moved past is brought up to date (`publr pull`, its server stopped first: only what
//! changed comes down). A folder not yet signed in to its project is signed in through
//! Cloud's sign-on (`publr login --sign-on`), nothing to approve. Sending work up is the
//! person's: `send` runs `publr push`, a branch someone reviews on Cloud.
//!
//! Every decision is made on the main thread; a job only runs one command and hands back.

const std = @import("std");
const native = @import("native");

pub const State = enum {
    checking,
    up_to_date,
    updating,
    /// Work of the folder's own not on Cloud yet.
    unsent,
    sending,
    /// Sent, waiting for someone to review it on Cloud.
    waiting,
    signing_in,
    failed,

    /// What the card says.
    pub fn text(s: State) []const u8 {
        return switch (s) {
            .checking => "Checking\u{2026}",
            .up_to_date => "Up to date",
            .updating => "Updating from Cloud\u{2026}",
            .unsent => "Changes not on Cloud yet",
            .sending => "Sending to Cloud\u{2026}",
            .waiting => "Sent for review",
            .signing_in => "Signing in\u{2026}",
            .failed => "Couldn\u{2019}t reach Cloud",
        };
    }
};

/// Why a command failed, from what it wrote: the last line that says something (not a bare
/// error name, `publr: FetchFailed`), without its `publr: ` and with the address it names
/// left off. Empty when it said nothing.
pub fn reasonOf(said: []const u8) []const u8 {
    var found: []const u8 = "";
    var lines = std.mem.tokenizeScalar(u8, said, '\n');
    while (lines.next()) |raw| {
        var line = std.mem.trim(u8, raw, " \r\t");
        if (std.mem.startsWith(u8, line, "publr: ")) line = line["publr: ".len..];
        if (line.len == 0 or bareName(line)) continue;
        found = line;
    }
    // `… (https://…)`: the address is for the log, not the card.
    if (std.mem.lastIndexOf(u8, found, " (")) |at| {
        if (std.mem.indexOf(u8, found[at..], "://") != null) found = found[0..at];
    }
    return found;
}

/// `ConnectionRefused`: one word, a capital first, as Zig names an error.
fn bareName(line: []const u8) bool {
    if (!std.ascii.isUpper(line[0])) return false;
    for (line) |c| if (!std.ascii.isAlphanumeric(c)) return false;
    return true;
}

/// Whether `reason` is Cloud (or the site) not answering at all.
fn unreachable_(reason: []const u8) bool {
    const words = [_][]const u8{
        "ConnectionRefused",     "UnknownHostName",         "NetworkUnreachable",         "ConnectionTimedOut",
        "ConnectionResetByPeer", "TlsInitializationFailed", "TemporaryNameServerFailure",
    };
    for (words) |w| if (std.mem.indexOf(u8, reason, w) != null) return true;
    return false;
}

/// What a failed folder's card says: Cloud not answering, or the reason's first part
/// (`couldn't download Publr 0.7.0: NotFound` → `Couldn't download Publr 0.7.0`).
pub fn failedLabel(reason: []const u8, buf: []u8) []const u8 {
    if (reason.len == 0 or unreachable_(reason)) return State.failed.text();
    const short = reason[0 .. std.mem.indexOf(u8, reason, ": ") orelse reason.len];
    const n = @min(short.len, buf.len);
    @memcpy(buf[0..n], short[0..n]);
    if (n > 0) buf[0] = std.ascii.toUpper(buf[0]);
    return buf[0..n];
}

test "a failed command's reason and its card's label" {
    var buf: [128]u8 = undefined;
    const fetch = "publr: fetching Publr 0.7.0\u{2026}\n" ++
        "publr: couldn't download Publr 0.7.0: NotFound (https://github.com/x)\n\npublr: FetchFailed\n";
    try std.testing.expectEqualStrings("couldn't download Publr 0.7.0: NotFound", reasonOf(fetch));
    try std.testing.expectEqualStrings("Couldn't download Publr 0.7.0", failedLabel(reasonOf(fetch), &buf));
    try std.testing.expectEqualStrings("Couldn\u{2019}t reach Cloud", failedLabel(reasonOf("publr: ConnectionRefused\n"), &buf));
    try std.testing.expectEqualStrings("Couldn\u{2019}t reach Cloud", failedLabel("", &buf));
}

const Entry = struct {
    state: State = .checking,
    busy: bool = false,
    checked_ms: i64 = 0,
    /// Signed in once already this run: a second refusal is not tried again.
    signed_in: bool = false,
    /// While waiting: where its branch is reviewed on Cloud.
    review: []u8 = &.{},
    /// Once failed: why, as the command said it (`reasonOf`).
    why: []u8 = &.{},
};

/// How long a folder's state stands before it is asked again.
const recheck_ms: i64 = 60_000;
/// `publr pull`'s exit codes (`publr/src/server/clone/pull.zig`).
const signed_out_code: u8 = 3;
const own_work_code: u8 = 4;

const Command = enum { check, pull, push, login };

const Job = struct {
    command: Command,
    name: []u8,
    dir: []u8,
    /// The project's address (`login`), and the sign-on token for it.
    site: []u8,
    token: []u8,
    /// `publr stop` first (`pull`: a server must not run while the folder is replaced).
    stop_first: bool,
    exit: u8 = 255,
    out: []u8 = &.{},
    /// What the command said, once it failed (`reasonOf`).
    why: []u8 = &.{},
    fn run(job: *Job) void {
        job.exec() catch |e| std.debug.print("studio: sync {s} {t}: {t}\n", .{ job.name, job.command, e });
        native.runOnMain(job, finish);
    }

    fn exec(job: *Job) !void {
        const a = shared.gpa;
        if (job.stop_first) {
            const stopped = try std.process.run(a, shared.io, .{
                .argv = &.{ shared.publr, "stop", job.dir },
                .environ_map = shared.env,
            });
            a.free(stopped.stdout);
            a.free(stopped.stderr);
        }
        const argv: []const []const u8 = switch (job.command) {
            .check => &.{ shared.publr, "pull", "--check" },
            .pull => &.{ shared.publr, "pull" },
            .push => &.{ shared.publr, "push" },
            .login => &.{ shared.publr, "login", job.site, "--sign-on", job.token },
        };
        const result = try std.process.run(a, shared.io, .{
            .argv = argv,
            .cwd = .{
                .path = job.dir,
            },
            .environ_map = shared.env,
        });
        defer a.free(result.stderr);
        job.out = result.stdout;
        job.exit = if (result.term == .exited) result.term.exited else 255;
        if (job.exit != 0) {
            std.debug.print("studio: publr {t} in {s}: {s}\n", .{ job.command, job.name, result.stderr });
            job.why = try a.dupe(u8, reasonOf(result.stderr));
        }
        // Stopped for the pull, running again after it, whatever it did.
        if (job.stop_first) {
            const started = try std.process.run(a, shared.io, .{
                .argv = &.{ shared.publr, "start", job.dir },
                .environ_map = shared.env,
            });
            a.free(started.stdout);
            a.free(started.stderr);
        }
    }

    fn finish(ctx: ?*anyopaque) callconv(.c) void {
        const job: *Job = @ptrCast(@alignCast(ctx));
        defer {
            const a = shared.gpa;
            a.free(job.name);
            a.free(job.dir);
            a.free(job.site);
            a.free(job.token);
            a.free(job.out);
            a.free(job.why);
            a.destroy(job);
        }
        finished(job);
    }
};

const Shared = struct {
    gpa: std.mem.Allocator = undefined,
    io: std.Io = undefined,
    env: *const std.process.Environ.Map = undefined,
    /// The `publr` command Studio carries.
    publr: []const u8 = "",
    /// Asks Cloud for a sign-on token for a project's slug; answers through `signedOn`.
    sign_on: *const fn (slug: []const u8) void = undefined,
    /// Something a card shows changed.
    changed: *const fn () void = undefined,
    /// Whether the site's server runs (a pull stops it first).
    running: *const fn (name: []const u8) bool = undefined,
    entries: std.StringHashMapUnmanaged(Entry) = .empty,
    /// Folders by name: where each is, and its project's address.
    dirs: std.StringHashMapUnmanaged([]const u8) = .empty,
    sites: std.StringHashMapUnmanaged([]const u8) = .empty,
};

var shared: Shared = .{};

pub fn init(options: struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    publr: []const u8,
    sign_on: *const fn (slug: []const u8) void,
    changed: *const fn () void,
    running: *const fn (name: []const u8) bool,
}) void {
    shared.gpa = options.gpa;
    shared.io = options.io;
    shared.env = options.env;
    shared.publr = options.publr;
    shared.sign_on = options.sign_on;
    shared.changed = options.changed;
    shared.running = options.running;
}

/// Where the folder's sent work is reviewed on Cloud; null when nothing waits.
pub fn reviewOf(name: []const u8) ?[]const u8 {
    const e = shared.entries.get(name) orelse return null;
    if (e.state != .waiting or e.review.len == 0) return null;
    return e.review;
}

/// Where the folder `name` is; null for a folder Studio has not asked about.
pub fn stateOf(name: []const u8) ?State {
    const e = shared.entries.get(name) orelse return null;
    return e.state;
}

/// Why the folder `name` failed, as its command said it; empty when it has not.
pub fn whyOf(name: []const u8) []const u8 {
    const e = shared.entries.get(name) orelse return "";
    return if (e.state == .failed) e.why else "";
}

/// What the folder's card says: its state, or for a failure a short reason.
pub fn labelOf(name: []const u8, state: State, buf: []u8) []const u8 {
    if (state != .failed) return state.text();
    return failedLabel(whyOf(name), buf);
}

/// Asks where the folder `name` (at `dir`, linked to `site`) is, unless it was asked lately
/// or is busy; `force` asks at once.
pub fn check(name: []const u8, dir: []const u8, site: []const u8, now_ms: i64, force: bool) void {
    const e = entry(name, dir, site) orelse return;
    if (e.busy) return;
    if (!force and e.checked_ms > 0 and now_ms - e.checked_ms < recheck_ms) return;
    e.checked_ms = now_ms;
    if (e.state != .unsent and e.state != .waiting and e.state != .up_to_date) e.state = .checking;
    start(name, .check, false, "");
}

/// The folder's work sent up as a branch for review.
pub fn send(name: []const u8) void {
    const e = shared.entries.getPtr(name) orelse return;
    if (e.busy) return;
    e.state = .sending;
    start(name, .push, false, "");
    shared.changed();
}

/// Cloud's answer to `sign_on`: the token signs the folder in, then it is asked again.
pub fn signedOn(slug: []const u8, token: ?[]const u8) void {
    var it = shared.sites.iterator();
    while (it.next()) |kv| {
        if (!std.mem.eql(u8, slugOf(kv.value_ptr.*), slug)) continue;
        const e = shared.entries.getPtr(kv.key_ptr.*) orelse continue;
        if (e.state != .signing_in) continue;
        if (token) |t| {
            start(kv.key_ptr.*, .login, false, t);
        } else {
            e.state = .failed;
            e.busy = false;
        }
    }
    shared.changed();
}

fn entry(name: []const u8, dir: []const u8, site: []const u8) ?*Entry {
    const a = shared.gpa;
    if (!shared.entries.contains(name)) {
        const key = a.dupe(u8, name) catch return null;
        shared.entries.put(a, key, .{}) catch return null;
        shared.dirs.put(a, key, a.dupe(u8, dir) catch return null) catch return null;
        shared.sites.put(a, key, a.dupe(u8, site) catch return null) catch return null;
    }
    return shared.entries.getPtr(name);
}

fn start(name: []const u8, command: Command, stop_first: bool, token: []const u8) void {
    const a = shared.gpa;
    const e = shared.entries.getPtr(name) orelse return;
    const job = a.create(Job) catch return;
    job.* = .{
        .command = command,
        .name = a.dupe(u8, name) catch return,
        .dir = a.dupe(u8, shared.dirs.get(name) orelse return) catch return,
        .site = a.dupe(u8, shared.sites.get(name) orelse return) catch return,
        .token = a.dupe(u8, token) catch return,
        .stop_first = stop_first,
    };
    e.busy = true;
    const t = std.Thread.spawn(.{}, Job.run, .{job}) catch {
        e.busy = false;
        return;
    };
    t.detach();
}

const Where = struct {
    changes: bool = false,
    unsent: bool = false,
    waiting: bool = false,
    behind: bool = false,
    review: []const u8 = "",
};

/// After a failure, Home drawn again once `recheck_ms` passed, which asks again: a failure
/// is tried again even while nobody touches the window.
fn retryLater() void {
    const t = std.Thread.spawn(.{}, struct {
        fn wait() void {
            std.Io.sleep(shared.io, .fromMilliseconds(recheck_ms + 1000), .awake) catch return;
            native.runOnMain(null, again);
        }
        fn again(_: ?*anyopaque) callconv(.c) void {
            shared.changed();
        }
    }.wait, .{}) catch return;
    t.detach();
}

/// What a job found, and what follows from it: on the main thread.
fn finished(job: *Job) void {
    defer shared.changed();
    defer if (shared.entries.get(job.name)) |held| {
        if (held.state == .failed) retryLater();
    };
    const e = shared.entries.getPtr(job.name) orelse return;
    e.busy = false;
    // Kept until the next answer: why it failed, for the card and the project's details.
    if (e.why.len > 0) shared.gpa.free(e.why);
    e.why = shared.gpa.dupe(u8, job.why) catch &.{};
    switch (job.command) {
        .check => {
            if (job.exit == signed_out_code) return signIn(job.name, e);
            if (job.exit != 0) {
                e.state = .failed;
                return;
            }
            const where = std.json.parseFromSliceLeaky(Where, shared.gpa, job.out, .{
                .ignore_unknown_fields = true,
            }) catch {
                e.state = .failed;
                return;
            };
            e.state = if (where.unsent) .unsent else if (where.waiting) .waiting else .up_to_date;
            if (e.review.len > 0) shared.gpa.free(e.review);
            e.review = shared.gpa.dupe(u8, where.review) catch &.{};
            // A folder with nothing of its own (or all of it merged) takes Cloud's state.
            if (where.behind and !where.unsent and !where.waiting) {
                e.state = .updating;
                start(job.name, .pull, shared.running(job.name), "");
            }
        },
        .pull => {
            if (job.exit == own_work_code) {
                e.state = .unsent;
                return;
            }
            e.state = if (job.exit == 0) .up_to_date else .failed;
        },
        .push => {
            if (job.exit == signed_out_code) return signIn(job.name, e);
            e.state = if (job.exit == 0) .waiting else .unsent;
            // Asked again at once: the check names where it is reviewed.
            if (job.exit == 0) start(job.name, .check, false, "");
        },
        .login => {
            if (job.exit != 0) {
                e.state = .failed;
                return;
            }
            e.state = .checking;
            start(job.name, .check, false, "");
        },
    }
}

fn signIn(name: []const u8, e: *Entry) void {
    if (e.signed_in) {
        e.state = .failed;
        return;
    }
    e.signed_in = true;
    e.state = .signing_in;
    e.busy = true;
    shared.sign_on(slugOf(shared.sites.get(name) orelse return));
}

/// A project's slug from its address: the first name of its host.
pub fn slugOf(address: []const u8) []const u8 {
    const h = if (std.mem.indexOf(u8, address, "://")) |i| address[i + 3 ..] else address;
    const end = std.mem.indexOfAny(u8, h, ".:/") orelse h.len;
    return h[0..end];
}
