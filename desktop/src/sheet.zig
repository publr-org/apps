//! A sheet: the modal panel over Home that asks for something (New site, Deploy to Cloud).
//! A title and a line saying what happens (a link under it, for more), fields with a note
//! under each, and Cancel
//! with the main button. Layout and hit testing together.

const std = @import("std");
const native = @import("native");
const ui = @import("ui");
const Theme = @import("theme.zig").Theme;
const i18n = @import("i18n.zig");
const translated = i18n.translated;

const width: f32 = 440;
const pad: f32 = 24;
const field_height: f32 = 36;
const button_height: f32 = 36;
/// The title alone, for a sheet with no line under it.
const head_bare: f32 = 20 + 16;
/// The link's line under the description.
const link_step: f32 = 24;

/// The title (20), the description under it, its link, and the room around them.
fn headHeight(s: State) f32 {
    if (s.description.len == 0) return head_bare;
    const link: f32 = if (s.link.len > 0) link_step else 0;
    return 20 + 8 + s.description_height + link + 12;
}

fn linkRect(s: State, u: *ui.Ui) ui.Rect {
    const p = panel(s);
    return .{
        .x = p.x + pad,
        .y = p.y + pad + 28 + s.description_height + 4,
        .w = u.measure(s.link, link_text),
        .h = 18,
    };
}

const link_text: ui.TextStyle = .{
    .size = 13,
    .weight = 500,
};
/// A field's label (22), the field and its note (26).
const field_step: f32 = 22 + field_height + 26;
/// A choice's label (22), its buttons and the room under them.
const choice_step: f32 = 22 + field_height + 16;
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

/// One of a few options, side by side as one bordered control ("On this Mac", "On Cloud").
pub const Choice = struct {
    label: []const u8,
    options: []const []const u8,
    selected: usize,
};

pub const State = struct {
    title: []const u8,
    description: []const u8,
    /// Room for the description: two lines unless it says more.
    description_height: f32 = 40,
    /// A link under the description ("How accounts work"); empty for none.
    link: []const u8 = "",
    /// Above the fields.
    choice: ?Choice = null,
    fields: []const Field,
    primary: []const u8,
    primary_enabled: bool,
    /// Empty for Cancel, in the language spoken now (`secondaryLabel`).
    secondary: []const u8 = "",
    /// Shown instead of the buttons while the work runs ("Making the site…").
    busy: ?[]const u8 = null,
    hover: Target,
    /// Filled in here: which fields' notes take two lines.
    long_notes: [2]bool = @splat(false),
    window_width: f32,
    window_height: f32,
};

pub const Target = union(enum) {
    none,
    primary,
    cancel,
    link,
    field: usize,
    option: usize,
};

/// The second button's words: its own, or Cancel.
fn secondaryLabel(s: State) []const u8 {
    return if (s.secondary.len > 0) s.secondary else translated("Cancel");
}

fn choiceHeight(s: State) f32 {
    return if (s.choice != null) choice_step else 0;
}

/// A field's room: one more line when its note takes two (`State.long_notes`).
fn fieldStep(s: State, i: usize) f32 {
    const long = i < s.long_notes.len and s.long_notes[i];
    return field_step + if (long) note_line else 0;
}

const note_line: f32 = 16;
const note_style: ui.TextStyle = .{
    .size = 12,
};

/// `s` with each note's lines measured, as layout and drawing need them.
fn measured(s: State, u: *ui.Ui) State {
    var out = s;
    const room = width - 2 * pad;
    for (s.fields, 0..) |f, i| {
        if (i >= out.long_notes.len) break;
        const note = f.note orelse continue;
        out.long_notes[i] = u.measure(note.text, note_style) > room;
    }
    return out;
}

fn panel(s: State) ui.Rect {
    var h: f32 = pad + headHeight(s) + choiceHeight(s);
    for (0..s.fields.len) |i| h += fieldStep(s, i);
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
    var above: f32 = 0;
    for (0..i) |j| above += fieldStep(s, j);
    return .{
        .x = p.x + pad,
        .y = p.y + pad + headHeight(s) + choiceHeight(s) + above + 22,
        .w = p.w - 2 * pad,
        .h = field_height,
    };
}

