# Publr Studio

The desktop app for Publr sites (`../.agents/specs/publr-studio.md`). One window, a tab per
open site: the bar and Home are drawn by Studio itself on the GPU (`native`'s `ui`), each
tab is the site's admin, signed in, in the system's web view.

```
zig build run         open Studio
zig build app         zig-out/Publr Studio.app
zig build app -Doptimize=safe && ditto "zig-out/Publr Studio.app" "/Applications/Publr Studio.app"
                      Studio in Applications, to open like any other app (ReleaseSafe:
                      std.http.Client breaks under ReleaseFast in Zig 0.16)
zig build test        unit tests
```

Keys: Command-T Home, Command-, Settings, Command-W close the tab, Command-1..9 a tab,
Command-R reload, Command-Shift-B the page in your browser.

The sites are the `publr` command's (`../cli`, linked as the `publr_cli` module): every
listed folder's sites (`~/Publr` and whatever `publr config` or Settings add), grouped by
folder on Home. Studio starts, stops and removes them, makes new ones and signs into their
admins through the same core; the first run takes over `~/publr-sites` as the command does.
It carries the command beside its executable (`Contents/MacOS/publr`, `zig-out/bin/publr`)
and runs it for sync and deploy (`pull`, `push`, `login --sign-on`, `pack`); `$STUDIO_PUBLR`
or the PATH's `publr` when that is missing. `$PUBLR_CONFIG` points at another config (tests).
`--open <folder>` opens that site's tab (`publr studio <name>`). Settings: the default folder,
other folders, and Install `publr` in PATH (`/usr/local/bin/publr`; `STUDIO_NO_INSTALL=1`
only prints what it would link).

`SELF_TEST=1` prints the window's number for `screencapture -o -l<number>`. The tabs open
at quit are reopened at the next start (`~/Library/Application Support/Publr Studio`).
