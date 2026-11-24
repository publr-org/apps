//! The welcome: the whole window, the first time Desktop opens on a Mac with nothing set.
//! First, Publr Cloud, recommended: what it gives, that it is free, and the way in, with using
//! Publr without Cloud under it. Without Cloud, two ways side by side: each project's admin
//! account made by hand, or one account for all projects; that one asks for its email on a
//! step of its own. Last, the AI tools on this Mac, each connected with one click. Layout and
//! hit testing together.

const std = @import("std");
const platform = @import("platform");
const ui = @import("ui");
const icons = @import("publr_icons");
const Theme = @import("theme.zig").Theme;
const mark = @import("mark.zig");
const ai_tools = @import("ai_tools.zig");
const i18n = @import("i18n.zig");
const translated = i18n.translated;

pub const Step = enum {
    start,
    without_cloud,
    email,
    tools,
};

pub const Choice = enum {
    by_hand,
    one_account,
};

pub const State = struct {
    window_width: f32,
    window_height: f32,
    step: Step,
    choice: ?Choice,
    /// The one account's email, asked on its own step.
    email: *ui.TextField,
    /// What is wrong with the email, or null.
    problem: ?[]const u8,
    /// The browser is asking the person to allow Desktop on Publr Cloud.
    signing_in: bool,
    /// Why the last sign-in did not work ("denied"), or null.
    cloud_problem: ?[]const u8,
    /// The AI tools, one row each.
    tools: []const ai_tools.Row = &.{},
    hover: Target,
};

pub const Target = enum {
    none,
    cloud,
    local,
    link,
    by_hand,
    one_account,
    field,
    back,
    confirm,
    tool_claude,
    tool_codex,
    tool_cursor,
    tool_vscode,
    tool_other,
};

fn toolTarget(tool: ai_tools.Tool) Target {
    return switch (tool) {
        .claude => .tool_claude,
        .codex => .tool_codex,
        .cursor => .tool_cursor,
        .vscode => .tool_vscode,
        .other => .tool_other,
    };
}

/// The tool a target connects, or null.
pub fn toolOf(target: Target) ?ai_tools.Tool {
    return switch (target) {
        .tool_claude => .claude,
        .tool_codex => .codex,
        .tool_cursor => .cursor,
        .tool_vscode => .vscode,
        .tool_other => .other,
        else => null,
    };
}

const Benefit = struct {
    icon: []const u8,
    title: []const u8,
    line: []const u8,
};

const benefit_count = 3;

/// In the language spoken now, which can change while Desktop runs.
fn benefits() [benefit_count]Benefit {
    return .{
        .{
            .icon = icons.user,
            .title = translated("One account everywhere"),
            .line = translated("Every project, on this Mac and online, opens with you signed in."),
        },
        .{
            .icon = icons.rocket,
            .title = translated("Online in one click"),
            .line = translated("Put a project online and get its address in seconds."),
        },
        .{
            .icon = icons.sync,
            .title = translated("Your projects on any Mac"),
            .line = translated("Bring a Cloud project down to this Mac and work on it here."),
        },
    };
}

const Way = struct {
    choice: Choice,
    icon: []const u8,
    title: []const u8,
    line: []const u8,
};

/// In the language spoken now, which can change while Desktop runs.
fn ways() [2]Way {
    return .{
        .{
            .choice = .by_hand,
            .icon = icons.users,
            .title = translated("Set up an account for every project"),
            .line = translated("Each project asks you to make its admin account the first time you open it."),
        },
        .{
            .choice = .one_account,
            .icon = icons.user,
            .title = translated("One account for all projects"),
            .line = translated("Choose one email. Every project you make gets an account with it and opens with you signed in."),
        },
    };
}

const width: f32 = 560;
const panel_pad: f32 = 28;
const button_height: f32 = 44;
const benefit_step: f32 = 56;
/// A sign-in that did not work, said above the Cloud button.
const problem_step: f32 = 30;
const tile_height: f32 = 196;
const tile_gap: f32 = 12;
const field_height: f32 = 40;
const tool_row_height: f32 = 68;
/// Publr's mark, and the room under it.
const mark_size: f32 = 40;
const mark_step: f32 = mark_size + 20;
/// The mark, the title, the lead and the room under them.
const head: f32 = mark_step + 38 + 10 + 22 + 32;

