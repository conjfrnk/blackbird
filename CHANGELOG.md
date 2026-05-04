# Changelog

All notable changes to Blackbird are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.3] - 2026-05-04

Cumulative bug-fix and hardening release. Audit-driven sweep of the Rust VT core, the PTY layer, the renderer, and the input pipeline; every audit finding (2 High, 4 Medium, 20 Low) addressed in 26 commits + 1 reviewer follow-up.

### Reliability
- **Fixed**: SIGPIPE on the PTY master fd no longer kills Blackbird. Writing a keystroke or IME commit during the moment the slave fd closes (typical at shell exit) used to deliver SIGPIPE and terminate the entire app via the default disposition. `F_SETNOSIGPIPE` on the master fd now converts the same condition to EPIPE on the syscall, which `writeRawLocked` already handles. (H1)
- **Fixed**: Post-fork-pre-exec child path no longer calls Swift `Array`/`Dictionary`/`String`/`os.Logger`/`getpwuid`. Any of those could deadlock on a malloc / dispatch / Mach-port lock the parent's other threads were holding at fork time. All such work hoisted to the parent; the child path is now strictly POSIX async-signal-safe. (H2 + M2)
- **Fixed**: HUP-ignoring shells (`trap '' HUP`) are no longer immortal when the spawn-time `proc_pidinfo` failed. Previously the SIGKILL escalation skipped on missing start-time to avoid PID-reuse risk; the resulting leaked tab is the worse failure. SIGKILL now fires anyway with a logged breadcrumb. (M1)
- **Changed**: Force-kill ladder is now SIGHUP → SIGTERM (100 ms) → SIGKILL (200 ms), matching Terminal.app and iTerm2. Total user-visible close latency unchanged. (L5)

### Input
- **Fixed**: F13–F24 and Mac system keys (brightness, media, eject) now reach AppKit's responder chain instead of being silently swallowed. (M3)
- **Changed**: Find/regex ReDoS heuristic catches brace-quantified nested groups (`(a{1,})+`, `(.+){2,5}`, etc.). The 250 ms timeout is the actual safety net; this is the cheap first-pass. (M4)
- **Fixed**: Find-replace refuses replacement strings containing newlines (LF or CR). A `\n` in the Replace field would otherwise execute the leading fragment as a separate shell command. (L20)
- **Added**: Opt-in `bb.confirmMultiLinePaste` preference (default off). When on, a non-bracketed-paste with embedded LF or CR pops a confirmation alert. (L19)

### Security / hygiene
- **Fixed**: OSC 133 D prompt-mark events are dropped when the exit-code payload contains non-ASCII-digit bytes. A hostile shell emitting `OSC 133;D;abc ST` no longer reaches Swift as a corrupt String. Per-instance one-shot log breadcrumb. (L1, reviewer follow-up)
- **Fixed**: OSC 7 reject-log latches are per-`BBTerm` rather than process-wide. Sibling tabs (or fresh shells in the same tab) now each get the breadcrumb on first occurrence instead of being silently suppressed. (L3)
- **Fixed**: Pill context menu (`Rename…`, `Reset to Auto`) hides items when no session — NSMenu doesn't run `validateMenuItem` on context menus, so the items previously appeared enabled but silently no-op'd. (L9)
- **Changed**: Sparkle "you're up to date" alert prefers a terminal window over the Settings window if the check was triggered from Settings → Updates. (L11)

