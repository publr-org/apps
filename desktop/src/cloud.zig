//! Publr Cloud from Desktop: signing in to the person's account (OAuth with PKCE in the
//! browser, back to Desktop through a one-off listener on 127.0.0.1), the account token in
//! the keychain, and the spaces and projects it lists. Network work runs off the main
//! thread; what it finds is handed back on the main thread (`changed`).
//! The calls are Cloud's (`cloud/docs/projects.md`, "Apps signed in to an account").

const std = @import("std");
const platform = @import("platform");
/// How Publr's API answers (`{ "result": … }`) and refuses (`{ "message": … }`).
const api = @import("publr_api");
const i18n = @import("i18n.zig");
const translated = i18n.translated;

// The first-party client id Publr Cloud signs this app in as.
const client_id = "publr-studio";
const keychain_service = "app.publr.desktop";

pub const Project = struct {
    name: []const u8,
    slug: []const u8,
    address: []const u8,
    preview: bool = false,
    state: []const u8 = "",
};

pub const Space = struct {
    slug: []const u8,
    name: []const u8,
    pro: bool = false,
    projects: []const Project = &.{},
};

const Listing = struct {
    account: struct {
        name: []const u8 = "",
        email: []const u8 = "",
    } = .{},
    spaces: []const Space = &.{},
};

pub const Status = enum {
    signed_out,
    /// The browser is open on Cloud's sign-in.
    signing_in,
    signed_in,
};

