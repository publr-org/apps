//! Settings: a page of Home's, beside its sidebar, set as Home's pages are (the bar with where
//! you are, the page's title, then its sections). Where new sites go (the default folder),
//! the other folders whose sites Desktop and `publr ls` show, the account email new sites
//! get, the AI tools Publr is added to, and, folded under Advanced, the Publr build every project runs instead of its own
//! version (one built from source).
//! The same config the command reads (`publr config`). Layout and hit testing together.

const std = @import("std");
const ui = @import("ui");
const icons = @import("publr_icons");
const Theme = @import("theme.zig").Theme;
const ai_tools = @import("ai_tools.zig");

const header_height: f32 = 48;
const head_height: f32 = 100;
const pad: f32 = 24;
/// The column the sections stand in, at most.
const column_max: f32 = 640;
/// A section's title and the room under it before its first row.
const title_step: f32 = 30;
const section_gap: f32 = 32;
const row_height: f32 = 40;
const hint_height: f32 = 22;
const button_height: f32 = 32;
const button_text: ui.TextStyle = .{
    .size = 13,
    .weight = 500,
};

/// What Terminal's `publr` is.
pub const State = struct {
    /// Where the page starts (under the tab bar) and where its left edge is (the sidebar's
    /// right edge).
    top: f32,
    left: f32,
    width: f32,
    height: f32,
    /// The default folder, as people read it (`~/Publr`).
    folder: []const u8,
    /// The other folders, as people read them.
    folders: []const []const u8,
    /// The build every project runs, as people read it; null when each runs its own version.
    publr: ?[]const u8,
    /// Who every new site gets as its admin, as people read it ("Your Cloud account", an email).
    admin: []const u8,
    /// The language Desktop speaks, and the one new projects start in, as people read them.
    app_language: []const u8,
    project_language: []const u8,
    /// The AI tools, one row each.
    tools: []const ai_tools.Row,
    /// Advanced is unfolded.
    advanced: bool,
    /// Said in place of the buttons' note while something runs ("Choosing a folder…"), or
    /// what went wrong.
    busy: ?[]const u8 = null,
    problem: ?[]const u8 = null,
    hover: Target,
};

pub const Target = union(enum) {
    none,
    change_folder,
    add_folder,
    remove_folder: usize,
    change_admin,
    change_app_language,
    change_project_language,
    connect_tool: ai_tools.Tool,
    advanced,
    choose_publr,
    clear_publr,
};

fn same(a: Target, b: Target) bool {
    return std.meta.eql(a, b);
}

// Layout: one column, each section under the one before.

fn column(s: State) ui.Rect {
    const x = s.left + pad;
    return .{
        .x = x,
        .y = s.top + header_height + head_height,
        .w = @min(column_max, s.width - x - pad),
        .h = 0,
    };
}

fn foldersTitle(s: State) f32 {
    return column(s).y + 8;
}

fn defaultRow(s: State) ui.Rect {
    return row(s, foldersTitle(s) + title_step + 18, 0);
}

/// The other folders' rows start under their own small label.
fn othersLabel(s: State) f32 {
    return defaultRow(s).y + row_height + 16;
}

fn otherRow(s: State, i: usize) ui.Rect {
    return row(s, othersLabel(s) + 18, i);
}

fn addRect(s: State, u: *ui.Ui) ui.Rect {
    const rows: f32 = @floatFromInt(@max(s.folders.len, 1));
    return buttonAt(u, column(s).x, otherRow(s, 0).y + rows * row_height + 8, add_label);
}

fn newSitesTitle(s: State, u: *ui.Ui) f32 {
    const add = addRect(s, u);
    return add.y + add.h + section_gap;
}

fn adminRow(s: State, u: *ui.Ui) ui.Rect {
    return row(s, newSitesTitle(s, u) + title_step, 0);
}

fn adminChangeRect(s: State, u: *ui.Ui) ui.Rect {
    return rowButton(u, adminRow(s, u), change_label);
}

fn languageTitle(s: State, u: *ui.Ui) f32 {
    const admin = adminRow(s, u);
    return admin.y + admin.h + section_gap;
}

fn appLanguageRow(s: State, u: *ui.Ui) ui.Rect {
    return row(s, languageTitle(s, u) + title_step + 18, 0);
}

fn projectLanguageRow(s: State, u: *ui.Ui) ui.Rect {
    const app = appLanguageRow(s, u);
    return row(s, app.y + app.h + 16 + 18, 0);
}

