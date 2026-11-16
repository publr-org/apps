//! The welcome: the whole window, the first time Desktop opens on a Mac with nothing set. What
//! Publr is in a line, then Publr Cloud, recommended: what it gives, that it is free, and the
//! way in; under it, using Publr without Cloud, and where accounts are explained. Layout and
//! hit testing together.

const std = @import("std");
const ui = @import("ui");
const icons = @import("publr_icons");
const Theme = @import("theme.zig").Theme;
const mark = @import("mark.zig");

pub const State = struct {
    window_width: f32,
    window_height: f32,
    hover: Target,
};

pub const Target = enum {
    none,
    cloud,
    local,
    link,
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

const width: f32 = 560;
const panel_pad: f32 = 28;
const button_height: f32 = 44;
const benefit_step: f32 = 56;
const link_label = "How accounts work";
/// Publr's mark, and the room under it.
const mark_size: f32 = 40;
const mark_step: f32 = mark_size + 20;

const title_text: ui.TextStyle = .{
    .size = 30,
    .weight = 600,
};
const button_text: ui.TextStyle = .{
    .size = 14,
    .weight = 500,
};

fn panelHeight() f32 {
    const rows: f32 = @floatFromInt(benefits.len);
    return panel_pad + 20 + 10 + 40 + 20 + rows * benefit_step + 8 + button_height + panel_pad;
}

/// Title, lead, the Cloud panel, the button under it and the link.
fn totalHeight() f32 {
    return mark_step + 38 + 10 + 22 + 32 + panelHeight() + 12 + button_height + 18 + 18;
}

fn top(s: State) f32 {
    return @max(56, (s.window_height - totalHeight()) / 2);
}

fn left(s: State) f32 {
    return (s.window_width - width) / 2;
}

fn panelRect(s: State) ui.Rect {
    return .{
        .x = left(s),
        .y = top(s) + mark_step + 38 + 10 + 22 + 32,
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

fn linkRect(s: State, u: *ui.Ui) ui.Rect {
    const local = localRect(s);
    const w = u.measure(link_label, button_text);
    return .{
        .x = left(s) + (width - w) / 2,
        .y = local.y + local.h + 18,
        .w = w,
        .h = 18,
    };
}

pub fn hit(s: State, u: *ui.Ui, x: f64, y: f64) Target {
    if (cloudRect(s).contains(x, y)) return .cloud;
    if (localRect(s).contains(x, y)) return .local;
    if (linkRect(s, u).contains(x, y)) return .link;
    return .none;
}

pub fn draw(u: *ui.Ui, s: State, t: *const Theme) !void {
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

    const y = top(s) + mark_step;
    try u.text(.{
        .x = x,
        .y = y,
        .w = width,
        .h = 38,
    }, "Welcome to Publr Desktop", .{
        .size = title_text.size,
        .weight = title_text.weight,
        .color = t.text,
        .tracking = -0.6,
        .@"align" = .center,
    });
    try u.text(.{
        .x = x,
        .y = y + 48,
        .w = width,
        .h = 22,
    }, "Make websites and apps on your Mac, with the AI tool you already use.", .{
        .size = 15,
        .color = t.text2,
        .@"align" = .center,
    });

    try drawPanel(u, s, t);

    const local = localRect(s);
    try u.box(local, .{
        .fill = if (s.hover == .local) t.hover else t.bg,
        .border = t.input,
        .radius = 10,
    });
    try u.text(local, "Use without Cloud", .{
        .size = button_text.size,
        .weight = button_text.weight,
        .color = t.text,
        .@"align" = .center,
    });

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

    const cloud = cloudRect(s);
    var fill = t.primary;
    if (s.hover == .cloud) fill.a = 0.86;
    try u.rect(cloud, fill, 10);
    try u.text(cloud, "Continue with Publr Cloud", .{
        .size = button_text.size,
        .weight = button_text.weight,
        .color = t.on_primary,
        .@"align" = .center,
    });
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
