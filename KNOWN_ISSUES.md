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

**Flag 4 (`reportAlternateKeys`)** emits `base:shifted` for every ASCII letter and for the 21 US-layout shifted symbols (`!`→`1`, `@`→`2`, …, `|`→`\`). The Kitty key-code field is `unicode-key : shifted-key : base-layout-key`, so the shifted codepoint occupies the second sub-field; the third (base-layout / alt-layout) field is omitted because macOS exposes no per-key alternate-layout codepoint. (Through v0.2.9 this emitted `base:0:shifted`, which misread the spec — a literal `0` in the shifted slot and the real shifted value pushed into the base-layout slot — so a spec-compliant TUI read shifted-key = U+0000. Fixed to the spec-correct `base:shifted` shape.) Non-US layouts (German QWERTZ, Dvorak, BÉPO, …) still see only the shifted char with no alt-layout slot — the reverse lookup would need Carbon's `UCKeyTranslate` + current-layout plumbing, deferred to a dedicated session.

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

Limitation kept (audit fix-#23, 2026-05-11 — accepted as designed): a renamed / aliased / statically-linked ssh-clone whose basename isn't in `remoteShellBinaryBasenames` (e.g. a user-installed `mysshwrapper` that IS the ssh transport with no descendant `ssh` process) classifies as `.local`, so OSC 7 cwd inheritance trusts the remote path. The audit-recommended mitigation (gate on a fixed list of "known-safe local-shell paths" like `/bin`, `/usr/bin`, `/opt/homebrew/bin`, `~/.local/bin`) would over-fire on legitimate custom installs (MacPorts at `/opt/local/bin/*`, cargo at `~/.cargo/bin/nushell`, user-built shells), trading a real UX cost for a niche security fix. The project's chosen posture (per the comment block at PTY.swift:1013-1019 — "Conservative set… False negatives are the security risk we're guarding against, so when in doubt, add to the set") is to expand `remoteShellBinaryBasenames` when a new canonical wrapper appears, rather than introduce path-based heuristics. v1.0 hardening: revisit if mysshwrapper-shaped tooling becomes common in the field.

## v0.1.9 hardening-sweep deferrals (2026-04-24)

A multi-agent review + blind-test pass surfaced 67 unique findings. The critical / high-severity items shipped across commits `f18d00e..53c17a7`; the items below are legitimately deferred because they touch public API shape, require architectural changes, or need test-host seams that don't exist yet.

- **Kitty flag 1 for arbitrary modified printables** (F-S3 finding, blind test `test_precedenceTruthTable_ctrlDot` relaxed). Per spec, flag 1 alone should emit `CSI <cp>;<mod>u` for any modified printable (Alt+s, Ctrl+., etc.), not just the C0 colliders + Enter/Esc/Tab/Backspace. Closing the gap needs encoder-shape work plus coordination with the TerminalView fast-path.
- **Kitty flag 4 for non-US keyboard layouts** (F-S3-013 / KNOWN_ISSUES § "Kitty flag 4 / 16"). Still needs Carbon `UCKeyTranslate` + current-layout plumbing.
- **`encodeSpecial` honouring Kitty flags** (F-S3-005). Arrows / F-keys / nav keys emit legacy `CSI 1;M <final>` regardless of flag 1 / 8 / 2. Making them protocol-aware needs the `mode` argument plumbed through `encodeSpecial`.
- **Accessibility role promotion — shipped 2026-04-30 (v0.2)** (F-S5-021). `TerminalView` promoted from `.staticText` to `.textArea` with line / character / range accessors (`accessibilityNumberOfCharacters`, `accessibilityRange(forLine:)`, `accessibilityString(for:)`, `accessibilityLine(for:)`, `accessibilityRange(for:)`, `accessibilityFrame(for:)`, `accessibilityVisibleCharacterRange`). Selection setter is a no-op + one-shot log because the rectangular grid model can't be expressed as a single character range cleanly; full selection is tracked for v1.0. Tests in `Tests/BlackbirdTests/AccessibilityTests.swift` (30 cases) cover role, value, cache, line/character/range accessors, selection contract, snapshot-identity invalidation, astral-codepoint round-trip, and trailing-newline line counting (the dominant production case — shell prompt on a blank bottom row — depends on this for VO line navigation). Manual VoiceOver checklist at `docs/voiceover-pass.md`.
- **Secure-input indicator badge** (SPR-006). Plumbing shipped; the visual indicator was never built.
- **F-S6-001 / F-S6-002 / F-S6-003** window lifecycle fixes (dock zombie on miniaturized auto-close, `closeWindow` ⌘⇧W bypass on single-tab, `newWindow` permanent `.disallowed` tabbingMode). Tests exist but are gated via `XCTSkip` because xctest can't spawn a real `MainWindowController` without destabilising later PTY tests under ASan. Fix requires `MainWindowController.makeForTesting(stubSession:)` seam.
- **`MainThreadWatchdog` modernisation** (F-S6-004). Uses deprecated `Process.launchPath`; swap to `executableURL` + handle macOS 13+ hardened-runtime rules.
- **Sparkle swizzle leak — shipped 2026-04-30 (v0.2)** (F-S7-001). `SparkleAlertOverride.install()` now tracks the IMP it minted via `imp_implementationWithBlock` and frees the prior block on re-install via `imp_removeBlock`. The runtime-owned original IMP returned by the FIRST `method_setImplementation` is left untouched (only IMPs we created are eligible for removal). Tests in `Tests/BlackbirdTests/SparkleAlertOverrideTests.swift` pin the tracking and replacement contracts.
- **Preferences schema-downgrade guard — shipped pre-v0.2** (F-S7-003). The fix was already on `main` before the v0.2 cycle: `Preferences.migrateIfNeeded(in:)` includes the `guard stored < Preferences.currentSchemaVersion` check that preserves a higher on-disk schema version. Tests in `Tests/BlackbirdTests/PreferencesMigrationTests.swift` (`test_schemaMigration_handlesDowngradeWithoutOverwrite` for source-level intent + `test_downgradeFromFutureSchema_doesNotStampOlderVersion` for runtime regression). Listed here for completeness.
- **publish-update.sh trust-root hardening — shipped 2026-04-28** (SEC-003 / F-S8-004). The script now runs `codesign --verify --strict`, `spctl --assess --type install`, parses `origin=` for a pinned Team ID (`F2B95Q4CT8`), and `xcrun stapler validate` before signing the DMG into the appcast. Pinned-SHA was dropped from the original deferred description because in a single-developer flow there's no out-of-band trust root for the SHA itself; the codesign+spctl+stapler chain plus Team ID parsed from spctl's origin line is the meaningful trust root. Three new test cases in `scripts/tests/publish_update_test.sh` (spctl reject, wrong-Team-ID origin, stapler reject) regression-guard the verify gate. Drive-by fix bundled in: F-S8-003 version-arg validation (semver regex).
- **publish-update.sh atomic appcast write — shipped 2026-04-29** (F-S8-025 / audit L-13). The previous `bash make-appcast.sh --full > website/appcast.xml` redirect truncated the live tracked appcast at FD-open time, so a mid-stream crash (sign_update failure, hdiutil failure, SIGINT) left every Sparkle client seeing malformed XML. Now staged to `mktemp` with an `EXIT` trap and `mv -f` to the final path on success. The atomic-write tripwire in `scripts/tests/publish_update_test.sh::case_atomic_appcast` now passes.
- **release.sh `CODESIGN_LOG` swallow + other script discipline** (F-S8-001, F-S8-002, F-S8-005, F-S8-009, F-S8-013). Three classes of `|| true`-on-git, untrapped `mktemp -d` leaks. Regression-guarded by `scripts/tests/release_test.sh::case_codesign_log_swallow`, gated behind `BB_TEST_RELEASE_FAILURE=1` (opt-in) so the default `scripts/tests/run.sh` invocation stays green; the gated case is expected to FAIL until the F-S8-001 fix lands.
- **Blind test flakiness in cumulative ASan run** (internal). `PTYLifetimeRaceTests` and a few sibling tests pass in isolation but trigger ASan cumulative-allocation aborts when the full suite runs in one xctest process. Gated behind `BB_RUN_FLAKY_PTY_TESTS=1` until we understand whether the cause is our code or the xctest runner's ASan accounting.

Full triage ledger in `docs/superpowers/reviews/v0.1.9-sweep/triage.md` (gitignored, local-only).

## v0.2 cycle additions (2026-04-30)

The v0.2 design (`docs/superpowers/specs/2026-04-30-blackbird-v0.2-design.md`) closed F-S5-021 / F-S7-001 (above) and added two surfaces that warrant their own entries:

- **Diagnostics tab in Settings — shipped 2026-04-30 (v0.2)**. Settings → Diagnostics surfaces hang reports (from `~/Library/Logs/Blackbird/hang-*.txt`, written by `MainThreadWatchdog`) and macOS crash reports (from `~/Library/Logs/DiagnosticReports/Blackbird-*.{ips,crash}`). Per-row actions: Reveal in Finder, Copy to Clipboard, Email Diagnostics. Email opens `mailto:conjfrnk@gmail.com` with the report content pre-copied to the clipboard for paste-attach (mailto: URLs cap at ~2 KB; we don't try to inline the report). No backend, no third-party SDK, no auto-upload — privacy posture is "data stays local until the user clicks Email." Symlinks in either directory are dropped (defense against an attacker-controlled symlink at `~/Library/Logs/DiagnosticReports/Blackbird-x.ips → /etc/passwd` that would otherwise be exfiltrated when the user clicks Email Diagnostics). Inline reads cap at 16 MiB to bound peak memory and main-thread stall on adversarial input. C0/C1 control characters are stripped before placing report text on the pasteboard (defense-in-depth against a planted report containing OSC 52 that would re-execute on paste). Model: `Sources/Blackbird/Settings/DiagnosticReportStore.swift` (23 tests). View: `Sources/Blackbird/Settings/DiagnosticsView.swift`.

- **End-to-end input→draw latency gate — split between PR-CI plumbing pin and nightly real-window measurement (P4.6, 2026-05-09)**. The PR-CI `latency-gate` job (renamed from "Latency gate — p50/p99 regression check" to "Latency probe plumbing format pin") is explicitly plumbing-only: it runs `LatencyHarnessTests`, which calls `markKeystroke()` and `markPresented()` back-to-back so deltas are ~0 µs and the LATENCY_P50_MS=6.0 / LATENCY_P99_MS=20.0 thresholds are unreachable by construction. That job exists to pin the probe's log-line FORMAT and the bench-script regex against drift — nothing more. The honest end-to-end measurement now lives in `Tests/BlackbirdTests/RealLatencyProbeWindowedTests.swift`, gated behind `BB_RUN_LATENCY_PROBE=1` (set only by `nightly-soak.yml` via `TEST_RUNNER_BB_RUN_LATENCY_PROBE=1`). That nightly test creates a real `NSWindow` + `MTKView`, drives synthesized `NSEvent.keyDown` events through `NSApp.sendEvent`, pumps the runloop until frames present, and asserts `max > 0.5 ms` (real frame latency, not the back-to-back ~0 µs the synthetic harness measures). The test pre-flights `MetalRenderer.didFrameSkipLastRender` after the first draw — if the xctest host's windowing stack can't acquire a `CAMetalLayer` drawable (a known limitation of GHA's macos-14 virtual display, and also of `xcodebuild test` on dev machines without an attached display), the test throws `XCTSkip` with a clear "windowed Metal probe cannot acquire drawable" reason. The nightly sentinel grep accepts EITHER `passed` (real measurement landed) OR `skipped` (host can't acquire drawable) but FAILS LOUDLY if the test never ran — that's the silent-green failure mode where `TEST_RUNNER_BB_RUN_LATENCY_PROBE` propagation breaks. Real-latency CI signal therefore depends on adding a self-hosted runner with an attached display (deferred); until then, the test ensures the path EXISTS and runs locally on a dev machine, while CI gets the format-pin. **Manual measurement remains available via `scripts/run-with-probe.sh`** for local pre-release verification: launches a signed Debug Blackbird with `BB_LATENCY_PROBE=1`, streams the unified-log `latency` category. Type continuously for ~60s to fill the 500-sample ring; the resulting `latency n=500 p50=… p99=… p999=… max=…` line is the authoritative measurement. Connor runs this locally before tagging each release; a regression vs. the 6 ms p50 / 20 ms p99 baseline blocks the cut. p999 + max thresholds are not yet gated — pending a few baseline runs of real-world data from both the nightly windowed test and manual sessions.

- **alacritty_terminal parser idempotence violation across split boundaries (deferred, 2026-05-10)**. The Phase 2 proptest invariant `parse_idempotent_across_arbitrary_split` in `core/tests/proptest_invariants.rs` correctly found a real bug on its first failing nightly seed: feeding a 2299-byte adversarial VTE payload split at index 2207 produces different `bb_term_text_range` output than feeding the whole payload at once — a single byte (`0x73 's'`) appears in the whole-feed but not the split-feed, somewhere around an OSC/CSI boundary. The bug is in alacritty_terminal=0.26.0 (or our wrapping of it) — splitting mid-CSI/OSC drops a byte from parser state. Not a crash, not user-visible in normal operation (real PTYs don't fragment payloads at adversarial offsets); proptest found the pathological case. The test is `#[ignore]`'d until the parser-state-preservation fix lands. The other three invariants in the file (snapshot back-to-back, mode set/reset, scroll roundtrip) continue to run on every PR. Failing seed captured: `cc de803e6a71e8eaa582ded0bc2a92ad56f7188931d6da90d3f9cf494561634a17`. Reference: `core/tests/proptest_invariants.rs:265`.

- **H-5 FFI re-entry surface — miri-detected aliasing UB (deferred, 2026-05-10)**. The Phase 2 nightly miri workflow flagged Undefined Behaviour in `core/tests/handler_reentry_guard.rs` on its first scheduled run: every protected FFI entry (`bb_term_clear_all`, `bb_term_take_snapshot`, `bb_term_text_range`, `bb_term_resize`, `bb_term_resize2`, `bb_term_current_mode`) materialises `&mut bb.term` BEFORE checking the `FFI_HANDLER_IN_FLIGHT` thread-local latch. The latch correctly suppresses any aliased read or write, so the runtime behaviour is observably correct (and the same tests pass under regular `cargo test` on every PR), but the materialisation itself takes a unique tag on the borrow stack while the outer `bb_term_input`'s tag is still active — both Stacked Borrows and Tree Borrows correctly classify this as UB whether or not we go on to use it. Until the H-5 surface is restructured to check the latch via raw-pointer access on `*term` before the `&mut *term` materialisation, every test in `handler_reentry_guard.rs` is `#[cfg_attr(miri, ignore)]`'d. The non-miri runs continue to pin the runtime invariants (no observable mutation, no crash, documented fallback returned) on every PR. The fix is mechanical (`if !(*term).handler_in_flight.get()` before each `let bb = &mut *term`) but touches every guarded FFI entry; tracking as a v1.0 hardening item.

## Deferred Audit Items (post-2026-04-29 campaign)

The 75-commit / 11-batch audit-fix campaign closed in commit `1050eee`. The
items below were intentionally scoped out of that campaign — either the
fix surface is too invasive for the campaign's incremental shape, or the
test seam for non-vacuous coverage doesn't exist yet. Tracked here so
they don't fall off the radar.

- **R1 — telemetry routing for one-shot warnings.** The campaign added
  one-shot Logger and `OSAllocatedUnfairLock<Bool>` warnings (M-15,
  L-17, M-17, dim clamp, OSC 7 reject classes, MetalRenderer.init paths,
  PTY SIGKILL rc/errno, watchdog clamp) across many code paths. These
  currently land in `os_log` only — no in-app surface, no opt-in
  telemetry pipe. A unified collector that an opt-in user could ship
  to `dist/` for triage would close the loop, but the design (privacy
  posture, opt-in affordance, retention) is its own track.
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

## Bug-hunt deferrals (2026-05-28, v0.2.10 cycle)

A multi-agent bug-hunt + adversarial-verification sweep confirmed 10
findings. The high-value, cleanly-testable ones shipped in v0.2.10
(Kitty flag-4 wire order, double-click-drag word-extend, FrameKey
atlas-generation skip-cache). The items below are confirmed-real but
deferred — either the safe fix is larger than a patch warrants, or no
non-vacuous test seam exists yet.

- **Unbounded OSC payload growth — memory DoS (deferred, needs
  dedicated work).** A single OSC sequence opened with `ESC ]` and
  never terminated (no BEL / ST / CAN / SUB) accumulates its payload
  without bound. Root cause is upstream: `vte 0.15.0` under the default
  `std` feature stores the OSC payload in `osc_raw: Vec<u8>`, and the
  `MAX_OSC_RAW` (1024) / `is_full()` cap in `action_osc_put` is gated
  behind `#[cfg(not(feature = "std"))]` — so under `std` (which
  `alacritty_terminal 0.26` enables) there is NO cap. `bb_term_input`
  drives *two* parsers over the same bytes — alacritty's `bb.processor`
  and Blackbird's parallel `bb.osc_parser` — so the retained memory is
  ~2× the streamed payload until a terminator / RIS / `bb_term_clear_all`
  arrives. The handlers' own caps (`OSC7_URL_MAX`, `OSC8_URI_MAX`) only
  fire at dispatch time, which never happens for an unterminated
  sequence. The `osc_possibly_pending` comment ("pathological but
  harmless") reasoned about the latch's correctness, not the `Vec`
  growth. Reachable by ordinary hostile terminal output: a malicious
  program or compromised remote over SSH writes `\x1b]2;` then an endless
  stream of printable bytes. **Why deferred:** a correct fix must bound
  BOTH parsers. Blackbird's own `osc_parser` is trivially recreatable,
  but alacritty's `Processor` exposes no parser-reset / cap, so bounding
  it means either (a) injecting an abort byte (`CAN`) into the stream —
  which risks corrupting a multi-byte UTF-8 scalar if the injection
  lands mid-character, since OSC payloads (and plain text) carry UTF-8 —
  or (b) a precise byte-level OSC-state tracker duplicating vte's
  entry/exit logic, which is fragile against the throughput/fuzz gates.
  The clean fix is upstream: a `std`-mode `osc_raw` cap in vte, or an
  alacritty `Processor` parser-reset hook. A generous cap (≥ several MiB)
  would not affect legitimate large OSCs (OSC 52 clipboard, OSC 8
  hyperlinks ≤ 4 KiB) and would bound the DoS. Tracked for a dedicated
  hardening pass with upstream coordination + a `long_session_memory`
  regression gate variant that feeds an unterminated OSC.

- **IME caret / candidate-window width model divergence (low).**
  `TerminalView+IME.swift` `characterIndex(for:)` measures per-grapheme
  cell width inline (`cluster.unicodeScalars.map { cellWidth(for:) }.max()`)
  while `firstRect(forCharacterRange:)` and `refreshPreeditOverlay()` use
  `terminalCellWidth(of:)`, which applies the VS-16 / keycap
  presentation promotion. For emoji-presentation / keycap graphemes the
  two disagree, so the IME candidate window can anchor a cell off from
  the caret. Fix: route `characterIndex` through `terminalCellWidth(of:)`
  (or a shared `graphemeCellWidth` helper). Niche; deferred to a polish
  batch.

- **VoiceOver tab-title value-changed notification can't fire (low).**
  `TabStripView.update` captures `oldTitles` from `self.tabs` *before*
  reassigning, but the pill titles are read live from the same window
  references, so by the time `update` runs the title already changed and
  `oldTitles[i] == tabs[i].title` — the `.valueChanged` post never
  fires. Fix: cache the last-applied titles in a stored property and diff
  against the previous call's snapshot. Low impact (AppKit's
  container-children invalidation still re-reads pills on list-shape
  changes); deferred.

- **Instance-buffer grow-failure presents a blank drawable (low).**
  In `MetalRenderer.buildInstances`, if `device.makeBuffer` returns nil
  on a grow, the frame proceeds and presents a cleared drawable instead
  of skipping (mirroring the drawable-acquisition early-return). A
  one-frame black flash on an allocation failure that effectively never
  occurs in practice. Fix: signal the inflight semaphore and bail before
  present/commit. Deferred (vanishingly rare trigger).

- **URL wrap-join follows only one continuation row (low).**
  `URLDetector` joins a soft-wrapped URL across `row → row + 1` only, so
  a URL wrapping across 3+ rows is truncated at the second row. Most
  real URLs fit two rows on an 80+ col grid; deferred as a documented
  2-row cap rather than a multi-row walk.