pub const Cloud = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    /// The dashboard's address (`https://cloud.publr.app`, `$DESKTOP_CLOUD` to change it).
    base: []const u8,
    status: Status = .signed_out,
    token: ?[]u8 = null,
    account: []const u8 = "",
    /// The account's email: the default account email for new sites when none is set.
    account_email: []const u8 = "",
    spaces: []const Space = &.{},
    /// What the listing points into; replaced with each listing.
    listing: ?std.heap.ArenaAllocator = null,
    /// A sign-in or listing is under way.
    busy: bool = false,
    /// Print the sign-in address instead of opening the browser (tests drive the browser).
    no_browser: bool = false,
    /// What went wrong last, for the person.
    problem: ?[]const u8 = null,
    changed: *const fn () void,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, base: []const u8, changed: *const fn () void) Cloud {
        var c: Cloud = .{
            .gpa = gpa,
            .io = io,
            .base = base,
            .changed = changed,
        };
        // Signed in before: list with the kept token.
        if (platform.keychain.get(gpa, keychain_service, base)) |t| {
            c.token = t;
            c.status = .signed_in;
        }
        return c;
    }

    /// Lists the spaces and projects again (when signed in).
    pub fn refresh(self: *Cloud) void {
        const token = self.token orelse return;
        if (self.busy) return;
        self.busy = true;
        const job = self.gpa.create(Job) catch return;
        job.* = .{
            .cloud = self,
            .token = self.gpa.dupe(u8, token) catch return,
        };
        platform.spawn(Job.list, .{job}) catch return;
    }

    /// Opens Cloud's sign-in in the browser; Desktop is signed in when the person allows it.
    pub fn signIn(self: *Cloud) void {
        if (self.busy) return;
        self.busy = true;
        self.status = .signing_in;
        self.problem = null;
        const job = self.gpa.create(Job) catch return;
        job.* = .{
            .cloud = self,
        };
        platform.spawn(Job.signIn, .{job}) catch return;
    }

    /// Forgets the token here and signs it out on Cloud (listed under the account's apps).
    pub fn signOut(self: *Cloud) void {
        const token = self.token orelse return;
        if (std.mem.indexOfScalar(u8, token, '.')) |dot| {
            var body_buf: [128]u8 = undefined;
            const body = std.fmt.bufPrint(&body_buf, "{{\"id\":\"{s}\"}}", .{token[0..dot]}) catch "";
            var arena: std.heap.ArenaAllocator = .init(self.gpa);
            defer arena.deinit();
            _ = request(self.io, arena.allocator(), self.base, .POST, "/api/device.revoke", .{
                .payload = body,
                .content_type = "application/json",
                .token = token,
            }) catch {};
        }
        platform.keychain.remove(keychain_service, self.base);
        self.gpa.free(token);
        self.token = null;
        self.dropListing();
        self.status = .signed_out;
    }

    fn dropListing(self: *Cloud) void {
        if (self.listing) |*a| a.deinit();
        self.listing = null;
        self.spaces = &.{};
        self.account = "";
        self.account_email = "";
    }

    /// Where projects live: the host projects' addresses end in (`publr.app`), from a
    /// listed project or else the dashboard's own host without `cloud.`.
    pub fn projectDomain(self: *const Cloud, buf: []u8) []const u8 {
        for (self.spaces) |sp| for (sp.projects) |p| {
            const host = hostPart(p.address);
            if (std.mem.indexOfScalar(u8, host, '.')) |dot| return std.fmt.bufPrint(buf, "{s}", .{host[dot + 1 ..]}) catch "publr.app";
        };
        const host = hostPart(self.base);
        const rest = if (std.mem.startsWith(u8, host, "cloud.")) host["cloud.".len..] else host;
        return std.fmt.bufPrint(buf, "{s}", .{rest}) catch "publr.app";
    }

    /// Makes a project named `name` in `space`, with the starter page, as the dashboard's
    /// New project does: `slug` its address before the six `suffix` characters (empty: made
    /// from the name). `done` gets its address, or Cloud's reason, on the main thread.
    pub fn createProject(self: *Cloud, space: []const u8, name: []const u8, slug: []const u8, suffix: []const u8, done: *const fn (made: Made) void) void {
        const token = self.token orelse return;
        var buf: [256]u8 = undefined;
        const job = self.gpa.create(Create) catch return;
        job.* = .{
            .cloud = self,
            .domain = self.gpa.dupe(u8, self.projectDomain(&buf)) catch return,
            .space = self.gpa.dupe(u8, space) catch return,
            .name = self.gpa.dupe(u8, name) catch return,
            .slug = self.gpa.dupe(u8, slug) catch return,
            .suffix = self.gpa.dupe(u8, suffix) catch return,
            .token = self.gpa.dupe(u8, token) catch return,
            .done = done,
        };
        platform.spawn(Create.run, .{job}) catch return;
    }

    /// Changes an app of the project `slug` on Cloud: `action` is `update` (`label` and `path`)
    /// or `remove`.
    pub fn manageApp(self: *Cloud, slug: []const u8, action: []const u8, app: []const u8, label: []const u8, path: []const u8, done: *const fn (problem: ?[]const u8) void) void {
        const token = self.token orelse return done(translated("Publr Cloud could not be reached."));
        const sent = std.json.Stringify.valueAlloc(self.gpa, .{
            .project = slug,
            .action = action,
            .app = app,
            .label = label,
            .path = path,
        }, .{}) catch return;
        const job = self.gpa.create(ManageApp) catch return;
        job.* = .{
            .cloud = self,
            .token = self.gpa.dupe(u8, token) catch return,
            .sent = sent,
            .path = "/api/cloud.manage_apps",
            .refused = translated("Couldn\u{2019}t save the change. Check the name and path, then try again. Reserved paths such as /admin and /api cannot be used."),
            .done = done,
        };
        platform.spawn(ManageApp.run, .{job}) catch return;
    }

    /// Renames the project `slug` on Cloud, its address unchanged: `cloud.rename_project`, as the
    /// dashboard's Settings does. `done` gets why not, or null, on the main thread.
    pub fn renameProject(self: *Cloud, slug: []const u8, name: []const u8, done: *const fn (problem: ?[]const u8) void) void {
        const token = self.token orelse return done(translated("Publr Cloud could not be reached."));
        const sent = std.json.Stringify.valueAlloc(self.gpa, .{
            .project = slug,
            .name = name,
        }, .{}) catch return;
        const job = self.gpa.create(ManageApp) catch return;
        job.* = .{
            .cloud = self,
            .token = self.gpa.dupe(u8, token) catch return,
            .sent = sent,
            .path = "/api/cloud.rename_project",
            .refused = translated("Couldn\u{2019}t rename the project. Use 1 to 60 characters, then try again."),
            .done = done,
        };
        platform.spawn(ManageApp.run, .{job}) catch return;
    }

    /// Signs in to the project `slug` as the member, as the dashboard's `/sign-on` does: `done`
    /// gets the project's `/auth/sign-on` address, good once and for a minute, which lands
    /// signed in on its admin; or Cloud's reason, on the main thread.
    pub fn signOnTo(self: *Cloud, slug: []const u8, done: *const fn (signed: SignedOn) void) void {
        const token = self.token orelse return;
        var buf: [256]u8 = undefined;
        const job = self.gpa.create(SignOn) catch return;
        job.* = .{
            .cloud = self,
            .domain = self.gpa.dupe(u8, self.projectDomain(&buf)) catch return,
            .slug = self.gpa.dupe(u8, slug) catch return,
            .token = self.gpa.dupe(u8, token) catch return,
            .done = done,
        };
        platform.spawn(SignOn.run, .{job}) catch return;
    }

    /// The dashboard page for the account's own settings (apps signed in, sign out).
    pub fn accountPage(self: *const Cloud, buf: []u8) [:0]const u8 {
        return std.fmt.bufPrintSentinel(buf, "{s}/account", .{self.base}, 0) catch "";
    }
};