fn toolsTitle(s: State, u: *ui.Ui) f32 {
    const projects = projectLanguageRow(s, u);
    return projects.y + projects.h + section_gap;
}

/// Each tool's row: its name and how it stands, its button at the right end.
const tool_row_height: f32 = 52;

fn toolRow(s: State, u: *ui.Ui, i: usize) ui.Rect {
    const c = column(s);
    return .{
        .x = c.x,
        .y = toolsTitle(s, u) + title_step + hint_height + 6 + @as(f32, @floatFromInt(i)) * tool_row_height,
        .w = c.w,
        .h = tool_row_height,
    };
}

fn toolButton(s: State, u: *ui.Ui, i: usize) ?ui.Rect {
    const label = s.tools[i].button;
    if (label.len == 0) return null;
    return rowButton(u, toolRow(s, u, i), label);
}

fn advancedRect(s: State, u: *ui.Ui) ui.Rect {
    const last = toolRow(s, u, s.tools.len);
    const c = column(s);
    return .{
        .x = c.x - 8,
        .y = last.y + section_gap - 6,
        .w = c.w + 16,
        .h = 32,
    };
}

fn publrLabel(s: State, u: *ui.Ui) f32 {
    return advancedRect(s, u).y + 32 + 14;
}

/// What runs: the default said in a line, or "All projects run this build:".
fn publrLine(s: State, u: *ui.Ui) f32 {
    return publrLabel(s, u) + 24;
}

/// The chosen build's path, under its line.
fn pathBox(s: State, u: *ui.Ui) ui.Rect {
    const c = column(s);
    return .{
        .x = c.x,
        .y = publrLine(s, u) + 26,
        .w = c.w,
        .h = 34,
    };
}

fn hintTop(s: State, u: *ui.Ui) f32 {
    if (s.publr == null) return publrLine(s, u) + 26;
    const b = pathBox(s, u);
    return b.y + b.h + 10;
}

fn chooseRect(s: State, u: *ui.Ui) ui.Rect {
    return buttonAt(u, column(s).x, hintTop(s, u) + hint_height + 8, choose_label);
}

fn clearRect(s: State, u: *ui.Ui) ui.Rect {
    const choose = chooseRect(s, u);
    return buttonAt(u, choose.x + choose.w + 8, choose.y, clear_label);
}

fn row(s: State, top: f32, i: usize) ui.Rect {
    const c = column(s);
    return .{
        .x = c.x,
        .y = top + @as(f32, @floatFromInt(i)) * row_height,
        .w = c.w,
        .h = row_height,
    };
}

/// A small bordered button at the right end of row `r`.
fn rowButton(u: *ui.Ui, r: ui.Rect, label: []const u8) ui.Rect {
    const w = u.measure(label, button_text) + 24;
    return .{
        .x = r.x + r.w - w,
        .y = r.y + (r.h - 30) / 2,
        .w = w,
        .h = 30,
    };
}

fn buttonAt(u: *ui.Ui, x: f32, y: f32, label: []const u8) ui.Rect {
    return .{
        .x = x,
        .y = y,
        .w = u.measure(label, button_text) + 32,
        .h = button_height,
    };
}

const change_label = "Change…";
const remove_label = "Remove";
const add_label = "Add folder…";
const choose_label = "Choose build…";
const clear_label = "Back to default";

fn changeRect(s: State, u: *ui.Ui) ui.Rect {
    return rowButton(u, defaultRow(s), change_label);
}

fn removeRect(s: State, u: *ui.Ui, i: usize) ui.Rect {
    return rowButton(u, otherRow(s, i), remove_label);
}

// Hit testing.

pub fn hit(s: State, u: *ui.Ui, x: f64, y: f64) Target {
    if (s.busy != null) return .none;
    if (changeRect(s, u).contains(x, y)) return .change_folder;
    for (0..s.folders.len) |i| if (removeRect(s, u, i).contains(x, y)) return .{ .remove_folder = i };
    if (addRect(s, u).contains(x, y)) return .add_folder;
    if (adminChangeRect(s, u).contains(x, y)) return .change_admin;
    if (rowButton(u, appLanguageRow(s, u), change_label).contains(x, y)) return .change_app_language;
    if (rowButton(u, projectLanguageRow(s, u), change_label).contains(x, y)) return .change_project_language;
    for (s.tools, 0..) |tool, i| if (toolButton(s, u, i)) |b| if (b.contains(x, y)) return .{ .connect_tool = tool.tool };
    if (advancedRect(s, u).contains(x, y)) return .advanced;
    if (!s.advanced) return .none;
    if (chooseRect(s, u).contains(x, y)) return .choose_publr;
    if (s.publr != null and clearRect(s, u).contains(x, y)) return .clear_publr;
    return .none;
}

