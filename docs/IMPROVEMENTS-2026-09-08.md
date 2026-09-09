# Blackbird — areas of improvement (2026-09-08)

Consolidated from eight parallel read-only reviews of `main` @ d0fad9b (v0.8.0,
build 49): Rust core, Swift terminal layer, window/tab layer, Metal renderer,
settings/security/app shell, process hygiene (tests/CI/scripts/docs), product
and UX gaps, and the end-to-end perf/concurrency pipeline. Every finding cites
`file:line`; the lead session independently re-verified the items marked ✔.
Nothing in `KNOWN_ISSUES.md` is re-reported unless the deferral now looks wrong.

Totals after dedupe: 7 tier-0, ~30 tier-1, ~70 tier-2, plus 9 structural
programs. Sizes: S hours, M days, L week+, XL multi-week.

---

## Tier 0 — deadline, crash, or adoption blocker

| # | Item | Where | Size |
|---|------|-------|------|
| 0.1 | **CI runners are `macos-14`, retired 2026-11-02 with brownouts from 2026-10-05.** Every workflow incl. `release.yml`; the next release cut after Oct 5 can randomly fail and after Nov 2 will never build. Blocked on the Xcode 16.2 pin (macos-26 ships only Xcode 26). ✔ | `.github/workflows/ci.yml:23,94,274,332,405,572,636-769`, `release.yml:22`, `nightly-*.yml` | S |
| 0.2 | **Xcode pinned to 16.2 in CI; local dev is Xcode 26.6 / macOS 26.** Every shipped DMG is built against the macOS 15 SDK; Tahoe-specific behaviour (hit-testable hidden NSTabBar, Liquid Glass) is never compiled or tested by CI. ✔ | `ci.yml:112,292,350,446,590`, `release.yml:46`, `README.md:68` | S |
| 0.3 | **Intel Macs likely crash at launch.** All three glyph-atlas textures use `storageMode = .shared`; on macOS that is unified-memory-only, so `makeTexture` returns nil → `GlyphAtlas.init?` nil → `MetalRenderer.init?` nil → `fatalError`. The comment claims Intel parity; the x86_64 CI smoke runs under Rosetta on an Apple GPU so cannot catch it. Confidence medium-high, needs one Intel run. ✔ (code) | `Sources/Renderer/GlyphAtlas.swift:188-190,210,260`; `TerminalView.swift:500` | S |
| 0.4 | **Mouse wheel is dead in `less`, `man`, `git log`, vim (mouse off), ssh pagers.** With reporting off the wheel calls `scroll_display`, a no-op on the alt screen. DEC 1007 is parsed by vte but never exported (`BBTermMode` has no bit) nor acted on. Every peer converts wheel→↑/↓ here. ✔ | `TerminalView+Mouse.swift:427-490`; `core/src/snapshot.rs:86-120,395-451` | S |
| 0.5 | **Claude Code emits no notification and no bell in Blackbird.** Its `preferredNotifChannel=auto` switches on `TERM_PROGRAM` (Apple_Terminal/iTerm.app/kitty/ghostty); Blackbird → `no_method_available`. Even forced `terminal_bell` gives only the visual flash: no audible bell, no `requestUserAttention`, no Dock badge, no tab dot. Core forwards only OSC 7/133; OSC 9/777/99 dropped. README calls Claude Code the design target. ✔ (binary strings) | `PTY.swift:574`; `BellController.swift:9-13`; `core/src/osc.rs:140-141` | M |
| 0.6 | **Every window that was ever in a multi-tab group leaks after close** (window + TerminalView + MTKView + MetalRenderer + atlases + strip + prefs sink). `TabStripView.tabs: [NSWindow]` strong-holds the group incl. its own host: `NSWindow → titlebarAccessoryViewControllers → view → tabs → NSWindow`. The ≤1-tab branch hides the strip without `update`, and `windowWillClose` never clears it. No dealloc test exists. ✔ | `TitlebarTabBar.swift:164,338,2308`; `TabGroupObserver.swift:419-436` | S–M |
| 0.7 | **Find walks the whole scrollback on main, one `coreQueue.sync` per line, re-run on every snapshot while the bar is open.** 100k-line default history → 100k round-trips per output burst, each also waiting behind queued feed chunks (0.8). Regex path captures rows the same way. ✔ | `FindController.swift:127-146,302-303,365-372,507-522`; `TerminalSession.swift:765-781` | M |
| 0.8 | **No backpressure between the PTY read loop and `coreQueue`.** One `coreQueue.async` per 128 KiB read, nothing bounds depth; a producer faster than the parser (~24 MiB/s dense cells) grows memory without bound and output keeps replaying seconds after Ctrl+C. Every main-side `.sync` (scroll, scrollToBottom on each keystroke while scrolled, copy, ⌘K, row-resize, find, scrollToMark) waits behind the backlog. ✔ | `TerminalSession.swift:1007-1012,623-647,669`; `PTY.swift:811-820`; `ResizeController.swift:19-37`; `TerminalView.swift:1788-1790` | M |