fn hostPart(address: []const u8) []const u8 {
    const h = if (std.mem.indexOf(u8, address, "://")) |i| address[i + 3 ..] else address;
    return if (std.mem.indexOfScalar(u8, h, '/')) |s| h[0..s] else h;
}

/// A change Cloud makes for the member: an app of a project changed or removed
/// (`cloud.manage_apps`, as the dashboard's app cards do), or a project renamed
/// (`cloud.rename_project`). `done` gets why not, or null.
const ManageApp = struct {
    cloud: *Cloud,
    token: []u8,
    /// The request, written whole on the main thread.
    sent: []u8,
    /// The operation's route, and what is said when Cloud refuses the change.
    path: []const u8,
    refused: []const u8,
    problem: ?[]const u8 = null,
    done: *const fn (problem: ?[]const u8) void,

    fn run(self: *ManageApp) void {
        var arena: std.heap.ArenaAllocator = .init(self.cloud.gpa);
        defer arena.deinit();
        self.problem = translated("Publr Cloud could not be reached.");
        if (request(self.cloud.io, arena.allocator(), self.cloud.base, .POST, self.path, .{
            .token = self.token,
            .payload = self.sent,
            .content_type = "application/json",
        })) |reply| {
            self.problem = switch (reply.status) {
                .ok => null,
                .conflict => translated("Another app already uses this path. Choose a different path."),
                else => self.refused,
            };
        } else |_| {}
        platform.runOnMain(self, finish);
    }

    fn finish(ctx: ?*anyopaque) callconv(.c) void {
        const self: *ManageApp = @ptrCast(@alignCast(ctx));
        const gpa = self.cloud.gpa;
        self.done(self.problem);
        gpa.free(self.sent);
        gpa.free(self.token);
        gpa.destroy(self);
    }
};

/// A project made, or why not: `address` is its site's, `problem` Cloud's words.
pub const Made = struct {
    name: []const u8,
    address: []const u8 = "",
    problem: ?[]const u8 = null,
};