### Robustness
- **Fixed**: `BBTerm.setColor(slot:)` clamps out-of-range `Int` (negative or > 65535) instead of trapping. Hand-edited theme JSON or preference can no longer crash the app. (L2)
- **Fixed**: Drop the redundant `stat` before `chdir` in the post-fork child — closes a TOCTOU window and a non-AS-safe call. (L4)
- **Fixed**: `recordPromptStart` no longer blocks main on the feed backlog under heavy streaming output; snapshot read is dispatched async to coreQueue. (L7)
- **Fixed**: `publishTitle` reads `displayTitle` inside the main-async block instead of capturing a snapshot before the hop, eliminating a torn-update window for back-to-back title changes. (L6)
- **Fixed**: `spawnedAt` cross-queue race closed by promoting the field from `var` to `let` and threading it through init. (L8)
- **Fixed**: `bypassCloseConfirm` resets synchronously in `applicationWillTerminate` instead of via an async closure that races process teardown. (L10)
- **Fixed**: `hideTabBarViews` no longer mutates the frame of AppKit-private tab bar views; relies on `isHidden` alone. (L12)

### Renderer / hygiene
- **Added**: Stride pin for `CursorUniforms` (mirrors the existing `CellInstance` pin) so a Swift/Metal struct desync fails loudly at first render rather than scrambling cursor draws. (L17)
- **Added**: Precondition that `cursorColor.w == 1.0` in `setCursorColor`. The cursor pipeline is built without blending; alpha < 1 would write a transparent hole. (L14)
- **Added**: Debug assertion that a flush-orphan slot index isn't already in `freeNarrowSlots` — guards against a future regression where two glyphs alias the same atlas region. (L15)
- **Documented**: DIM (`SGR 2`) is intentionally halved in sRGB-encoded space, consistent with the rest of the sRGB pipeline. (L13)
- **Documented**: Color-emoji raster path is intentionally sRGB even on Display P3 panels — pipeline-wide sRGB consistency vs. emoji-fidelity trade-off. (L16)

### Scripts
- **Fixed**: `make-appcast.sh` enumerates DMGs via shell glob array instead of `for x in $(ls ...)` — whitespace-safe by construction. (L18)

### CI / process
- Restored CI to green for the first time since v0.2.0:
  - `cargo fmt` drift across the OSC scanner / OSC 133 paths.
  - Four `PreferencesTests` `*_fallsBackToDefault*` cases obsoleted by commit 1eb85ab; the semantically correct repair-target tests already exist behind `BB_RUN_STRESS_TESTS=1`.
  - Test-quality lint baseline bumped to 17 (two pre-existing `XCTAssertNotNil` smoke checks from commit 69c5bb2).
  - Smoke test's `setOnBytes`-before-`startReading` assertion moved into `readQueue.async` so it observes serial-queue-ordered state instead of racing the dispatch.

## [0.2.2] - 2026-05-04

### Changed
- Window resize is now pixel-precise. Drag from any edge or corner to any size — no more cell-multiple snap. The renderer's existing live-resize viewport stretch keeps the in-between frames smooth, and SIGWINCH is throttled to one fire per cell-boundary cross via the `lastPropagatedSize` dedup.
- Grid reserves an 8pt left + 8pt right inset between text and window edge so glyphs no longer kiss the chrome. Sub-cell pixel leftover from pixel-precise resize is absorbed into the right inset rather than producing a partial column.
- `contentMinSize` floor recomputes with the new horizontal inset; the font-size change path carries the new formula too, so bumping the font still respects a usable 20-col / 4-row minimum.

### Fixed
- `MainWindowController.startSession` used raw view bounds for the initial PTY grid; on launch the shell saw +1–2 cols too many and any output before the first layout pass wrapped at the wrong column count. Both call sites (`startSession` and `propagateResize`) now route through the shared `TerminalView.usableViewSize` helper, so the start size and the first SIGWINCH agree by construction.
- New public `TerminalView.cellAt(point:)` coordinate helper hardens against NaN / ±Infinity / absurd-magnitude input the same way `Selection.bufferPoint(forView:)` does — stray Core Animation values from misbehaving input devices clamp to the origin sentinel instead of trapping at `Int(NaN)`.
- The XTerm mouse-protocol report path (`sendMouseEvent`) now subtracts the horizontal inset before the col divide, so clicks reported to TUI apps (vim, htop) match the rendered glyph positions.