const button_text: ui.TextStyle = .{
    .size = 14,
    .weight = 500,
};

fn panelHeight(s: State) f32 {
    const rows: f32 = @floatFromInt(benefit_count);
    const problem: f32 = if (s.cloud_problem != null) problem_step else 0;
    return panel_pad + 20 + 10 + 40 + 20 + rows * benefit_step + problem + 8 + button_height + panel_pad;
}

/// What the step shows under its head, down to its buttons.
fn bodyHeight(s: State) f32 {
    return switch (s.step) {
        .start => panelHeight(s) + 12 + button_height,
        .without_cloud => tile_height + 24 + button_height,
        .email => 22 + field_height + 32 + button_height,
        .tools => toolsHeight(s) + 24 + button_height,
    };
}

fn toolsHeight(s: State) f32 {
    return @as(f32, @floatFromInt(s.tools.len)) * tool_row_height;
}

fn toolRow(s: State, i: usize) ui.Rect {
    return .{
        .x = left(s),
        .y = bodyTop(s) + @as(f32, @floatFromInt(i)) * tool_row_height,
        .w = width,
        .h = tool_row_height,
    };
}

fn toolButton(s: State, u: *ui.Ui, i: usize) ?ui.Rect {
    const label = s.tools[i].button;
    if (label.len == 0) return null;
    const r = toolRow(s, i);
    const w = u.measure(label, button_text) + 32;
    return .{
        .x = r.x + r.w - 20 - w,
        .y = r.y + (r.h - 36) / 2,
        .w = w,
        .h = 36,
    };
}

/// Continue, the whole width, under the tools.
fn continueRect(s: State) ui.Rect {
    return .{
        .x = left(s),
        .y = bodyTop(s) + bodyHeight(s) - button_height,
        .w = width,
        .h = button_height,
    };
}

fn top(s: State) f32 {
    return @max(56, (s.window_height - head - bodyHeight(s) - 36) / 2);
}

fn left(s: State) f32 {
    return (s.window_width - width) / 2;
}

fn bodyTop(s: State) f32 {
    return top(s) + head;
}

fn panelRect(s: State) ui.Rect {
    return .{
        .x = left(s),
        .y = bodyTop(s),
        .w = width,
        .h = panelHeight(s),
    };
}

fn cloudRect(s: State) ui.Rect {
    const p = panelRect(s);
    return .{
        .x = p.x + panel_pad,
        .y = p.y + p.h - panel_pad - button_height,
        .w = p.w - 2 * panel_pad,
        .h = button_height,
    };
}

fn localRect(s: State) ui.Rect {
    const p = panelRect(s);
    return .{
        .x = p.x,
        .y = p.y + p.h + 12,
        .w = p.w,
        .h = button_height,
    };
}

fn tileRect(s: State, which: Choice) ui.Rect {
    const w = (width - tile_gap) / 2;
    return .{
        .x = if (which == .by_hand) left(s) else left(s) + w + tile_gap,
        .y = bodyTop(s),
        .w = w,
        .h = tile_height,
    };
}

fn fieldRect(s: State) ui.Rect {
    return .{
        .x = left(s),
        .y = bodyTop(s) + 22,
        .w = width,
        .h = field_height,
    };
}

/// Back and Next (or Continue) under the step.
fn backRect(s: State) ui.Rect {
    return .{
        .x = left(s),
        .y = bodyTop(s) + bodyHeight(s) - button_height,
        .w = (width - 12) / 2,
        .h = button_height,
    };
}

fn confirmRect(s: State) ui.Rect {
    const b = backRect(s);
    return .{
        .x = b.x + b.w + 12,
        .y = b.y,
        .w = b.w,
        .h = button_height,
    };
}

fn linkLabel(s: State) []const u8 {
    return if (s.step == .tools) translated("How building with AI works") else translated("How accounts work");
}

fn linkRect(s: State, u: *ui.Ui) ui.Rect {
    const above = switch (s.step) {
        .start => localRect(s),
        .tools => continueRect(s),
        else => backRect(s),
    };
    const w = u.measure(linkLabel(s), button_text);
    return .{
        .x = left(s) + (width - w) / 2,
        .y = above.y + above.h + 18,
        .w = w,
        .h = 18,
    };
}

