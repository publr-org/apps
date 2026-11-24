# Publr apps

Publr's apps for the computer, in Zig, for macOS, Windows and Linux.

```
desktop/     Publr Desktop: your Publr sites in one window, a tab each
design/      PublrDesign's app: designs drawn by PublrEngine on the GPU, no web view
platform/    what both run on: windows, menus, input, web views and the GPU, one backend
             per operating system
```

Each folder builds on its own (`zig build` inside it) and has its own README. They build
beside Publr's other repositories, as the workspace lays them out: `../icons`, `../cli`,
`../publr`, `../lib` and `../publr-design` (publr-org/design, for PublrEngine).

Each app has its own version and releases: Publr Desktop's are tagged `desktop-v<version>`
(Actions › Desktop release).

Licensed under the Apache License 2.0 (`LICENSE`).
