# Publr Desktop

The desktop app for Publr sites (`../.agents/specs/publr-desktop.md`). One window, a tab per
open site: the bar and Home are drawn by Desktop itself on the GPU (`native`'s `ui`), each
tab is the site's admin, signed in, in the system's web view.

```
zig build run         open Desktop
zig build app         zig-out/Publr Desktop.app
zig build app -Doptimize=safe && ditto "zig-out/Publr Desktop.app" "/Applications/Publr Desktop.app"
                      Desktop in Applications, to open like any other app (ReleaseSafe:
                      std.http.Client breaks under ReleaseFast in Zig 0.16)
zig build test        unit tests
```

Keys: Command-T Home, Command-, Settings, Command-W close the tab, Command-1..9 a tab,
Command-R reload, Command-Shift-B the page in your browser.

The sites are the `publr` command's (`../cli`, linked as the `publr_cli` module): every
listed folder's sites (`~/Publr` and whatever `publr config` or Settings add), grouped by
folder on Home. Desktop starts, stops and removes them, makes new ones and signs into their
admins through the same core; the first run takes over `~/publr-sites` as the command does.
It carries the command beside its executable (`Contents/MacOS/publr`, `zig-out/bin/publr`)
and runs it for sync and deploy (`pull`, `push`, `login --sign-on`, `pack`); `$DESKTOP_PUBLR`
or the PATH's `publr` when that is missing. `$PUBLR_CONFIG` points at another config (tests).
`--open <folder>` opens that site's tab (`publr desktop <name>`). Settings: the default folder,
other folders, the default account email and the AI tools (Claude Code, Codex, Cursor) with
Publr added to them by `publr setup <tool>` (`src/ai_tools.zig`), also the welcome's last
step. Each start puts the command it carries on
the PATH, as `cli/install.sh` does (`src/command_line.zig`): `~/.local/bin/publr` a link to it,
that folder added to `~/.zshrc` or `~/.bashrc` once; a `publr` file already there is kept.

Languages: every word a person sees is marked as Publr marks its own (`translated("…")`,
`translated_count`, `translated_in`; `src/i18n.zig`), and each language is a PO file,
`i18n/<code>.po`, read with Publr's catalogue. `zig run ../publr/scripts/i18n.zig -- src`
writes the template for translators. Settings › Language: Desktop's own (the Mac's by
default) and the one new projects start in (`publr config language`).

`SELF_TEST=1` prints the window's number for `screencapture -o -l<number>`. The tabs open
at quit are reopened at the next start (`~/Library/Application Support/Publr Desktop`).
