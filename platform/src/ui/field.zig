//! A one-line text field: its text, caret and selection, edited by `platform`'s `.text` and
//! `.text_command` events (so input methods, the system's key bindings and the clipboard
//! all work) and drawn with the `ui`. The app owns one per field and says which has focus.

const std = @import("std");
const platform = @import("platform");
const ui = @import("ui.zig");

pub const TextField = struct {
    gpa: std.mem.Allocator,
    text: std.ArrayList(u8) = .empty,
    /// Byte offsets: the caret, and where the selection starts (equal: none).
    caret: usize = 0,
    anchor: usize = 0,
    /// An input method's composition, shown at the caret until it is committed.
    marked: std.ArrayList(u8) = .empty,
    /// How far the text is scrolled left to keep the caret in view, in points.
    offset: f32 = 0,
    max_len: usize = 256,

    pub fn init(gpa: std.mem.Allocator) TextField {
        return .{
            .gpa = gpa,
        };
    }

    pub fn deinit(self: *TextField) void {
        self.text.deinit(self.gpa);
        self.marked.deinit(self.gpa);
    }

    pub fn value(self: *const TextField) []const u8 {
        return self.text.items;
    }

    pub fn set(self: *TextField, s: []const u8) void {
        self.text.clearRetainingCapacity();
        self.text.appendSlice(self.gpa, s[0..@min(s.len, self.max_len)]) catch {};
        self.caret = self.text.items.len;
        self.anchor = self.caret;
        self.offset = 0;
    }

    fn selection(self: *const TextField) struct { usize, usize } {
        return .{ @min(self.caret, self.anchor), @max(self.caret, self.anchor) };
    }

    fn replaceSelection(self: *TextField, s: []const u8) void {
        const from, const to = self.selection();
        const room = self.max_len -| (self.text.items.len - (to - from));
        const add = s[0..@min(s.len, room)];
        self.text.replaceRange(self.gpa, from, to - from, add) catch return;
        self.caret = from + add.len;
        self.anchor = self.caret;
    }

    /// Applies a text event; true when the field changed (redraw).
    pub fn handle(self: *TextField, event: platform.Event) bool {
        switch (event) {
            .text => |t| switch (t.kind) {
                .insert => {
                    self.marked.clearRetainingCapacity();
                    // One line: line breaks from a paste or an input method become spaces.
                    var buf: [256]u8 = undefined;
                    const s = t.text();
                    for (s, 0..) |ch, i| buf[i] = if (ch == '\n' or ch == '\r' or ch == '\t') ' ' else ch;
                    self.replaceSelection(buf[0..s.len]);
                },
                .marked => {
                    self.marked.clearRetainingCapacity();
                    self.marked.appendSlice(self.gpa, t.text()) catch {};
                },
            },
            .text_command => |c| return self.command(c),
            else => return false,
        }
        return true;
    }

    fn command(self: *TextField, c: platform.event.TextCommand) bool {
        const s = self.text.items;
        const from, const to = self.selection();
        switch (c) {
            .delete_backward => if (from != to) self.replaceSelection("") else if (self.caret > 0) {
                self.anchor = prevChar(s, self.caret);
                self.replaceSelection("");
            },
            .delete_forward => if (from != to) self.replaceSelection("") else if (self.caret < s.len) {
                self.anchor = nextChar(s, self.caret);
                self.replaceSelection("");
            },
            .delete_word_backward => {
                if (from == to) self.anchor = prevWord(s, self.caret);
                self.replaceSelection("");
            },
            .delete_to_start => {
                if (from == to) self.anchor = 0;
                self.replaceSelection("");
            },
            .left => self.moveTo(if (from != to) from else prevChar(s, self.caret), false),
            .right => self.moveTo(if (from != to) to else nextChar(s, self.caret), false),
            .word_left => self.moveTo(prevWord(s, self.caret), false),
            .word_right => self.moveTo(nextWord(s, self.caret), false),
            .start => self.moveTo(0, false),
            .end => self.moveTo(s.len, false),
            .select_left => self.moveTo(prevChar(s, self.caret), true),
            .select_right => self.moveTo(nextChar(s, self.caret), true),
            .select_word_left => self.moveTo(prevWord(s, self.caret), true),
            .select_word_right => self.moveTo(nextWord(s, self.caret), true),
            .select_to_start => self.moveTo(0, true),
            .select_to_end => self.moveTo(s.len, true),
            .select_all => {
                self.anchor = 0;
                self.caret = s.len;
            },
            .copy, .cut => {
                if (from == to) return false;
                platform.setClipboardText(s[from..to]);
                if (c == .cut) self.replaceSelection("");
            },
            .paste => {
                const clip = platform.clipboardText(self.gpa) orelse return false;
                defer self.gpa.free(clip);
                for (clip) |*ch| if (ch.* == '\n' or ch.* == '\r' or ch.* == '\t') {
                    ch.* = ' ';
                };
                self.replaceSelection(clip);
            },
            // Enter, Tab and Escape are the form's, not the field's.
            .enter, .tab, .backtab, .escape => return false,
        }
        return true;
    }

    fn moveTo(self: *TextField, at: usize, extend: bool) void {
        self.caret = at;
        if (!extend) self.anchor = at;
    }

    pub const Look = struct {
        text: ui.Color,
        placeholder: ui.Color,
        background: ui.Color,
        border: ui.Color,
        focus: ui.Color,
        selection: ui.Color,
        caret: ui.Color,
        size: f32 = 12,
        radius: f32 = 6,
    };

    /// Draws the field in `r`, with the caret and selection when it has focus; tells the
    /// window where the caret is (for input methods).
    pub fn draw(self: *TextField, u: *ui.Ui, r: ui.Rect, look: Look, focused: bool, placeholder: []const u8, window: ?*platform.Window) !void {
        try u.box(r, .{
            .fill = look.background,
            .border = if (focused) look.focus else look.border,
            .border_width = if (focused) 2 else 1,
            .radius = look.radius,
        });
        const pad: f32 = 10;
        const inner: ui.Rect = .{
            .x = r.x + pad,
            .y = r.y,
            .w = r.w - 2 * pad,
            .h = r.h,
        };
        const style: ui.TextStyle = .{
            .size = look.size,
            .color = look.text,
            .truncate = false,
        };
        // What is shown: the text with any composition at the caret.
        var shown: std.ArrayList(u8) = .empty;
        defer shown.deinit(self.gpa);
        try shown.appendSlice(self.gpa, self.text.items[0..self.caret]);
        try shown.appendSlice(self.gpa, self.marked.items);
        try shown.appendSlice(self.gpa, self.text.items[self.caret..]);

        const caret_x = u.measure(shown.items[0 .. self.caret + self.marked.items.len], style);
        // Keep the caret in view.
        if (caret_x - self.offset > inner.w) self.offset = caret_x - inner.w;
        if (caret_x - self.offset < 0) self.offset = caret_x;

        try u.beginClip(inner);
        const x0 = inner.x - self.offset;
        if (shown.items.len == 0 and placeholder.len > 0) {
            try u.text(.{
                .x = inner.x,
                .y = inner.y,
                .w = inner.w,
                .h = inner.h,
            }, placeholder, .{
                .size = look.size,
                .color = look.placeholder,
            });
        }
        const from, const to = self.selection();
        if (focused and from != to and self.marked.items.len == 0) {
            const a = u.measure(self.text.items[0..from], style);
            const b = u.measure(self.text.items[0..to], style);
            try u.rect(.{
                .x = x0 + a,
                .y = inner.y + (inner.h - look.size * 1.5) / 2,
                .w = b - a,
                .h = look.size * 1.5,
            }, look.selection, 0);
        }
        try u.text(.{
            .x = x0,
            .y = inner.y,
            .w = @max(inner.w, u.measure(shown.items, style) + 4),
            .h = inner.h,
        }, shown.items, style);
        if (self.marked.items.len > 0) {
            // The composition, underlined as the system shows it.
            const a = u.measure(shown.items[0..self.caret], style);
            try u.rect(.{
                .x = x0 + a,
                .y = inner.y + inner.h / 2 + look.size * 0.6,
                .w = caret_x - a,
                .h = 1,
            }, look.text, 0);
        }
        const caret_h = look.size * 1.35;
        const caret_y = inner.y + (inner.h - caret_h) / 2;
        if (focused and (from == to or self.marked.items.len > 0)) try u.rect(.{
            .x = x0 + caret_x,
            .y = caret_y,
            .w = 1,
            .h = caret_h,
        }, look.caret, 0);
        try u.endClip();
        if (focused) if (window) |w| w.setTextCaret(x0 + caret_x, caret_y, caret_h);
    }
};

