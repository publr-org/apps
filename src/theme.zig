//! Desktop's colours: Publr's admin palette (`publr/ui/styles/base.css`, near-black and
//! cool greys, no brand colour), so Desktop feels like the CMS it opens. Dark is the same
//! greys turned over, for a Mac set to dark.

const ui = @import("ui");

pub const Theme = struct {
    /// The page, cards, menus and sheets.
    bg: ui.Color,
    /// The sidebar.
    sidebar: ui.Color,
    /// A hovered row or button, an empty picture.
    hover: ui.Color,
    /// The chosen row (the admin's pale blue-grey).
    selected: ui.Color,
    border: ui.Color,
    /// Fields' and secondary buttons' edges.
    input: ui.Color,
    text: ui.Color,
    /// Counts, details, labels.
    text2: ui.Color,
    /// Placeholders, what cannot be chosen.
    text3: ui.Color,
    /// The main button, and the avatar.
    primary: ui.Color,
    on_primary: ui.Color,
    /// Selected text in a field.
    select: ui.Color,
    danger: ui.Color,
    running: ui.Color,
    preview: ui.Color,
    stopped: ui.Color,
    shadow: ui.Color,
    /// The tab bar, the shown tab, a hovered tab.
    bar: ui.Color,
    tab_active: ui.Color,
    tab_hover: ui.Color,
};

fn rgba(rgb: u24, a: f32) ui.Color {
    var c = ui.hex(rgb);
    c.a = a;
    return c;
}

pub const light: Theme = .{
    .bg = ui.hex(0xffffff),
    .sidebar = ui.hex(0xf6f8f9),
    .hover = ui.hex(0xeff0f2),
    .selected = ui.hex(0xe5eef7),
    .border = ui.hex(0xe1e3e5),
    .input = ui.hex(0xd2d4d7),
    .text = ui.hex(0x0e0f12),
    .text2 = ui.hex(0x606369),
    .text3 = ui.hex(0x9a9ca1),
    .primary = ui.hex(0x13161b),
    .on_primary = ui.hex(0xfafafa),
    .select = ui.hex(0xd5e3f2),
    .danger = ui.hex(0xdb2b33),
    .running = ui.hex(0x1c8742),
    .preview = ui.hex(0xe18600),
    .stopped = ui.hex(0xb4b6ba),
    .shadow = rgba(0x0e0f12, 0.12),
    .bar = ui.hex(0xeceef0),
    .tab_active = ui.hex(0xffffff),
    .tab_hover = ui.hex(0xe4e6e9),
};

pub const dark: Theme = .{
    .bg = ui.hex(0x17191d),
    .sidebar = ui.hex(0x1d2024),
    .hover = ui.hex(0x272a30),
    .selected = ui.hex(0x2b323d),
    .border = ui.hex(0x2c2f35),
    .input = ui.hex(0x3a3e45),
    .text = ui.hex(0xf2f3f5),
    .text2 = ui.hex(0x9a9ea6),
    .text3 = ui.hex(0x666a72),
    .primary = ui.hex(0xf2f3f5),
    .on_primary = ui.hex(0x13161b),
    .select = ui.hex(0x34455c),
    .danger = ui.hex(0xf0565c),
    .running = ui.hex(0x3cb36a),
    .preview = ui.hex(0xf0a030),
    .stopped = ui.hex(0x5c6068),
    .shadow = rgba(0x000000, 0.45),
    .bar = ui.hex(0x111316),
    .tab_active = ui.hex(0x17191d),
    .tab_hover = ui.hex(0x191b1f),
};
