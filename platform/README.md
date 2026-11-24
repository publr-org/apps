# platform

The layer between Publr's apps and the operating system, in Zig: windows, menus, input,
web views and the GPU behind one API, with a backend per platform. Used by Publr Desktop
(`../desktop`) and the PublrDesign app (`../design`).

```
src/platform.zig, event.zig, gpu.zig    the API every app calls, the same everywhere
src/macos/                              AppKit and WebKit through the Objective-C runtime
src/windows/                            Win32 and WebView2 (to come)
src/linux/                              GTK and WebKitGTK (to come)
src/web/                                a browser page (Desktop's `zig build web`)
src/ui/                                 the drawing the apps share
```

```
zig build demo        a GPU window and a web window, both with their own bar
zig build test        unit tests
```

Two modules:

- **`platform`**: app and menu bar (`init`, `run`, `setMenu`/`onMenu`), windows
  (`Window.create`) whose content is a GPU surface, web views, or a GPU bar above web
  views; every input event as one `Event` union; a display link (`.frame` at the display's
  rate); `runOnMain` from other threads. `titlebar = .custom` runs the content to the top
  edge with the window's buttons floating over it, and the app draws its own bar
  (`dragWindow` and `titlebarDoubleClick` on a mouse-down there; in a page,
  `data-window-drag`). `gpu` is WebGPU through wgpu-native (`Gpu`, `Surface`), the same API
  a browser has.
- **`ui`**: our own-drawn UI on PublrEngine: boxes, text (Inter, embedded, SIL OFL) and
  Publr icons, drawn the same on every platform. Immediate: each frame the app says what
  is where, `render` draws it, `Blit` puts it on a surface.

macOS is reached through the Objective-C runtime (`src/macos/objc.zig`): no Objective-C,
Swift or C source. wgpu-native is fetched by `build.zig.zon` (pinned release, static
library) into `zig-pkg/`. Pages in a web view message the app with
`webkit.messageHandlers.native.postMessage(text)`.

Apps add a `.app` bundle with `addAppBundle` from their `build.zig`
(`@import("platform").addAppBundle(b, exe, name, id, .{})`, step `app`).