fn optionRect(s: State, i: usize) ui.Rect {
    const p = panel(s);
    const n: f32 = @floatFromInt(s.choice.?.options.len);
    const w = (p.w - 2 * pad) / n;
    return .{
        .x = p.x + pad + w * @as(f32, @floatFromInt(i)),
        .y = p.y + pad + headHeight(s) + 22,
        .w = w,
        .h = field_height,
    };
}

fn buttonRect(s: State, u: *ui.Ui, which: Target) ui.Rect {
    const p = panel(s);
    const pw = u.measure(s.primary, button_text) + 32;
    const cw = u.measure(secondaryLabel(s), button_text) + 32;
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

pub fn hit(given: State, u: *ui.Ui, x: f64, y: f64) Target {
    const s = measured(given, u);
    if (s.busy == null) {
        if (buttonRect(s, u, .primary).contains(x, y)) return .primary;
        if (buttonRect(s, u, .cancel).contains(x, y)) return .cancel;
        if (s.link.len > 0 and linkRect(s, u).contains(x, y)) return .link;
        if (s.choice) |c| for (0..c.options.len) |i| {
            if (optionRect(s, i).contains(x, y)) return .{ .option = i };
        };
    }
    for (0..s.fields.len) |i| if (fieldRect(s, i).contains(x, y)) return .{ .field = i };
    return .none;
}

pub fn draw(u: *ui.Ui, given: State, t: *const Theme, focus: ?usize, window: *native.Window) !void {
    const s = measured(given, u);
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
        .h = s.description_height,
    }, s.description, .{
        .size = 13,
        .color = t.text2,
        .truncate = false,
    });
    if (s.link.len > 0) {
        const l = linkRect(s, u);
        const over = std.meta.eql(s.hover, Target.link);
        try u.text(l, s.link, .{
            .size = link_text.size,
            .weight = link_text.weight,
            .color = t.text,
        });
        try u.rect(.{
            .x = l.x,
            .y = l.y + l.h - 1,
            .w = l.w,
            .h = 1,
        }, if (over) t.text else t.text3, 0);
    }
    if (s.choice) |c| try drawChoice(u, s, t, c);
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
            .h = if (i < s.long_notes.len and s.long_notes[i]) 2 * note_line else note_line,
        }, n.text, .{
            .size = note_style.size,
            .truncate = false,
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
    try u.text(c, secondaryLabel(s), .{
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

/// The choice as the admin's segmented control: one bordered box, the chosen part filled.
fn drawChoice(u: *ui.Ui, s: State, t: *const Theme, c: Choice) !void {
    const first = optionRect(s, 0);
    try u.text(.{
        .x = first.x,
        .y = first.y - 22,
        .w = first.w * @as(f32, @floatFromInt(c.options.len)),
        .h = 16,
    }, c.label, .{
        .size = 13,
        .weight = 500,
        .color = t.text,
    });
    try u.box(.{
        .x = first.x,
        .y = first.y,
        .w = first.w * @as(f32, @floatFromInt(c.options.len)),
        .h = first.h,
    }, .{
        .fill = t.bg,
        .border = t.input,
        .radius = 8,
    });
    for (c.options, 0..) |option, i| {
        const r = optionRect(s, i);
        const inner: ui.Rect = .{
            .x = r.x + 3,
            .y = r.y + 3,
            .w = r.w - 6,
            .h = r.h - 6,
        };
        const over = std.meta.eql(s.hover, Target{ .option = i });
        if (i == c.selected) try u.rect(inner, t.selected, 6) else if (over) try u.rect(inner, t.hover, 6);
        try u.text(r, option, .{
            .size = 13,
            .weight = if (i == c.selected) 500 else 400,
            .color = if (i == c.selected) t.text else t.text2,
            .@"align" = .center,
        });
    }
}