---

## Tier 1 — should fix (next one or two releases)

### Release funnel and docs (all verified ✔)

- **1.1 CHANGELOG stops at 0.2.6 (2026-05-18)**: 12 tags / 408 commits undocumented. GitHub releases carry only a compare link; `make-appcast.sh` emits no `sparkle:releaseNotesLink`, so in-app updaters see nothing. Fix: backfill from tags; make `cut-release.sh` refuse to tag without a `## [X.Y.Z]` entry; emit the link. (S–M)
- **1.2 Homebrew cask pinned to 0.2.6** with a stale sha256; `auto_updates true` makes `brew upgrade` skip it. `publish-update.sh` already has the DMG sha and version: two `sed`s. Also the `zap` list misses `~/.terminfo/x/xterm-kitty`, `~/.local/share/blackbird`, `~/.local/state/blackbird`. (S)
- **1.3 Auto-update checks are off and nobody is ever asked.** `SUEnableAutomaticChecks=false` in Info.plist suppresses Sparkle's one-time permission prompt, then `bb.autoUpdateChecks` (default false) is forced onto the updater at every launch. Security releases reach only people who open Settings → Updates. Fix: drop the plist key or default the pref true with the existing opt-out. (S) `Info.plist:39-40`, `Preferences.swift:197`, `App.swift:73-85,301-311`
- **1.4 `cut-release.sh` never checks CI is green, and the release commit's own CI run is always cancelled** (`cancel-in-progress` + the website commit minutes later): v0.5.1…v0.8.0 all show `cancelled`. Tags only trigger `release.yml`, which runs no tests. Fix: require a green `ci.yml` run on HEAD before tagging; exempt release commits from cancellation. (S)
- **1.5 `release.yml` publishes an unsigned DMG as a public non-draft release if signing secrets are missing** (`release.yml:82-87`, `draft: false`). Today `release.sh`'s codesign gate would fail first, but the encoded intent is wrong. Fail hard instead. (S)
- **1.6 SECURITY.md describes v0.2.x**: says Blackbird never replies to OSC 10/11/12 (replies are default-on since v0.6.0 with a rate cap), Sparkle 2.9.1 (pinned 2.9.2), "last reviewed against v0.2.6". Posture-script comments still call the appcast a placeholder. (S) `SECURITY.md:85-94,149,198`
- **1.7 KNOWN_ISSUES.md is mostly FIXED entries** (lines 122, 190, 206-217, 230, 232, 250, 294, 313, 324). CLAUDE.md tells agents to grep it before triaging; signal-to-noise now defeats that. Move resolved items into the changelog. (S)
- **1.8 Open issue #12 has waited on the maintainer since 2026-06-10** across seven releases that changed drag behaviour. Reply with v0.8.0 behaviour and close or convert. (S)
- **1.9 README/compat/KNOWN_ISSUES disagree**: README says light/dark auto-follows the system but the registered default is `.dark` (`Preferences.swift:161,405`); README says `ftp` blocked, `URLDetector.swift:36` and KNOWN_ISSUES say matched; compat matrix "reviewed against v0.2.6"; website benchmark link points at the pre-fix April doc, not `docs/benchmarks/throughput-2026-06-09.md`. (S)
- **1.10 CI drift check covers pbxproj but not the tracked, xcodegen-written `Info.plist`**; a hand edit to `SUFeedURL`/`SUPublicEDKey` passes both the drift check and the posture script. (S) `ci.yml:124-127`

### Rendering correctness

- **1.11 Glyph anti-aliasing coverage is squared on default-background cells.** `mix(bg, fg, c)` with `bg.a == 0` yields alpha `c`, then straight-alpha blending gives `(1-c²)·dst + c²·fg`. Explicit-bg cells get the correct `c`, so text changes weight when selected / under the block cursor / on a status line, and all ordinary text is thinner than CoreText. Fix: premultiplied output + `.one/.oneMinusSourceAlpha`; also deletes the emoji de-premultiply branch and fixes the emoji halo (2.x). ✔ (S) `Shaders.metal:138`, `MetalRenderer.swift:626-630`
- **1.12 Combining marks are dropped at the FFI**: `BBCell.ch` is one scalar; `e`+U+0301 (macOS filenames, git output) renders as `e`. Copy is correct, pixels are wrong. Not in KNOWN_ISSUES (which covers ZWJ/keycaps). Same root cause as ligatures (1.31) and ZWJ. (M) `core/src/snapshot.rs:692-704`, `CellInstanceBuilder.swift:226-236`
- **1.13 Half-texel UV inset resamples every glyph horizontally** (quad `pxW` px wide samples `pxW-1` texels; left pixel of a 16 px cell samples texel 0.97). Vertical axis is exact and shows what horizontal should look like. (S) `GlyphAtlas.swift:634-646`
- **1.14 Undercurl / dotted / dashed phase restarts at every cell** (`localPx.x` resets per quad; 8 pt · 1.4 rad is not a multiple of 2π). (S) `Shaders.metal:195,216,222`
- **1.15 Empty damage set → full rebuild instead of no rebuild.** `decideRebuildRows` returns nil when `damaged.isEmpty`; DSR/DA replies, mode toggles, OSC, bells each cost a 16k-cell walk + present. ✔ (S) `MetalRenderer.swift:1647`

