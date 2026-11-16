//! The welcome: the whole window, the first time Desktop opens on a Mac with nothing set.
//! First, Publr Cloud, recommended: what it gives, that it is free, and the way in, with using
//! Publr without Cloud under it. Without Cloud, two ways side by side: each project's admin
//! account made by hand, or one account for all projects; that one asks for its email on a
//! step of its own. Layout and hit testing together.

const std = @import("std");
const native = @import("native");
const ui = @import("ui");
const icons = @import("publr_icons");
const Theme = @import("theme.zig").Theme;
const mark = @import("mark.zig");

pub const Step = enum {
    start,
    without_cloud,
    email,
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
};

const Benefit = struct {
    icon: []const u8,
    title: []const u8,
    line: []const u8,
};

const benefits = [_]Benefit{
    .{
        .icon = icons.user,
        .title = "One account everywhere",
        .line = "Every project, on this Mac and online, opens with you signed in.",
    },
    .{
        .icon = icons.rocket,
        .title = "Online in one click",
        .line = "Put a project online and get its address in seconds.",
    },
    .{
        .icon = icons.sync,
        .title = "Your projects on any Mac",
        .line = "Bring a Cloud project down to this Mac and work on it here.",
    },
};

const Way = struct {
    choice: Choice,
    icon: []const u8,
    title: []const u8,
    line: []const u8,
};

const ways = [_]Way{
    .{
        .choice = .by_hand,
        .icon = icons.users,
        .title = "Set up an account for every project",
        .line = "Each project asks you to make its admin account the first time you open it.",
    },
    .{
        .choice = .one_account,
        .icon = icons.user,
        .title = "One account for all projects",
        .line = "Choose one email. Every project you make gets an account with it and opens with you signed in.",
    },
};

const width: f32 = 560;
const panel_pad: f32 = 28;
const button_height: f32 = 44;
const benefit_step: f32 = 56;
const tile_height: f32 = 196;
const tile_gap: f32 = 12;
const field_height: f32 = 40;
const link_label = "How accounts work";
/// Publr's mark, and the room under it.
const mark_size: f32 = 40;
const mark_step: f32 = mark_size + 20;
/// The mark, the title, the lead and the room under them.
const head: f32 = mark_step + 38 + 10 + 22 + 32;

const button_text: ui.TextStyle = .{
    .size = 14,
    .weight = 500,
};

fn panelHeight() f32 {
    const rows: f32 = @floatFromInt(benefits.len);
    return panel_pad + 20 + 10 + 40 + 20 + rows * benefit_step + 8 + button_height + panel_pad;
}

/// What the step shows under its head, down to its buttons.
fn bodyHeight(s: State) f32 {
    return switch (s.step) {
        .start => panelHeight() + 12 + button_height,
        .without_cloud => tile_height + 24 + button_height,
        .email => 22 + field_height + 32 + button_height,
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
        .h = panelHeight(),
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

fn linkRect(s: State, u: *ui.Ui) ui.Rect {
    const above = if (s.step == .start) localRect(s) else backRect(s);
    const w = u.measure(link_label, button_text);
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
    };
}

pub fn hit(s: State, u: *ui.Ui, x: f64, y: f64) Target {
    if (linkRect(s, u).contains(x, y)) return .link;
    switch (s.step) {
        .start => {
            if (cloudRect(s).contains(x, y)) return .cloud;
            if (localRect(s).contains(x, y)) return .local;
            return .none;
        },
        .without_cloud => {
            if (tileRect(s, .by_hand).contains(x, y)) return .by_hand;
            if (tileRect(s, .one_account).contains(x, y)) return .one_account;
        },
        .email => if (fieldRect(s).contains(x, y)) return .field,
    }
    if (backRect(s).contains(x, y)) return .back;
    if (confirmRect(s).contains(x, y)) return .confirm;
    return .none;
}

pub fn draw(u: *ui.Ui, s: State, t: *const Theme, window: *native.Window) !void {
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
        .start => .{ "Welcome to Publr Desktop", "Make websites and apps on your Mac, with the AI tool you already use." },
        .without_cloud => .{ "Without Publr Cloud", "How should your projects' admin accounts be made?" },
        .email => .{ "One account for all projects", "Every project you make gets an account with this email and opens with you signed in." },
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
            try secondary(u, t, localRect(s), "Use without Cloud", s.hover == .local);
        },
        .without_cloud => {
            for (ways) |way| try drawTile(u, s, t, way);
            try secondary(u, t, backRect(s), "Back", s.hover == .back);
            try primary(u, t, confirmRect(s), "Next", s.hover == .confirm, ready(s));
        },
        .email => {
            try drawEmail(u, s, t, window);
            try secondary(u, t, backRect(s), "Back", s.hover == .back);
            try primary(u, t, confirmRect(s), "Continue", s.hover == .confirm, ready(s));
        },
    }

    const link = linkRect(s, u);
    try u.text(link, link_label, .{
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

fn drawEmail(u: *ui.Ui, s: State, t: *const Theme, window: *native.Window) !void {
    const f = fieldRect(s);
    try u.text(.{
        .x = f.x,
        .y = f.y - 22,
        .w = f.w,
        .h = 16,
    }, if (s.problem) |p| p else "Email", .{
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
    const pill = "Recommended";
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
    }, "For the best experience, we recommend Publr Cloud. It's free forever, and no credit card is needed.", .{
        .size = 14,
        .color = t.text2,
        .truncate = false,
    });

    y += 40 + 20;
    for (benefits) |b| {
        try drawBenefit(u, t, b, x, y, inner);
        y += benefit_step;
    }

    try primary(u, t, cloudRect(s), "Continue with Publr Cloud", s.hover == .cloud, true);
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
