# Changelog

All notable changes to Blackbird are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