const Create = struct {
    cloud: *Cloud,
    /// Where its address goes, read on the main thread with the listing.
    domain: []u8,
    space: []u8,
    name: []u8,
    slug: []u8,
    suffix: []u8,
    token: []u8,
    arena: ?std.heap.ArenaAllocator = null,
    made: Made = .{
        .name = "",
    },
    done: *const fn (made: Made) void,

    fn run(self: *Create) void {
        self.arena = .init(self.cloud.gpa);
        const a = self.arena.?.allocator();
        self.made = .{
            .name = self.name,
            .problem = translated("Publr Cloud could not be reached."),
        };
        const sent = std.json.Stringify.valueAlloc(a, .{
            .space = self.space,
            .name = self.name,
            .slug = self.slug,
            .suffix = self.suffix,
        }, .{}) catch return platform.runOnMain(self, finish);
        if (request(self.cloud.io, a, self.cloud.base, .POST, "/api/cloud.create_project", .{
            .token = self.token,
            .payload = sent,
            .content_type = "application/json",
        })) |reply| {
            const Created = struct {
                slug: []const u8 = "",
            };
            const answer = if (reply.status == .ok) api.result(Created, a, reply.body) catch Created{} else Created{};
            if (answer.slug.len > 0) {
                const scheme = if (std.mem.startsWith(u8, self.cloud.base, "http://")) "http" else "https";
                self.made.problem = null;
                self.made.address = std.fmt.allocPrint(a, "{s}://{s}.{s}", .{ scheme, answer.slug, self.domain }) catch "";
            } else {
                self.made.problem = refused(a, reply.body) orelse translated("Publr Cloud did not make the project.");
            }
        } else |_| {}
        platform.runOnMain(self, finish);
    }

    fn finish(ctx: ?*anyopaque) callconv(.c) void {
        const self: *Create = @ptrCast(@alignCast(ctx));
        const gpa = self.cloud.gpa;
        self.done(self.made);
        if (self.arena) |*arena| arena.deinit();
        gpa.free(self.domain);
        gpa.free(self.space);
        gpa.free(self.name);
        gpa.free(self.slug);
        gpa.free(self.suffix);
        gpa.free(self.token);
        gpa.destroy(self);
    }
};

/// A project's sign-on address, or why there is none.
pub const SignedOn = struct {
    slug: []const u8,
    url: [:0]const u8 = "",
    /// The one-time token itself, for a sign-in other than the tab's (`publr login --sign-on`).
    token: []const u8 = "",
    problem: ?[]const u8 = null,
};

const SignOn = struct {
    cloud: *Cloud,
    /// Where projects live when Cloud names none, read on the main thread.
    domain: []u8,
    slug: []u8,
    token: []u8,
    arena: ?std.heap.ArenaAllocator = null,
    signed: SignedOn = .{
        .slug = "",
    },
    done: *const fn (signed: SignedOn) void,

    fn run(self: *SignOn) void {
        self.arena = .init(self.cloud.gpa);
        const a = self.arena.?.allocator();
        self.signed = .{
            .slug = self.slug,
            .problem = translated("Publr Cloud could not be reached."),
        };
        const sent = std.json.Stringify.valueAlloc(a, .{
            .project = self.slug,
        }, .{}) catch return platform.runOnMain(self, finish);
        if (request(self.cloud.io, a, self.cloud.base, .POST, "/api/cloud.sign_on_token", .{
            .token = self.token,
            .payload = sent,
            .content_type = "application/json",
        })) |reply| {
            const Signed = struct {
                token: []const u8 = "",
                slug: []const u8 = "",
                domain: ?[]const u8 = null,
            };
            const answer = if (reply.status == .ok) api.result(Signed, a, reply.body) catch Signed{} else Signed{};
            if (answer.token.len > 0) {
                const scheme = if (std.mem.startsWith(u8, self.cloud.base, "http://")) "http" else "https";
                self.signed.problem = null;
                self.signed.token = answer.token;
                self.signed.url = std.fmt.allocPrintSentinel(a, "{s}://{s}.{s}/auth/sign-on?token={s}&return=%2Fadmin", .{
                    scheme,
                    answer.slug,
                    answer.domain orelse self.domain,
                    answer.token,
                }, 0) catch "";
            } else {
                self.signed.problem = refused(a, reply.body) orelse translated("Publr Cloud did not sign you in to the project.");
            }
        } else |_| {}
        platform.runOnMain(self, finish);
    }

    fn finish(ctx: ?*anyopaque) callconv(.c) void {
        const self: *SignOn = @ptrCast(@alignCast(ctx));
        const gpa = self.cloud.gpa;
        self.done(self.signed);
        if (self.arena) |*arena| arena.deinit();
        gpa.free(self.domain);
        gpa.free(self.slug);
        gpa.free(self.token);
        gpa.destroy(self);
    }
};

