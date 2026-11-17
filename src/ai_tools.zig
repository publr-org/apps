//! The AI tools on this Mac that Publr works in (Claude Code, Codex, Cursor): which are
//! installed, which have Publr added, and adding it (`publr setup <tool>`, off the main
//! thread). Asked again when Desktop comes to the front, since a tool is installed, or
//! Cursor's own Install chosen, outside it.

const std = @import("std");
const native = @import("native");
const i18n = @import("i18n.zig");
const translated = i18n.translated;

pub const Tool = enum {
    claude,
    codex,
    cursor,

    pub fn name(t: Tool) []const u8 {
        return switch (t) {
            .claude => "Claude Code",
            .codex => "Codex",
            .cursor => "Cursor",
        };
    }
};

pub const all = [_]Tool{ .claude, .codex, .cursor };

pub const Status = enum {
    missing,
    found,
    connecting,
    /// Cursor asked the person to install Publr in its own window.
    in_cursor,
    connected,
    failed,
};

/// One tool as a row says it.
pub const Row = struct {
    tool: Tool,
    line: []const u8,
    /// The row's button, empty for none.
    button: []const u8,
    connected: bool,
};

pub const Tools = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    home: []const u8,
    /// The `publr` command Desktop carries.
    publr: []const u8,
    changed: *const fn () void,
    status: [all.len]Status = @splat(.missing),
    /// The folder each tool's command is in, for its `mcp add`.
    dirs: [all.len][]const u8 = @splat(""),

    /// Which tools are here and which have Publr, read again.
    pub fn check(self: *Tools) void {
        for (all, 0..) |t, i| {
            const busy = self.status[i] == .connecting;
            if (busy) continue;
            if (self.dirs[i].len > 0) self.gpa.free(self.dirs[i]);
            self.dirs[i] = self.find(t) orelse "";
            const here = self.dirs[i].len > 0 or (t == .cursor and self.cursorApp());
            const has = here and self.hasPublr(t);
            self.status[i] = if (has) .connected else if (!here) .missing else switch (self.status[i]) {
                .in_cursor, .failed => self.status[i],
                else => .found,
            };
        }
    }

    pub fn anyFound(self: *const Tools) bool {
        for (self.status) |s| if (s != .missing) return true;
        return false;
    }

    pub fn rows(self: *const Tools, out: *[all.len]Row) []const Row {
        for (all, 0..) |t, i| out[i] = .{
            .tool = t,
            .line = switch (self.status[i]) {
                .missing => translated("Not on this Mac"),
                .found => translated("On this Mac, not connected"),
                .connecting => translated("Connecting\u{2026}"),
                .in_cursor => translated("In Cursor, choose Install"),
                .connected => translated("Connected"),
                .failed => translated("Couldn\u{2019}t connect. Try again."),
            },
            .button = switch (self.status[i]) {
                .found, .failed => translated("Connect"),
                .in_cursor => translated("Open Cursor again"),
                else => "",
            },
            .connected = self.status[i] == .connected,
        };
        return out[0..];
    }

    /// Adds Publr to `tool`; the row says how it went.
    pub fn connect(self: *Tools, tool: Tool) void {
        const i = @backingInt(tool);
        if (self.status[i] == .connecting or self.status[i] == .missing) return;
        self.status[i] = .connecting;
        const job = self.gpa.create(Job) catch return;
        job.* = .{
            .tools = self,
            .tool = tool,
        };
        native.spawn(Job.run, .{job}) catch {
            self.gpa.destroy(job);
            self.status[i] = .failed;
        };
    }

    /// The folder holding the tool's command, or null when it is not installed.
    fn find(self: *Tools, tool: Tool) ?[]const u8 {
        const command = switch (tool) {
            .claude => "claude",
            .codex => "codex",
            .cursor => "cursor",
        };
        var buf: [1024]u8 = undefined;
        const local = std.fmt.bufPrint(&buf, "{s}/.local/bin", .{self.home}) catch return null;
        var buf2: [1024]u8 = undefined;
        const claude_local = std.fmt.bufPrint(&buf2, "{s}/.claude/local", .{self.home}) catch return null;
        const places = [_][]const u8{ local, claude_local, "/opt/homebrew/bin", "/usr/local/bin" };
        for (places) |dir| {
            var pb: [1100]u8 = undefined;
            const path = std.fmt.bufPrint(&pb, "{s}/{s}", .{ dir, command }) catch continue;
            if (std.Io.Dir.cwd().access(self.io, path, .{})) |_| {
                return self.gpa.dupe(u8, dir) catch null;
            } else |_| {}
        }
        return null;
    }

    fn cursorApp(self: *Tools) bool {
        var buf: [1024]u8 = undefined;
        const mine = std.fmt.bufPrint(&buf, "{s}/Applications/Cursor.app", .{self.home}) catch return false;
        for ([_][]const u8{ "/Applications/Cursor.app", mine }) |path| {
            if (std.Io.Dir.cwd().access(self.io, path, .{})) |_| return true else |_| {}
        }
        return false;
    }

    /// Whether the tool's own settings name Publr for every folder.
    fn hasPublr(self: *Tools, tool: Tool) bool {
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const file = switch (tool) {
            .claude => ".claude.json",
            .codex => ".codex/config.toml",
            .cursor => ".cursor/mcp.json",
        };
        const path = std.fs.path.join(a, &.{ self.home, file }) catch return false;
        const text = std.Io.Dir.cwd().readFileAlloc(self.io, path, a, .limited(64 << 20)) catch return false;
        if (tool == .codex) return std.mem.indexOf(u8, text, "[mcp_servers.publr]") != null;
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, text, .{}) catch return false;
        if (parsed != .object) return false;
        const servers = parsed.object.get("mcpServers") orelse return false;
        return servers == .object and servers.object.get("publr") != null;
    }
};

const Job = struct {
    tools: *Tools,
    tool: Tool,
    ok: bool = false,

    fn run(self: *Job) void {
        self.ok = self.setup() catch false;
        native.runOnMain(self, finish);
    }

    /// `publr setup <tool>`, with the tool's folder on the PATH: Desktop started from the
    /// Dock has no shell PATH.
    fn setup(self: *Job) !bool {
        const t = self.tools;
        var arena: std.heap.ArenaAllocator = .init(t.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var env = try t.env.clone(a);
        const dir = t.dirs[@backingInt(self.tool)];
        const path = try std.fmt.allocPrint(a, "{s}{s}{s}/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin", .{
            dir,
            if (dir.len > 0) ":" else "",
            t.home,
        });
        try env.put("PATH", path);
        const result = try std.process.run(a, t.io, .{
            .argv = &.{ t.publr, "setup", @tagName(self.tool) },
            .environ_map = &env,
        });
        if (result.term != .exited or result.term.exited != 0) {
            std.debug.print("desktop: publr setup {t}: {s}{s}\n", .{ self.tool, result.stdout, result.stderr });
            return false;
        }
        return true;
    }

    fn finish(ctx: ?*anyopaque) callconv(.c) void {
        const self: *Job = @ptrCast(@alignCast(ctx));
        const t = self.tools;
        defer t.gpa.destroy(self);
        const i = @backingInt(self.tool);
        t.status[i] = if (!self.ok) .failed else if (self.tool == .cursor) .in_cursor else .found;
        t.check();
        t.changed();
    }
};
