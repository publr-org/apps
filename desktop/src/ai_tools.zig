//! The AI tools on this Mac that Publr works in (Claude Code, Codex, Cursor, VS Code): which
//! are installed, which have Publr added, and adding it (`publr setup <tool>`, off the main
//! thread); and, for any other tool, the settings to paste into it. Asked again when Desktop
//! comes to the front, since a tool is installed, or Cursor's own Install chosen, outside it.
//! A command installed where Desktop does not look (nvm, Volta) is asked of the person's login
//! shell, as Terminal would find it.

const std = @import("std");
const platform = @import("platform");
const i18n = @import("i18n.zig");
const translated = i18n.translated;

pub const Tool = enum {
    claude,
    codex,
    cursor,
    vscode,
    /// Any other tool: its MCP settings, pasted by hand.
    other,

    pub fn name(t: Tool) []const u8 {
        return switch (t) {
            .claude => "Claude Code",
            .codex => "Codex",
            .cursor => "Cursor",
            .vscode => "VS Code",
            .other => translated("Other AI tool"),
        };
    }

    /// The tool's command, looked for on this Mac; empty for one found as an app.
    fn command(t: Tool) []const u8 {
        return switch (t) {
            .claude => "claude",
            .codex => "codex",
            else => "",
        };
    }
};

pub const all = [_]Tool{ .claude, .codex, .cursor, .vscode, .other };

pub const Status = enum {
    missing,
    found,
    connecting,
    /// Cursor asked the person to install Publr in its own window.
    in_cursor,
    connected,
    failed,
    /// The other tool's settings are on the clipboard.
    copied,
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
    /// Where the login shell found each command, when Desktop's own places do not have it.
    shell_dirs: [all.len][]const u8 = @splat(""),
    /// The login shell is being asked.
    asking: bool = false,

    /// Which tools are here and which have Publr, read again; the login shell asked again in
    /// the background.
    pub fn check(self: *Tools) void {
        self.read();
        self.askShell();
    }

    fn read(self: *Tools) void {
        for (all, 0..) |t, i| {
            if (self.status[i] == .connecting) continue;
            if (t == .other) {
                if (self.status[i] != .copied) self.status[i] = .found;
                continue;
            }
            if (self.dirs[i].len > 0) self.gpa.free(self.dirs[i]);
            self.dirs[i] = self.find(t) orelse "";
            const here = self.dirs[i].len > 0 or self.app(t);
            const has = here and self.hasPublr(t);
            self.status[i] = if (has) .connected else if (!here) .missing else switch (self.status[i]) {
                .in_cursor, .failed => self.status[i],
                else => .found,
            };
        }
    }

    pub fn rows(self: *const Tools, out: *[all.len]Row) []const Row {
        for (all, 0..) |t, i| out[i] = .{
            .tool = t,
            .line = if (t == .other) switch (self.status[i]) {
                .copied => translated("Copied. Paste it into the tool\u{2019}s MCP settings."),
                else => translated("Add Publr to its MCP settings by hand."),
            } else switch (self.status[i]) {
                .missing => translated("Not on this Mac"),
                .found => translated("On this Mac, not connected"),
                .connecting => translated("Connecting\u{2026}"),
                .in_cursor => translated("In Cursor, choose Install"),
                .connected => translated("Connected"),
                .failed => translated("Couldn\u{2019}t connect. Try again."),
                .copied => "",
            },
            .button = if (t == .other) translated("Copy settings") else switch (self.status[i]) {
                .found, .failed => translated("Connect"),
                .in_cursor => translated("Open Cursor again"),
                else => "",
            },
            .connected = self.status[i] == .connected,
        };
        return out[0..];
    }

    /// Adds Publr to `tool`; the row says how it went. The other tool's settings go to the
    /// clipboard.
    pub fn connect(self: *Tools, tool: Tool) void {
        const i = @backingInt(tool);
        if (tool == .other) {
            self.copySettings();
            self.status[i] = .copied;
            return;
        }
        if (self.status[i] == .connecting or self.status[i] == .missing) return;
        self.status[i] = .connecting;
        const job = self.gpa.create(Job) catch return;
        job.* = .{
            .tools = self,
            .tool = tool,
        };
        platform.spawn(Job.run, .{job}) catch {
            self.gpa.destroy(job);
            self.status[i] = .failed;
        };
    }

    /// The MCP settings most tools take: Publr's command, run in the project's folder. The
    /// command on the PATH (`~/.local/bin/publr`, which Desktop keeps) when there is one.
    fn copySettings(self: *Tools) void {
        var pb: [1024]u8 = undefined;
        const linked = std.fmt.bufPrint(&pb, "{s}/.local/bin/publr", .{self.home}) catch return;
        const command = if (std.Io.Dir.cwd().access(self.io, linked, .{})) |_| linked else |_| self.publr;
        var buf: [2048]u8 = undefined;
        const text = std.fmt.bufPrint(&buf,
            \\{{
            \\  "mcpServers": {{
            \\    "publr": {{
            \\      "command": "{s}",
            \\      "args": ["mcp"]
            \\    }}
            \\  }}
            \\}}
            \\
        , .{command}) catch return;
        platform.setClipboardText(text);
    }

    /// The folder holding the tool's command, or null when it is not installed.
    fn find(self: *Tools, tool: Tool) ?[]const u8 {
        const command = tool.command();
        if (command.len == 0) return null;
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
        const shell = self.shell_dirs[@backingInt(tool)];
        if (shell.len > 0) return self.gpa.dupe(u8, shell) catch null;
        return null;
    }

    /// Whether the tool is installed as an app, in Applications or the person's own.
    fn app(self: *Tools, tool: Tool) bool {
        const name = switch (tool) {
            .cursor => "Cursor.app",
            .vscode => "Visual Studio Code.app",
            else => return false,
        };
        var buf: [1024]u8 = undefined;
        var buf2: [1024]u8 = undefined;
        const shared = std.fmt.bufPrint(&buf, "/Applications/{s}", .{name}) catch return false;
        const mine = std.fmt.bufPrint(&buf2, "{s}/Applications/{s}", .{ self.home, name }) catch return false;
        for ([_][]const u8{ shared, mine }) |path| {
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
            .vscode => "Library/Application Support/Code/User/mcp.json",
            .other => return false,
        };
        const path = std.fs.path.join(a, &.{ self.home, file }) catch return false;
        const text = std.Io.Dir.cwd().readFileAlloc(self.io, path, a, .limited(64 << 20)) catch return false;
        if (tool == .codex) return std.mem.indexOf(u8, text, "[mcp_servers.publr]") != null;
        const key = if (tool == .vscode) "servers" else "mcpServers";
        // VS Code's file may hold comments, which JSON does not: its name is enough there.
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, text, .{}) catch {
            return tool == .vscode and std.mem.indexOf(u8, text, "\"publr\"") != null;
        };
        if (parsed != .object) return false;
        const servers = parsed.object.get(key) orelse return false;
        return servers == .object and servers.object.get("publr") != null;
    }

    /// The person's login shell asked where each command is, as Terminal finds it.
    fn askShell(self: *Tools) void {
        if (self.asking) return;
        self.asking = true;
        const job = self.gpa.create(ShellJob) catch {
            self.asking = false;
            return;
        };
        job.* = .{
            .tools = self,
        };
        platform.spawn(ShellJob.run, .{job}) catch {
            self.gpa.destroy(job);
            self.asking = false;
        };
    }
};