/// The step's main button can be pressed: a way chosen; an email that is one.
pub fn ready(s: State) bool {
    return switch (s.step) {
        .start => true,
        .without_cloud => s.choice != null,
        .email => s.email.value().len > 0 and s.problem == null,
        .tools => true,
    };
}

pub fn hit(s: State, u: *ui.Ui, x: f64, y: f64) Target {
    if (linkRect(s, u).contains(x, y)) return .link;
    switch (s.step) {
        .start => {
            if (!s.signing_in and cloudRect(s).contains(x, y)) return .cloud;
            if (localRect(s).contains(x, y)) return .local;
            return .none;
        },
        .without_cloud => {
            if (tileRect(s, .by_hand).contains(x, y)) return .by_hand;
            if (tileRect(s, .one_account).contains(x, y)) return .one_account;
        },
        .email => if (fieldRect(s).contains(x, y)) return .field,
        .tools => {
            for (s.tools, 0..) |tool, i| if (toolButton(s, u, i)) |b| if (b.contains(x, y)) return toolTarget(tool.tool);
            return if (continueRect(s).contains(x, y)) .confirm else .none;
        },
    }
    if (backRect(s).contains(x, y)) return .back;
    if (confirmRect(s).contains(x, y)) return .confirm;
    return .none;
}

pub fn draw(u: *ui.Ui, s: State, t: *const Theme, window: *platform.Window) !void {
    try u.rect(.{
        .x = 0,
        .y = 0,
        .w = s.window_width,
        .h = s.window_height,
    }, t.bg, 0);

    const x = left(s);
    const art = mark_size * 24 / mark.units;
    try u.icon(.{
        .x = x + (width - mark_size) / 2,
        .y = top(s),
        .w = art,
        .h = art,
    }, mark.markup, t.text);

    const words: [2][]const u8 = switch (s.step) {
        .start => .{ translated("Welcome to Publr Desktop"), translated("Make websites and apps on your Mac, with the AI tool you already use.") },
        .without_cloud => .{ translated("Without Publr Cloud"), translated("How should your projects' admin accounts be made?") },
        .email => .{ translated("One account for all projects"), translated("Every project you make gets an account with this email and opens with you signed in.") },
        .tools => .{ translated("Connect your AI tool"), translated("Publr works inside the AI tool you use. Connect it once, for every project.") },
    };
    const y = top(s) + mark_step;
    try u.text(.{
        .x = x,
        .y = y,
        .w = width,
        .h = 38,
    }, words[0], .{
        .size = 30,
        .weight = 600,
        .color = t.text,
        .tracking = -0.6,
        .@"align" = .center,
    });
    try u.text(.{
        .x = x - 40,
        .y = y + 48,
        .w = width + 80,
        .h = 22,
    }, words[1], .{
        .size = 15,
        .color = t.text2,
        .@"align" = .center,
    });

    switch (s.step) {
        .start => {
            try drawPanel(u, s, t);
            try secondary(u, t, localRect(s), translated("Use without Cloud"), s.hover == .local);
        },
        .without_cloud => {
            for (ways()) |way| try drawTile(u, s, t, way);
            try secondary(u, t, backRect(s), translated("Back"), s.hover == .back);
            try primary(u, t, confirmRect(s), translated("Next"), s.hover == .confirm, ready(s));
        },
        .email => {
            try drawEmail(u, s, t, window);
            try secondary(u, t, backRect(s), translated("Back"), s.hover == .back);
            try primary(u, t, confirmRect(s), translated("Continue"), s.hover == .confirm, ready(s));
        },
        .tools => {
            try drawTools(u, s, t);
            try primary(u, t, continueRect(s), translated("Continue"), s.hover == .confirm, true);
        },
    }

    const link = linkRect(s, u);
    try u.text(link, linkLabel(s), .{
        .size = button_text.size,
        .weight = button_text.weight,
        .color = t.text2,
    });
    try u.rect(.{
        .x = link.x,
        .y = link.y + link.h,
        .w = link.w,
        .h = 1,
    }, if (s.hover == .link) t.text else t.text3, 0);
}

