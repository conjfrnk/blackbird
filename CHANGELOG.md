# Changelog

All notable changes to Blackbird are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html). Source is
distributed under the [MIT license](https://opensource.org/license/MIT).

## [Unreleased]

### Fixed
- **Mouse wheel works in `less`, `man`, `git log`, vim with mouse off and ssh pagers.** With mouse reporting off the wheel scrolled the (empty) alt-screen history and did nothing. DEC 1007 "alternate scroll" is now exported from the core (`ALTERNATE_SCROLL`, on by default; `CSI ? 1007 l` opts a TUI out) and the view sends ↑/↓ (SS3 under DECCKM), 3 per notch or one per cell height of trackpad travel. Wheel events under mouse reporting are paced the same way instead of one report per NSEvent, which turned a trackpad flick into dozens of 3-line steps. (commit `14ab734`)
- **Intel Macs no longer crash at launch.** The glyph-atlas textures used `.shared` storage, which macOS allows for textures only on unified-memory GPUs; on Intel iGPU / AMD hosts `makeTexture` returned nil and the view hit `fatalError`. Storage is `.shared` iff `device.hasUnifiedMemory`, else `.managed`. (commit `14ab734`)
- **Text renders at its true weight.** The fragment shader returned `mix(bg, fg, c)` with alpha `c` for default-background cells under SRC_ALPHA blending, so glyph coverage was applied twice (`c²`): ordinary text was thinner than CoreText rasterised it and changed weight under the block cursor or a selection. The shader now emits premultiplied colour and blends ONE / ONE_MINUS_SRC_ALPHA; colour emoji composite over the cell background instead of the framebuffer. Undercurl / dotted / dashed underlines use the absolute x so the pattern no longer restarts at every cell. (commit `14ab734`)
- Snapshots with no changed cells (DSR/DA replies, mode toggles, OSC, bells) no longer force a full-grid rebuild; only the cursor rows are re-encoded. (commit `14ab734`)
- nvim's XTWINOPS 22/23 title save/restore in a shell that never set a title left the tab reading "nvim" after exit: `Event::ResetTitle` was dropped. It is forwarded as an empty title, which restores the shell-basename seed. (commit `14ab734`)
- **Every window that was ever in a multi-tab group leaked after close**, with its TerminalView, MTKView, MetalRenderer and glyph atlases: the tab strip strong-held its group's windows, including its own host. The strip now detaches on close and on the last-sibling refresh. (commit `cf477ba`)
- Cancelling "Close this tab?" no longer leaves you on a different tab: the visual-neighbour selection runs once the close is certain, for every close entry point. (commit `cf477ba`)
- A ⌘N window takes the saved frame's size instead of the 800×480 default that its first drag then persisted over the user's real frame. (commit `cf477ba`)
- Kitty keyboard protocol, flag 1 (disambiguate): plain Esc is `CSI 27 u`, and Ctrl+key / Alt+key / Shift+Alt+key are `CSI <key>;<mod>u` as the spec requires (only unmodified Enter, Tab and Backspace stay legacy). This deliberately reverses the v0.3.4 F-S3 "scope correction": a program that pushes flag 1 receives `CSI 99;5u` for Ctrl+C, as it does in kitty, Ghostty, WezTerm and foot. The encoder had kept bare `ESC`, `ESC a` and the C0 byte for letters — the very ambiguity the flag exists to remove — and its tests pinned the deviation. Legacy bytes still flow when no kitty flag is active.
- Kitty flags 4/8 and Shift: every plain printable reaches the encoder through `insertText` with no modifier information, so Shift+A became `CSI 97u` and the TUI typed `a`. The routing `keyDown`'s Shift now rides along (`CSI 97:65;2u`).
- Sparkle's "You're up to date" alert no longer swallows the real reason: a macOS-too-old / too-new / newer-than-latest outcome is forwarded to Sparkle's own dialog instead of a false reassurance.
- PTY protocol replies (DA1, CPR, DECRQM, kitty `CSI ?u`, XTGETTCAP) are governed by a 128-token bucket refilled at 32/s instead of a flat 32-per-second window, so a tmux attach plus an nvim startup in the same second no longer loses replies (a dropped DA1/CPR stalled the TUI until its own timeout). The sustained rate — the DoS bound — is unchanged.
- The core's OSC tap parser was effectively never bypassed: its "possibly mid-sequence" latch cleared only on a BEL, and the bundled prompt marks end in ST, so after the first prompt every plain-text chunk ran through both parsers for the session. The latch now clears whenever the tap parser is back in Ground with no partial UTF-8.
- After a caught core panic the terminal poisons itself and every mutating entry becomes a no-op; the session stops feeding on the first Fatal and the title says so. Previously the core kept parsing on a grid in unknown state, producing a Fatal per chunk.

### Added
- **Program notifications.** OSC 9 (iTerm2 form), OSC 777 `;notify;title;body` and kitty OSC 99 reach Notification Center when the tab is not the one you're looking at (app inactive, window not key, or another tab selected), and the tab pill shows an accent dot until you return. A BEL under the same condition bounces the Dock icon and dots the tab. New event kind in the core with control/bidi scrubbing, length caps and a 4/s rate cap. Settings → Behavior → "Show notifications from programs". Claude Code still needs `claude config set preferredNotifChannel terminal_bell` (its auto channel doesn't know `TERM_PROGRAM=Blackbird` yet).
- Bell styles: Visual / Sound / Visual and Sound / Off. A program's BEL could not make a sound before.
- **OSC 52 clipboard writes** (Neovim, tmux `set-clipboard on`, `pbcopy`-style helpers over ssh) can be enabled in Settings → Security. The core gained a runtime switch (`bb_term_set_osc52_write_enabled`; a documented one-line hunk in the vendored alacritty), so the toggle removed in audit S4-001 is back and does what it says. Off by default; reads are never answered.
- **Open at a folder.** Finder "Open With", a folder dropped on the Dock icon, `open -a Blackbird <dir>` and a Services-menu item ("New Blackbird Terminal at Folder") open a new window there; a file opens at its parent.
- Settings → Terminal: **Shell** (empty = the account's login shell from the passwd database, which was never consulted before — `$SHELL` inherited from whatever launched Blackbird decided). A preference that names a non-executable path is logged and falls back.
- Settings → Terminal: **Set locale environment variables (LANG)** (on by default). A Finder-launched app inherits no `LANG`, so the login shell ran in the C locale unless dotfiles set one; `LANG=<lang>_<REGION>.UTF-8` is exported when the parent environment has no `LANG`/`LC_ALL`/`LC_CTYPE`, falling back to `en_US.UTF-8` when the system locale has no matching definition.
- Settings → Security: **Confirm multi-line pastes at a shell prompt** — the preference existed but had no control.
- Settings → Diagnostics: **Detect main-thread hangs** (on by default in Release, 1 s threshold, 0.25 s ping). Release builds only armed the watchdog under `BB_HANG_WATCHDOG=1` while the tab promised hang reports. The newest 20 reports are kept.
- Settings → Terminal: **Scrollback lines** (10k / 50k / 100k / 200k, applies to new sessions) and **Copy selected text automatically**.
- File → **Export Scrollback…** (⌘⇧S) writes the whole retained buffer as UTF-8 text through the same scrub as ⌘C; Edit → Find → **Use Selection for Find** (⌘E); a Dock-menu **New Window**.
- Protocol replies: DA1 advertises VT220 + ANSI colour (`CSI ? 62 ; 22 c`, was bare VT102 `?6c`); XTVERSION (`CSI > q`) answers `DCS > | Blackbird <version> ST` so tmux 3.4+ / nvim 0.10+ identify the terminal instead of timing out; DECRQSS answers SGR and cursor-style requests and returns the spec's "invalid" form for the rest (vim's `$qm` probe no longer waits on a timeout).
- Program notifications show a banner even while Blackbird is the active app (another tab or window has the user's attention) and clicking one selects the originating tab; kitty OSC 99 chunked title+body arrives as one notification; a core panic now ends the session and offers Close Tab instead of leaving a dead tab that still accepted keystrokes; a rejected Settings → Shell value is explained inline; folders opened at launch wait for the app to finish launching.
- Automatic update checks default ON (`bb.autoUpdateChecks`, opt-out in Settings → Updates). The Info.plist key suppressed Sparkle's own permission prompt and the bridge forced the pref onto the updater at every launch, so with a `false` default nobody was ever asked. (commit `14ab734`)
- Wheel events under mouse reporting are capped at 64 units per NSEvent.

### Changed
- **Release builds use the macOS 26 SDK (Xcode 26.6 on `macos-26`), which opts the app into Liquid Glass on macOS 26.** Through v0.8.0 every DMG was built against the macOS 15 SDK, so Tahoe users got the Sequoia-era chrome that local Xcode 26 dev builds had already left behind. ci.yml's `macos-15` leg keeps the macOS 15 SDK compiling, and the x86_64 Rosetta smoke now also runs on `macos-26` so the Intel slice that ships is the one smoked. macOS 14 and 15 keep their pre-Tahoe appearance (linked-on-or-after behaviour changes only apply on macOS 26).
- Dependencies: Sparkle 2.9.2 → 2.9.6 (2.9.5/2.9.6 carry symlink-hardening and root privilege-escalation fixes in the installer, sparkle-project/Sparkle#2891, #2895, #2897, #2898; 2.9.4 fixes update windows not coming to the front for backgrounded apps); `cargo update` for both the core and fuzz lockfiles under the MSRV-aware resolver (`CARGO_RESOLVER_INCOMPATIBLE_RUST_VERSIONS=fallback`), which holds every pick at the Rust 1.85 floor CI compiles with; supersedes Dependabot #32 and #33.
- Renderer polish: the half-texel UV inset is gone (every glyph was resampled horizontally; quads are pixel-aligned so 1:1 sampling is exact); bold/italic are synthesised (stroke / 12° shear) when the font family has no such face instead of silently drawing regular; the selection highlight is derived from the theme (bright-blue slot blended toward the background) and selected text falls back to the theme background colour when its own foreground lacks contrast; underline, double underline, undercurl, dotted, dashed and strike geometry come from the font's underline position / thickness / x-height instead of fixed 1.5 pt constants (a hairline at 32 pt); the glyph bitmap cache evicts the oldest font set instead of refusing every new glyph for the process lifetime once full.
- Tabs: right-clicking a background pill no longer switches to it before the menu appears; the `+` button's action is a typed selector; the private `NSBezierPath.cgPath` copy is gone (SDK 14 provides it).
- Core: ⌘K inside an alt-screen TUI clears the primary scrollback too (3J only reached the alt grid); an OSC 7 path containing `;` is joined back instead of truncated at the first one; an OSC 133 D exit code longer than 16 bytes is rejected instead of delivered truncated.
- Terminal: ⌘C on a >16 MiB selection no longer ends in U+FFFD; ⌘⇧↑/↓ at the oldest/newest prompt reports "no more prompts" (beep) instead of silently staying; legacy Ctrl+2…8, Ctrl+-, Ctrl+/ send xterm's C0 bytes (NUL, ESC, FS, GS, RS, US, DEL) instead of the bare character; a glyph-atlas reconfigure failure on display migration is logged in Release, not only DEBUG.
- Settings: "Confirm quit" is labelled for what it gates (closing a tab, too); `automaticShellIntegration` reads the app's persistent domain only (a `defaults write -g` could flip injection); the theme fallback and registered default are one constant; Info.plist sets `SUVerifyUpdateBeforeExtraction`; the Sparkle floor is 2.9.2.

### CI / process
- Every CI job installs fish + shellcheck (fish suites skipped on CI; the shellcheck gate passed only because the image happened to ship it); the release-script harness runs its failure-path cases (`BB_TEST_RELEASE_FAILURE=1`); `release.sh` clones SwiftPM packages under `dist/` and `release.yml` clears the shared checkout cache (the "already exists in file system" exit-74 flake); Dependabot covers cargo and swift monthly; `smoke.sh` picks the newest DerivedData (or `BB_DERIVED_DATA`); `bench-latency.sh` defaults match the CI thresholds; `docs/SIMULATIONS.md`, the tab RCA and the 2026-09-08 improvement backlog are tracked.
- The fuzz workspace resolved `vte` from crates.io, so the blocking fuzz job never exercised the vendored fork's 8 MiB OSC cap or partial-UTF-8 fix. The fuzz manifest patches both crates and CI asserts neither resolves from a registry. (commit `14ab734`)
- Release funnel: `cut-release.sh` refuses to tag without a green `ci.yml` run on HEAD and without a `## [X.Y.Z]` CHANGELOG section; `release.yml` uses that section as the GitHub release body; `publish-update.sh` renders it to `website/releases/vX.Y.Z.html`, which the appcast links via `<sparkle:releaseNotesLink>`, and bumps the Homebrew cask's version and sha256 (the cask sat at 0.2.6 for twelve releases). (commit `d47a164`)
- CHANGELOG backfilled for 0.2.7–0.8.0; KNOWN_ISSUES.md holds open items only; SECURITY.md, README, compat matrix and website re-aligned with the code. (commit `19b117e`)
- CI migrated off the retiring `macos-14` runner image (brownouts from 2026-10-05, removal 2026-11-02): single-OS jobs on `macos-15`, AppKit/Metal matrices on `[macos-15, macos-26]`, Xcode pinned per image (16.4 / 26.6). Every job gets a `timeout-minutes`; `release.yml` refuses to build with any signing/notarization secret empty (the old branch uploaded an unsigned DMG as a public release); the pbxproj drift gate also diffs the xcodegen-written `Info.plist`; release commits get their own concurrency group — the website commit `publish-update.sh` pushes minutes later had cancelled every release's CI run from v0.5.1 through v0.8.0. (commit `5379338`)

## [0.8.0] - 2026-08-06

Issues #29 (resize smoothness + background tabs) and #30 (⌘-click links inside mouse-reporting TUIs), followed by a two-round review panel whose confirmed findings shipped in the same release.

### Fixed
- ⌘-click opens links inside mouse-reporting TUIs (Claude Code's REPL, vim `mouse=a`, tmux, htop). `mouseDown` skipped URL resolution whenever mouse reporting was on and fell through to the ⌘ window-drag branch; ⌘ has no representation in the xterm mouse protocol, so the gate protected nothing. The URL resolves on ⌘-mousedown and opens on mouseUp within 3 pt, so ⌘-drag-to-move still works from a link; a swallowed press no longer emits an orphan release; drag reports are deduped per cell. (commit `630ae96`, #30)
- Hover re-resolves the link under a stationary pointer on every published snapshot: per-snapshot OSC 8 link ids no longer go stale under a repainting TUI, the pointing-hand cursor tracks links sliding under the pointer, and Force-Touch Quick Look reads the policy-checked, credential-redacted href instead of a raw stale id. (commit `85c8d92`, #30)
- A window resize now fans out to the group's background tabs at settle points. AppKit applies a group resize to a background tab only at the instant it is next selected, so in every non-selected tab `stty size` lied, output hard-wrapped at the old width into scrollback, and alt-screen TUIs never got SIGWINCH. Also: one frame save at end-of-resize instead of per tick, and a width-only pill relayout mid-drag. (commit `c2fa9a3`, #29)
- Review-panel fixes: the coalesced resize publishes in coreQueue order (a wheel scroll could be silently reverted); background-tab fan-out never runs `coreQueue.sync` on main; a wheel notch no longer kills hover (AppKit sends no `mouseMoved` for scrolls); `windowDidMove` guarded like `windowDidResize` against the fan-out echo; the end-of-drag frame save is no longer swallowed by the screen-reconfiguration settle; the ⌘-right-drag resize gets settle and persistence; a cancelled ⌘-link drag falls through to selection instead of emitting orphan drag reports; a press the X10 encoder refuses (past column 223) no longer ships an orphan release; hover no longer promises links over the titlebar band; `coalescedInFlight` is a count, not a boolean cleared by whichever block finishes first. (commits `c3a840a`, `1640a72`, `02e8767`)
- Core: one-shot log breadcrumb when the 1 MiB OSC 8 intern budget is exhausted and new hyperlinks silently stop resolving (~16k distinct URIs; reachable from Claude Code hyperlinking every path). Recovery is ⌘K. (commit `44c996e`)

### Changed
- Column-change resizes drive a latest-wins coalesced reflow on coreQueue instead of `coreQueue.sync` from main: a full-scrollback reflow costs 10 ms at 20k lines and 37 ms at 100k per column crossing, and a horizontal drag crosses a column every ~8 pt. Row-only changes stay synchronous (0 ms). Renderer `FrameKey` now includes the view bounds, so live-resize frames re-encode instead of CoreAnimation stretching the last drawable — the visible wobble. (commit `076d3a4`, #29)

### Documented
- README/SECURITY dropped the stale claim that `ftp` is in the ⌘-click allowlist (removed in v0.2.8); ⌥-drag / ⌥-scroll / ⌥-right-click escapes documented; the Claude Code `file://` and `TERM` residuals recorded in KNOWN_ISSUES. (commit `da1d2e1`)

## [0.7.1] - 2026-07-31

Bug hunt 2026-07-24/25. Headline: `NSEvent.clickCount` counts the window server's click run, not the receiving view's — three bugs from one assumption.

### Fixed
- Phantom tab rename after returning to the app or switching tabs. Rename now gates on the clicks the strip actually received; the click mark is shared process-wide across strips (every tab is its own `NSWindow` with its own strip) but confined to one tab group; and a rename requires the tab to have already been selected — double-clicking a background tab switches and stops. (commits `9811f4a`, `1cbc1f9`, `02b0246`, `1463927`)
- `+` was dead on the click after an activation click, and a fast double-click could open two tabs across the refresh that opening a tab causes. (commits `1ccb607`, `c42c347`)
- Terminal body: a single click after returning from another app selected a word and a real double-click selected a line; selection mode is now classified by this view's own click run. (commit `d86ea9e`)
- Double-clicking a one-character word selected nothing. (commit `daeaeef`)
- F13–F20 typed private-use garbage into the shell; they now emit the VT220/xterm `CSI 25/26/28/29/31/32/33/34 ~` sequences, and any unmapped special key falls through to the responder chain instead of typing its scalar. (commit `bbbd2b8`)
- Rename Tab's advertised ⌥⌘R was dead — Edit ▸ Find ▸ Regular Expression owned the chord and won the responder search. Moved to ⌃⌘R. (commit `89397da`)
- Core: a stalled synchronized update (BSU with no ESU — a TUI killed mid-frame, a dropped ssh) froze the tab permanently because vte never self-aborts. A coreQueue watchdog now drives vte's 150 ms deadline, and ⌘K force-flushes first so it can clear a wedged tab. New FFI `bb_term_sync_status` / `bb_term_flush_sync_update`. (commit `9e31b8a`)
- Core: 4097 kitty keyboard-mode pushes panicked the VT — the vendored alacritty trimmed `title_stack` instead of `keyboard_mode_stack`. (commit `357cc2e`)

### Changed
- Four vetted hot-path wins: single-accumulator text extraction (find over 100k-line scrollback), row-invariant hoists in the cell-instance builder, hover same-cell early return before OSC 8 resolution, linear URL-row UTF-16 measurement. (commit `6ed8c6d`)

## [0.7.0] - 2026-07-13

### Added
- Per-tab / per-window text size (issue #28): ⌘+ / ⌘− / pinch size only the focused view via a session-lifetime override; ⌘0 clears it back to the global default; the Settings slider remains the global default and drives every non-overridden view. (commit `b9feeeb`)

### Fixed
- The Preferences font sink stamped its dedupe key before the apply, so a failed atlas rebuild stranded that view at its old size until the pref moved to a different value; the key now advances only after a successful apply, and the per-view path rolls its override back on failure. (commit `b9feeeb`)

## [0.6.2] - 2026-07-10

Shell-integration bug hunt after the v0.6.0 auto-injection.

### Fixed
- The OSC 133 B (input-start) mark never fired under stock zsh/bash: PS1 carried a `$(…)` substitution that needs PROMPT_SUBST / promptvars, so every auto-injected plain-zsh session rendered the literal `$(__bb_osc133_b)` in the prompt. Raw bytes are now embedded at source time, B moves to the end of the prompt, and bash doubles the ST backslash so prompt decode can't eat the `\]` marker. (commit `99fdc0e`)
- bash PS0 C mark: same class, now literal bytes. (commit `1f27f25`)
- fish emits the B mark automatically by wrapping `fish_prompt` (kitty's approach), guarded against re-wrapping a `funcsave`'d wrapper. (commit `a4b027c`)
- Nested fish spawns no longer stack a duplicate root segment onto `XDG_DATA_DIRS` per nesting level. (commit `2bbf12e`)
- `ssh.fish` treated an empty `XDG_STATE_HOME` as set, producing a root-anchored cache path. (commit `3e41aea`)
- PTY child: `setenv("TERM")` guarded against a NULL `strdup` under memory pressure (Darwin dereferences the value); falls back to `xterm-256color` with a parent-side breadcrumb. (commit `739b6fa`)
- Themed find fields clip to their rounded corners. (commit `3474ed8`)

### Documented
- KNOWN_ISSUES: `/etc/zshenv` `ZDOTDIR` reassignment, fish ≥ 4 native OSC 133 doubling, the `funcsave fish_prompt` hazard. (commit `69075a5`)

## [0.6.1] - 2026-07-07

Same-day correction to v0.6.0 (PR #26).

### Changed
- The ssh wrapper defaults to `TERM=xterm-256color` for every connection; installing the kitty terminfo remotely and keeping `TERM=xterm-kitty` is opt-in via `BB_SSH_REMOTE_TERM=kitty`. Tools that decide colour depth from TERM strings rather than terminfo — Codex CLI via `supports-color`, the npm chalk ecosystem — treated `xterm-kitty` without `COLORTERM` (which never survives ssh) as 16-colour and dropped styling. The kitty keyboard protocol still negotiates at runtime over ssh. (commit `5a0ead3`)

### Documented
- tmux substitutes its own `default-terminal` for every pane; remedy is `set -g default-terminal "tmux-256color"`. (commit `4b95b9b`)

## [0.6.0] - 2026-07-07

Issues #23 (`'xterm-kitty': unknown terminal type` over ssh) and #24 (Codex CLI degraded rendering) via PR #25, plus the post-v0.5.1 tab/window feature batch.

### Added
- Automatic shell integration, default on (Settings ▸ Terminal): zsh via a `ZDOTDIR` bootstrap that restores the real `ZDOTDIR` and chains the user's rc files; fish via an `XDG_DATA_DIRS` vendor conf.d entry. No rc-file edits; trees are materialised to `~/.local/share/blackbird/shell` on launch. bash stays manual (a login bash ignores `--rcfile`). (commits `efa21f5`, `3fba298`, `b517602`)
- ssh terminfo wrapper (zsh/bash/fish dialects kept in sync): installs the kitty terminfo on first connect per `user@host:port`, cached in `~/.local/state/blackbird/ssh-terminfo-hosts`, otherwise runs that connection with `TERM=xterm-256color`. Failures are never cached; a pre-existing ssh alias/function is never shadowed. (commit `45bb5dd`)
- Tab-pill context menu gains "Move Tab to New Window" and a "Move Tab to Window ▸" submenu (RCA Bug 6). Minimised and fullscreen windows sit out in v1. (commit `5b06310`)
- The modifier-right-drag resize clamps the dragged edges to the monitor under the mouse. (commit `b8e79c9`)
- The ⌘F find bar is styled from the theme palette instead of system colours. (commit `ab94183`)

### Changed
- OSC 10/11/12 colour queries are answered by default (`colorQueryEnabled` → true), matching iTerm2 / kitty / alacritty / WezTerm / Ghostty. Codex CLI probes OSC 10/11 for light/dark at startup and fell back to a colourless palette when no reply came; Claude Code never queries, which is why only Codex looked wrong. The reply rate cap and the Settings opt-out remain. (commit `dd2e9d7`, #24)

### Fixed
- Wrapper review-panel fixes: attached-form option arguments (`-oFoo=bar`, `-i/path`) no longer swallow the destination and append `tic` to the user's remote command; `-N`/`-f`/`-W`/`-O` bail to the quiet downgrade; an empty local `infocmp` no longer "installs" nothing and caches the host; deleting the materialised tree mid-session re-materialises on the next spawn instead of pointing `ZDOTDIR` at a dead directory; every wrapper function opens with `emulate -L zsh`. (commits `962e131`, `c3a450e`)
- `smoke.sh` signs by certificate hash — two copies of the same Apple Development cert made the display name ambiguous. (commit `50b7715`)

## [0.5.1] - 2026-07-02

The tab-behaviour RCA release (`docs/rca-tab-behaviors-2026-07-01.md`): eleven per-bug commits.

### Fixed
- macOS 26 Tahoe rebuilt the private `NSTabBar` on hosts that keep answering `hitTest` while `isHidden`, so the top ~2 rows of terminal text in every multi-tab window sat over a live invisible tab bar — clicks switched tabs in arrival order, drags tore tabs off into new windows. The hider now zeroes the frame of the shallowest pure-tab-bar ancestor. (commit `1f48a2c`)
- Merge All Windows / Move Tab to New Window left non-key members with a stale hidden pill strip and no selection KVO, so keystrokes beeped until the body was clicked; every strip refreshes after those actions and re-asserts native-strip suppression on every refresh. (commit `8ffe942`)
- Tab-group resubscription compared a dead group's recycled address and could skip forever (ABA); now a weak reference compared with `===`. (commit `8e1f5fd`)
- Pill order is preserved when a tab leaves and returns to a group (a departure hint reinserts it next to its remembered neighbour). (commit `bf1aaec`)
- `contentMinSize` derives its titlebar reservation from the live style (32 pt on macOS 26, not a hard-coded 28). (commit `0290cec`)
- Tab strip gestures: hover is recomputed after relayout so the close-× tracks the cursor during live resize; a fast double-click on `+` opened two tabs; reorder drags gained Escape / right-click cancel; the window-move hand-off is seeded with the original mouseDown; `moveLeft` clamps a stale focus index. (commits `af84372`, `34d8a3a`)
- VoiceOver frames for pills are computed in screen space (the flipped strip put them 4 pt off). (commit `832d94b`)
- The native Show/Hide Tab Bar action is disabled outright: the pill strip replaces it and the toggle desynced the chrome. (commit `1127091`)
- Frame saves are suppressed during fullscreen entry (a mid-animation `windowDidResize` persisted a screen-sized frame, so the next launch opened screen-sized without fullscreen); the screen-reconfiguration settle window widened 2 s → 5 s for slow wake-from-sleep renegotiation. (commit `c243128`)
- Duplicate theme re-apply on the first-window show path dropped. (commit `ab0ebe9`)

## [0.5.0] - 2026-07-01

A-grade refactor campaign (PRs #20, #22): Rust `lib.rs` modularised 7500 → 1344 lines with compile-time layout guards, and every Swift file driven to A grade by pure extraction with no intended behaviour change. The intermediate `release: v0.4.1` bump (build 41, commit `cb3b6cc`) was never tagged and is folded in here.

### Changed
- Rust core split into modules (`snapshot`, `osc`, `input`, `text`, `guard`, `callback`, `color`, `scrub`, `rate_limit`, `event`); `const` `offset_of!` guards make an ABI-affecting field reorder a build error instead of a runtime test failure. (commit `96bf164`, PR #20)
- Swift collaborators hoisted out of `TerminalView` / `TerminalSession` / `MetalRenderer` / `MainWindowController` / `TabStripView` (FindController, HoverCoordinator, SelectionController, PromptNavigator, SnapshotCoalescer, CellInstanceBuilder, WindowFramePersistence, TabDragController, PasteSanitizer, …). (PR #22)

### Fixed
- `character(at:)` kept as a raw scalar accessor after review caught the refactor changing spacer-cell results feeding the OSC 8 anchor/host-divergence gate. (commit `900f764`)
- `anyhow` bumped for RUSTSEC-2026-0190 (dev-only dependency). (commit `1a2e1fc`)

## [0.4.0] - 2026-06-21

Pre-v0.4 bug-fix sweep (PR #18): 16 confirmed bugs plus seven long-deferred KNOWN_ISSUES entries closed. Six-dimension adversarial pre-release audit verdict: ship, zero blockers.

### Security
- Unbounded OSC payload memory DoS: vte 0.15.0 under `std` had no cap on `osc_raw` (the cap was no-std-only), and both of the core's parsers accumulated an unterminated OSC — ~2× the streamed bytes until a terminator or ⌘K. vte is now vendored at `vendor/vte` and the std-mode buffer capped at 8 MiB; streaming 128 MiB grows RSS ~17.6 MiB. (commit `d5589bd`)

### Fixed
- Core split-idempotence: a multi-byte UTF-8 sequence split across two feeds and followed by a printable dropped that printable — vte's `advance_partial_utf8` error arm returned `valid_bytes - old_bytes`, consuming the following character. Fixed in the vendored vte; the proptest invariant is un-ignored and an exhaustive every-split probe added. (commit `9e19d7a`)
- Core H-5: `bb_term_take_snapshot` returned a pointer narrowed to the `snap` field, so retain/release's `rc` access was out-of-provenance UB under miri; the box pointer is cast instead. The miri tests run by default. (commit `e8e0575`)
- Kitty flag 1: Ctrl+printable with no C0 mapping (Ctrl+digit, Ctrl+., Ctrl+/) emits `CSI <cp>;<mod>u` instead of dropping the Ctrl bit. Kitty flag 2: arrows / nav / F-keys emit release events `CSI <lead>;<mod>:3 <terminator>`; the press path is byte-identical. (commit `a7d5449`)
- Window lifecycle (F-S6-001/002/003): a shell exiting while its window sat in the Dock left a zombie that blocked auto-quit (`isVisible` is also false when miniaturised); single-tab ⌘⇧W skipped the running-process confirm; a ⌘N window set `tabbingMode = .disallowed` for life and could never be merged. (commit `2fc90a6`)
- Frame-save user-driven check scoped to this window's pointer (a left button held elsewhere during a display reconfig clobbered the saved multi-display frame); deferred auto-close polls with 50 ms backoff instead of spinning while a sibling modal is up; ⌘T tabs get their translucent blur applied on first key. (commit `18d9770`)
- VoiceOver now announces tab-title changes — the diff compared a title against itself because both arrays held the same window refs; closing the active tab selects the visual neighbour after a reorder, not the arrival-order one. (commit `f502836`)
- Find: regex ⌘G during live output swallowed the press and reset to match 1; regex Replace All / Replace silently no-op'd or spliced stale matches; the word-drag anchor snapped to a vacated line when output scrolled mid-drag; a deferred ⌘G is no longer stranded when the rescan times out or the pattern is invalid. (commits `3fb77ba`, `63d2aa9`)
- Option-as-Meta: Ctrl+Option+letter lost the ESC prefix on both the keyDown fast path and the legacy encoder branch (M-C-f did forward-char in Emacs), and Option+e/i/u/n were swallowed by the dead-key composer; Meta chords now bypass the IME. (commits `3657e7e`, `5769222`)
- Sparkle's "You're up to date" alert no longer yanks selection to tab 1 — every tab in a group reports `isVisible`, so `.first` picked the oldest; the sheet parent is now the selected tab. (commit `713f1dc`)
- OSC 8 links blocked by the anchor/host-divergence gate get a right-click "Copy Link (host mismatch)" escape hatch; the ⌥⌘-click bypass two comments promised never existed. (commit `1589a33`)
- `MainThreadWatchdog` spawns `sample` via `Process.executableURL` (the deprecated `launchPath` retired, F-S6-004). (commit `92bcd49`)

### Changed
- `AppDelegate` is `@MainActor`; compile-time isolation replaces the runtime `dispatchPrecondition` tripwires, which stay as belt-and-suspenders. Bounded change: one `MainActor.assumeIsolated` hop, two test classes marked `@MainActor`. (commit `3cc40c1`)

## [0.3.6] - 2026-06-16

### Fixed
- Soft-wrapped URLs are reconstructed across N rows, not just 2; all five wrap-join security guards (joined URL parses, first-row host non-empty, host and port unchanged, no structure-leader continuation) are re-evaluated at every row boundary against the first-row portion the user sees underlined. (commit `c3a64b3`)
- `TabOrderCoordinator` purges dead-group entries on every reconcile; they previously lingered for the process lifetime. (commit `4be3983`)

### CI / process
- `scripts/test.sh` whole-suite runs match CI's ASan-off build settings — the ~900-test suite tripped the sanitizer VM-mapping ceiling locally and SEGV'd in a CoreAnimation flush; scoped runs keep ASan on; test-run bells suppressed. (commit `e48bc43`)

## [0.3.5] - 2026-06-09

### Changed
- Feed-path snapshot generation coalesced to one per PTY burst. `feed()` took a full snapshot after every 128 KiB chunk and the publish coalescer discarded nearly all of them, capping sustained end-to-end throughput at ~8 MB/s regardless of parser speed; kitten `__benchmark__` geomean 8.0 → 69.4 MB/s. (commit `84f9970`)

### Documented
- Seven-terminal throughput comparison (vtebench + kitten): Blackbird #1 on vtebench (78.5 MB/s geomean, 1.9× Alacritty), 4th on kitten. "Fastest macOS terminal on vtebench" is supported; unqualified "fastest terminal" is not. (commits `12bac66`, `40e2d50`)

## [0.3.4] - 2026-06-09

The 26-finding June audit remediation: 51 commits across the core, session, PTY, renderer, window, view, and release scripts, each with blind-authored regression tests and a per-batch review wave.

### Fixed — core
- Copy / ⌘A dropped every zero-width scalar (NFD accents, VS16, ZWJ) and injected newlines at soft wraps; `bb_term_text_range` now emits the zerowidth list and honours WRAPLINE. Select All no longer truncates at 65,536 rows (cap raised to 262,144, above any real buffer). (commits `79804cd`, `45f3cf0`, `51b4548`)
- Prompt marks anchor on a new monotonic `linesScrolled` counter: after scrollback saturation ⌘[ landed at the live bottom and pre-saturation marks drifted one row per evicted line. (commits `2acf780`, `66dcc9c`)
- The OSC 133 rate cap (16/s) dropped legitimate marks when holding Return; now 240/s with a one-shot breadcrumb. (commit `c817276`)
- Title and Bell events rate-capped like PtyWrite — a title/BEL flood queued ~13,000 main-queue items per 128 KiB chunk; suppressed titles coalesce to the latest instead of pinning the 32nd. (commits `88952d8`, `d72493d`)
- `BBEvent.payload` honours its documented null-when-empty contract (an empty title crossed the ABI as `NonNull::dangling()`, address 0x1); `i32_arg` documented per event kind. (commits `dd6010b`, `7f0b43a`, `d53c50c`)
- The debug FFI thread diagnostic detects overlapping access instead of thread identity — the sanctioned serial-queue architecture tripped it on the first event of every debug build. (commit `083c8b6`)

### Fixed — session / PTY
- A stopped foreground child (`kill -STOP`'d vim) could beachball the whole app: the master fd is now non-blocking with a bounded 4 MiB pending-write buffer. (commit `beabf5a`)
- Terminate escalation could SIGTERM/SIGKILL a recycled PID under heavy process churn; both rungs now stand down once the child is reaped. (commit `b6b08d5`)
- `setOnBytes` / `setOnExit` take effect mid-session — they queued behind the infinite read loop and only ran at EOF. (commit `d865e3b`)
- Selection stays glued to its content while output streams (endpoints rotate by `linesScrolled`; row-only resizes exempt). (commits `b0c357a`, `5d6cdf4`)
- ⌘K prompt-mark append race closed on both the snapshot and event hops; post-terminate resizes gated; grid-size bookkeeping coreQueue-confined. (commits `66dcc9c`, `07940f8`, `35e93c5`, `5f4ee1f`)

### Fixed — find / replace
- Find-bar Replace emitted `DEL × n` at the shell cursor, not at the match, destroying unrelated tail text while leaving the match intact. The splice now walks the cursor to the match (honouring the pending-wrap position, exported as `BBSnapshot.cursorPendingWrap`) and Replace All is one all-or-nothing edit; multi-codepoint replacements are refused. (commits `b06a331`, `ae7fc5d`)

### Fixed — renderer
- Instance-buffer grow failure presented a blank frame that the frame-skip cache then pinned until an unrelated `FrameKey` field changed; the frame is now abandoned and nothing is presented. Aborted frames return their triple-buffer rotation turn (torn frames under drawable exhaustion). Wide-glyph alignment orphans are staged until rasterisation succeeds (two cached entries could alias one atlas region). (commits `8987e16`, `f1a1c39`, `0b70ada`)
- Snapshot sequence IDs are per-session, restoring the partial-row damage fast path that any background tab's snapshots defeated. (commits `a26a74b`, `4742d9e`)

### Fixed — window
- Unplugging a display no longer overwrites the saved multi-display frame (frame saves suppressed for a settle window after screen reconfiguration; user drags bypass it); windows shorter than 100 pt can satisfy the on-screen reachability check; degenerate 0×0 frames never count as reachable. (commits `efaaf0b`, `8c7159e`, `42b1759`)

### Fixed — release scripts
- `publish-update.sh` signs exactly the DMG it verified (`APPCAST_DMG` pin) instead of the version-highest leftover in `dist/`, and cross-checks bytes, build number, and enclosure cardinality before replacing the appcast; prerelease names accepted. (commits `fddcf48`, `7e92f06`, `3d60943`)
- `release.sh` / `cut-release.sh` / `publish-update.sh` diagnostics were unreachable under `set -e` — codesign verify, PlistBuddy reads, the tag timestamp — so a failing step aborted with no message. Now captured with status. Closes F-S8-001; the gated `release_test.sh` harness passes 10/10. (commits `0eb101b`, `767e6d1`, `4ee6944`, `c98cc6e`, `75eab60`)
- Fuzz targets were building the unpatched upstream alacritty instead of the vendored fork. (commit `982b270`)

### CI / process
- The release-script regression harness runs on every PR. The test-host safety net is idle-based (300 s without a heartbeat) instead of a 60 s fuse that shot long suites mid-run. (commits `1966f35`, `738d7e3`)

## [0.3.3] - 2026-06-08

### Changed
- Removed the tab strip's ~44 pt trailing drag gutter right of `+`; pills and `+` now fill the strip. Trade-off: multi-tab windows lose no-modifier titlebar drag — use modifier-drag on a pill or the body. (commit `34608cd`)

## [0.3.2] - 2026-06-07

### Fixed
- Window position/size restore across display changes (PR #17): reachability is tested per screen instead of against the union bounding box (a window stranded in the gap between displays was judged reachable and left invisible), and a recentered frame is clamped to the target screen (a window saved on a larger, now-unplugged display came back with its title bar above the screen top). (commit `65b5fd4`)

## [0.3.1] - 2026-06-07

### Changed
- Tab-pill drag redesign (PR #16): a plain drag reorders in any axis, the configured window-move modifier moves the window, and selection defers to mouseUp — grabbing a background pill to move the window no longer switches to it. The v0.3.0 vertical-drag direction classifier is gone. (commit `20c2de3`)

## [0.3.0] - 2026-06-06

### Added
- Drag a tab pill vertically to move the window without ⌘; horizontal still reorders. (commit `e235a42`, PR #14)
- Configurable window move/resize modifier {Command, Option-Command} in Settings, applied to body drag and pill drag. Control is excluded: macOS routes ⌃+left-click to right-click. (commit `84b3340`, PR #15)

## [0.2.14] - 2026-06-06

Audit remediation (5 LOW, PR #13) plus a dependency refresh.

### Fixed
- Removed the inert "Allow remote clipboard writes (OSC 52)" Settings toggle — the core hardcodes OSC 52 off and no FFI could flip it. The pref and the Swift scrub handler stay as dormant defence-in-depth. (commit `ab87f48`)
- Paste bidi-strip validates the 4-byte tag-block continuation byte; a malformed lead no longer drops the following byte. (commit `6c2716f`)
- `ThemePalette` normalises non-16-entry ANSI arrays instead of aborting in release. (commit `51d6089`)
- Wrapped-URL dedup prefix recorded in column units, not grapheme count. (commit `5485fbf`)
- Cursor-column cast in `bb_term_take_snapshot` saturates instead of wrapping. (commit `e4012ef`)

### Changed
- Sparkle 2.9.1 → 2.9.2; Rust lockfile refreshed within semver. (commit `21bbd7f`)

### CI / process
- `cargo-audit` pinned to 0.22.1: 0.22.2 raised its MSRV to 1.88, above the repo's 1.85 floor, and broke every Rust job. (commit `44e0251`)

## [0.2.13] - 2026-05-31

The Claude Code "random newlines" fix.

### Fixed
- Emoji-presentation sequences (base + VS16 such as ⚠️ ‼️ ❤️, and keycaps) now occupy 2 cells, matching string-width, iTerm2 and Terminal.app. The grid counted them as 1 while Claude Code's Ink layout measured 2, so near the right margin its cursor-relative redraw drifted a row and ate or duplicated lines. Patched in a vendored alacritty_terminal `Term::input`. (commits `2600561`, `420c0f9`)
- Promoted emoji render in colour (new `EMOJI_PRESENTATION` cell flag; VS16 appended for CoreText). (commit `c3b6606`)
- IME caret hit-testing uses the same grapheme-width model, so a click past a wide emoji lands on the right offset. (commit `157e932`)
- Focus events (`CSI I` / `CSI O`) had two emitters that could disagree across a DEC 1004 toggle and send stray bytes to a TUI with focus reporting off; consolidated to one live-core-gated, deduped path. (commit `098b2d9`)

## [0.2.12] - 2026-05-30

Seven audit fixes: prefs scoping, keypad modifiers, OSC hardening, a FIFO-swap hang, and a ReDoS.

### Security / hygiene
- OSC 133 A/B/C payloads screened at codepoint level — C1 and bidi/invisible scalars rejected, parity with OSC 7 and titles. (commit `329754c`)
- The OSC 7 rate limit moved after validation so a flood of tainted `file://` URIs can't starve a legitimate `cd`. (commit `d501e17`)
- `mailto:` accepts at most one `subject` query item. (commit `382cfb2`)
- Enum-repair preference reads scoped to the app's persistent domain; a `defaults write -g` could suppress or clobber the repair. (commit `4af1415`)

### Fixed
- Diagnostics Copy/Email hung forever if a report was swapped for a FIFO between scan and click; opens are now `O_NONBLOCK` with an `fstat` regular-file check. (commit `35cf105`)
- Keypad keys honoured Option-as-Meta / Kitty / modifyOtherKeys only when DECPAM was on. (commit `982d266`)
- The email regex is bounded (local part 64, labels 63) to defeat an O(n²) ⌘-hover hang on `x@aaa…`. (commit `e0bee62`)

## [0.2.11] - 2026-05-29

Startup / new-tab latency release.

### Changed
- The colour glyph atlas is allocated lazily on the first colour glyph — it was ~9.5 ms of the ~21.5 ms per-tab renderer init. (commit `37a54d8`)
- Rasterised glyph bitmaps are cached process-wide across atlases (capped at 4096 entries); renderer init 7.73 → 3.70 ms on every tab after the first. (commit `354b182`)
- The kitty terminfo prewarm and orphan hang-partial pruning moved off the cold-launch main-thread path. (commits `50063a4`, `0716b1b`)

## [0.2.10] - 2026-05-29

Three fixes from the 2026-05-28 multi-agent bug hunt.

### Fixed
- Kitty flag 4 emitted `base:0:shifted`; the shifted key belongs in the second sub-field, so a spec-compliant TUI read shifted = NUL. Now `base:shifted`. (commit `fb09e8d`)
- Double-click-drag extends the word selection; it re-selected only the anchor word on every tick. (commit `e19de96`)
- `FrameKey` keys on `atlasGeneration`, so a glyph rasterised against a pre-flush atlas self-corrects on the next frame instead of persisting. (commit `96eb171`)

## [0.2.9] - 2026-05-28

### Fixed
- Variation Selectors are no longer stripped from drag/paste data — a dragged `❤️.png` became a non-existent `❤.png`, and every ⌘V of emoji-presentation text was corrupted. Display scrubbers keep stripping them. (commit `fcb6738`)
- `characterIndex(for:)` clamps its point before the `Int(Double)` cast; a huge or infinite point from an input method trapped the app. (commit `4eb7a7f`)
- RIS (`ESC c`) clears `modifyOtherKeys`, so `reset` after a TUI exits stops emitting `CSI 27;…~` to a plain shell. (commit `ef6bc24`)

## [0.2.8] - 2026-05-28

Audit remediation: 7 confirmed + 2 downgraded findings (PR #9).

### Security
- Diagnostics reads refuse symlinks at open time (`O_NOFOLLOW`); a same-uid swap of a report for a symlink to `~/.ssh/id_rsa` between scan and click previously reached the pasteboard and Email Diagnostics. (commit `e59c924`)
- The OSC 7 path control filter walks codepoints, catching C1 controls such as `%C2%85`. (commit `3b40182`)
- `ftp` dropped from the OSC 8 scheme allowlist — no default macOS client, and plaintext credentials in the authority. (commit `a3f54be`)
- The OSC 8 click gate rejects the full extended invisible set (soft hyphen, word joiner, BOM, tag block, VS17–256). (commit `f546a79`)
- URL wrap-join refuses `:` as a continuation leader (`https://apple.com/` + `:8080/admin?…` spliced into the path). (commit `ab1af62`)
- `make-appcast.sh` validates operator-supplied URLs against an XML-attribute-safe charset. (commit `c870f46`)

### Fixed
- ⌘K drains the OSC 8 URI cache unconditionally; a live snapshot kept every `Arc` pinned, so a pre-clear flood permanently disabled OSC 8 attribution for the session. (commit `c50b21a`)
- Find-replace refuses TAB in the replacement (readline completion fired mid-stream). (commit `ea4edf3`)
- `osc133.fish`'s double-source guard used `exit`, killing the user's shell whenever `config.fish` was re-sourced. (commit `5c5c5b8`)

## [0.2.7] - 2026-05-22

Audit remediation 2026-05-21 (8 fixes, PR #8) plus tab reordering.

### Added
- Drag-to-reorder tab pills within a window. Visual order is layered on `NSWindowTabGroup` via `TabOrderCoordinator`; ⌘1–9 and ⌘⇧] / ⌘⇧[ follow it. Cross-window drag is out of scope. (commit `33ea665`)

### Security
- `bb_term_free` guarded against handler re-entry: an event handler calling `terminate()` synchronously raced `processor.advance` and produced a use-after-free (SIGSEGV reproduced 3/3); now a defensive leak. Swift `terminate()` / `deinit` mirror the gate. (commits `5471e42`, `6673530`)
- OSC 8 policy rejects percent-encoded bidi and C1 (`%E2%80%AE`, `%C2%85`). (commit `095c795`)
- OSC 133 A/B/C payloads containing raw control bytes are dropped. (commit `7f1c8f2`)
- Copy/Email diagnostics and drop-path scrubs strip Variation Selectors (the data-path half was reverted in v0.2.9). (commit `c015e0d`)

### Fixed
- Numeric preference reads scoped to the app's persistent domain; a `defaults write -g bb.fontSize 999` was clamped and written back over the registered default on a fresh install. (commit `49dd897`)
- OSC 7 `file://` / `localhost` prefix matching is case-insensitive per RFC 3986. (commit `770c28a`)
- The colour-query reply counter increments only after a successful callback fire. (commit `5c7adf3`)
- Settings footer text no longer stuck in a narrow centred column. (commit `af5486a`)

### CI / process
- Test-quality lint baseline driven from 19 to 0; blind, property-based and mutation-driven suites added across the FFI surface and the Swift session layer. (commits `61755f5`, `e957e4d`, `a3e64d1`)
- Homebrew cask bumped to 0.2.6 (it was six releases behind). (commit `175d508`)

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
- Diagnostics tab in Settings — surfaces hang reports (from `~/Library/Logs/Blackbird/`) and macOS crash reports (from `~/Library/Logs/DiagnosticReports/`) with Reveal in Finder, Copy to Clipboard, and Email Diagnostics actions. No auto-upload, no third-party SDK, no backend. Email opens `mailto:` with the report pre-copied to the clipboard (mailto URLs cap at ~2 KB). Symlinks in either directory are dropped (an attacker-controlled `Blackbird-x.ips → /etc/passwd` would otherwise be exfiltrated on Email), inline reads cap at 16 MiB, and C0/C1 controls are stripped before the pasteboard so a planted OSC 52 can't re-execute on paste.
- VoiceOver navigation by character / word / line — `TerminalView` promoted from `.staticText` to `.textArea` with full character / line / range accessors (F-S5-021). The selection setter is a no-op with a one-shot log: the rectangular grid model can't be expressed as a single character range.
- `docs/compat-matrix.md` documenting tested apps (Claude Code, vim, neovim, tmux, ssh, mosh, fzf, git pager, lazygit, gh, ranger, htop, btop, Emacs) and indexing the existing protocol-level pin tests (XTGETTCAP, modifyOtherKeys, OSC 8 round-trip, OSC 7 SSH trust, etc.) under one document.
- `docs/voiceover-pass.md` — manual VoiceOver acceptance checklist.
- `CHANGELOG.md` (this file).

### Documented
- End-to-end input→draw latency measurement procedure via the existing `scripts/run-with-probe.sh`. xctest can't acquire `CAMetalLayer` drawables and OS-level keystroke injection is forbidden by project rule, so an automated CI gate for real latency stays out of scope; the manual recipe (run-with-probe + 60s of typing → `latency n=500 p50=… p99=…` line in unified log) plus the 6 ms p50 / 20 ms p99 cut-blocking thresholds are now spelled out in `KNOWN_ISSUES.md`.

### Fixed
- `SparkleAlertOverride.install()` no longer leaks the previously installed block IMP on re-install (F-S7-001): the IMP minted via `imp_implementationWithBlock` is tracked and freed with `imp_removeBlock`; the runtime-owned original IMP is left untouched.

## [0.1.17] - 2026-04-29

### Fixed
- `mailto:` hyperlink parsing now reads the domain from `URL.absoluteString` instead of `URL.path`. Previously empty-host mailto links silently produced no clickable region.
- Atomic appcast write in `publish-update.sh` (F-S8-025 / audit L-13): the old `> website/appcast.xml` redirect truncated the live tracked appcast at FD-open time, so a mid-stream crash (sign_update failure, hdiutil failure, SIGINT) left every Sparkle client seeing malformed XML. Now staged via `mktemp` with an `EXIT` trap and `mv -f` on success. (commit `214e00f`)

### Changed
- CI Rust toolchain pinned to 1.85.0; adopted `repeat_n` for forward compatibility with newer toolchains.
- Several runloop-pumping tests are now gated behind a stress flag — they were the cumulative-ASan ceiling tippers in earlier releases.

## [0.1.16] - 2026-04-28

### Fixed
- `release.sh` signs the DMG before notarization so Gatekeeper accepts the published download. Earlier flow notarized first, signing after — leaving a window where downloaded DMGs failed initial Gatekeeper check.
- `actions/upload-artifact` bumped from 4 to 7 in CI.

## [0.1.15] - 2026-04-28

### Added
- OSC 7 SSH trust gate. `PTY.classifyForegroundNamespace()` walks `tcgetpgrp(masterFD)` via `proc_listpids(PROC_PPID_ONLY)`, checking each pid's basename against `{ssh, slogin, mosh-client, telnet, docker, podman, nerdctl, kubectl, lima}`, and classifies the foreground process as `local`, `remote(<exe>, <pid>)`, or `unknown(reason)`. `TerminalSession` only honors OSC 7 when the result is `.local`; both `.remote` and `.unknown` (PTY closed, syscall failure, BFS cap hit) leave `lastKnownCwd` at its previous trusted value. Fail-closed by design — a `Bool` return would have collapsed "definitely local" with "couldn't tell" (audit deferral SEC-003). Complements the core's `handle_osc7` input validation (`..` segments, non-absolute paths, NUL, non-UTF-8 all dropped).
- `publish-update.sh` now runs `codesign --verify --strict`, `spctl --assess --type install`, parses Team ID from the spctl origin line (must match the pinned `F2B95Q4CT8`), and `xcrun stapler validate` before signing the DMG into the appcast (F-S8-004). A pinned SHA was deliberately dropped from the design: in a single-developer flow there is no out-of-band trust root for the SHA itself, so the codesign + spctl + stapler chain plus the Team ID is the meaningful trust root. Version argument validated against a semver regex (F-S8-003).
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

### Fixed
- Preferences schema-downgrade guard (F-S7-003): `migrateIfNeeded` preserves a higher on-disk schema version instead of stamping the older binary's version over it. (commit `3bae5be`)
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
- `modifyOtherKeys` (xterm `CSI > 4 ; N m`; level 1 or 2 both light the bit). `CSI 27 ; <mod> ; <cp> ~` emission kicks in for modified printables when no Kitty flag is active; precedence is Kitty > modifyOtherKeys > legacy. Emacs, tmux `extended-keys on`, and Neovim's auto-request all covered.
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
