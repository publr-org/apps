//! What a window tells the app, the same on every platform. Positions are in points from
//! the content's top left; `Window.scale` turns them into device pixels.

pub const Mods = packed struct {
    shift: bool = false,
    control: bool = false,
    option: bool = false,
    command: bool = false,

    /// The platform's shortcut modifier: Command on macOS, Control elsewhere.
    pub fn shortcut(m: Mods) bool {
        return m.command;
    }
};

pub const MouseButton = enum {
    left,
    right,
    middle,
};

pub const Mouse = struct {
    x: f64,
    y: f64,
    button: MouseButton = .left,
    /// 2 on a double click.
    clicks: u32 = 1,
    /// A move with a button held.
    dragging: bool = false,
    mods: Mods = .{},
};

pub const Scroll = struct {
    x: f64,
    y: f64,
    /// Points to move the content by (positive: content moves right / down).
    dx: f64,
    dy: f64,
    /// A trackpad's pixel deltas; false for a wheel's line steps.
    precise: bool,
    /// Momentum after the fingers lifted.
    momentum: bool = false,
    mods: Mods = .{},
};

pub const Magnify = struct {
    x: f64,
    y: f64,
    /// Change in scale: 0.1 is 10% larger.
    amount: f64,
};

pub const KeyCode = enum {
    enter,
    tab,
    space,
    backspace,
    escape,
    delete,
    left,
    right,
    up,
    down,
    home,
    end,
    page_up,
    page_down,
    other,
};

pub const Key = struct {
    code: KeyCode,
    mods: Mods = .{},
    repeat: bool = false,
    /// The characters the key types (UTF-8), for shortcuts. Text entry goes through the
    /// text input events, which handle input methods.
    text_buf: [16]u8 = undefined,
    text_len: u8 = 0,

    pub fn text(k: *const Key) []const u8 {
        return k.text_buf[0..k.text_len];
    }
};

/// Typed text: committed (`insert`), or an input method's composition so far (`marked`,
/// shown underlined in place; empty when it ends).
pub const Text = struct {
    kind: enum {
        insert,
        marked,
    },
    buf: [256]u8 = undefined,
    len: u16 = 0,

    pub fn of(kind: @FieldType(Text, "kind"), s: []const u8) Text {
        var t: Text = .{
            .kind = kind,
        };
        const n = @min(s.len, t.buf.len);
        @memcpy(t.buf[0..n], s[0..n]);
        t.len = @intCast(n);
        return t;
    }

    pub fn text(t: *const Text) []const u8 {
        return t.buf[0..t.len];
    }
};

/// What editing keys mean, as the system's key bindings say (Option-arrow, Command-arrow,
/// Shift for selecting, and the user's own bindings).
pub const TextCommand = enum {
    delete_backward,
    delete_forward,
    delete_word_backward,
    delete_to_start,
    left,
    right,
    word_left,
    word_right,
    start,
    end,
    select_left,
    select_right,
    select_word_left,
    select_word_right,
    select_to_start,
    select_to_end,
    select_all,
    enter,
    tab,
    backtab,
    escape,
    copy,
    cut,
    paste,
};

pub const Resize = struct {
    width: f64,
    height: f64,
    scale: f64,
};

pub const Appearance = enum {
    light,
    dark,
};

pub const Cursor = enum {
    arrow,
    pointer,
    text,
    grab,
    grabbing,
    crosshair,
};

pub const Event = union(enum) {
    /// The display is ready for a frame (its refresh rate).
    frame,
    resize: Resize,
    mouse_down: Mouse,
    mouse_up: Mouse,
    mouse_move: Mouse,
    /// The mouse left the app's view.
    mouse_leave,
    scroll: Scroll,
    magnify: Magnify,
    key_down: Key,
    /// Text typed while `Window.setTextInput(true)`.
    text: Text,
    /// An editing key while `Window.setTextInput(true)`.
    text_command: TextCommand,
    key_up: Key,
    modifiers: Mods,
    focus: bool,
    /// The system switched between light and dark (`platform.appearance()`).
    appearance: Appearance,
    close,
};