// Drawing.

pub fn draw(u: *ui.Ui, s: State, t: *const Theme) !void {
    try drawHeader(u, s, t);
    const c = column(s);
    try u.text(.{
        .x = c.x,
        .y = s.top + header_height + 24,
        .w = c.w,
        .h = 34,
    }, "Settings", .{
        .size = 28,
        .weight = 600,
        .color = t.text,
        .tracking = -0.56,
    });
    try u.text(.{
        .x = c.x,
        .y = s.top + header_height + 60,
        .w = c.w,
        .h = 20,
    }, s.problem orelse s.busy orelse "Where projects live on this Mac, and who new projects belong to.", .{
        .size = 14,
        .color = if (s.problem != null) t.danger else t.text2,
    });

    // Folders.
    try sectionTitle(u, t, c, foldersTitle(s), "Folders");
    try smallLabel(u, t, c, defaultRow(s).y - 18, "Default projects folder");
    try pathRow(u, t, defaultRow(s), s.folder);
    try button(u, t, changeRect(s, u), change_label, same(s.hover, .change_folder), true);
    try smallLabel(u, t, c, othersLabel(s), "Other locations");
    if (s.folders.len == 0) {
        try u.text(otherRow(s, 0), "No other folders.", .{
            .size = 13,
            .color = t.text3,
        });
    }
    for (s.folders, 0..) |f, i| {
        try pathRow(u, t, otherRow(s, i), f);
        try button(u, t, removeRect(s, u, i), remove_label, same(s.hover, .{ .remove_folder = i }), true);
    }
    try button(u, t, addRect(s, u), add_label, same(s.hover, .add_folder), true);

    // New sites.
    try sectionTitle(u, t, c, newSitesTitle(s, u), "Default account email");
    try pathRow(u, t, adminRow(s, u), s.admin);
    try button(u, t, adminChangeRect(s, u), change_label, same(s.hover, .change_admin), true);

    // Language.
    try sectionTitle(u, t, c, languageTitle(s, u), "Language");
    const app_row = appLanguageRow(s, u);
    try smallLabel(u, t, c, app_row.y - 18, "Publr Desktop");
    try pathRow(u, t, app_row, s.app_language);
    try button(u, t, rowButton(u, app_row, change_label), change_label, same(s.hover, .change_app_language), true);
    const projects_row = projectLanguageRow(s, u);
    try smallLabel(u, t, c, projects_row.y - 18, "New projects");
    try pathRow(u, t, projects_row, s.project_language);
    try button(u, t, rowButton(u, projects_row, change_label), change_label, same(s.hover, .change_project_language), true);

    // AI tools.
    try sectionTitle(u, t, c, toolsTitle(s, u), "AI tools");
    try u.text(.{
        .x = c.x,
        .y = toolsTitle(s, u) + title_step - 4,
        .w = c.w,
        .h = 18,
    }, "Connect the AI tool you use once, and it works with every project.", .{
        .size = 13,
        .color = t.text2,
    });
    for (s.tools, 0..) |tool, i| try drawTool(u, s, t, i, tool);

    // Advanced, folded.
    const a = advancedRect(s, u);
    if (same(s.hover, .advanced)) try u.rect(a, t.hover, 8);
    try u.icon(.{
        .x = a.x + 8,
        .y = a.y + (a.h - 16) / 2,
        .w = 16,
        .h = 16,
    }, if (s.advanced) icons.chevron_down else icons.chevron_right, t.text2);
    try u.text(.{
        .x = a.x + 32,
        .y = a.y,
        .w = a.w - 40,
        .h = a.h,
    }, "Advanced", .{
        .size = 15,
        .weight = 600,
        .color = t.text,
    });
    if (!s.advanced) return;

    try smallLabel(u, t, c, publrLabel(s, u), "Publr build");
    const line: ui.Rect = .{
        .x = c.x,
        .y = publrLine(s, u),
        .w = c.w,
        .h = 20,
    };
    if (s.publr) |path| {
        try u.text(line, "All projects run this build:", .{
            .size = 13,
            .color = t.text,
        });
        const b = pathBox(s, u);
        try u.box(b, .{
            .fill = t.hover,
            .radius = 8,
        });
        try u.text(.{
            .x = b.x + 10,
            .y = b.y,
            .w = b.w - 20,
            .h = b.h,
        }, path, .{
            .size = 13,
            .color = t.text,
        });
    } else {
        try u.text(line, "Default: each project runs the Publr version it was made with.", .{
            .size = 13,
            .color = t.text,
        });
    }
    try u.text(.{
        .x = c.x,
        .y = hintTop(s, u),
        .w = c.w,
        .h = 18,
    }, "Projects switch when they next start. A project's own choice comes first.", .{
        .size = 12,
        .color = t.text3,
    });
    try button(u, t, chooseRect(s, u), choose_label, same(s.hover, .choose_publr), true);
    if (s.publr != null) try button(u, t, clearRect(s, u), clear_label, same(s.hover, .clear_publr), true);
}