fn prevChar(s: []const u8, at: usize) usize {
    if (at == 0) return 0;
    var i = at - 1;
    while (i > 0 and s[i] & 0xC0 == 0x80) i -= 1;
    return i;
}

fn nextChar(s: []const u8, at: usize) usize {
    if (at >= s.len) return s.len;
    var i = at + 1;
    while (i < s.len and s[i] & 0xC0 == 0x80) i += 1;
    return i;
}

fn isWord(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch >= 0x80;
}

fn prevWord(s: []const u8, at: usize) usize {
    var i = at;
    while (i > 0 and !isWord(s[i - 1])) i -= 1;
    while (i > 0 and isWord(s[i - 1])) i -= 1;
    return i;
}

fn nextWord(s: []const u8, at: usize) usize {
    var i = at;
    while (i < s.len and !isWord(s[i])) i += 1;
    while (i < s.len and isWord(s[i])) i += 1;
    return i;
}

test "typing, moving and deleting" {
    var f = TextField.init(std.testing.allocator);
    defer f.deinit();
    _ = f.handle(.{ .text = platform.event.Text.of(.insert, "zółć") });
    try std.testing.expectEqualStrings("zółć", f.value());
    _ = f.handle(.{ .text_command = .left });
    _ = f.handle(.{ .text_command = .delete_backward });
    try std.testing.expectEqualStrings("zóć", f.value());
    _ = f.handle(.{ .text_command = .select_all });
    _ = f.handle(.{ .text = platform.event.Text.of(.insert, "new shop") });
    try std.testing.expectEqualStrings("new shop", f.value());
    _ = f.handle(.{ .text_command = .delete_word_backward });
    try std.testing.expectEqualStrings("new ", f.value());
    // A composition shows but is not the value until committed.
    _ = f.handle(.{ .text = platform.event.Text.of(.marked, "´") });
    try std.testing.expectEqualStrings("new ", f.value());
    _ = f.handle(.{ .text = platform.event.Text.of(.insert, "é") });
    try std.testing.expectEqualStrings("new é", f.value());
}