### Input protocol conformance

- **1.16 Kitty flag 1 (disambiguate) leaves plain Esc, Option-Meta+key and Ctrl+letter in legacy form.** The spec: those three must be CSI u under flag 1 (only Enter/Tab/Backspace stay legacy). KNOWN_ISSUES' F-S3 "scope correction" misreads the spec, and `test_plainEsc_disambiguateMode_stillEsc` pins the deviation. A flag-1 TUI (nvim, helix, fish 4, Claude Code) still gets `ESC a` for Meta-a, exactly the ambiguity the flag exists to remove. (S–M) `KeyEncoder.swift:141-146,208-214,270-283`; `KittyKeyboardProtocolTests.swift:163`
- **1.17 Shift is lost for printables under kitty flag 8/4 and modifyOtherKeys=2.** `keyDown` hands every event to `inputContext.handleEvent`; AppKit answers a plain printable via `insertText`, which encodes with `modifiers: []`. `Shift+A` under flag 8 → `CSI 97u`. Encoder tests pass only because they bypass this path. Fix: stash the in-flight event's modifiers in `keyDown`; use them in `insertText` when `composition == nil`; add a windowed keyDown test. (S) `TerminalView.swift:1823-1832`, `TerminalView+IME.swift:100-101,247-256`
- **1.18 Wheel reporting emits one button-64/65 report per NSEvent regardless of delta**; precise-delta trackpad momentum floods vim/less/tmux with 3-line steps. Accumulate points, emit ⌊acc/cellHeight⌋. (S) `TerminalView+Mouse.swift:463-467`
- **1.19 32/s `PtyWrite` cap silently drops protocol replies** (DA1, CPR, DECRQM, kitty `CSI ?u`, per-cap XTGETTCAP share one budget). tmux attach + nvim startup in one second can exceed it; a dropped DA1/CPR stalls the TUI until its own timeout. Token bucket with burst, or exempt fixed-size replies. (S) `core/src/rate_limit.rs:62`, `callback.rs:270`
- **1.20 `Event::ResetTitle` is dropped.** nvim's XTWINOPS 22/23 save-restore in a shell that never set a title leaves the tab saying "nvim" after exit; RIS also nulls the title with no event. No test. ✔ (S) `core/src/callback.rs:547-550`

### Tabs and windows

- **1.21 Cancelling the close-confirm on the selected tab leaves the user on a different tab**: `onCloseWindow` selects the neighbour before `performClose`, which `windowShouldClose` may refuse. Same closure serves hover × and `deleteBackward`. (S) `TitlebarTabBar.swift:39-47`; `MainWindowController.swift:497-509`
- **1.22 Dragging a fresh ⌘N window clobbers the saved main-window frame**: ⌘N windows are created `autosaveFrame: false` at 800×480, then `windowDidMove` saves that to the single shared key on first drag. Next launch restores 800×480. Seed ⌘N from the saved size, cascade origin only. (S) `App.swift:554-557`; `MainWindowController.swift:269-273,819-840`
- **1.23 The click-run model is keyed on pill index**, which is why eight commits since July each added a guard (cross-strip hand-off, cross-group aliasing, relayout mid-double-click, `+` exemption). The gesture is about a window identity; `ClickTarget.pill(WeakWindow)` makes the mark survive relayout by construction and removes the `ObjectIdentifier(tabGroup)` ABA gate. (M) `TitlebarTabBar.swift:767-770,795,814,912`

### App shell and environment

