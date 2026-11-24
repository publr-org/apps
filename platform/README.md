# native

Native apps in Zig, with no web view in what the app draws itself. Used by Publr Desktop and
the PublrDesign app. macOS first; Windows and Linux follow the same API.

```
zig build demo        a GPU window and a web window, both with their own bar
zig build test        unit tests
```

Two modules:

- **`native`**: the platform layer. App and menu bar (`init`, `run`, `setMenu`/`onMenu`),
  windows (`Window.create`) whose content is a GPU surface, web views, or a GPU bar above
  web views; every input event as one `Event` union; a display link (`.frame` at the
  display's rate); `runOnMain` from other threads. `titlebar = .custom` gives Figma's
  look: the content runs to the top edge, the traffic lights float over it, and the app
  draws its own bar (`dragWindow` and `titlebarDoubleClick` on a mouse-down there; in a
  page, `data-window-drag`). `gpu` is WebGPU through wgpu-native (`Gpu`, `Surface`), the
  same API a browser has.
- **`ui`**: our own-drawn UI on PublrEngine: boxes, text (Inter, embedded, SIL OFL) and
  Publr icons, drawn the same on every platform. Immediate: each frame the app says what
  is where, `render` draws it, `Blit` puts it on a surface.

macOS is reached through the Objective-C runtime (`src/macos/objc.zig`): no Objective-C,
Swift or C source. wgpu-native is fetched by `build.zig.zon` (pinned release, static
library) into `zig-pkg/`.

Apps add a `.app` bundle with `addAppBundle` from their `build.zig`
(`@import("native").addAppBundle(b, exe, name, id, .{})`, step `app`).
