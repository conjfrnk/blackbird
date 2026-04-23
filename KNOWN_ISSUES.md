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

## Color emoji render as monochrome silhouettes

**Symptom:** 🎉 shows as a gray wedge-shape, not the party popper you expected.

**Root cause:** The glyph atlas is a single `r8Unorm` texture rasterized through a DeviceGray CGContext. That pipeline can't carry color — Apple Color Emoji's bitmap data is discarded during rasterization.

**Why it's deferred:** The proper fix is a second `bgra8Unorm` texture alongside the mono atlas, with per-glyph path selection (`CTFontCopyTraits` → `kCTFontTraitColorGlyphs`). That touches `GlyphAtlas.swift`, `CellInstance.swift`, `MetalRenderer.swift`, and `Shaders.metal` — a reasonably-sized refactor with real shader-testing risk. A broken emoji pipeline (double-draws, wrong premultiplication, leaking alpha) is more jarring than the current grayscale fallback, so we take the time to do it right rather than rush it in a polish pass.

**Status:** Tracked in the audit's `glyph-atlas F2` finding. Picking this up is its own dedicated session with visual regression testing.

## xterm `modifyOtherKeys` / Kitty flags 4/16 partial

**Flag 4 (`reportAlternateKeys`)** emits the shifted-form codepoint for ASCII letters — Shift+A produces `ESC[97:0:65;2u` under flags 1+4+8. Flag 4 for symbols with unusual keyboard layouts (German ß on a QWERTZ layout, etc.) requires NSEvent keyboard-layout context not currently plumbed through.

**Flag 16 (`reportAssociatedText`)** emits the produced text as a trailing `;<utf32>` section — differs from the base codepoint under Shift and (eventually) IME composition. Dead-key / multi-scalar IME text is currently limited to the single-scalar fast path.

**xterm `modifyOtherKeys` (CSI > 4 ; N m + CSI 27;mod;cp~)** is not implemented. Requires Rust-side private-mode parser changes in `core/src/lib.rs`, a new `BBTermMode` bit, and a new encoder branch. Scope warranted a dedicated session; the Kitty flags give Claude Code / nvim the modifier-disambiguation they actually need.

## `file://` URLs are intentionally not clickable

The scrollback URL detector matches `http(s)://` and `ftp://` only. `mailto:` is clickable too (detected from bare email-shaped strings and from OSC 8 hyperlinks). `file://` is deliberately excluded — we don't want to give a terminal-pasted string the ability to open a local path just by being clickable.

If you actually want to open a local path, drag the file into the terminal or use `open path/to/file` in the shell.