/// One piece of network work, off the main thread; its result is applied on the main one.
const Job = struct {
    cloud: *Cloud,
    token: ?[]u8 = null,
    arena: ?std.heap.ArenaAllocator = null,
    listing: ?Listing = null,
    /// 403 from the listing: the token was signed out elsewhere.
    signed_out: bool = false,
    problem: ?[]const u8 = null,

    fn list(self: *Job) void {
        self.fetch();
        platform.runOnMain(self, apply);
    }

    fn fetch(self: *Job) void {
        var arena: std.heap.ArenaAllocator = .init(self.cloud.gpa);
        const a = arena.allocator();
        const reply = request(self.cloud.io, a, self.cloud.base, .GET, "/api/cloud.spaces", .{
            .token = self.token.?,
        }) catch {
            self.problem = translated("Publr Cloud could not be reached.");
            arena.deinit();
            return;
        };
        if (reply.status == .forbidden or reply.status == .unauthorized) {
            self.signed_out = true;
            arena.deinit();
            return;
        }
        if (reply.status != .ok) {
            self.problem = translated("Publr Cloud did not list your sites.");
            arena.deinit();
            return;
        }
        self.listing = api.result(Listing, a, reply.body) catch {
            self.problem = translated("Publr Cloud answered something Desktop does not understand.");
            arena.deinit();
            return;
        };
        self.arena = arena;
    }

    fn signIn(self: *Job) void {
        self.token = authorize(self.cloud) catch |e| blk: {
            self.problem = switch (e) {
                error.Denied => translated("Sign-in was denied. Try again, or use Publr without Cloud."),
                error.TimedOut => translated("Sign-in took too long. Try again."),
                else => translated("Signing in to Publr Cloud did not work."),
            };
            break :blk null;
        };
        if (self.token != null) self.fetch();
        platform.runOnMain(self, apply);
    }

    /// On the main thread: the cloud takes what the job found.
    fn apply(ctx: ?*anyopaque) callconv(.c) void {
        const self: *Job = @ptrCast(@alignCast(ctx));
        const c = self.cloud;
        const gpa = c.gpa;
        defer gpa.destroy(self);
        c.busy = false;
        c.problem = self.problem;
        if (self.signed_out) {
            if (self.token) |t| gpa.free(t);
            if (c.token) |t| gpa.free(t);
            c.token = null;
            platform.keychain.remove(keychain_service, c.base);
            c.dropListing();
            c.status = .signed_out;
            return c.changed();
        }
        if (self.token) |t| {
            // A new sign-in, or the same token listed again.
            if (c.token == null or !std.mem.eql(u8, c.token.?, t)) {
                if (c.token) |old| gpa.free(old);
                c.token = t;
                _ = platform.keychain.set(keychain_service, c.base, t);
                platform.activate();
            } else gpa.free(t);
        }
        if (self.listing) |l| {
            c.dropListing();
            c.listing = self.arena;
            c.spaces = l.spaces;
            c.account = if (l.account.name.len > 0) l.account.name else l.account.email;
            c.account_email = l.account.email;
        }
        c.status = if (c.token != null) .signed_in else .signed_out;
        c.changed();
    }
};