- **1.24 Child shell gets no `LANG`/`LC_CTYPE`.** Spawn exports TERM/COLORTERM/TERM_PROGRAM only; a Finder-launched app inherits no LANG from launchd, so the login shell runs in the C locale unless dotfiles set one. Every peer synthesizes it from `Locale.current`. Confidence medium; verify with `locale` in a fresh Finder-launched session. (S) `PTY.swift:569-578`
- **1.25 Shell is `$SHELL`-or-`/bin/zsh`**: `pw_shell` is never consulted, so launching from another terminal with a different SHELL changes every tab; no custom shell/command pref; no `X_OK` check before spawn. (S) `MainWindowController.swift:436`; `SessionLifecycle.swift:55-77`
- **1.26 "You're up to date" swizzle discards Sparkle's no-update reason** (`SystemIsTooOld` etc.). The day `minimumSystemVersion` rises above 14.0, old-macOS users are told they are current. (S) `SparkleAlertOverride.swift:226-231`
- **1.27 `confirmMultiLinePaste` is registered, sanitized, honoured, and has no UI**; reachable only via `defaults write`. kitty and Ghostty default the equivalent on. (S) `Preferences.swift:221`; `SettingsView.swift:196-211`
- **1.28 Hang detection is off in Release while the Diagnostics tab promises hang reports** (`BB_HANG_WATCHDOG=1` only). Add a toggle; cap report count/bytes (`HangReportStore` prunes only `.partial`). (S) `App.swift:244-250`; `DiagnosticsView.swift:59-66`; `HangReportStore.swift:112-152`
- **1.29 OSC 52 clipboard *write* is hard-disabled in core with no user control**; nvim-over-ssh, tmux `set-clipboard on` need it and every peer allows writes by default (reads gated). The Swift scrub/cap path already exists and is tested. (M) `Preferences.swift:198-210`; `vendor/alacritty_terminal/src/term/mod.rs:1781`
- **1.30 No way to open Blackbird at a folder**: no `application(_:open:)`, no `CFBundleDocumentTypes`/`CFBundleURLTypes`/`NSServices`, no CLI. `createTerminalController(cwd:)` already exists. (M) `App.swift:458`

### Core / build hygiene

