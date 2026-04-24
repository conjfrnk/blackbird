# Known issues

Small list of deliberately-deferred polish items. If you hit one of these, it's documented, not forgotten.

## Tab-merge titlebar flash on ⌘T

**Symptom:** Pressing ⌘T on a single-tab window briefly shows macOS's native `NSTabBar` before Blackbird's pill strip replaces it. The titlebar permanently grows from 32pt to 68pt for the lifetime of the multi-tab window group.

**Root cause:** The 36pt extension is enforced by `NSWindowTabGroup` inside AppKit. Every approach that collapses the band (removing the tab-bar view, `toggleTabBar`, styleMask twiddling) either no-ops or detaches the window from its group and destroys the titlebar accessory.

**Why it's deferred:** Two fixes exist, neither small:

1. **Ghost-tab trick** — open a hidden `alphaValue = 0` window at app launch and merge it so the first real window starts already-multi-tab. Trade-off: every single-tab window now shows the 36pt band even when the user has only one tab. Also needs careful filtering of the ghost from `tabGroup.windows` in the pill strip.
2. **Custom tabs (no `NSWindowTabGroup`)** — re-implement tabs as child views of one window. Roughly a day of rewrite: new-tab creation, IME first-responder coupling, ⌘` cycling, drag-to-separate, cross-Space behavior. WezTerm takes this route.

Two previous attempts to suppress the AppKit animation (`43f5356`, `dd4bd96`) were reverted (`1c9a68f`, `3e58665`) after causing regressions — one beach-balled ⌘T.

**Status: won't-fix (2026-04-24).** Two careful attempts — `43f5356` (CATransaction + `NSAnimationContext` suppression) and `dd4bd96` (three-layer suppression + `toggleTabBar` inside the merge transaction) — triggered a beachball hang on ⌘T and were reverted. Neither Option 1 (ghost tab) nor Option 2 (custom tabs without `NSWindowTabGroup`) is worth the trade:

- Ghost-tab forces every single-tab window to show the 36pt band permanently, trading a one-frame flash for a full-session visual regression.
- Custom tabs is a full-day refactor with real IME / responder-chain coupling risk; a broken IME is a worse regression than the flash.
- No new macOS 14–15 API exposes a way to collapse the 36pt reservation or suppress the merge animation.

The flash is documented rather than fixed. If Apple ships a suppression API in a future macOS, revisit.

## Color emoji — shipped 2026-04-24

Glyphs from fonts that report `CTFontSymbolicTraits.colorGlyphs` (Apple Color Emoji, Noto Color Emoji, any third-party COLRv1 / sbix / CBDT font) now rasterize into a dedicated `bgra8Unorm` atlas alongside the mono coverage atlas. The fragment shader branches on `BB_ATTR_IS_COLOR_GLYPH` (bit 7 of `CellInstance.attrs.x`) to sample the correct texture.

Not supported: ZWJ sequences like 👨‍👩‍👧 (family) still render as the base 👨 scalar because atlas keys are single `UnicodeScalar`. Proper grapheme-cluster keying is future work — a rare enough case that it stayed out of v1.

## Kitty flag 4 / 16 — US-layout only

**Flag 4 (`reportAlternateKeys`)** emits `base:0:shifted` for every ASCII letter and for the 21 US-layout shifted symbols (`!`→`1`, `@`→`2`, …, `|`→`\`). Non-US layouts (German QWERTZ, Dvorak, BÉPO, …) still see only the shifted char with no alt-layout slot — the reverse lookup would need Carbon's `UCKeyTranslate` + current-layout plumbing, deferred to a dedicated session.

**Flag 16 (`reportAssociatedText`)** emits the produced text as a trailing `;<utf32>` section for the single-key press case, elided when the text equals the base codepoint (saves bytes; spec says parsers treat "absent" as "text=base"). IME-committed multi-scalar text (e.g. Chinese pinyin commits, ZWJ emoji composed via input methods) goes through `insertText` directly and doesn't synthesize a flag-16-style key event — Kitty's spec doesn't define IME commit as a keystroke, so no reasonable TUI expects it.

**xterm `modifyOtherKeys` — shipped 2026-04-24.** `CSI > 4 ; N m` toggles the mode (level 1 or 2 both light the bit); `CSI 27 ; <mod> ; <cp> ~` emission kicks in for modified printables when no Kitty flag is active. Precedence: Kitty > modifyOtherKeys > legacy. Emacs, tmux `extended-keys on`, neovim auto-request all covered.

## `file://` URLs are intentionally not clickable

The scrollback URL detector matches `http(s)://` and `ftp://` only. `mailto:` is clickable too (detected from bare email-shaped strings and from OSC 8 hyperlinks). `file://` is deliberately excluded — we don't want to give a terminal-pasted string the ability to open a local path just by being clickable.

If you actually want to open a local path, drag the file into the terminal or use `open path/to/file` in the shell.