/// A tool: its name, how it stands, and Connect (or a tick once it is connected).
fn drawTool(u: *ui.Ui, s: State, t: *const Theme, i: usize, tool: ai_tools.Row) !void {
    const r = toolRow(s, u, i);
    if (i > 0) try u.rect(.{
        .x = r.x,
        .y = r.y,
        .w = r.w,
        .h = 1,
    }, t.border, 0);
    try u.text(.{
        .x = r.x,
        .y = r.y + 8,
        .w = r.w - 160,
        .h = 18,
    }, tool.tool.name(), .{
        .size = 14,
        .weight = 500,
        .color = t.text,
    });
    try u.text(.{
        .x = r.x,
        .y = r.y + 27,
        .w = r.w - 160,
        .h = 16,
    }, tool.line, .{
        .size = 12,
        .color = if (tool.connected) t.running else t.text2,
    });
    if (toolButton(s, u, i)) |b| {
        try button(u, t, b, tool.button, same(s.hover, .{ .connect_tool = tool.tool }), true);
    } else if (tool.connected) {
        try u.icon(.{
            .x = r.x + r.w - 18,
            .y = r.y + (r.h - 16) / 2,
            .w = 16,
            .h = 16,
        }, icons.check, t.running);
    }
}

/// The bar over the page: where you are, as Home's says it.
fn drawHeader(u: *ui.Ui, s: State, t: *const Theme) !void {
    try u.rect(.{
        .x = s.left,
        .y = s.top + header_height - 1,
        .w = s.width - s.left,
        .h = 1,
    }, t.border, 0);
    try u.text(.{
        .x = s.left + pad,
        .y = s.top,
        .w = s.width - s.left - 2 * pad,
        .h = header_height,
    }, "Settings", .{
        .size = 13,
        .weight = 500,
        .color = t.text,
    });
}

fn sectionTitle(u: *ui.Ui, t: *const Theme, c: ui.Rect, top: f32, text: []const u8) !void {
    try u.text(.{
        .x = c.x,
        .y = top,
        .w = c.w,
        .h = 20,
    }, text, .{
        .size = 15,
        .weight = 600,
        .color = t.text,
    });
}

fn smallLabel(u: *ui.Ui, t: *const Theme, c: ui.Rect, top: f32, text: []const u8) !void {
    try u.text(.{
        .x = c.x,
        .y = top,
        .w = c.w,
        .h = 16,
    }, text, .{
        .size = 12,
        .weight = 500,
        .color = t.text2,
    });
}

/// A path in a filled box, as a read-only field, leaving room for the row's button.
fn pathRow(u: *ui.Ui, t: *const Theme, r: ui.Rect, path: []const u8) !void {
    try u.box(.{
        .x = r.x,
        .y = r.y + 4,
        .w = r.w - 120,
        .h = r.h - 8,
    }, .{
        .fill = t.hover,
        .radius = 8,
    });
    try u.text(.{
        .x = r.x + 10,
        .y = r.y,
        .w = r.w - 140,
        .h = r.h,
    }, path, .{
        .size = 13,
        .color = t.text,
    });
}

fn button(u: *ui.Ui, t: *const Theme, r: ui.Rect, text: []const u8, hovered: bool, enabled: bool) !void {
    try u.box(r, .{
        .fill = if (hovered and enabled) t.hover else t.bg,
        .border = t.input,
        .radius = 8,
    });
    try u.text(r, text, .{
        .size = button_text.size,
        .weight = button_text.weight,
        .color = if (enabled) t.text else t.text3,
        .@"align" = .center,
    });
}