- **1.31 The fuzz harness fuzzes upstream vte, not the vendored fork.** `core/fuzz/Cargo.toml` mirrors only the alacritty patch; the fuzz lockfile resolves `vte 0.15.0` from crates.io, so the blocking CI fuzz job never exercises the 8 MiB OSC cap or the partial-UTF-8 fix. ✔ (S) `core/fuzz/Cargo.toml:17-19`, `core/fuzz/Cargo.lock:787-790`
- **1.32 The OSC-tap fast path is dead in real sessions.** `osc_possibly_pending` is set on any ESC chunk and cleared only by a BEL in an ESC-free chunk; the bundled marks end in ST, so after the first prompt every plain-text chunk runs both parsers (~10–15 % priced by the code's own comment; ~2× on CSI-heavy streams). The throughput gate feeds pure text and never sees it. ✔ (S) `core/src/input.rs:52-80`; `core/tests/throughput.rs:56-75`
- **1.33 After a caught panic the core keeps accepting input on a `Term` in unknown state**; Swift only rewrites the title. Add a `poisoned` flag checked at every mutating entry; Swift stops feeding and offers restart. (S) `core/src/guard.rs:41-80`; `TerminalSession.swift:1129-1140`
- **1.34 `.receive(on: DispatchQueue.main)` on the snapshot sink adds a runloop hop to every publish** (DispatchQueue as a Combine scheduler always dispatches async) and voids the synchronous-resize contract `ResizeController` blocks main to guarantee; the audit-F3 comment claiming it saves a tick is inverted. (S) `TerminalView.swift:1691-1716`; `ResizeController.swift:75-80`
- **1.35 ⌘-held hover rescans the whole grid with a per-row regex on every snapshot** (cache keyed on `sequenceID`); 60 O(rows×cols) scans/s over a repainting TUI. Rescan damaged rows only. (S) `HoverCoordinator.swift:208-220,385-402`; `URLDetector.swift:106-160`
- **1.36 Display link never idles**: 120 wakeups/s per visible window forever, each paying a main hop, `titlebarOnlyTopInset` (an AppKit `contentRect` round-trip) and a FrameKey compare, with blink off by default. Pause after N skipped frames, resume on publish/selection/hover/blink/resize. Measure idle energy first. (S–M) `TerminalView.swift:511-521,739-749,1567-1574`

---

## Tier 2 — worth doing, grouped

### Perf pipeline
- Coalescing discards intermediate damage, so the partial-row path turns off exactly under load (every busy frame is a full rebuild). Accumulate dropped snapshots' damage rows. `SnapshotCoalescer.swift:178-186`; `MetalRenderer.swift:1609-1611`
- Non-renderer consumers (`PromptNavigator:206`, `PaletteApplier:68`, `ResizeController:152/198/277`) take snapshots that drain damage, forcing a renderer full rebuild per prompt mark / palette apply. Add a PEEK flag or a core-side seq id.
- Three byte copies per chunk (`PTY.swift:817` → `Data`; `SnapshotCoalescer.swift:119` → `[UInt8]`) plus `stateQueue.sync` per read iteration. `withUnsafeBytes` straight into the FFI; atomic for `_isRunning`.
- Every snapshot allocates a fresh full `Vec<BBCell>` (20 B/cell) even during a pending DEC 2026 sync update. Pool or damage-only rows.
- Paste throughput capped by a 10 ms drain poll against a ~1 KiB tty queue (≈100 KiB/s) and `Data.removeFirst` memmove per tick. Use a POLLOUT source and a read offset. `PTY.swift:1036-1085`
- Selection drag rebuilds every row every frame (selection lives in `CacheKey`). `MetalRenderer.swift:264-268,1594`
- Per-cell `GlyphKey` hash + `isSelected` closure call in the hot loop; `damagedRows` allocates three times per frame (`[UInt16]` → `[Int]` → `Set`). `GlyphAtlas.swift:453-459`; `CellInstanceBuilder.swift:80`; `BBTerm.swift:939-958`
- Prompt-mark ticks rebuilt (up to 200 CALayers + `controlAccentColor` read) on every publish. `TerminalView.swift:1189-1197`; `ScrollIndicator.swift:182-244`
- Pill titles re-measured with a binary search of `NSString.size` on every draw, incl. 120 Hz live resize. `TitlebarTabBar.swift:660,721-745`
- Refresh fan-in is O(N²) per group change (KVO + `scheduleTabBarRefresh` + `windowDidBecomeKey`, each walking the theme frame with `String(describing:)` per view); every OSC title change broadcasts to all siblings. `TabGroupObserver.swift:210-225,300-331`; `NativeTabStripHider.swift:146`
- `applyEffectiveFont` dedupes on `familyName == wantName`, which never matches a PostScript name or unresolvable name, so every prefs emission rebuilds the atlas for those users. `TerminalView.swift:676,2036-2046`
- Every `Preferences.objectWillChange` emission re-sends `setColorQueryEnabled` per session (one @AppStorage write ≈ 17 emissions). `TerminalSession.swift:858-879`
- `Preferences.shared.osc52Enabled` (@AppStorage) is read on `coreQueue`; mirror into a core-side atomic like `colorQueryEnabled`. `TerminalSession.swift:931`
- Watchdog pings main every 100 ms for the app's lifetime. `MainThreadWatchdog.swift:94`
- Glyph atlas saturation: `flushBarrier` (commit + `waitUntilCompleted` on main) + full `byKey` clear; `GlyphBitmapCache` stops admitting forever at 4096 entries (no eviction); per-tab atlases at 32 pt Retina ≈ 12 MB mono + 47 MB colour each, zeroed via a transient CPU array on every reconfigure. `GlyphAtlas.swift:219,273,519-526`; `GlyphBitmapCache.swift:93,129-142`
- Latency probe measures command-buffer commit, not presentation, and closes on the first non-skipped frame after keyDown rather than the echo; `run-with-probe.sh` measures a Debug build; the PR "latency gate" is a format pin. `TerminalView.swift:1609`; `MetalRenderer.swift:1443`; `bench-latency.sh` defaults (3/10 ms) disagree with CI (6/20 ms).

### Rendering polish
- Colour-emoji edge texels blend over the framebuffer, not `bgColor` (thin halo when selected). Resolved by the premultiplied fix (1.11).
- Block elements are stretched in X only though the comment promises Y; 1 px seams in btop bars / Claude Code avatar. `GlyphAtlas.swift:873-886`
- Fallback-font glyphs with taller ascent (CJK, symbols) can clip at the slot top. `GlyphAtlas.swift:908,1012`
- Selection tint is hardcoded `SIMD4(0.25,0.45,0.90,1)`, opaque, theme-blind, and leaves fg unchanged. `CellInstanceBuilder.swift:81,147`
- No synthetic bold/italic when the face lacks the variant. `GlyphAtlas.swift:658-676`
- Underline/strike geometry fixed in points (hairline at 32 pt). `Shaders.metal:162-224`
- No GPU-fault recovery; renderer init failure is a bare `fatalError` with no dialog. `MetalRenderer.swift:1252-1261`
- `applyTheme` always passes `keepBgOpaque: false`; that `resolveColors` branch is dead. `TerminalView.swift:1042`

### Core
- `bb_term_clear_all` on the alt screen clears the alt grid's empty history; primary scrollback survives ⌘K inside Claude Code and returns on exit, contrary to the doc comment. `core/src/lib.rs:1071-1090`
- OSC 7 paths containing `;` are truncated to the prefix (only `params[1]` read). `core/src/osc.rs:402`
- OSC 133 D exit code truncated to 16 bytes instead of rejected. `core/src/osc.rs:641-642`
- Five hand-copied tumbling-window rate limiters; one `TumblingWindow` + caps table. `core/src/rate_limit.rs`, `lib.rs:216-217`, `input.rs:174-184`
- All core diagnostics go through `eprintln!`; a Finder-launched app's stderr reaches nothing, so every carefully built breadcrumb is invisible in the support scenario it was written for. Route a `BBEventKind::Log` to `os.Logger` and the Diagnostics tab.
- URI intern cache stores each URI twice (String key + `Arc<CStr>`), so the 1 MiB cap is ~2 MiB. `core/src/snapshot.rs:570-576`
- `BBTerm` has 22 fields, eight of them one-shot log latches threaded through `osc_scanner!`. Group into `Breadcrumbs` + `OscTapState`.
- Modes 1007 and 1005 not exposed in `bb_mode`.
- No `vendor/PATCHES.md`; the drift check can run offline against the checksum-pinned registry copies (`~/.cargo/registry/src`) — KNOWN_ISSUES' "needs network" deferral is wrong. Five hunks total, all clean.
- Coverage gaps: no ResetTitle test; nothing asserts the OSC latch clears; no fuzz target drives `bb_term_flush_sync_update` / DEC 2026 abort-replay; nothing verifies the committed `BBCore.h` equals a fresh cbindgen run.

### Terminal layer
- Mouse-report and selection use two different cell-mapping formulas (`sendMouseEvent` clamps to 10 000, ignores `displayOffset`). `TerminalView+Mouse.swift:225-258,611-626`
- `copy(_:)` can cut a UTF-8 sequence at the 16 MiB cap (trailing U+FFFD) and runs extraction on main. `TerminalView.swift:2050-2064`
- `jumpToPreviousPrompt`/`Next` clamp and still return `true`, so the documented "no more prompts" beep never fires. `PromptNavigator.swift:232-256`
- Legacy Ctrl+2/6/-// (NUL, 0x1E, 0x1F) unmapped. `KeyEncoder.swift:837-846`
- Atlas reconfigure failure on display migration logged only in DEBUG. `TerminalView.swift:1540-1546`
- Stale docs: `BBTerm.swift:414-418` says colour queries off by default (on since v0.6.0); `FindController.swift:488-490` says the grid lives on the main actor; the `receive(on:)` comment (1.34).
- `findBarDidClose` reaches into six `FindController` fields; two "clear find state" copies can drift. `TerminalView.swift:1675-1687,2620-2634`
- ~100 lines of DEBUG-only fakes in `TerminalView` (incl. a second copy of the URL regex). `TerminalView.swift:2501-2603`
- Hover re-resolution allocates (`String` + `URL(string:)`) per publish while over a link. `HoverCoordinator.swift:268-275`

### Tabs and windows
- Rapid successive clicks on `+` open only one tab (`clicks == 1` gate swallows every later click of a run). `TitlebarTabBar.swift:985`
- `departureHints` consumed on a non-matching join; "move away, move back" loses the slot. `TabOrderCoordinator.swift:218-220`
- Context-menu open selects the right-clicked tab first ("Close Tab" on a background pill foregrounds it). `TitlebarTabBar.swift:1500`
- Shell-start failure sheet is attached before `showWindow` (RCA A1 still open). `MainWindowController.swift:181`; `SessionLifecycle.swift:121`
- `newWindowForTab:` wired by string selector with the `sendAction` Bool ignored. `TitlebarTabBar.swift:49-51`
- Hover state is three fields reset in lockstep at four sites; `MainWindowController` still carries the Bool flag pile (KNOWN_ISSUES R3 #5) though the `makeForTesting` seam it waited on now exists; dead reimplementation of `NSBezierPath.cgPath` (`TitlebarTabBar.swift:2213-2238`); `applicationShouldTerminate` comment describes a sweep that does not happen; KVO tokens invalidated from inside their own handler; fullscreen fan-out unprobed.

### Settings and packaging
- Missing baseline prefs: scrollback size (fixed 100k, core cap 200k), shell/command, starting directory, line height/padding, audible bell, custom palette / `.itermcolors` import, copy-on-select, cursor colour, keybinding customization (and the ⌃⇥/⌃⇧⇥ app-wide swallow has no opt-out). Documenting the `bb.*` `defaults write` keys gives dotfile users a story without a config parser.
- Option key defaults to Meta (breaks é/ø/– for many layouts); translucency defaults to 5 (≈60 % opaque + blur) where every peer defaults opaque.
- "Confirm quit" label also governs per-tab ⌘W close. `SettingsView.swift:188`; `MainWindowController.swift:500`
- `automaticShellIntegration` reads through the full search list, unlike every other security pref. `Preferences.swift:254-263`
- Theme fallback (`?? .defaultTheme`) disagrees with the registered default (`.gruvbox`). `Preferences.swift:286,404`
- `SUVerifyUpdateBeforeExtraction` unset; Sparkle floor allows 2.6.0. `project.yml:18-20,130-133`

### Product gaps (beyond tier 0/1)
- Prompt marks are collected (incl. exit codes) but only used for ⌘⇧↑/↓; exit-status gutter markers, "Copy Last Command Output", click-to-jump are cheap wins.
- `file://` links from Claude Code are inert by design; Claude Code hyperlinks every path it prints. A safe middle: ⌘-click / context "Reveal in Finder" / "Open in $EDITOR" only for existing paths under cwd or `$HOME`, never `open` on executables.
- Quick-terminal / global hotkey window; session restore of tab count + cwd + titles (not shell state); scrollback export; Dock menu; ⌘E Use Selection for Find; XTVERSION + DECRQSS replies; richer DA1; mode 2031 colour-scheme notification (OSC 10/11 replies already exist); OSC 9;4 progress bars in the tab pill; non-US kitty flag 4/16 via `UCKeyTranslate`.
- tmux/zellij path as first-class since splits are out: OSC 7 passthrough, `default-terminal` snippet, kitty keyboard through tmux; turn the ⚠️ compat rows green.
- No user docs page: settings reference, keybinding reference, shell-integration page, Claude Code page, troubleshooting, and a "why no splits / config / images" positioning page. No real screenshot on the website.

### Tests, CI, scripts
- PR CI never spawns a real PTY shell (`BB_RUN_FLAKY_PTY_TESTS` only in the TSAN nightly); `BB_RUN_WINDOW_LIFECYCLE_TESTS` is set by no workflow; fish tests skip on CI (no `brew install fish`); release-script failure-path tests (`BB_TEST_RELEASE_FAILURE`) never enabled; shellcheck gate silently skips when the tool is missing.
- No `timeout-minutes` on main CI jobs (6 h default on a hung xctest host).
- The two "treat exit 65 as success" fallbacks differ between `scripts/test.sh` and `ci.yml` and both can mask a first-run crash.
- SwiftPM Sparkle artifact flake in `release.yml` has no durable fix (`-clonedSourcePackagesDirPath`).
- `docs/SIMULATIONS.md` and the tab RCA dossier are gitignored; losing the machine loses them.
- No test file references `TabGroupObserver` (488 lines), `PromptNavigator` (325), `PrefsMaintenance` (280) or 14 smaller collaborators; `makeView(` is defined 14 times across test files; `ScrollIndicatorBlindTests.swift:18` references a `#if false` block that no longer exists; `CellInstanceLayoutTests.swift:503` ends in `XCTAssertTrue(true)`.
- No pixel-level render test of any shader path (would have caught 1.11, 1.14, and the emoji halo); `decideRebuildRows`/`planRowRebuild`/`computeBlinkSkip` are pure but private and untested; source-regex "pin" tests (`MetalRendererTests.swift:973-1110`, `MetalDrawableCountSourcePinTests`) fail on harmless refactors and pass on real regressions; no windowed `keyDown`→`insertText` modifier test; no `scrollWheel` test at all; no backlog-depth, feed-to-present, or find-over-100k-lines gate; no pref↔UI parity test (would have caught 1.27); no Info.plist↔project.yml pin; no test for `check-security-posture.sh` itself.
- `dependabot.yml` covers only GitHub Actions; `smoke.sh` picks an arbitrary DerivedData dir.

---

## Structural programs (each closes a cluster above)

1. **Runner + toolchain migration (deadline 2026-10-05).** `macos-15` + `macos-26` matrix, Xcode 26.x, dry `workflow_dispatch` release run. Closes 0.1, 0.2.
2. **Release funnel automation.** One `## [X.Y.Z]` changelog entry feeds the GitHub release body and `sparkle:releaseNotesLink`; `publish-update.sh` bumps the cask; `cut-release.sh` gates on green CI, changelog presence, and a SECURITY.md "reviewed against" stamp. Split KNOWN_ISSUES into open vs. resolved. Closes 1.1–1.8.
3. **Bounded snapshot ingress.** One byte budget between the read loop and the parser, a single publish path (today: `publishPendingSnapshot`, `publishImmediate`, the burst watchdog, plus a Combine hop), main-side core work off `.sync`, incremental find/hover keyed on damage rows + `linesScrolled`, display link paused when idle. Closes 0.7, 0.8, 1.34–1.36 and most of the perf tier 2.
4. **Per-group `TabGroupModel`.** Each window's strip renders a shared per-group model (order, selection, hover, click run, drag, rename) via `TabDescriptor { id, weak window, title, isSelected }`. Deletes the process-wide `lastMouseDown` static, the group-ID gate, the sweeps, and the `[NSWindow]` cycle; makes the strip testable without real windows and shrinks the parked-window test rule to a handful of env-gated AppKit integration tests. Closes 0.6, 1.21–1.23, and the tab tier 2.
5. **Premultiplied compositing.** One shader formula for mono and colour glyphs; then the half-texel inset and cell-continuous decoration phase. Closes 1.11, 1.13, 1.14, emoji halo. Add an offscreen readback test harness first.
6. **Grapheme-keyed atlas + run-level shaping.** Carry the cluster (or an id) in `BBCell`; key `GlyphKey` on it; shape contiguous same-attribute runs with `CTTypesetter`. Closes 1.12, ligatures, ZWJ, keycaps in one project (L).
7. **Kill the second parser.** Both crates are already forks; an `Event::UnhandledOsc` + DCS passthrough hook lets OSC 7/133/XTGETTCAP/`CSI > 4 m` ride alacritty's parser. Removes the tap, the latch (1.32), and its cost. Pair with `vendor/PATCHES.md`, an offline drift script, the fuzz patch mirror (1.31), and upstream PRs for the three genuine fixes.
8. **Diagnostics that reach users.** Core log events → `os.Logger` + Diagnostics tab; watchdog toggle in Release with a report cap; `poisoned` core state Swift can act on. Closes 1.28, 1.33, the `eprintln!` item.
9. **Spec-driven conformance and blind lifetime tests.** Table-driven KeyEncoder tests from the kitty spec's own examples per flag set; windowed keyDown→bytes tests; weak-ref dealloc tests for ex-group windows; pref↔UI parity; pixel readback for shaders. Closes 1.16, 1.17, and the test-gap cluster.

## Suggested order

1. Program 1 (runner migration) — hard deadline, small.
2. 0.3 (Intel storage mode), 0.4 (alt-scroll), 1.15 (empty damage), 1.11 (premultiplied blend), 1.31 (fuzz patch), 1.20 (ResetTitle), 1.3 (auto-update prompt), 1.27 (paste-confirm UI): all S, all high-confidence, ship together as a v0.8.1 correctness patch.
3. Program 2 (release funnel) before the next tag so v0.8.1 has notes, a cask bump, and a green-CI gate.
4. 0.6 (window leak) + 1.21/1.22, then Program 4 if the click-run patches keep coming.
5. Program 3 (bounded ingress) — the one that changes the app's worst-case behaviour under load.
6. 0.5 (notifications + bell) and the Claude Code positioning items, with the upstream PR in parallel.
7. Programs 5 → 6 → 7 as renderer/core quarters.

---

## Status (2026-09-09)

Implemented on `main` after the sweep, in the order the dossier suggested
(see CHANGELOG `[Unreleased]` for user-facing wording and the commit
messages for mechanism):

- **Tier 0:** all seven — runner/Xcode migration (0.1, 0.2), Intel texture
  storage (0.3), alternate scroll (0.4), Claude Code notifications + bell
  attention (0.5), ex-group window leak (0.6), find scrollback capture
  (0.7), PTY→parser backpressure (0.8).
- **Tier 1:** all except 1.12 (grapheme-keyed atlas / combining marks) and
  1.23 (click-run model keyed on window identity); both are Program 6 / 4
  work and remain open.
- **Tier 2:** perf (empty-damage path, snapshot hop, hover incremental
  rescan, idle display link, wheel pacing, find coalescing, pref-sink
  dedupe, watchdog cadence, bitmap-cache eviction); rendering (UV inset,
  synthetic bold/italic, theme selection colour, font-metric decorations);
  core (alt-screen ⌘K, OSC 7 `;`, OSC 133 D reject, DA1, XTVERSION,
  DECRQSS, poison choke point); terminal (copy cap, prompt-jump beep,
  Ctrl+digit chords, reconfigure log, stale docs, wheel reset on mode
  change); tabs (context-menu selection, departure hints, typed `+`
  selector, cgPath duplicate); settings (confirm-quit label, persistent-
  domain reads, theme default constant, Sparkle floor + pre-extraction
  verify, scrollback size, copy-on-select, shell + LANG + notification +
  hang-detection prefs); product (OSC 52 writes, open at folder, Dock
  menu, ⌘E, export scrollback); CI/scripts (fish + shellcheck, release-
  script failure cases, SwiftPM flake, dependabot, smoke DerivedData,
  bench defaults, tracked dossiers).
- **Tests:** twenty blind-authored suites plus retargeted pins.

Still open (deliberately, or sized beyond this pass): Program 4
(`TabGroupModel` / weak strip references), Program 6 (grapheme-keyed
atlas: combining marks, ZWJ, keycaps, ligatures), Program 7 (fold the OSC
tap into alacritty's parser; `vendor/PATCHES.md` + offline drift script),
`eprintln!` → structured core log events, selection out of `CacheKey`,
per-cell hash table, mouse-report/selection mapping unification,
`file://` reveal, quick-terminal window, session restore, custom palette
import, mode 2031, kitty flag 4/16 non-US layouts, prompt-mark gutter
markers, website docs pages/screenshots, PR-CI PTY job, pixel-level
shader tests, fixture dedupe, the Option-Meta / translucency defaults
(product calls left as they were), and the `+` double-click policy (RCA
decision kept).