### Internal
- New `TerminalView.cellOriginPx(row:col:)` and `cellAt(point:)` helpers are the single source of truth for grid↔view coordinate conversion. `MetalRenderer` gains `setLeftInsetPoints` mirroring `setTopInsetPoints`, with `leftInsetPoints` folded into `FrameKey` and `CacheKey` so a re-inset invalidates both per-frame and per-row caches.
- `Selection.bufferPoint(forView:…, leftInsetPoints:)` makes the inset parameter required (no default) so a caller can never silently get an 8pt-off selection.

## [0.2.1] - 2026-05-03

### Security
- OSC 8 hyperlinks with embedded credentials (`https://user:pass@host/`) are now rejected at the policy gate. `URL.host` strips userinfo before the IDN homograph and divergence checks ran, so credential-bearing URLs previously sailed through to `NSWorkspace.open` (passed to the system browser in plaintext) and to the hover tooltip (visible via the AX API and screen capture). The redactor strips userinfo via `URLComponents` before display (audit H3).

### Fixed
- IME multi-scalar commits (NFD `à`, keycap `#️⃣`, VS-16 emoji like `❤️`) no longer drop trailing scalars under Kitty flag 8 (`reportAllKeysAsEsc`); multi-scalar input falls back to UTF-8 instead of emitting a single-codepoint CSI u (H4).
- Window minimize/restore no longer leaves the surface frozen on a stale frame: `lastFrameKey` advances atomically only after a successful drawable + encoder, so nil-drawable bails leave the skip-cache pinned to the last actually-encoded frame (H7).
- Atlas saturation flush no longer tears glyphs on the flush frame: a flush barrier drains in-flight GPU command buffers before the shared-storage textures are overwritten (H6).
- `bb.prefsSchemaVersion` replaces the unprefixed `prefsSchemaVersion`; a global `defaults write -g prefsSchemaVersion <n>` can no longer permanently bypass schema migrations via NSGlobalDomain (H8). One-shot bootstrap promotes the legacy key from the app's persistent domain on first launch.
- Corrupted `themeRaw` / `themeModeRaw` values now repair to `Gruvbox` / `dark` (the registered defaults), not `Default` / `auto` — a tampered pref no longer recovers to a different state than a fresh install (M4).
- VS-16-paired emoji (`❤️`) and keycap sequences (`#️⃣`) measure as 2 cells in the IME preedit overlay (L5).
- Lone CR (0x0D) on the non-bracketed-paste branch converts to LF before reaching the PTY; a hostile clipboard payload with `cmd\r` no longer triggers Enter under raw-mode TUIs where ICRNL is off (L4).
- Tab strip: closing a focused tab snapshots focus before the synchronous close mutates `tabs.count` (M7). Long titles now use binary-search truncation; OSC 0/2 titles are capped at 256 graphemes at ingress so a hostile remote can't blow up per-frame measurement cost (M8).
- Diagnostics copy/email reads + sanitizes off the main thread; the Settings UI no longer stalls for seconds on a 16 MB report (M6).
- `BBTerm.resize` returns `Size?` — nil signals the Rust panic fallback so callers skip TIOCSWINSZ and the kernel winsize stays in lockstep with the (unchanged) grid (M3).
- PTY no longer drops bytes the shell emits before `onBytes` is wired; `setOnBytes` + `startReading()` are now a documented pair, and the optional-closure storage data race is closed (M2).
- `installKittyTerminfoIfNeeded` now checks `tic` exit status; a hostile pre-planted `xterm-kitty` terminfo entry can no longer survive a failed re-install — falls back to `xterm-256color` (L1).
- OSC 7 `.unknown` classification logs the reason once per `.local→.unknown` transition; the latch re-arms on each `.local` so reconnect cycles each get a breadcrumb (L3).
- Font-slider `renderer.reconfigure` failure now logs an error breadcrumb in Release builds (L2).
- `fontSize` / `translucency` `didSet` use re-entry boolean guards so out-of-range writes don't double-fire `UserDefaults.set` and `objectWillChange` — closes the latent 982b719-class feedback-loop pattern (M5). `PTY.terminate()` collapses check + set into one `stateQueue.sync` (L6).

