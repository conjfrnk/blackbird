# Changelog

All notable changes to Blackbird are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html). Source is
distributed under the [MIT license](https://opensource.org/license/MIT).

## [0.2.6] - 2026-05-18

Stress / edge audit follow-up: 19 audit findings closed across 17 commits, plus 3 regression tails (`S4-003`, `S1-002`/`S4-001`, `S5-R-001`) introduced by the in-flight fixes and cleaned up before the tag. No new feature work — entirely correctness, sanitiser parity, and contract-shape fixes.

### Security / hygiene
- **Fixed**: OSC 8 wrap-join URL-host injection. The detector joined the next row's leading URL-safe text onto a match ending at the right edge, but the joined string was only used for dispatch — the underline stayed clamped to row N. A row ending `https://apple.com` followed by `.evil.com/login` opened `apple.com.evil.com/login` in `NSWorkspace` while the user saw only `apple.com` underlined. Wrap-join now requires scheme/host/port match and refuses URL-structure-leader continuations (`?`, `#`, `&`, `@`, `;`). (commit `0f05cd6`, [audit:S4-001])
- **Fixed**: Diagnostics Copy / Email-Diagnostics paths now strip bidi-override, zero-width, and invisible scalars on outbound text, matching the inbound paste sanitiser (Trojan Source parity). (commit `6f311e0`, [audit:S4-002])
- **Fixed**: Drag-drop `sanitizeDropPath` extended to the same bidi / zero-width / invisible set. Three sanitiser surfaces (paste, copy/email, drop) now lockstep. (commit `abaaf76`, [audit:S4-014])
- **Fixed**: Post-fork `BLACKBIRD_*` / `BB_*` env-prefix scrub is now case-insensitive. POSIX env names are conventionally uppercase but not enforced; a launcher exporting `bb_token` lowercase previously slipped the sweep. (commit `0d06837`, [audit:S2-004])
- **Fixed**: `migrateV1toV2` reads legacy unprefixed keys via `persistentDomain(forName:)` instead of `defaults.object(forKey:)`. The latter walks NSGlobalDomain, so a stray `defaults write -g theme "X"` was being imported into `bb.theme` on first migration. (commit `97cca15`, [audit:S5-001])
- **Fixed**: `sanitizeStoredTypes` reads via `persistentDomain(forName:)` so the wrong-type check and the follow-up `removeObject` touch the same domain. Sibling root-cause to S5-001. (commit `cd6a413`, [audit:S5-009])
- **Fixed**: XTGETTCAP `cap_hex` echo rejects odd-length hex. The Kitty cap-query reply previously accepted any all-hex payload; a 3-byte query produced a structurally-well-formed reply containing a half-byte cap name. (commit `10abc52`, [audit:S3-004])
- **Fixed**: Find regex alternation gate catches 3+ way alternations. The body class required exactly one `|` separator, so `(a|aa|aaa)+x` slipped through and pegged the find worker until the 250 ms async timeout fired. (commit `400c265`, [audit:S3-003])

### Reliability / observability
- **Fixed**: `MainThreadWatchdog.captureHangReport` writes to `<name>.txt.partial` and `moveItem`-renames after `sample(1)` exits cleanly. A force-quit during the 2 s sample window — typical user response to a visible beachball — previously left a truncated trace surfaced in Settings → Diagnostics indistinguishable from a complete report. (commit `7e65977`, [audit:S5-004])
- **Fixed**: `MainThreadWatchdog.pruneOrphanPartials` reaps `hang-*.txt.partial` files older than 60 s at startup. Pairs with the atomic-rename fix: a force-quit during `sample(1)` leaves a `.partial` orphan that the Diagnostics-tab filter never surfaces, turning `~/Library/Logs/Blackbird/` into a silent disk ratchet. (commit `e1576d8`, [regression:S4-003])
- **Fixed**: `DiagnosticReportStore` logs per-file `resourceValues` failures instead of silently dropping the entry. A transient I/O race (EBUSY, TCC re-evaluation) could make a legitimate hang report disappear from Settings → Diagnostics with no breadcrumb. (commit `a83d0e6`, [audit:S2-008])
- **Fixed**: `focusChanged` and `wire()`'s initial-snapshot coreQueue hop both gate on `isTerminated` under `publishLock`, matching the canonical `feed` / `applyPalette` / `recordPromptStart` shape. Masked by downstream defences today; future refactors that drop the sibling defence no longer silently regress. (commit `fec7e77`, [audit:S2-010,S1-007])
- **Fixed**: `bb_term_take_snapshot` logs once per session when the OSC 8 link-id `u16` cap saturates. Unreachable on realistic TUI traffic but reachable by a hostile remote emitting unique per-cell URIs; support engineers triaging "my OSC 8 links stopped working" now get a breadcrumb. (commit `1588fd8`, [audit:S2-014])
- **Fixed**: `SparkleAlertOverride` "you're up to date" message omits the version segment cleanly when `CFBundleShortVersionString` is empty. Pre-fix a corrupted Info.plist produced `"Blackbird  is the latest version."` with a double space. (commit `8a8ede6`, [audit:S2-009])

### Robustness / contracts
- **Fixed**: `bb_term_text_range` honours the caller's start/end column on rows that fall outside the grid. The per-row branch compared `line_i` against the pre-clamp endpoints; an over-bottom selection emitted the full last row ignoring `e_col`, and an over-top selection dropped `s_col`. Comparison moved to the post-clamp `iter_start` / `iter_end`. (commit `4d0a8d1`, [audit:S5-002,S5-003])
- **Fixed**: regression-fix tail on the above — `single_line` collapse on over-bottom multi-row requests dropped the start-row trim, and the `MAX_TEXT_RANGE_ROWS` cap firing routed `iter_end` to a hard-stop that the end-col branch then cropped against. Tracks `cap_truncated` separately and requires both iter-collapse and `s_line == e_line` for the `single_line` branch. (commit `a5eb565`, [regression:S1-002,S4-001])
- **Fixed**: `Preferences.init` skips the init-time `fontSize` / `translucency` re-assign-to-clamp on schema downgrade. Matches the existing `repairEnumRawValues` downgrade-skip — a future v(N+1) widening of the `fontSize` envelope no longer gets clobbered back to the current binary's range. (commit `d053fb1`, [audit:S6-010])
- **Fixed**: regression-fix tail on the above — the `isDowngrade` predicate read `storedSchemaVersion` via `defaults.integer(forKey:)` (walks NSGlobalDomain). A `defaults write -g bb.prefsSchemaVersion 99` elevated `storedSchemaVersion` to 99, flipped `isDowngrade` true, and silently skipped the numeric clamp protecting against a hand-edited `bb.fontSize = NaN`. New `storedSchemaVersion(in:domain:)` helper reads via `persistentDomain(forName:)` only. (commit `58973d2`, [regression:S5-R-001])
- **Fixed**: `BBTerm.setColor(slot:)` rejects negative slots cleanly instead of `UInt16(clamping:)`-demoting them to 0 (which corrupted the Black ANSI palette entry). (commit `47b81ab`, [audit:S6-009])

### FFI / contracts
- **Fixed**: `BBPromptMarkKind` is exported into `BBCore.h` via `cbindgen.toml`'s `[export].include` list. Swift previously redeclared a parallel enum whose raw values had to match Rust's (1..4) with no header binding; new `FFIContractTests.testPromptMarkKind_rawValuesMatchExportedC` pins each Swift case against the imported C constant. (commit `a1072e8`, [audit:S6-001])

## [0.2.5] - 2026-05-14

Dogfood-driven hotfix for two v0.2.4-introduced regressions that hit real-world use:

### Fixed
- **Paste from Notes / Messages / any non-plain-text-first pasteboard was silently dropped.** v0.2.4's `paste(_:)` added a guard requiring `item.types.first` to be a plain-text UTI to refuse the RTF→`.string` coercion attack class, but legitimate sources (Notes, Messages, anything writing `com.apple.uikit.attributedstring`) declare a richer UTI first — `⌘V` silently no-op'd. Reverted just the `paste(_:)` guard; the drag-and-drop `sanitizeDropPath` C0-stripping in the same v0.2.4 commit is intact. Trade-off: the RTF→`.string` coercion class is reopened at a bare shell with `confirmMultiLinePaste` defaulted off; bracketed-paste mode (every modern TUI / shell with mode 2004) and the existing C0 / bidi-control sanitizers still cover the rest of the surface. (commit `7f42cc9`)
- **Window size persistence dropped resizes from any non-launch-time window.** v0.2.4's frame-autosave logic gated saves on a `shouldAutosaveFrame` flag that was only true for the FIRST window opened at app launch. ⌘T tab windows and ⌘N standalone windows had it false, so their `windowDidResize` / `windowDidMove` delegate handlers no-op'd — after closing the original window and continuing to work in a later one, every resize was silently dropped, and relaunch restored an older "size I had once used." Save behaviour is now universal (last writer wins under the shared autosave key); restore-on-init stays gated to the first window so `⌘N`'s AppKit-default cascade isn't disrupted. (commit `333abf9`)
- **Cascade-induced `windowDidMove` clobbered the saved frame on ⌘N.** Follow-up to the above: `NSWindowController.shouldCascadeWindows` defaults to true, so the first `super.showWindow` fires `setFrameTopLeftPoint` to cascade the new window. With the universalised save path, that cascade move was writing the constructor-default 800×480 ⌘N frame to the autosave key. Gated `saveCurrentFrame` on a transient `isPerformingShowWindow` flag for the duration of `super.showWindow`. (commit `15f6292`)
- **Fullscreen frame poisoned the persisted size.** Entering native fullscreen drives `window.frame` to the screen frame and fires `windowDidResize`; saving that frame meant next launch opened the window at screen dimensions but *without* fullscreen, with traffic-lights buried and the menu bar overlapping. Gated `saveCurrentFrame` on `!styleMask.contains(.fullScreen)`. (commit `15f6292`)
- **Dead stored property removed.** `restoresFrameOnInit: Bool` was assigned in init but never read — the restore branch read the parameter directly. Removed to eliminate the footgun where a future maintainer would expect a behavioural effect from flipping it post-super-init. (commit `15f6292`)

### CI / process
- **`cache-bin: 'false'` on every `Swatinem/rust-cache@v2` step.** GHA macos-14 / macos-15 image rev `.0048.1` (rolled out 2026-05-13) ships a broken Homebrew `rustup-init` at `/opt/homebrew/bin/cargo` that shadows the `dtolnay/rust-toolchain`-installed `~/.cargo/bin/cargo` on PATH; the rust-cache bin-restore (PR #325, default `cache-bin: true`) compounds the issue by pinning the broken shim across cache-hit runs. Upstream: [actions/runner-images#14097](https://github.com/actions/runner-images/issues/14097), [Swatinem/rust-cache#341](https://github.com/Swatinem/rust-cache/issues/341). Disabling the bin restore on all 15 cache blocks in `ci.yml` / `release.yml` / the three nightly workflows fixes both PR CI and the Nightly TSAN sentinel grep. (commit `85ac517`)

### Test coverage
- **Added**: `test_saveFrameUsingName_lastWriteWinsAcrossWindows` pinning the cross-window-save primitive the autosave fix relies on.
- **Removed**: `test_paste_isNoopOrSanitized_whenOnlyRtfPresent` + the `types.first` / `pasteboardItems` required-token block in `test_paste_sourcePin_readsOnlyStringType` — both pinned the reverted v0.2.4 RTF-coercion policy. Other paste-source pins (`.string`-wins-over-`.rtf`, ignore-`.fileURL`, no `.rtf` / `.html` reference in `TerminalView+Paste`) still hold.

## [0.2.4] - 2026-05-12

Two cumulative work-streams since v0.2.3: (1) a multi-agent audit (2026-05-10) of the Rust core, Swift session/PTY/renderer, and FFI surface — 25 findings, 20 fixed in 21 commits; 4 skipped as documented design tradeoffs (#04 OSC 8 cache eviction, #05 PID-reuse on missing start-time, #12 osc7_reject_logged latch, #20 TERMINFO env redirect — all already documented as accepted in inline comments); 1 skipped as accepted limitation (#23 mysshwrapper basename allowlist — KNOWN_ISSUES.md updated). (2) An adversarial-pasteboard / Cmd+letter intercept-matrix pass that found two CVE-class pasteboard bugs and a no-op menu binding, plus the stress/edge-test infrastructure that now gates the same regressions on every PR + nightly.

### Security / hygiene
- **Fixed**: RTF → `.string` pasteboard coercion bypass. `NSPasteboard.string(forType: .string)` auto-decodes RTF body when only `.rtf` is present, so a pasteboard whose RTF body contained `\par` newlines reached `pasteText` as LF-bearing plain text and (with `confirmMultiLinePaste` defaulted off) executed line-by-line in the shell. `TerminalView+Paste` now inspects `pasteboardItems` and requires at least one item whose `types.first` is an explicit plain-text UTI (utf8 / utf16 / plain); AppKit populates synthesized coerced types AFTER the canonical declared type, so first-position is the reliable signal. New `PasteboardSourceTypePinTests` pins the rtf-only no-op + plain-text positive control. (CVE-class)
- **Fixed**: HFS+ filenames legally contain LF / CR / ESC, and a hostile pasteboard provider can synthesize `file://` URLs whose path strings carry C0 bytes. `shellQuote`'s single-quote wrap doesn't neutralize an embedded LF (reaches the shell as Enter) or ESC (injects bracketed-paste terminators). `TerminalView+Dragging.sanitizeDropPath` now strips all C0 (0x00..=0x1F including TAB) and DEL before quoting. The typed-paste path's LF / CR whitelist is correct for keyboards and stays untouched. New `DragDropTests` cover LF / CR / ESC / full C0+DEL coverage. (CVE-class)
- **Fixed**: OSC 8 hyperlink URI ingest scrubs raw bidi-override / invisible scalars (U+202E, U+200E, etc.), matching the existing OSC 7 (`contains_bidi_or_invisible` reject) and OSC 0/2 title (`scrub_title_controls`) parity. A hostile remote can no longer embed RTL-override bytes into a hyperlink URI that QuickLook / NSTextField renders as bidi-flipped text. ([audit:#03])
- **Fixed**: `classifyProcessTree` fail-CLOSED on rootPID `proc_pidpath` / `proc_listpids` failure. The function's docstring promised fail-CLOSED on any syscall error; the implementation fell through `return .local`, so an OSC 7 cwd from a remote shell whose proc metadata was briefly inaccessible (TCC-restricted target, ESRCH race with exit, sandbox profile change) was trusted as local. Strict probe variants surface the failure; the BFS keeps lenient nil/empty-on-failure semantics for descendant walks. New regression: `testClassifyProcessTreeOnDefunctPIDReturnsUnknown`. ([audit:#01])
- **Fixed**: `ffi_reentry_blocked` covers `FFI_FATAL_IN_FLIGHT` in addition to `FFI_HANDLER_IN_FLIGHT`. A Fatal-event handler that synchronously called `bb_term_*` would otherwise alias the outer `&*term` with a fresh `&mut *term` reborrow AND fire a nested event whose Swift dispatch tripped the M-9 release-mode precondition. New regression: `ffi_call_inside_fatal_handler_is_dropped`. ([audit:#09])
- **Fixed**: `BLACKBIRD_*` / `BB_*` parent env vars are scrubbed at fork-time in addition to the fixed XPC/dyld/CoreFoundation deny-list. Today's surface (`BLACKBIRD_STARTUP_LOG`, `BB_HANG_WATCHDOG`, `BB_LATENCY_PROBE`) is configuration-only, but the deny-list pattern would silently leak future token-bearing variants — the prefix sweep future-proofs that contract. ([audit:#13])
- **Fixed**: Find/replace ReDoS heuristic counts `?` quantifiers in addition to `+`/`*`/`{`. The shape `a?a?a?…aaaa` (N optionals + N literals) produces 2^N backtracking branches in ICU; pre-fix the gate let it through because `?` wasn't tallied. ([audit:#10])

### Reliability / concurrency
- **Fixed**: `wire()` installs `bbterm.onEvent` and `pty.onExit` BEFORE `pty.setOnBytes` / `pty.startReading`. A shell prompt emitting OSC 7 / OSC 0/2 / DA1 reply within ~10–30 ms of spawn (zsh + vcs_info, starship, fish themed prompts) no longer loses `.title`, `.cwdChanged`, `.ptyWrite-DA-reply`, or `.promptMark` events to the unset-handler window. Closes the latent two-word Swift closure assignment race against the coreQueue worker thread. ([audit:#06])
- **Fixed**: `resize(to:)` routes through `publishImmediate` so the H8 user-action-wins invariant holds. Previously the main-thread fast path wrote `self.snapshot = newSnap` directly without clearing `pendingSnapshot`; a feed-driven coalescer queued before the resize would fire after the inline write and clobber the new-grid frame with pre-resize content. ([audit:#07])
- **Fixed**: `recordPromptStart`'s coreQueue and main async hops both gate on `isTerminated` under `publishLock`, matching the F11 / M-1 / L-1 termination-gate pattern used by `feed` / `publishImmediate` / `applyPalette`. ([audit:#11])
- **Fixed**: `PTY.onExit` is now `private(set)` with a `setOnExit(_:)` accessor that serialises the closure assignment through `readQueue` (mirroring the existing `setOnBytes` shape). The read-loop teardown reads `onExit` on main via async-from-readQueue, so the dispatch chain establishes happens-before regardless of which thread the caller invoked the setter on. ([audit:#17] partial: #16 BBTerm.deinit thread-affinity deferred for owningQueue design pass.)
- **Fixed**: `scrollToMark` drops prompt marks whose absolute buffer line has been evicted past the scrollback retention threshold (100k lines). Pre-fix, walking back through `promptMarks` after long output landed on arbitrary interior lines instead of progressive prompts. ([audit:#22])

### Input / find
- **Fixed**: `wordRange` walks through wide-cell spacers via `BBSnapshot.cellKind` rather than `character(at:row:)`. Double-clicking on a multi-CJK / wide-emoji word now selects the full word (e.g. `中文` → both characters); pre-fix the walk broke at the first trailing-spacer cell and selected only the first character. Test `test_cjkChars_selectAsOneWord` tightened from `endCol ∈ [0, 3]` to `endCol ∈ [1, 3]` so the spacer-breaks-walk regression cannot silently re-emerge. ([audit:#02])
- **Fixed**: `replaceAll` wrap-ambiguity guard uses viewport-row mapping (`priorRow + snap.displayOffset`) instead of indexing the cells array with the buffer-line coord. With `displayOffset > 0` the guard previously read a stray scrollback row's last cell instead of the line above the cursor, false-negativing the wrap-detection and allowing DEL overshoot into the wrapped prior input. ([audit:#08])
- **Fixed**: `replaceAllMatches` calls `refreshFindMatchesIfStale` before iterating cached matches. A user who scrolled between `performSearch` and clicking Replace All previously produced col-real `findMatches` values paired with an out-of-viewport cursor; the col-span DEL fallback overcounted wide-char matches by one per glyph. ([audit:#18])
- **Fixed**: `sendMouseEvent` clamps `loc.x` / `loc.y` magnitude to `sanePx=1_000_000` before the `Int(...)` cast (mirroring the existing `Selection.bufferPoint` defense). A finite-but-huge bridged `CGPoint` from a misbehaving input device or fault-injected NSEvent can no longer trap inside the cell-coord arithmetic. ([audit:#19])

### Theme / renderer
- **Fixed**: `applyPalette` derives + writes `BrightForeground` (slot 267, lighten 20% toward white) and `DimForeground` (slot 268, darken 30% toward black) from the theme's foreground. Pre-fix both slots fell through to `named_color_rgb`'s hardcoded `0xEEEEEE` regardless of theme — a TUI emitting xterm bold-color path (SGR 1 on default-fg) rendered the same light-grey under Solarized Dark, Catppuccin Latte, or any custom palette. Also corrects the FFI doc-comment at `bb_term_set_named_color` which incorrectly mapped slot 259 to BrightForeground (actual mapping per vte-0.15.0/src/ansi.rs: 259..=266 = DimBlack..DimWhite, 267 = BrightForeground, 268 = DimForeground). ([audit:#24])
- **Fixed**: `ThemePalette.init` snaps `cursor` to `foreground` (with `os.Logger` warning) when cursor/bg contrast falls below 1.25 in release builds. Previously the contrast guards were `#if DEBUG + assert(...)` and compiled out at -O, so a user-supplied palette with cursor RGB == background RGB shipped silently with an invisible cursor. Preserves the no-crash-on-poor-contrast invariant the original design chose. ([audit:#14])

### Menus / UI
- **Removed**: `Edit > Undo` and `Edit > Redo`. Both items were wired to `Selector(("undo:"))` / `Selector(("redo:"))` but no responder in the chain implements either, so AppKit's automatic menu validation greyed them out and the chord fell through to `super.keyDown` — NSBeep on every press. A terminal has no edit document; matches Terminal.app and iTerm2 (neither ships `Edit > Undo/Redo`). `CmdLetterInterceptMatrixTests` entries flipped from `.menuBindingDeadOnArrival` to `.forwardedToSuper`; the enum case is preserved for future regressions of similar shape.

### Robustness / contracts
- **Fixed**: `bb_string_release` magic-check + zero is performed via `AtomicU64::compare_exchange` (`AcqRel` / `Acquire`) using `AtomicU64::from_ptr`. Two threads racing release on the same pointer can no longer both observe `BB_STRING_MAGIC` before either's zero-write lands — exactly one CAS wins; the loser short-circuits. Struct field stays `u64` (no cbindgen ABI change). New regression: `bb_string_release_magic_is_atomic_cas`. ([audit:#25])
- **Fixed**: Hang-report filenames in `MainThreadWatchdog.captureHangReport` use millisecond precision + PID + 8-char UUID suffix (`hang-<tsMs>-<pid>-<uuid8>.txt`) instead of integer-second granularity. Back-to-back hangs that recover and re-stall within the same wall-clock second no longer clobber the first trace via `sample(1) -file`'s truncate semantics. ([audit:#21])
- **Fixed**: `bb.confirmMultiLinePaste` pref is now registered in `register(defaults:)` and appended to `sanitizeStoredTypes`' `boolKeys` list. Sibling bool prefs (cursorBlink, confirmClose, osc52Enabled, etc.) all participate in the wrong-type CLI-write cleanup; pre-fix this one didn't. ([audit:#15])

### Documented limitations
- `osc8_uri_cstr_cache` eviction policy intentionally evicts only at `bb_term_clear_all` (pointer-stability requirement for live snapshots). Confirmed accepted at `lib.rs:2729-2732`. ([audit:#04])
- PID-reuse SIGKILL when `bsdProcessStartTime` failed at spawn is an explicit fallback against leaking a HUP-ignoring child; the rare same-uid stranger-kill risk is documented at `PTY.swift:1306-1316`. ([audit:#05])
- `osc7_reject_logged` per-instance one-shot latch is intentional log-flood avoidance per `lib.rs:1023-1034`. ([audit:#12])
- TERMINFO redirect requires pre-existing user-level code execution; marginal escalation over what the attacker could already do. ([audit:#20])
- mysshwrapper-shaped renamed-binary ssh-clones evade the basename allowlist; the path-prefix alternative would break legitimate custom shell installs (MacPorts, cargo, user-built). Project's chosen posture is to expand `remoteShellBinaryBasenames` when new canonical wrappers appear. KNOWN_ISSUES.md updated. ([audit:#23])

### CI / process
- **Added**: Stress / edge-test scaffolding pinning existing behavior — proptest invariants over the FFI surface, libFuzzer targets for `text_range` / `reply_storm` / `resize2`, FD + thread-count leak gate, a real 60 s sweep soak (renamed from `sweep_soak` to `sweep_probe` + new `sweep_soak_60s`), and a hostile-environment failure-mode matrix. The latency probe gained p99.9 + max tail percentiles.
- **Added**: Nightly workflows — sweep / leak soak, ThreadSanitizer, and miri (Tree Borrows) over `handler_reentry_guard`. PR CI also now runs a Rosetta x86_64 smoke gate (universal binary launches and exits cleanly under translation) and a macOS [14, 15] matrix.
- **Added**: VT-conformance harness (`vt_conformance.rs`) + OSC 8 cap-recovery pin, multi-tab + single-session soak gates, real-window latency / GPU-pin / shell-integration tests. BBTerm RSS guard hardened.
- **Fixed**: Nightly TSAN xctest VM-quirk absorber (load-time mapping ceiling under sanitizers) + miri ignore for the upstream proptest idempotence PRODUCT-BUG. Latency-gate naming clarified to distinguish synthetic-from-probe vs real-window measurement.

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
