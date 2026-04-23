# Known issues

Small list of deliberately-deferred polish items. If you hit one of these, it's documented, not forgotten.

## Tab-merge titlebar flash on ⌘T

**Symptom:** Pressing ⌘T on a single-tab window briefly shows macOS's native `NSTabBar` before Blackbird's pill strip replaces it. The titlebar permanently grows from 32pt to 68pt for the lifetime of the multi-tab window group.

**Root cause:** The 36pt extension is enforced by `NSWindowTabGroup` inside AppKit. Every approach that collapses the band (removing the tab-bar view, `toggleTabBar`, styleMask twiddling) either no-ops or detaches the window from its group and destroys the titlebar accessory.

**Why it's deferred:** Two fixes exist, neither small:

1. **Ghost-tab trick** — open a hidden `alphaValue = 0` window at app launch and merge it so the first real window starts already-multi-tab. Trade-off: every single-tab window now shows the 36pt band even when the user has only one tab. Also needs careful filtering of the ghost from `tabGroup.windows` in the pill strip.
2. **Custom tabs (no `NSWindowTabGroup`)** — re-implement tabs as child views of one window. Roughly a day of rewrite: new-tab creation, IME first-responder coupling, ⌘` cycling, drag-to-separate, cross-Space behavior. WezTerm takes this route.

Two previous attempts to suppress the AppKit animation (`43f5356`, `dd4bd96`) were reverted (`1c9a68f`, `3e58665`) after causing regressions — one beach-balled ⌘T.

**Status:** Lives in [`.claude/memory/project_tab_bar_flash.md`](../.claude) as a decision record. Re-opening this should be a dedicated PR, not incremental polish.

## `file://` URLs are intentionally not clickable

The scrollback URL detector matches `http(s)://` and `ftp://` only. `mailto:` is clickable too (detected from bare email-shaped strings and from OSC 8 hyperlinks). `file://` is deliberately excluded — we don't want to give a terminal-pasted string the ability to open a local path just by being clickable.

If you actually want to open a local path, drag the file into the terminal or use `open path/to/file` in the shell.