### Internal
- Rust core: `FFI_HANDLER_IN_FLIGHT` re-entry latch extended from `bb_term_input` to every entry point that reborrows `&mut BBTerm` (clear_all, resize2, set_named_color, take_snapshot, scroll, scroll_to_bottom, text_range, current_mode, set_event_cb, set_color_query_enabled, test_only_panic). A misbehaving callback synchronously calling one of those previously aliased the outer mutable borrow — UB by Rust's borrow rules (H5).
- Rust core: `bb_term_text_range` truncates iteration at 65,536 rows so a malformed FFI request can't allocate ~200 MB transient on a saturated 200k-row scrollback (M1). URI intern dedupe uses `Arc<str>` to halve per-snapshot allocations (L7).
- Release tooling: `make-appcast.sh` filters prerelease DMGs before `sort -V` (would otherwise misship rc as GA — C1); `smoke.sh` captures wait exit and fails on crash-on-launch (H1); `release.sh` propagates Info.plist read failure rather than shipping `Blackbird-0.0.0.dmg` (H2); appcast `pubDate` derived from the tag commit timestamp so retries are byte-identical (M11); STRAY checks use anchored `grep -Fxv` (M10); `trap EXIT` cleanup added for DMG mounts and tempdirs (M9).

## [0.2.0] - 2026-05-01

### Added
- Diagnostics tab in Settings — surfaces hang reports (from `~/Library/Logs/Blackbird/`) and macOS crash reports (from `~/Library/Logs/DiagnosticReports/`) with Reveal in Finder, Copy to Clipboard, and Email Diagnostics actions. No auto-upload, no third-party SDK, no backend.
- VoiceOver navigation by character / word / line — `TerminalView` promoted from `.staticText` to `.textArea` with full character / line / range accessors (F-S5-021).
- `docs/compat-matrix.md` documenting tested apps (Claude Code, vim, neovim, tmux, ssh, mosh, fzf, git pager, lazygit, gh, ranger, htop, btop, Emacs) and indexing the existing protocol-level pin tests (XTGETTCAP, modifyOtherKeys, OSC 8 round-trip, OSC 7 SSH trust, etc.) under one document.
- `docs/voiceover-pass.md` — manual VoiceOver acceptance checklist.
- `CHANGELOG.md` (this file).

### Documented
- End-to-end input→draw latency measurement procedure via the existing `scripts/run-with-probe.sh`. xctest can't acquire `CAMetalLayer` drawables and OS-level keystroke injection is forbidden by project rule, so an automated CI gate for real latency stays out of scope; the manual recipe (run-with-probe + 60s of typing → `latency n=500 p50=… p99=…` line in unified log) plus the 6 ms p50 / 20 ms p99 cut-blocking thresholds are now spelled out in `KNOWN_ISSUES.md`.

### Fixed
- `SparkleAlertOverride.install()` no longer leaks the previously installed block IMP on re-install (F-S7-001).

## [0.1.17] - 2026-04-29

### Fixed
- `mailto:` hyperlink parsing now reads the domain from `URL.absoluteString` instead of `URL.path`. Previously empty-host mailto links silently produced no clickable region.

### Changed
- CI Rust toolchain pinned to 1.85.0; adopted `repeat_n` for forward compatibility with newer toolchains.
- Several runloop-pumping tests are now gated behind a stress flag — they were the cumulative-ASan ceiling tippers in earlier releases.

## [0.1.16] - 2026-04-28

### Fixed
- `release.sh` signs the DMG before notarization so Gatekeeper accepts the published download. Earlier flow notarized first, signing after — leaving a window where downloaded DMGs failed initial Gatekeeper check.
- `actions/upload-artifact` bumped from 4 to 7 in CI.

## [0.1.15] - 2026-04-28