fn primary(u: *ui.Ui, t: *const Theme, r: ui.Rect, label: []const u8, over: bool, enabled: bool) !void {
    var fill = t.primary;
    if (!enabled) fill.a = 0.35 else if (over) fill.a = 0.86;
    try u.rect(r, fill, 10);
    try u.text(r, label, .{
        .size = button_text.size,
        .weight = button_text.weight,
        .color = t.on_primary,
        .@"align" = .center,
    });
}

fn secondary(u: *ui.Ui, t: *const Theme, r: ui.Rect, label: []const u8, over: bool) !void {
    try u.box(r, .{
        .fill = if (over) t.hover else t.bg,
        .border = t.input,
        .radius = 10,
    });
    try u.text(r, label, .{
        .size = button_text.size,
        .weight = button_text.weight,
        .color = t.text,
        .@"align" = .center,
    });
}

/// One way without Cloud, as a card to choose: its circle filled when chosen.
fn drawTile(u: *ui.Ui, s: State, t: *const Theme, way: Way) !void {
    const r = tileRect(s, way.choice);
    const chosen = s.choice == way.choice;
    const over = s.hover == @as(Target, if (way.choice == .by_hand) .by_hand else .one_account);
    try u.box(r, .{
        .fill = if (chosen) t.sidebar else if (over) t.hover else t.bg,
        .border = if (chosen) t.text2 else t.border,
        .radius = 14,
    });
    const square: ui.Rect = .{
        .x = r.x + 20,
        .y = r.y + 20,
        .w = 36,
        .h = 36,
    };
    try u.box(square, .{
        .fill = t.bg,
        .border = t.border,
        .radius = 9,
    });
    try u.icon(.{
        .x = square.x + 10,
        .y = square.y + 10,
        .w = 16,
        .h = 16,
    }, way.icon, t.text);
    const circle: ui.Rect = .{
        .x = r.x + r.w - 20 - 18,
        .y = r.y + 20,
        .w = 18,
        .h = 18,
    };
    try u.box(circle, .{
        .fill = t.bg,
        .border = if (chosen) t.text else t.input,
        .radius = 9,
    });
    if (chosen) try u.rect(.{
        .x = circle.x + 5,
        .y = circle.y + 5,
        .w = 8,
        .h = 8,
    }, t.text, 4);
    // The title on one line, or two when it is longer; the words follow it.
    const title_style: ui.TextStyle = .{
        .size = 15,
        .weight = 600,
        .color = t.text,
        .truncate = false,
    };
    const title_height: f32 = if (u.measure(way.title, title_style) > r.w - 40) 42 else 20;
    try u.text(.{
        .x = r.x + 20,
        .y = r.y + 72,
        .w = r.w - 40,
        .h = title_height,
    }, way.title, title_style);
    try u.text(.{
        .x = r.x + 20,
        .y = r.y + 72 + title_height + 6,
        .w = r.w - 40,
        .h = 58,
    }, way.line, .{
        .size = 13,
        .color = t.text2,
        .truncate = false,
    });
}

/// The tools in one bordered list: each its name, how it stands, and Connect or a tick.
fn drawTools(u: *ui.Ui, s: State, t: *const Theme) !void {
    try u.box(.{
        .x = left(s),
        .y = bodyTop(s),
        .w = width,
        .h = toolsHeight(s),
    }, .{
        .fill = t.bg,
        .border = t.border,
        .radius = 14,
    });
    for (s.tools, 0..) |tool, i| {
        const r = toolRow(s, i);
        if (i > 0) try u.rect(.{
            .x = r.x + 1,
            .y = r.y,
            .w = r.w - 2,
            .h = 1,
        }, t.border, 0);
        // The words stop short of the button, however long it says.
        const room: f32 = if (toolButton(s, u, i)) |b| r.x + r.w - b.x + 32 else 80;
        try u.text(.{
            .x = r.x + 20,
            .y = r.y + 15,
            .w = r.w - room,
            .h = 20,
        }, tool.tool.name(), .{
            .size = 15,
            .weight = 600,
            .color = t.text,
        });
        try u.text(.{
            .x = r.x + 20,
            .y = r.y + 37,
            .w = r.w - room,
            .h = 18,
        }, tool.line, .{
            .size = 13,
            .color = if (tool.connected) t.running else t.text2,
        });
        if (toolButton(s, u, i)) |b| {
            try secondary(u, t, b, tool.button, s.hover == toolTarget(tool.tool));
        } else if (tool.connected) {
            try u.icon(.{
                .x = r.x + r.w - 20 - 18,
                .y = r.y + (r.h - 18) / 2,
                .w = 18,
                .h = 18,
            }, icons.check, t.running);
        }
    }
}

