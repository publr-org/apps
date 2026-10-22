# Publr Studio

The desktop app for Publr sites (`../.agents/specs/publr-studio.md`). One window, a tab per
open site: the bar and Home are drawn by Studio itself on the GPU (`native`'s `ui`), each
tab is the site's admin, signed in, in the system's web view.

```
zig build run         open Studio
zig build app         zig-out/Publr Studio.app
zig build test        unit tests
```

Keys: Command-T Home, Command-W close the tab, Command-1..9 a tab, Command-R reload,
Command-Shift-B the page in your browser.

For now the sites are `p`'s (`~/publr-sites`): Studio lists them with `p ls` and opens a
tab with the one-use link `p open <name> --print` gives (it starts a stopped server). `p`
is found at `~/.local/bin/p`, or `$STUDIO_P`. The `studio` plugin takes this over.

`SELF_TEST=1` prints the window's number for `screencapture -o -l<number>`. The tabs open
at quit are reopened at the next start (`~/Library/Application Support/Publr Studio`).