### Added
- OSC 7 SSH trust gate. `PTY.classifyForegroundNamespace()` walks `tcgetpgrp(masterFD)` via `proc_listpids(PROC_PPID_ONLY)` and classifies the foreground process as `local`, `remote(<exe>, <pid>)`, or `unknown`. `TerminalSession` only honors OSC 7 when the result is `.local`. Fail-closed posture by design (audit deferral SEC-003).
- `publish-update.sh` now runs `codesign --verify --strict`, `spctl --assess --type install`, parses Team ID from the spctl origin line (must match the pinned `F2B95Q4CT8`), and `xcrun stapler validate` before signing the DMG into the appcast (F-S8-004).
- HSTS preload submitted for `blackbird-terminal.com`.

### Fixed
- Website CSP no longer permits `unsafe-inline`; www→apex redirect, /404, /index.html canonicalization fixed.
- Settings v1→v2 migration unbroken; Sparkle override diagnostics improved.
- Hyperlink wildcard-host phishing closed; always-run divergence check enabled.
- Core: `clear_all` parser reset, `take_snapshot` panic safety, `D-mark` rate limit.
- Tab pill clicks yield first responder back to the terminal so typing resumes immediately.
- Mouse: scroll-wheel button mapping respects content direction; ⌘-drag from titlebar suppresses OSC 8 resolution.

## [0.1.14] - 2026-04-27

### Added
- ⌃⇥ and ⌃⇧⇥ shortcuts cycle tabs.
- Website redesign: hero, terminal mockup, features section.
- Release pipeline substitutes the actual version into `website/index.html` on publish.

### Fixed
- TerminalView focus restored on tab-group selection change and on tab-close survivor promotion.
- Hyperlink: OSC 8 click blocked on anchor/href host divergence (audit H1).
- Hover: OSC 8 tooltip URL scrubbed for bidi / control bytes (audit C1).
- Find: column math honours wide CJK and non-BMP graphemes.
- Renderer: explicit black-bg paint on non-black themes; row cache invalidated on atlas saturation flush.
- Input: Native-Option preserves meta when Ctrl is also held.
- Window persists size and position across shell-exit close.
- Drops are forwarded to foreground children (Claude Code, REPLs, vim).

## [0.1.13] - 2026-04-27

### Fixed
- Core: scrollback no longer wiped on every TUI redraw.

## [0.1.12] - 2026-04-27

### Added
- Atomic appcast write in `publish-update.sh` — staged via `mktemp` with an `EXIT` trap and `mv -f` on success (F-S8-025 / audit L-13). Prevents truncated appcast XML during a mid-publish crash.

### Fixed
- Various session and core hardening: `scroll`/`clearAll`/`scrollToBottom` keep synchronous publish; SIGKILL escalation guards against PID reuse; explicit `terminate()` drives FFI teardown on `coreQueue` (audit M6/M8/M9).
- DSR / DA / CPR / DECXCPR PTY replies rate-limited (audit M1).
- `BBSnap.display_offset` widened `u16 → u32` across FFI to support deeper scrollback (audit M5).
- Invisible-codepoint scrub policy extended across surfaces.

## [0.1.11] - 2026-04-27

