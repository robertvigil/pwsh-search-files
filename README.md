# Search-Files — PowerShell 7

`Search-Files` — a GUI file finder for the `S:\` share, summoned by a global
hotkey. Hit **Ctrl+Alt+F** and a window pops up with a **Find** box and a results
pane. It searches the folder of the Explorer window you were just looking at —
type a pattern, press Enter, and matching files stream into the pane as they're
found.

It's the GUI sibling of the console tool [`pwsh-find-files`](../pwsh-find-files):
same **full-path** matching (folder names count, not just file names), same
copy-clean output — just in a window instead of the console. A single paste-in
PowerShell 7 script (no install), alongside `pwsh-switch-window` and
`pwsh-launch`.

## The root folder

This is the whole point of the GUI version. On summon it captures the
**frontmost Explorer window** — the one you were on before you pressed the hotkey
— and puts its folder in the **Root** box. So the workflow is:

1. Browse Explorer to the folder you want to search.
2. Press **Ctrl+Alt+F**. The searcher pops up, Root already filled with that folder.
3. Type a pattern in **Find**, press **Enter**. Results appear below.

If you *weren't* on an Explorer window when you hit the hotkey, Root falls back to
`S:\` (or your profile folder if `S:\` isn't mapped). Root is a normal text box —
type or paste any path to search somewhere else.

> How it knows which folder: at the instant you press the hotkey — *before* the
> window shows itself and steals focus — it records the foreground window handle,
> then matches that exact handle against the open Explorer windows (via the
> `Shell.Application` COM object) and reads that one's folder. So with several
> Explorer windows open, it still picks the one you were actually looking at.

## Load it

PowerShell 7 (`pwsh`) only. Copy **`pwsh-search-files.ps1`** in full, then at the
prompt — once per session:

```powershell
Invoke-Expression (Get-Clipboard -Raw)
```

That defines `Search-Files`; then:

```powershell
Search-Files
```

starts the detached background searcher and prints its PID. From then on,
**Ctrl+Alt+F** summons it from anywhere. Or skip the paste-load and launch it
from a Desktop shortcut (see `create-shortcuts.ps1` in the `pwsh-launch` folder).

## Use it

- **Ctrl+Alt+F** — summon (captures the current Explorer folder into Root)
- **Type** a pattern in Find, **Enter** — search Root, newest results first
- **Up / Down** — move through results (Down from Find jumps into the list)
- **Enter / double-click** a result — open the file with its default app
- **Ctrl+C** — copy selected results (or all, if none selected) as `time<tab>path`
- **F5** — re-run the last search
- **Esc** — hide the window (stays loaded; re-summon with the hotkey)

The pattern is auto-wrapped in `*...*`, case-insensitive — `etv` matches any path
containing "etv". Include your own inner `*` for ordered tokens: `etv*xls` matches
"etv" then "xls" later in the path.

## Commands

Type a command in the Find box starting with `!`, then Enter.

| Command | Does |
|---|---|
| `!hotkey [combo]` | Show or change the global hotkey (default `Ctrl+Alt+F`). Modifiers `Ctrl` `Alt` `Shift` `Win`; keys `A–Z` `0–9` `F1–F12` `Space` `Tab` `Escape` `Enter`. Remembered between runs. |
| `!quit` | Stop the background searcher. |
| `!help` | Open these docs in Notepad. |

## Notes

- **Results stream, then sort.** Hits appear in *discovery order* while the walk
  runs (so you see matches without waiting for the end); when it finishes, the
  list re-sorts **newest-first** to match the console tool's final output. The
  status bar shows a running file/match count while searching and the final count
  when done.
- **Never freezes.** The tree walk runs on a background thread (a separate
  PowerShell runspace) and feeds results to the window through a thread-safe
  queue, so typing and scrolling stay responsive even on a slow / VPN-backed
  share. Starting a new search, hiding the window, or `!quit` cancels a walk in
  progress.
- **One instance.** A second searcher can't claim the hotkey — it shows a message
  box and exits. Stop the running one first (`!quit`, or `Stop-Process -Id <pid>`).
- **Session-scoped** unless you use the Desktop shortcut — the background process
  lives until `!quit`, `Stop-Process`, or logoff.

## License

MIT — see [LICENSE](LICENSE). Copyright (c) 2026 Robert Vigil.

---

*Fully vibe-coded with [Claude Code](https://claude.com/claude-code) — design,
implementation, and docs.*
