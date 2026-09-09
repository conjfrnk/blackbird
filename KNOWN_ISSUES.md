# Known issues

Resolved items live in CHANGELOG.md under the release that fixed them.

Small list of deliberately-deferred polish items. If you hit one of these, it's documented, not forgotten.

## Shell integration auto-injection — bash, nested shells, stale ssh cache

Since the issue-#23 fix, Blackbird injects shell integration (OSC 133 prompt
marks + the ssh terminfo wrapper) automatically for **zsh** (`ZDOTDIR`
redirect) and **fish** (`XDG_DATA_DIRS` vendor conf.d) — no rc-file edits,
opt-out in Settings. Three deliberate gaps:

**bash is manual.** A login bash (`-il`, what Blackbird spawns) ignores
`--rcfile`, and kitty's `--posix`+`ENV` bootstrap workaround is the most
fragile part of kitty's tree — rejected for now. Bash users source the
bundled `osc133.bash` / `ssh.bash` from `~/.bashrc` (path in each file's
header). Revisit if anyone asks.

**Nested interactive shells lose integration.** The zsh bootstrap restores
the user's real `ZDOTDIR` before their rc files run, so typing `zsh` inside
a session starts a shell that never sees the bootstrap (same trade kitty
and Ghostty make). The ssh wrapper is therefore absent in nested shells;
`TERM` is still `xterm-kitty`, so a nested `ssh` to a host without the
entry reproduces #23. Manual sourcing from `.zshrc` covers this for anyone
who nests routinely.

**A system `/etc/zshenv` that reassigns `ZDOTDIR` silently disables
integration.** zsh sources `/etc/zshenv` BEFORE `$ZDOTDIR/.zshenv`, so a
managed-fleet `/etc/zshenv` that sets its own `ZDOTDIR` redirects zsh away
from Blackbird's bootstrap before it ever runs — no OSC 133, no ssh
wrapper, no error (and the spawn-time `BB_ORIG_ZDOTDIR` is left in the
session env unconsumed). Same trade every ZDOTDIR-based integration
(kitty included) makes. Manual sourcing from `.zshrc` covers affected
fleets.

**A `.zshrc` that ASSIGNS `precmd_functions=(…)` silently disables
integration.** The zsh bootstrap defers loading to a one-shot entry in
`$precmd_functions` registered before `.zshrc` runs; a dotfile that
assigns the array wholesale (instead of appending or using
`add-zsh-hook`) wipes the loader, and prompt marks + the ssh wrapper
never load — with no error. Frameworks (oh-my-zsh, powerlevel10k) use
`add-zsh-hook` and are unaffected; hand-rolled dotfiles that assign the
array should append instead, or source the integration manually.

**Remote TERM is xterm-256color by default (v0.6.1); kitty TERM remotely
is opt-in.** v0.6.0 installed the kitty terminfo on remote hosts and kept
`TERM=xterm-kitty` there. Measured fallout (2026-07-07): tools that sniff
TERM strings for color depth instead of reading terminfo — Codex CLI's
composer bar, the npm `supports-color`/chalk ecosystem — treat an
unrecognized `xterm-kitty` without `COLORTERM` (which never survives ssh)
as ≤16-color and drop styling entirely, while VS Code "worked" purely
because its remote TERM is `xterm-256color`. The ssh wrapper therefore
now defaults to `TERM=xterm-256color` for every connection (kitty
KEYBOARD protocol still works remotely — apps negotiate it at runtime
via `CSI ?u`, which is TERM-independent). Export `BB_SSH_REMOTE_TERM=kitty`
to restore the v0.6.0 install-and-keep-kitty behavior (useful for
terminfo-reading tools like nvim's truecolor autodetect); its per-host
cache lives in `~/.local/state/blackbird/ssh-terminfo-hosts` — delete a
host's line if you wipe the remote `~/.terminfo` (successes are cached,
failures never are).