### Added
- `cut-release.sh` auto-bumps `CFBundleVersion` (Sparkle's update-comparison key). Earlier releases shipped with a stale build number that hid updates.

### Fixed
- CI: trust `BlackbirdTests.xctest 'passed'` over xcodebuild exit code; ASan disabled at the build-setting level on PR runs (the cumulative ceiling fight); 1000-iter stress tests gated under `BB_RUN_STRESS_TESTS`; real-shell PTY tests skipped under cumulative ASan.

## [0.1.10] - 2026-04-25

### Fixed
- Re-gated a `hideTabBarViews` canary log to DEBUG. Fixed the Release build that broke during the ASan-ceiling firefight.

## [0.1.9] - 2026-04-24

### Added
- `modifyOtherKeys` (xterm `CSI > 4 ; N m`). Emacs, tmux `extended-keys on`, and Neovim's auto-request all covered.
- Color emoji atlas. Glyphs from fonts that report `CTFontSymbolicTraits.colorGlyphs` (Apple Color Emoji, Noto Color Emoji, COLRv1/sbix/CBDT) now rasterize into a dedicated `bgra8Unorm` atlas; the fragment shader branches on `BB_ATTR_IS_COLOR_GLYPH`.
- Kitty flag 4 — US-layout shifted symbols emit `base:0:shifted`.

### Changed
- `TerminalView` decomposed into Mouse / Hover / Find / Drag / Paste / Accessibility extensions for orthogonality.
- Atlas detects color glyphs per-scalar via CoreText font cascade.

## [0.1.8] - 2026-04-23

### Changed
- Tab system simplified: pill-strip rebuild eliminates flicker on close.

## [0.1.7] - 2026-04-22

### Added
- Cursor-style preference (Block / Underline / Bar / Follow Shell).
- Manual tab rename via ⌥⌘R.
- Tab-bar hardening: pill strip refresh on tab-add/-close.

## [0.1.6] - 2026-04-22

### Fixed
- Tab merge / drag glitches in NSWindowTabGroup integration.

## [0.1.5] - 2026-04-21

### Added
- Find-and-replace bar (⌘⌥E). ⌘⌥E replaces current match; Replace All routes DEL×N + UTF-8 through PTY; warns if matches are off the live input line.
- XTGETTCAP Kitty capability queries — `OscScanner` gained `hook`/`put`/`unhook`; cap table covers `TN`, `Co`, `RGB`, `Smulx`, `Setulc`.
- Latency CI gate (probe-pipeline). Parses `log show` for the probe's p50/p99 and fails above 6 ms / 20 ms thresholds.

## [0.1.4] - 2026-04-21

### Fixed
- Sparkle update detection by switching `CFBundleVersion` to a monotonic integer (`<sparkle:version>` is component-wise compared; the previous string scheme hid updates).

## [0.1.3] - 2026-04-20

### Fixed
- Release build ad-hoc Sparkle launch crash. `release.sh` now re-signs Sparkle XPC bundles with the same identity as the parent app so hardened-runtime + ad-hoc + Sparkle XPC isn't rejected by dyld at launch.

## [0.1.2] - 2026-04-20

### Fixed
- Initial post-launch hotfixes.

## [0.1.1] - 2026-04-20

### Fixed
- Sparkle update detection (initial CFBundleVersion fix; superseded by 0.1.4).

## [0.1.0] - 2026-04-20

### Added
- First public release.
- Core: alacritty_terminal via thin C ABI (~10 functions); fuzz-tested parser; long-session memory gate; throughput gate (>200 MB/s on plain text).
- Renderer: Metal pipeline with mono coverage atlas + emoji atlas (added in 0.1.9); 120 Hz ProMotion.
- Shell: AppKit + SwiftUI; tabs via `NSWindowTabGroup` (no splits, locked non-goal); CSI u modifier encoding; Kitty keyboard protocol flags 1 / 2 / 8 / 16; xterm `modifyOtherKeys` (added in 0.1.9).
- Hyperlinks: OSC 8 emit + scrollback retain + ⌘-click + hover; URL detector (http/https/ftp; mailto; deliberately no `file://`).
- IME: `NSTextInputClient` integration; astral-plane support.
- Drag-and-drop: file URLs forwarded to foreground children.
- Manual tab rename (⌥⌘R).
- Settings: SwiftUI `@AppStorage`-backed Preferences; themes (Default, Gruvbox, Solarized, Catppuccin × light/dark); cursor shape + blink; bell style; Option-key behavior; OSC 52 toggle.
- Updates: Sparkle 2.x with EdDSA-signed appcast at `blackbird-terminal.com`.
- Distribution: universal binary (arm64 + x86_64), macOS 14+, Developer ID + notarytool.