/// The OAuth flow for a native app (RFC 8252, PKCE): a listener on a free 127.0.0.1 port,
/// the browser on Cloud's authorize page, the code it sends back exchanged for the token.
fn authorize(c: *Cloud) ![]u8 {
    var arena: std.heap.ArenaAllocator = .init(c.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const io = c.io;

    var verifier_bytes: [32]u8 = undefined;
    io.random(&verifier_bytes);
    var state_bytes: [16]u8 = undefined;
    io.random(&state_bytes);
    const b64 = std.base64.url_safe_no_pad.Encoder;
    var verifier_buf: [64]u8 = undefined;
    const verifier = b64.encode(&verifier_buf, &verifier_bytes);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(verifier, &digest, .{});
    var challenge_buf: [64]u8 = undefined;
    const challenge = b64.encode(&challenge_buf, &digest);
    var state_buf: [32]u8 = undefined;
    const state = b64.encode(&state_buf, &state_bytes);

    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var listener = try address.listen(io, .{
        .reuse_address = true,
    });
    defer listener.deinit(io);
    const port = listener.socket.address.getPort();
    const redirect = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/callback", .{port});

    const url = try std.fmt.allocPrintSentinel(a, "{s}/oauth/authorize?response_type=code&client_id={s}&redirect_uri={f}&code_challenge={s}&code_challenge_method=S256&state={s}", .{
        c.base,
        client_id,
        std.fmt.alt(std.Uri.Component{
            .raw = redirect,
        }, .formatEscaped),
        challenge,
        state,
    }, 0);
    if (c.no_browser) std.debug.print("desktop: sign in at {s}\n", .{url}) else platform.openInBrowser(url);

    // The browser comes back once: the code, or the person's no.
    const code = try waitForCode(io, a, &listener, state);

    const form = try std.fmt.allocPrint(a, "grant_type=authorization_code&code={s}&code_verifier={s}&client_id={s}&redirect_uri={f}", .{
        code,
        verifier,
        client_id,
        std.fmt.alt(std.Uri.Component{
            .raw = redirect,
        }, .formatEscaped),
    });
    const reply = try request(io, a, c.base, .POST, "/oauth/token", .{
        .payload = form,
        .content_type = "application/x-www-form-urlencoded",
    });
    if (reply.status != .ok) return error.Refused;
    const Token = struct {
        access_token: []const u8,
    };
    const tok = try std.json.parseFromSliceLeaky(Token, a, reply.body, .{
        .ignore_unknown_fields = true,
    });
    return c.gpa.dupe(u8, tok.access_token);
}

/// What a refusal says, when it says something.
fn refused(arena: std.mem.Allocator, body: []const u8) ?[]const u8 {
    const said = api.refusal(arena, body).message;
    return if (said.len > 0) said else null;
}

const back_page =
    \\<!doctype html><html lang={s}><meta charset=utf-8><title>Publr Desktop</title>
    \\<body style="margin:0;height:100vh;display:grid;place-items:center;font:15px -apple-system,system-ui,sans-serif;color:#222">
    \\<div style="text-align:center"><p style="font-size:18px;font-weight:600;margin:0 0 8px">{s}</p><p style="margin:0;color:#777">{s}</p></div>
;

fn waitForCode(io: std.Io, a: std.mem.Allocator, listener: *std.Io.net.Server, state: []const u8) ![]const u8 {
    // Connections that are not the callback (a favicon) are answered and waited past.
    var tries: usize = 0;
    while (tries < 8) : (tries += 1) {
        const stream = try listener.accept(io);
        defer stream.close(io);
        var in_buf: [8192]u8 = undefined;
        var out_buf: [2048]u8 = undefined;
        var reader = stream.reader(io, &in_buf);
        var writer = stream.writer(io, &out_buf);
        const line = reader.interface.takeDelimiterExclusive('\n') catch continue;
        var parts = std.mem.tokenizeScalar(u8, std.mem.trimEnd(u8, line, "\r"), ' ');
        _ = parts.next();
        const target = parts.next() orelse "/";
        if (!std.mem.startsWith(u8, target, "/callback?")) {
            try writer.interface.writeAll("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
            try writer.interface.flush();
            continue;
        }
        var code: ?[]const u8 = null;
        var got_state: []const u8 = "";
        var denied = false;
        var pairs = std.mem.tokenizeScalar(u8, target["/callback?".len..], '&');
        while (pairs.next()) |pair| {
            const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
            const k = pair[0..eq];
            const v = pair[eq + 1 ..];
            if (std.mem.eql(u8, k, "code")) code = try a.dupe(u8, v);
            if (std.mem.eql(u8, k, "state")) got_state = v;
            if (std.mem.eql(u8, k, "error")) denied = true;
        }
        const ok = code != null and std.mem.eql(u8, got_state, state);
        const body = try std.fmt.allocPrint(a, back_page, if (ok)
            .{ i18n.language(), translated("Signed in to Publr Desktop"), translated("You can close this tab and go back to Desktop.") }
        else
            .{ i18n.language(), translated("Sign-in denied"), translated("Publr Desktop is still signed out. You can close this tab.") });
        try writer.interface.print("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ body.len, body });
        try writer.interface.flush();
        if (denied or !ok) return error.Denied;
        return code.?;
    }
    return error.TimedOut;
}

const Reply = struct {
    status: std.http.Status,
    body: []const u8,
};

const RequestOptions = struct {
    payload: ?[]const u8 = null,
    content_type: ?[]const u8 = null,
    /// Sent as `Authorization: Bearer`; none for a call made before signing in.
    token: ?[]const u8 = null,
};

fn request(io: std.Io, a: std.mem.Allocator, base: []const u8, method: std.http.Method, path: []const u8, options: RequestOptions) !Reply {
    var client: std.http.Client = .{
        .allocator = a,
        .io = io,
    };
    defer client.deinit();
    var body: std.Io.Writer.Allocating = .init(a);
    const url = try std.fmt.allocPrint(a, "{s}{s}", .{ base, path });
    const bearer = if (options.token) |t| try std.fmt.allocPrint(a, "Bearer {s}", .{t}) else "";
    const auth: []const std.http.Header = if (options.token != null) &.{.{
        .name = "Authorization",
        .value = bearer,
    }} else &.{};
    const result = try client.fetch(.{
        .location = .{
            .url = url,
        },
        .method = method,
        .payload = options.payload,
        .keep_alive = false,
        .headers = .{
            .content_type = if (options.content_type) |ct| .{
                .override = ct,
            } else .default,
        },
        .extra_headers = auth,
        .response_writer = &body.writer,
    });
    return .{
        .status = result.status,
        .body = body.written(),
    };
}

test "Cloud's answers are read inside Publr's envelope" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const listed = try api.result(Listing, arena,
        \\{"result":{"account":{"name":"Ada","email":"ada@example.com"},
        \\"spaces":[{"slug":"ada","name":"Ada's space","pro":false,"projects":[
        \\{"name":"Shop","slug":"shop-x1","address":"https://shop-x1.publr.app","preview":false,"state":"ready"}]}]},
        \\"meta":{}}
    );
    try std.testing.expectEqualStrings("Ada", listed.account.name);
    try std.testing.expectEqual(1, listed.spaces.len);
    try std.testing.expectEqualStrings("shop-x1", listed.spaces[0].projects[0].slug);

    // The bare listing of Cloud before Publr 0.8 is no answer: Desktop says so, never
    // "no spaces".
    try std.testing.expectError(error.Invalid, api.result(Listing, arena,
        \\{"account":{"name":"Ada"},"spaces":[]}
    ));
    try std.testing.expectEqualStrings("You may not do this.", refused(arena,
        \\{"error":"Denied","message":"You may not do this.","problems":[]}
    ).?);
}
