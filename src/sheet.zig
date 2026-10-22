//! A sheet: the modal panel over Home that asks for something (New site, Deploy to Cloud).
//! A title and a line saying what happens, fields with a note under each, and Cancel
//! with the main button. Layout and hit testing together.

const std = @import("std");
const native = @import("native");
const ui = @import("ui");
const Theme = @import("theme.zig").Theme;

const width: f32 = 440;
const pad: f32 = 24;
const field_height: f32 = 36;
const button_height: f32 = 36;
/// The title (20), the line under it (40) and the room around them.
const head: f32 = 20 + 8 + 40 + 12;
/// A field's label (22), the field and its note (26).
const field_step: f32 = 22 + field_height + 26;
const button_text: ui.TextStyle = .{
    .size = 13,
    .weight = 500,
};

pub const Note = struct {
    text: []const u8,
    kind: enum {
        hint,
        good,
        bad,
    } = .hint,
};

pub const Field = struct {
    label: []const u8,
    field: *ui.TextField,
    placeholder: []const u8 = "",
    /// Text right after the field inside its box (".publr.app").
    suffix: []const u8 = "",
    note: ?Note = null,
};

pub const State = struct {
    title: []const u8,
    description: []const u8,
    fields: []const Field,
    primary: []const u8,
    primary_enabled: bool,
    secondary: []const u8 = "Cancel",
    /// Shown instead of the buttons while the work runs ("Making the site…").
    busy: ?[]const u8 = null,
    hover: Target,
    window_width: f32,
    window_height: f32,
};

pub const Target = union(enum) {
    none,
    primary,
    cancel,
    field: usize,
};

fn panel(s: State) ui.Rect {
    var h: f32 = pad + head;
    h += @as(f32, @floatFromInt(s.fields.len)) * field_step;
    h += 12 + button_height + pad;
    return .{
        .x = (s.window_width - width) / 2,
        .y = @max(60, (s.window_height - h) / 2.4),
        .w = width,
        .h = h,
    };
}

fn fieldRect(s: State, i: usize) ui.Rect {
    const p = panel(s);
    return .{
        .x = p.x + pad,
        .y = p.y + pad + head + @as(f32, @floatFromInt(i)) * field_step + 22,
        .w = p.w - 2 * pad,
        .h = field_height,
    };
}

fn buttonRect(s: State, u: *ui.Ui, which: Target) ui.Rect {
    const p = panel(s);
    const pw = u.measure(s.primary, button_text) + 32;
    const cw = u.measure(s.secondary, button_text) + 32;
    const y = p.y + p.h - pad - button_height;
    const px = p.x + p.w - pad - pw;
    return switch (which) {
        .primary => .{
            .x = px,
            .y = y,
            .w = pw,
            .h = button_height,
        },
        else => .{
            .x = px - 8 - cw,
            .y = y,
            .w = cw,
            .h = button_height,
        },
    };
}

pub fn hit(s: State, u: *ui.Ui, x: f64, y: f64) Target {
    if (s.busy == null) {
        if (buttonRect(s, u, .primary).contains(x, y)) return .primary;
        if (buttonRect(s, u, .cancel).contains(x, y)) return .cancel;
    }
    for (0..s.fields.len) |i| if (fieldRect(s, i).contains(x, y)) return .{ .field = i };
    return .none;
}

pub fn draw(u: *ui.Ui, s: State, t: *const Theme, focus: ?usize, window: *native.Window) !void {
    // The window dimmed behind it.
    try u.rect(.{
        .x = 0,
        .y = 0,
        .w = s.window_width,
        .h = s.window_height,
    }, .{
        .a = 0.28,
    }, 0);
    const p = panel(s);
    try u.box(p, .{
        .fill = t.bg,
        .border = t.border,
        .radius = 12,
        .shadow = .{
            .color = t.shadow,
            .y = 16,
            .blur = 48,
        },
    });
    try u.text(.{
        .x = p.x + pad,
        .y = p.y + pad,
        .w = p.w - 2 * pad,
        .h = 20,
    }, s.title, .{
        .size = 15,
        .weight = 600,
        .color = t.text,
    });
    try u.text(.{
        .x = p.x + pad,
        .y = p.y + pad + 28,
        .w = p.w - 2 * pad,
        .h = 40,
    }, s.description, .{
        .size = 13,
        .color = t.text2,
        .truncate = false,
    });
    for (s.fields, 0..) |f, i| {
        const r = fieldRect(s, i);
        try u.text(.{
            .x = r.x,
            .y = r.y - 22,
            .w = r.w,
            .h = 16,
        }, f.label, .{
            .size = 13,
            .weight = 500,
            .color = t.text,
        });
        var fr = r;
        if (f.suffix.len > 0) {
            const sw = u.measure(f.suffix, .{
                .size = 13,
            });
            fr.w -= sw + 6;
            try u.text(.{
                .x = r.x + r.w - sw,
                .y = r.y,
                .w = sw,
                .h = r.h,
            }, f.suffix, .{
                .size = 13,
                .color = t.text2,
            });
        }
        try f.field.draw(u, fr, .{
            .text = t.text,
            .placeholder = t.text3,
            .background = t.bg,
            .border = t.input,
            .focus = t.primary,
            .selection = t.select,
            .caret = t.text,
            .size = 13,
            .radius = 8,
        }, focus == i, f.placeholder, window);
        if (f.note) |n| try u.text(.{
            .x = r.x,
            .y = r.y + r.h + 5,
            .w = r.w,
            .h = 16,
        }, n.text, .{
            .size = 12,
            .color = switch (n.kind) {
                .hint => t.text2,
                .good => t.running,
                .bad => t.danger,
            },
        });
    }

    if (s.busy) |b| {
        const y = p.y + p.h - pad - button_height;
        try u.text(.{
            .x = p.x + pad,
            .y = y,
            .w = p.w - 2 * pad,
            .h = button_height,
        }, b, .{
            .size = 13,
            .color = t.text2,
            .@"align" = .right,
        });
        return;
    }
    const c = buttonRect(s, u, .cancel);
    try u.box(c, .{
        .fill = if (std.meta.eql(s.hover, Target.cancel)) t.hover else t.bg,
        .border = t.input,
        .radius = 8,
    });
    try u.text(c, s.secondary, .{
        .size = button_text.size,
        .weight = button_text.weight,
        .color = t.text,
        .@"align" = .center,
    });
    const pr = buttonRect(s, u, .primary);
    var fill = t.primary;
    if (!s.primary_enabled) fill.a = 0.35 else if (std.meta.eql(s.hover, Target.primary)) fill.a = 0.86;
    try u.rect(pr, fill, 8);
    try u.text(pr, s.primary, .{
        .size = button_text.size,
        .weight = button_text.weight,
        .color = t.on_primary,
        .@"align" = .center,
    });
}
