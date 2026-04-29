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

## OSC 7 trust over SSH — shipped 2026-04-28

The Swift-side process-tree gate landed. `PTY.classifyForegroundNamespace()` does a BFS from `tcgetpgrp(masterFD)` via `proc_listpids(PROC_PPID_ONLY)`, checking each pid's `proc_pidpath` basename against `{ssh, slogin, mosh-client, telnet, docker, podman, nerdctl, kubectl, lima}`. The gate returns one of three states — `.local`, `.remote(basename, pid)`, or `.unknown(reason)` — and `TerminalSession` trusts the OSC 7 payload **only when the result is `.local`**. Both `.remote` and `.unknown` (PTY closed, syscall failure, BFS cap hit) drop the update and leave `lastKnownCwd` at its previous trusted value.

Fail-closed posture is deliberate: a `Bool` return would have collapsed "definitely local" with "couldn't tell" and silently let attacker-controlled OSC 7 through on syscall failure. That's the opposite of the security stance the gate is meant to take, even though the sibling helpers `hasForegroundChild()` / `foregroundWorkingDirectory()` are advisory and fail-open.

Defense-in-depth complement to the input validation already in `handle_osc7` (audit synthesis #13: `..` segments, non-absolute paths, NUL bytes, non-UTF-8 — all dropped silently in core). Tests in `Tests/BlackbirdTests/CwdTests.swift`: gate fires on `.remote`, gate fires on `.unknown`, gate clears resumes updates, headless session defaults to `.unknown`, BFS-on-self returns `.local`, and a positive-control test that spawns a fake binary named `ssh` and asserts the BFS finds it.

Limitation kept: a remote shell running inside a multiplexer (tmux/screen) on the local host evades the gate, because the multiplexer's server detaches from the original PTY and `proc_listpids` from the terminal can't see across the boundary. Multiplexers also don't generally proxy OSC 7 across, so the practical exposure is low.

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
- **publish-update.sh trust-root hardening — shipped 2026-04-28** (SEC-003 / F-S8-004). The script now runs `codesign --verify --strict`, `spctl --assess --type install`, parses `origin=` for a pinned Team ID (`F2B95Q4CT8`), and `xcrun stapler validate` before signing the DMG into the appcast. Pinned-SHA was dropped from the original deferred description because in a single-developer flow there's no out-of-band trust root for the SHA itself; the codesign+spctl+stapler chain plus Team ID parsed from spctl's origin line is the meaningful trust root. Three new test cases in `scripts/tests/publish_update_test.sh` (spctl reject, wrong-Team-ID origin, stapler reject) regression-guard the verify gate. Drive-by fix bundled in: F-S8-003 version-arg validation (semver regex).
- **publish-update.sh atomic appcast write — shipped 2026-04-29** (F-S8-025 / audit L-13). The previous `bash make-appcast.sh --full > website/appcast.xml` redirect truncated the live tracked appcast at FD-open time, so a mid-stream crash (sign_update failure, hdiutil failure, SIGINT) left every Sparkle client seeing malformed XML. Now staged to `mktemp` with an `EXIT` trap and `mv -f` to the final path on success. The atomic-write tripwire in `scripts/tests/publish_update_test.sh::case_atomic_appcast` now passes.
- **release.sh `CODESIGN_LOG` swallow + other script discipline** (F-S8-001, F-S8-002, F-S8-005, F-S8-009, F-S8-013). Three classes of `|| true`-on-git, untrapped `mktemp -d` leaks. Tracked in `scripts/tests/` which currently fails 1 of 14 by design as regression guards (down from 2/14 after F-S8-025 atomic-write fix landed 2026-04-29).
- **Blind test flakiness in cumulative ASan run** (internal). `PTYLifetimeRaceTests` and a few sibling tests pass in isolation but trigger ASan cumulative-allocation aborts when the full suite runs in one xctest process. Gated behind `BB_RUN_FLAKY_PTY_TESTS=1` until we understand whether the cause is our code or the xctest runner's ASan accounting.

Full triage ledger in `docs/superpowers/reviews/v0.1.9-sweep/triage.md` (gitignored, local-only).

## Deferred Audit Items (post-2026-04-29 campaign)

The 75-commit / 11-batch audit-fix campaign closed in commit `1050eee`. The
items below were intentionally scoped out of that campaign — either the
fix surface is too invasive for the campaign's incremental shape, or the
test seam for non-vacuous coverage doesn't exist yet. Tracked here so
they don't fall off the radar.

- **R1 — telemetry routing for one-shot warnings.** The campaign added
  ~20 one-shot Logger / `OSAllocatedUnfairLock<Bool>` warnings (M-15,
  L-17, M-17, dim clamp, OSC 7 reject classes, MetalRenderer.init paths,
  PTY SIGKILL rc/errno, watchdog clamp). These currently land in
  `os_log` only — no in-app surface, no opt-in telemetry pipe. A
  unified collector that an opt-in user could ship to `dist/` for
  triage would close the loop, but the design (privacy posture, opt-in
  affordance, retention) is its own track.
- **R3 #4 — `@MainActor AppDelegate`.** Promoting `AppDelegate` to
  `@MainActor` would let the type system enforce what the runtime
  guarantees today. Currently relies on `dispatchPrecondition(.onQueue(.main))`
  tripwires (M-12). Promotion needs sweeping every NSApplicationDelegate
  delegate-call site for actor-isolation soundness; deferred behind a
  real Swift 6 concurrency pass.
- **R3 #5 — `BatchCloseToken`.** The window-close batching path uses
  ad-hoc Bool flags; a typed token (struct with explicit lifecycle) would
  make the batch boundary discoverable and testable. Quick refactor but
  needs MainWindowController seams that don't exist yet (see F-S6
  deferrals re `makeForTesting(stubSession:)`).
- **R3 #7 — titleObserver KVO precondition.** The
  `NSWindow.title` KVO observer relies on the observer being installed
  before the first `setTitle:` fires; a precondition tripwire on observer
  presence would make the contract explicit. Today the contract holds
  by construction (observer is installed in init), but a future
  refactor that delays observer install could regress silently.
- **M-8 — `BBTerm.owningQueue`.** The FFI contract requires every
  `bb_term_*` call to happen on the same thread/queue that drives
  `bb_term_input`. Production paths satisfy this via
  `coreQueue.sync` discipline; a runtime check needs an `owningQueue`
  field on BBTerm and `dispatchPrecondition(.onQueue(owningQueue))` at
  every entry point. Deferred because the queue's worker pthread isn't
  a stable identity (GCD's `dispatch_sync` optimisation can borrow the
  calling thread); enforcement lives in `TerminalSession`'s
  dispatchPrecondition tripwires (M-12) for now. Resolution path:
  thread `owningQueue: DispatchQueue` through BBTerm's init.
- **`FFI_HANDLER_IN_FLIGHT` coverage for non-`bb_term_input` entry
  points.** The Rust-side handler-reentry latch (M-9 follow-up,
  2026-04-29) is wired up only at `bb_term_input` — the canonical
  re-entry vector. The other entry points (`bb_term_resize2`,
  `bb_term_scroll`, `bb_term_take_snapshot`, `bb_term_text_range`,
  `bb_term_clear_all`, `bb_term_set_named_color`, etc.) still rely on
  the Swift-side `BBTerm.isInsideEventDispatch` precondition — which
  fires AFTER the second `&mut Term` is on stack, one frame too late.
  Adding the latch check at every entry point is mechanical but
  requires a parallel Rust unit test per entry point to prove the
  guard fires; deferred as a follow-up batch.