const ShellJob = struct {
    tools: *Tools,
    found: [all.len][]const u8 = @splat(""),

    fn run(self: *ShellJob) void {
        self.ask() catch |e| std.debug.print("desktop: asking the shell for AI tools: {t}\n", .{e});
        platform.runOnMain(self, finish);
    }

    /// `command -v` for each command in an interactive login shell, which reads the same
    /// files Terminal does; only lines that are a path to that command count.
    fn ask(self: *ShellJob) !void {
        const t = self.tools;
        var arena: std.heap.ArenaAllocator = .init(t.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const shell = t.env.get("SHELL") orelse "/bin/zsh";
        const result = try std.process.run(a, t.io, .{
            .argv = &.{ shell, "-ilc", "command -v claude; command -v codex" },
            .environ_map = t.env,
        });
        var lines = std.mem.tokenizeScalar(u8, result.stdout, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \r\t");
            if (line.len == 0 or line[0] != '/') continue;
            for (all, 0..) |tool, i| {
                const command = tool.command();
                if (command.len == 0) continue;
                const dir = std.fs.path.dirname(line) orelse continue;
                if (!std.mem.eql(u8, std.fs.path.basename(line), command)) continue;
                if (self.found[i].len == 0) self.found[i] = try t.gpa.dupe(u8, dir);
            }
        }
    }

    fn finish(ctx: ?*anyopaque) callconv(.c) void {
        const self: *ShellJob = @ptrCast(@alignCast(ctx));
        const t = self.tools;
        defer t.gpa.destroy(self);
        t.asking = false;
        var changed = false;
        for (self.found, 0..) |dir, i| {
            if (dir.len == 0) continue;
            if (std.mem.eql(u8, t.shell_dirs[i], dir)) {
                t.gpa.free(dir);
                continue;
            }
            if (t.shell_dirs[i].len > 0) t.gpa.free(t.shell_dirs[i]);
            t.shell_dirs[i] = dir;
            changed = true;
        }
        if (changed) {
            t.read();
            t.changed();
        }
    }
};

const Job = struct {
    tools: *Tools,
    tool: Tool,
    ok: bool = false,

    fn run(self: *Job) void {
        self.ok = self.setup() catch false;
        platform.runOnMain(self, finish);
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
        t.read();
        t.changed();
    }
};