fn drawEmail(u: *ui.Ui, s: State, t: *const Theme, window: *platform.Window) !void {
    const f = fieldRect(s);
    try u.text(.{
        .x = f.x,
        .y = f.y - 22,
        .w = f.w,
        .h = 16,
    }, if (s.problem) |p| p else translated("Email"), .{
        .size = 13,
        .weight = 500,
        .color = if (s.problem != null) t.danger else t.text,
    });
    try s.email.draw(u, f, .{
        .text = t.text,
        .placeholder = t.text3,
        .background = t.bg,
        .border = t.input,
        .focus = t.primary,
        .selection = t.select,
        .caret = t.text,
        .size = 14,
        .radius = 8,
    }, true, "you@example.com", window);
}

/// Publr Cloud: its name, recommended; that it is free; what it gives; the way in.
fn drawPanel(u: *ui.Ui, s: State, t: *const Theme) !void {
    const p = panelRect(s);
    try u.box(p, .{
        .fill = t.sidebar,
        .border = t.border,
        .radius = 16,
    });

    const x = p.x + panel_pad;
    const inner = p.w - 2 * panel_pad;
    var y = p.y + panel_pad;
    const name = "Publr Cloud";
    const name_width = u.measure(name, .{
        .size = 16,
        .weight = 600,
    });
    try u.text(.{
        .x = x,
        .y = y,
        .w = name_width,
        .h = 20,
    }, name, .{
        .size = 16,
        .weight = 600,
        .color = t.text,
    });
    const pill = translated("Recommended");
    const pill_width = u.measure(pill, .{
        .size = 11,
        .weight = 500,
    }) + 16;
    const pill_rect: ui.Rect = .{
        .x = x + name_width + 10,
        .y = y,
        .w = pill_width,
        .h = 20,
    };
    try u.rect(pill_rect, t.selected, 10);
    try u.text(pill_rect, pill, .{
        .size = 11,
        .weight = 500,
        .color = t.text,
        .@"align" = .center,
    });

    y += 20 + 10;
    try u.text(.{
        .x = x,
        .y = y,
        .w = inner,
        .h = 40,
    }, translated("For the best experience, we recommend Publr Cloud. It's free forever, and no credit card is needed."), .{
        .size = 14,
        .color = t.text2,
        .truncate = false,
    });

    y += 40 + 20;
    for (benefits()) |b| {
        try drawBenefit(u, t, b, x, y, inner);
        y += benefit_step;
    }
    if (s.cloud_problem) |problem| try u.text(.{
        .x = x,
        .y = y,
        .w = inner,
        .h = 18,
    }, problem, .{
        .size = 13,
        .weight = 500,
        .color = t.danger,
    });

    const label = if (s.signing_in) translated("Waiting for your browser…") else translated("Continue with Publr Cloud");
    try primary(u, t, cloudRect(s), label, s.hover == .cloud, !s.signing_in);
}

fn drawBenefit(u: *ui.Ui, t: *const Theme, b: Benefit, x: f32, y: f32, w: f32) !void {
    const square: ui.Rect = .{
        .x = x,
        .y = y,
        .w = 36,
        .h = 36,
    };
    try u.box(square, .{
        .fill = t.bg,
        .border = t.border,
        .radius = 9,
    });
    try u.icon(.{
        .x = x + 10,
        .y = y + 10,
        .w = 16,
        .h = 16,
    }, b.icon, t.text);
    try u.text(.{
        .x = x + 50,
        .y = y,
        .w = w - 50,
        .h = 18,
    }, b.title, .{
        .size = 14,
        .weight = 600,
        .color = t.text,
    });
    try u.text(.{
        .x = x + 50,
        .y = y + 20,
        .w = w - 50,
        .h = 18,
    }, b.line, .{
        .size = 13,
        .color = t.text2,
    });
}