**fish ≥ 4.0 emits its own OSC 133 marks, so integrated fish sessions
double every mark.** fish 4.0 added native shell integration (A/B/C/D,
some with parameters like `A;click_events=1`, which the core accepts —
the payload slot is only validated for D). With Blackbird's osc133.fish
also loaded, the core receives each mark twice per prompt cycle;
consumers tolerate it (B/C/D are last-wins on `lastPromptMark`), but the
doubled A registers two prompt-ring entries per prompt, so ⌘[ visits
each fish prompt twice. Pre-existing since v0.6.0 (the doubling predates
the v0.6.2 B-wrap). Remedy sketch: early-return in osc133.fish when
`$version` major ≥ 4 (native coverage wins; keep the file for fish 3.x)
— deferred because it inverts the fish test expectations and the fish-3.x
`functions -c` autoload path is unverified on the dev machine.

**`funcsave fish_prompt` while integrated persists Blackbird's prompt
wrapper, not your prompt.** The fish B-mark wrap copies your
`fish_prompt` aside and shadows it; `funcsave fish_prompt` (the normal
way fish users persist an edited prompt) saves the WRAPPER body. Next
session the load guard detects the already-integrated body and skips
re-wrapping (no recursion, no error spam — the wrapper degrades to a
bare prompt that still emits B), but your prompt CONTENT is gone from
the saved function. Recovery: `functions -e fish_prompt; funcsave
fish_prompt` restores the autoloaded default (or re-`funced` your own).
kitty's fish integration shares this hazard.

**tmux is out of the wrapper's reach.** tmux substitutes its own
`default-terminal` for every pane's TERM, so what a TUI inside tmux
sees is decided entirely by the tmux config — local or remote, no ssh
wrapper can touch it. If tmux falls back to bare `screen` (old tmux, or
an unset `default-terminal`), string-sniffing TUIs drop styling inside
tmux under EVERY outer terminal, Blackbird included. Remedy is one line
of tmux config: `set -g default-terminal "tmux-256color"`.

## Move Tab to Window — minimized and fullscreen windows aren't offered

**Symptom:** The tab-pill context menu's "Move Tab to Window ▸" submenu omits minimized (Dock) windows and fullscreen windows; with only one other window and it minimized, the submenu is absent entirely. The submenu is also absent while the *source* window is fullscreen.

**Why (v1 scope decision, 2026-07-02):** A move into a minimized window would make the tab vanish into the Dock unseen; a splice into or out of a fullscreen group crosses Spaces on the sensitive fullscreen-reconfigure path (see the frame-save suppression in `c243128`). `TabMover.destinationEligible` enforces visible + non-fullscreen at menu build AND again at fire time. Windows on other Spaces are offered (they're `isVisible`); moving to one follows macOS's "switch to a Space with open windows" setting.

**Possible upgrades:** deminiaturize-on-move, or listing excluded windows as disabled items. Also: each submenu entry weakly references one representative window of the destination group — if that exact tab closes while the menu is open, the move is dropped (logged under subsystem `dev.conjfrnk.blackbird`, category `tabMove`) even though the rest of its group survives.

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

## Color emoji — ZWJ sequences

Not supported: ZWJ sequences like 👨‍👩‍👧 (family) still render as the base 👨 scalar because atlas keys are single `UnicodeScalar`. Proper grapheme-cluster keying is future work — a rare enough case that it stayed out of v1.

## Kitty flag 4 / 16 — US-layout only

**Flag 4 (`reportAlternateKeys`)** emits `base:shifted` for every ASCII letter and for the 21 US-layout shifted symbols (`!`→`1`, `@`→`2`, …, `|`→`\`). The Kitty key-code field is `unicode-key : shifted-key : base-layout-key`, so the shifted codepoint occupies the second sub-field; the third (base-layout / alt-layout) field is omitted because macOS exposes no per-key alternate-layout codepoint. (Through v0.2.9 this emitted `base:0:shifted`, which misread the spec — a literal `0` in the shifted slot and the real shifted value pushed into the base-layout slot — so a spec-compliant TUI read shifted-key = U+0000. Fixed to the spec-correct `base:shifted` shape.) Non-US layouts (German QWERTZ, Dvorak, BÉPO, …) still see only the shifted char with no alt-layout slot — the reverse lookup would need Carbon's `UCKeyTranslate` + current-layout plumbing, deferred to a dedicated session.

**Flag 16 (`reportAssociatedText`)** emits the produced text as a trailing `;<utf32>` section for the single-key press case, elided when the text equals the base codepoint (saves bytes; spec says parsers treat "absent" as "text=base"). IME-committed multi-scalar text (e.g. Chinese pinyin commits, ZWJ emoji composed via input methods) goes through `insertText` directly and doesn't synthesize a flag-16-style key event — Kitty's spec doesn't define IME commit as a keystroke, so no reasonable TUI expects it.

## Claude Code hyperlinks — the residuals after issue #30

⌘-click now opens links through a TUI's mouse grab (issue #30, v0.8.0).
Three related things are deliberately NOT fixed:

**`file://` links from Claude Code stay inert.** Claude Code hyperlinks
every file path it prints (`ESC]8;;file://<path>`). Those cells carry OSC 8
attribution, but `OSC8URLPolicy` rejects the scheme, so there is no
underline, no tooltip, and no click — by design, see the section below.
kitty / iTerm2 / WezTerm open them; Blackbird won't hand a
terminal-supplied path to `NSWorkspace.open`.

**OSC 8 emission depends on `TERM` containing `kitty`.** Claude Code's
hyperlink gate is `supports-hyperlinks` plus an allowlist of
`TERM_PROGRAM` values (ghostty / Hyper / kitty / alacritty / iTerm.app /
iTerm2) and one `TERM.includes("kitty")` check. `TERM_PROGRAM=Blackbird`
is on nobody's list, so the kitty `TERM` is the only thing that makes it
emit OSC 8 at all. If the bundled kitty terminfo can't install, `TERM`
falls back to `xterm-256color` and Claude Code **drops link targets
entirely** — it prints the label with no href, so no terminal-side fix
can recover them. Spoofing `TERM_PROGRAM` would get us on the allowlist
and is exactly the identity lie whose blast radius the v0.6.1 same-day
correction documents (see "Remote TERM" above); the real fix is upstream
allowlist entries. Over SSH the remote `TERM` is `xterm-256color` for the
same reason, so a remote Claude Code loses hyperlinks too.

**A URL that an application hard-wrapped itself opens truncated.**
`URLDetector`'s wrap-join needs the match to end at the last column AND the
next row to begin with a URL-safe character. An app that does its own
wrapping — Claude Code writes each row independently with `CR` + cursor
motion, and indents continuation rows — satisfies neither, so a plain-text
URL split across rows resolves to its first-row fragment and ⌘-click
navigates somewhere shorter than intended. Does NOT affect Claude Code's
own linkified URLs: those carry OSC 8, and OSC 8 attribution wins over the
regex detector, with the full href on every row-span.

**The anchor/href divergence gate can over-block a wrapped bare URL.**
When Claude Code auto-linkifies a bare URL whose text is the href, and
its own hard wrap splits the URL *inside the host*, the row-local anchor
walk sees a truncated host (`https://gith`) and the anti-phishing gate
blocks the click with only a log line. Reachability is low (the wrapper
moves an over-long token to a fresh line before breaking it, so the break
lands deep in the path unless the content width is under ~20 columns) and
the safe fix is not cheap: prefix tolerance is unsound — an anchor of
`https://apple.com` IS a prefix of `https://apple.com.evil.tld/x`, which
is precisely the phishing shape the gate exists to catch. Revisit with a
multi-row anchor reconstruction if anyone hits it.

## `file://` URLs are intentionally not clickable

The scrollback URL detector matches `http(s)://` and `ftp://` only. `mailto:` is clickable too (detected from bare email-shaped strings and from OSC 8 hyperlinks). `file://` is deliberately excluded — we don't want to give a terminal-pasted string the ability to open a local path just by being clickable.

If you actually want to open a local path, drag the file into the terminal or use `open path/to/file` in the shell.

## OSC 7 trust over SSH — limitations kept

The gate itself (`PTY.classifyForegroundNamespace()`, fail-closed `.local` / `.remote` / `.unknown`) shipped in v0.1.15 — see CHANGELOG.md. Two limitations remain:

Limitation kept: a remote shell running inside a multiplexer (tmux/screen) on the local host evades the gate, because the multiplexer's server detaches from the original PTY and `proc_listpids` from the terminal can't see across the boundary. Multiplexers also don't generally proxy OSC 7 across, so the practical exposure is low.

Limitation kept (audit fix-#23, 2026-05-11 — accepted as designed): a renamed / aliased / statically-linked ssh-clone whose basename isn't in `remoteShellBinaryBasenames` (e.g. a user-installed `mysshwrapper` that IS the ssh transport with no descendant `ssh` process) classifies as `.local`, so OSC 7 cwd inheritance trusts the remote path. The audit-recommended mitigation (gate on a fixed list of "known-safe local-shell paths" like `/bin`, `/usr/bin`, `/opt/homebrew/bin`, `~/.local/bin`) would over-fire on legitimate custom installs (MacPorts at `/opt/local/bin/*`, cargo at `~/.cargo/bin/nushell`, user-built shells), trading a real UX cost for a niche security fix. The project's chosen posture (per the comment block at PTY.swift:1013-1019 — "Conservative set… False negatives are the security risk we're guarding against, so when in doubt, add to the set") is to expand `remoteShellBinaryBasenames` when a new canonical wrapper appears, rather than introduce path-based heuristics. v1.0 hardening: revisit if mysshwrapper-shaped tooling becomes common in the field.

## v0.1.9 hardening-sweep deferrals (2026-04-24)

A multi-agent review + blind-test pass surfaced 67 unique findings. The critical / high-severity items shipped across commits `f18d00e..53c17a7`; the items below are legitimately deferred because they touch public API shape, require architectural changes, or need test-host seams that don't exist yet.

- **Kitty flag 4 for non-US keyboard layouts** (F-S3-013 / KNOWN_ISSUES § "Kitty flag 4 / 16"). Still needs Carbon `UCKeyTranslate` + current-layout plumbing.
- **Secure-input indicator badge — built, then removed by decision (SPR-006).** The Secure Keyboard Entry lock indicator was implemented (`035300d`) and then deliberately removed (`e0d8f9e`, 2026-04-20): the lock icon destabilised multi-tab titlebar-accessory stacking (two right-anchored accessories don't stack reliably across tabbed windows), and the protected-input state is conveyed by *who owns secure input*, not a titlebar lamp. The actual protection — `TerminalView`'s `EnableSecureEventInput()` / `DisableSecureEventInput()` bracketing on focus gain/loss (Terminal.app parity) — is untouched. Won't reintroduce unless a stable multi-tab accessory placement justifies it.
- **Blind test flakiness in cumulative ASan run** (internal). `PTYLifetimeRaceTests` and a few sibling tests pass in isolation but trigger ASan cumulative-allocation aborts when the full suite runs in one xctest process. Gated behind `BB_RUN_FLAKY_PTY_TESTS=1` until we understand whether the cause is our code or the xctest runner's ASan accounting.

Full triage ledger in `docs/superpowers/reviews/v0.1.9-sweep/triage.md` (gitignored, local-only).

## v0.2 cycle additions (2026-04-30)

The v0.2 design (`docs/superpowers/specs/2026-04-30-blackbird-v0.2-design.md`) closed F-S5-021 / F-S7-001 and shipped the Diagnostics tab (all in CHANGELOG.md under 0.2.0); one surface it added still warrants an entry:

- **End-to-end input→draw latency gate — split between PR-CI plumbing pin and nightly real-window measurement (P4.6, 2026-05-09)**. The PR-CI `latency-gate` job (renamed from "Latency gate — p50/p99 regression check" to "Latency probe plumbing format pin") is explicitly plumbing-only: it runs `LatencyHarnessTests`, which calls `markKeystroke()` and `markPresented()` back-to-back so deltas are ~0 µs and the LATENCY_P50_MS=6.0 / LATENCY_P99_MS=20.0 thresholds are unreachable by construction. That job exists to pin the probe's log-line FORMAT and the bench-script regex against drift — nothing more. The honest end-to-end measurement now lives in `Tests/BlackbirdTests/RealLatencyProbeWindowedTests.swift`, gated behind `BB_RUN_LATENCY_PROBE=1` (set only by `nightly-soak.yml` via `TEST_RUNNER_BB_RUN_LATENCY_PROBE=1`). That nightly test creates a real `NSWindow` + `MTKView`, drives synthesized `NSEvent.keyDown` events through `NSApp.sendEvent`, pumps the runloop until frames present, and asserts `max > 0.5 ms` (real frame latency, not the back-to-back ~0 µs the synthetic harness measures). The test pre-flights `MetalRenderer.didFrameSkipLastRender` after the first draw — if the xctest host's windowing stack can't acquire a `CAMetalLayer` drawable (a known limitation of GHA's macos-14 virtual display, and also of `xcodebuild test` on dev machines without an attached display), the test throws `XCTSkip` with a clear "windowed Metal probe cannot acquire drawable" reason. The nightly sentinel grep accepts EITHER `passed` (real measurement landed) OR `skipped` (host can't acquire drawable) but FAILS LOUDLY if the test never ran — that's the silent-green failure mode where `TEST_RUNNER_BB_RUN_LATENCY_PROBE` propagation breaks. Real-latency CI signal therefore depends on adding a self-hosted runner with an attached display (deferred); until then, the test ensures the path EXISTS and runs locally on a dev machine, while CI gets the format-pin. **Manual measurement remains available via `scripts/run-with-probe.sh`** for local pre-release verification: launches a signed Debug Blackbird with `BB_LATENCY_PROBE=1`, streams the unified-log `latency` category. Type continuously for ~60s to fill the 500-sample ring; the resulting `latency n=500 p50=… p99=… p999=… max=…` line is the authoritative measurement. Connor runs this locally before tagging each release; a regression vs. the 6 ms p50 / 20 ms p99 baseline blocks the cut. p999 + max thresholds are not yet gated — pending a few baseline runs of real-world data from both the nightly windowed test and manual sessions.

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

## v0.4 pre-release audit follow-ups (2026-06-21)

Non-blocking residuals surfaced by the 6-dimension adversarial pre-release
audit of PR #18. None gate v0.4 (the audit verdict was SHIP, zero confirmed
blockers); logged here so the triaged backlog stays honest.

- **IME drops an Option+letter Meta chord during an active CJK preedit.**
  `TerminalView`'s `isOptionMetaChord` fast-path bypasses the IME so
  `optionIsMeta` chords reach the encoder, but when a CJK marked-text
  (preedit) composition is already in flight, the chord is swallowed by the
  composition instead of emitting `ESC`+letter. Narrow edge (Meta mode +
  mid-composition); NOT byte-corruption — it's a dropped chord, and the
  common Meta-mode-without-IME path is unaffected. Fix would route the chord
  ahead of the marked-text commit; deferred as low.
- **Rapid double-⌘G during live output can lose the find cursor anchor.**
  Two `findNext` invocations landing within the same live-output snapshot
  refresh window can race the anchor rotation so the second advance resumes
  from a stale match index (cosmetic: the selection jumps to an unexpected
  match, no data loss). The single-advance and idle-buffer paths are covered
  by the F-S5/find fixes already in this PR; the double-tap-during-scroll
  ordering is the residual. Low UX nit.
- **`resolveSheetParent` final fallback can theoretically return a
  non-selected-tab window.** The Sparkle sheet-parent resolver targets
  `keyWindow.tabGroup?.selectedWindow` (the fix for the "popup jumps to tab
  1" bug); its last-resort fallback, reached only when there is no key/main
  window and no terminal tab group at all, could in principle pick a
  non-selected window. Documented as unreachable in practice (a sheet
  presents only when a terminal window exists). Consider tightening the
  fallback or adding an assert; low residual.
- **Vendored-crate drift detection (tooling follow-up).** `vendor/vte` (and
  the pre-existing `vendor/alacritty_terminal`) are full-source vendored
  forks carrying a small set of intended deviations. The pre-release audit
  verified `vendor/vte` byte-for-byte against the sha256-pinned upstream
  0.15.0 tarball by hand. Add a `scripts/` check (run in CI on dep bumps)
  that re-diffs each vendored crate against its pinned upstream and asserts
  only the known deviations are present, so future drift is caught
  automatically rather than by manual audit. Deferred to its own PR
  (a network-fetching gate needs its own flake-proofing — not rushed into
  the release commit).

## Per-tab text size — deliberately deferred residuals (2026-07-13, issue #28)

The per-tab/per-window text-size batch was reviewed by a 30-agent pass
(25 lenses → 3-way adversarial verification → 5-judge panel; verdict:
unanimous approve, zero confirmed serious findings). These medium/low
residuals were judged non-blocking and are logged so the backlog stays
honest.

- **Native tab-group members can carry inconsistent `contentMinSize`.**
  `applyEffectiveFont` sets each window's `contentMinSize` from its own
  view's cell metrics (the 20-col/4-row readability floor). With per-tab
  sizes, a group can hold tab A at override 32 (large minimum) and tab B
  at 9 (small minimum) while sharing one window frame: resizing the group
  with B selected is constrained only by B's minimum, so selecting A can
  present it below the floor its own apply just installed. Grid math is
  safe (`propagateResize` guards cols/rows > 0 and UInt16-clamps); only
  the readability guarantee is voided for large-override tabs in
  mixed-size groups. Fix would compute a group-max minimum on selection;
  deferred until someone actually hits it.
- **Failed-apply window: per-view steps anchor to the model, not the
  rendered size, and there is no retry backoff.** When an atlas rebuild
  fails (GPU memory pressure — the only failure path), the view keeps its
  old rendered size while `effectiveFontSize` reflects the target; the
  Preferences sink retries on every later emission (by design — the
  latch fix), including emissions from unrelated prefs, with no backoff.
  During that rare window a ⌘+/⌘− step computes from the model value, so
  the rendered size can jump more than one point (or, degenerately, ⌘−
  can land larger than the stale rendered size), and ⌘0 with no override
  is a no-op rather than a manual retry. All states remain internally
  consistent (override ↔ metrics never disagree — rollback guarantees
  it) and any later pref write self-heals. Hardening candidates if the
  window ever proves reachable in practice: retry budget/backoff in the
  sink, and an unconditional `applyEffectiveFont()` in `resetFontSize`.
