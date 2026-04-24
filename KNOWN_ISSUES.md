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

## v0.1.9 hardening-sweep deferrals (2026-04-24)

A multi-agent review + blind-test pass surfaced 67 unique findings. The critical / high-severity items shipped across commits `f18d00e..53c17a7`; the items below are legitimately deferred because they touch public API shape, require architectural changes, or need test-host seams that don't exist yet.

- **Kitty flag 1 for arbitrary modified printables** (F-S3 finding, blind test `test_precedenceTruthTable_ctrlDot` relaxed). Per spec, flag 1 alone should emit `CSI <cp>;<mod>u` for any modified printable (Alt+s, Ctrl+., etc.), not just the C0 colliders + Enter/Esc/Tab/Backspace. Closing the gap needs encoder-shape work plus coordination with the TerminalView fast-path.
- **Kitty flag 4 for non-US keyboard layouts** (F-S3-013 / KNOWN_ISSUES § "Kitty flag 4 / 16"). Still needs Carbon `UCKeyTranslate` + current-layout plumbing.
- **`encodeSpecial` honouring Kitty flags** (F-S3-005). Arrows / F-keys / nav keys emit legacy `CSI 1;M <final>` regardless of flag 1 / 8 / 2. Making them protocol-aware needs the `mode` argument plumbed through `encodeSpecial`.
- **Accessibility role promotion** (F-S5-021). `TerminalView` advertises `.staticText`; a proper `.textArea` with line / char accessors is a dedicated a11y track.
- **Secure-input indicator badge** (SPR-006). Plumbing shipped; the visual indicator was never built.
- **F-S6-001 / F-S6-002 / F-S6-003** window lifecycle fixes (dock zombie on miniaturized auto-close, `closeWindow` ⌘⇧W bypass on single-tab, `newWindow` permanent `.disallowed` tabbingMode). Tests exist but are gated via `XCTSkip` because xctest can't spawn a real `MainWindowController` without destabilising later PTY tests under ASan. Fix requires `MainWindowController.makeForTesting(stubSession:)` seam.
- **`MainThreadWatchdog` modernisation** (F-S6-004). Uses deprecated `Process.launchPath`; swap to `executableURL` + handle macOS 13+ hardened-runtime rules.
- **Sparkle swizzle leak** (F-S7-001). `SparkleAlertOverride.install()` leaks the previous `imp_implementationWithBlock` block on re-call. Track replacement / restorable swizzle.
- **Preferences schema-downgrade guard** (F-S7-003). Migration silently overwrites a higher on-disk schema version with `currentSchemaVersion`, destroying the breadcrumb that a newer release was ever installed.
- **publish-update.sh trust-root hardening** (SEC-003 / F-S8-004). Download the DMG from GitHub Releases, then verify `codesign --strict`, `spctl --assess`, `stapler validate`, and a pinned SHA-256 before feeding to `sign_update`.
- **release.sh `CODESIGN_LOG` swallow + other script discipline** (F-S8-001, F-S8-002, F-S8-005, F-S8-009, F-S8-013, F-S8-025). Three classes of `|| true`-on-git, non-atomic appcast write, and untrapped `mktemp -d` leaks. Tracked in `scripts/tests/` which currently fails 3 of 6 by design as regression guards.
- **Blind test flakiness in cumulative ASan run** (internal). `PTYLifetimeRaceTests` and a few sibling tests pass in isolation but trigger ASan cumulative-allocation aborts when the full suite runs in one xctest process. Gated behind `BB_RUN_FLAKY_PTY_TESTS=1` until we understand whether the cause is our code or the xctest runner's ASan accounting.

Full triage ledger in `docs/superpowers/reviews/v0.1.9-sweep/triage.md` (gitignored, local-only).

