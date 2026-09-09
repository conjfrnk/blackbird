# SIMULATIONS.md — creative bug hunting via simulation

Status: living dossier (AI-drafted from an 8-dimension idea-generation pass,
multi-agent-reviewed). Gitignored by convention (`docs/*`), like the RCA and
refactor dossiers. Promote individual harnesses into `scripts/` + CI as they
prove out.

## Why this doc

Blackbird's existing gates (unit tests, throughput/latency/memory floors,
30-second fuzz smoke, adversarial code review) are good at catching bugs we
already know how to look for. The bugs that actually hurt — VS16 "random
newlines", zsh PROMPT_SUBST mark garbage, the FIFO-swap hang, the invisible
hit-testable tab bar — were all found *in vivo*: a real program doing something
no test author imagined. This doc catalogs ways to manufacture "in vivo"
conditions on demand: simulated user workflows, hostile and weird shells,
demanding real programs (pi, opencode, Claude Code, codex), differential
references, chaos injection, and agent-driven synthetic users.

Organizing principle: **every simulation needs an oracle.** A harness that
only notices crashes wastes most of its signal. Preferred oracles, strongest
first:

1. **Differential** — same bytes into a reference implementation; diff grids.
2. **Metamorphic** — same bytes, different chunking/ordering; results must be
   identical (the stream is its own oracle — no reference needed).
3. **Golden** — frozen known-good snapshot; diff on change.
4. **Invariant** — properties that must always hold (wide-cell continuity,
   cursor-in-bounds, mark grammar), checkable on any snapshot.
5. **Ground truth** — filesystem/process effects (the file the shell wrote,
   the SIGINT the child received, `git log` after the rebase).
6. **Judge** — LLM/visual "does this look garbled" — cheapest to build,
   noisiest; use only as a *classifier of deterministic diffs*, never as the
   primary pass/fail signal.

## Ground rules (host safety — non-negotiable)

Claude runs *inside* Blackbird on this machine. Every harness below respects:

- **Headless first.** Drive the Rust core FFI (`bb_term_*`) directly, or
  `TerminalSession` at unit level, or a standalone PTY harness binary. No
  fleets of GUI Blackbird instances (OOM'd the host before), no AppleScript
  keystroke injection (keystrokes land in the operator's own terminal).
  Writing bytes to a harness-owned PTY fd is the safe substitute for
  keystrokes; `tmux send-keys` into a detached private-socket session is the
  safe substitute for an input robot.
- **One live shell session at a time per xctest process.** Matrix harnesses
  run strictly sequentially (spawn→drive→reap); the hazard is *concurrent*
  live sessions, which destabilize the xctest host. Standalone harness
  binaries likewise get one PTY child at a time, watchdog-killed
  (SIGKILL + reap).
- **Budget memory/time before writing any test** (the UInt16.max resize test
  once allocated >100 GB). Caps live in the harness code, not in discipline:
  grids ≤ 500×100, streams ≤ 4 MB, explicit RSS watchdogs.
- **Never signal by name** (`pkill zsh` would hit the operator's shells) —
  only the harness's own child pid.
- **Scratch HOME/ZDOTDIR for every spawned shell** so the operator's dotfiles
  are never read, written, or executed.
- **CI Swift suite runs ASan off; local runs keep it on** — exercise both.
- **New Swift harness binaries/test targets go through `project.yml` +
  `xcodegen generate`** (Hard Rule 1 — never hand-edit the pbxproj); Rust
  bins under `core/` need no project changes.
- **Blind test authoring applies to harness oracle code too** — reference
  decoders, invariant checkers, and expectation tables are written by a
  subagent that hasn't seen the implementation (the house rule, not just for
  D8's decoder).
- Recorded corpora may contain repo text or user content — keep them in the
  gitignored corpus cache by default, scrub before committing any fixture.

## What we already have (build on, don't reinvent)

| Asset | Where | Reuse for |
|---|---|---|
| Headless core FFI: `bb_term_new/input/resize/resize2/take_snapshot/scroll/text_range/current_mode` + event callback | `core/src/lib.rs` → `BBCore.h` | every replay/differential harness |
| Golden snapshots + `goldens.rs` | `core/tests/goldens/` | corpus regression oracle |
| VT conformance, proptest invariants, `csi_fragmentation_repro`, FFI sweeps, `terminal_replies`, `decrqm`, `osc133`, `damage_blind`, `dirty_rows` | `core/tests/` | invariant + reply oracle library |
| 4 fuzz targets (term_input, resize2, reply_storm, text_range) | `core/fuzz/` | corpus exchange, grammar upgrades |
| Real-PTY `TerminalSession` tests (forkpty-based) | `Tests/BlackbirdTests/` | workflow scripting at Swift level |
| RecordingPTY seam (DEBUG-only *outgoing*-byte recorder, swapped in via `ptyRecorderForTests`) | `Sources/Blackbird/Terminal/RecordingPTY.swift` | IME-commit byte assertions only — it drives no shell and captures no output |
| OSC 133 hooks for bash/zsh/fish + ssh terminfo wrapper + ZDOTDIR injection | `Sources/Blackbird/Resources/shell/`, `ShellIntegration` | shell-matrix subject under test |
| Renderer reconfigure failure-injection DEBUG seam (8bed502) | `Sources/Renderer/` | Metal fault-injection harness |
| Latency probe, vte/kitten bench scripts | `scripts/` | perf-regression oracles for sims |
| Diagnostics tab + `DiagnosticReportStore` | `Sources/Blackbird/Settings/` | flight-recorder dump UI |

## Tooling inventory (this machine)

- **Shells installed:** zsh, bash 3.2 (system), fish 4, dash, ksh, tcsh, csh.
  Brew-installable: nushell, xonsh, elvish, pwsh, oils-for-unix, murex;
  prompt kits: starship, powerlevel10k, oh-my-zsh, oh-my-posh.
- **Agent CLIs installed:** `pi`, `opencode`, `codex`, `claude` — the heaviest
  real workloads this terminal sees, and the class that exposed the VS16 bug.
  All have non-interactive modes (`claude -p`, `codex exec`, `opencode run`,
  `pi --print`) — the key to driving them headlessly and reproducibly.
- **TUIs installed:** nvim, vim, emacs, tmux, screen, htop, lazygit, fzf,
  ranger, cmatrix, fastfetch. Brew-installable: vttest, zellij, btop, yazi,
  asciinema, notcurses, libvterm, timg.
- **Runtimes:** node, bun, python3, rustc, docker (throwaway sshd), gh.

---

# Part 1 — Substrates (build these first; everything else rides them)

## S1. `bb-replay`: deterministic byte-replay engine with chunk shredding

The single highest-leverage build. A Rust bin (`core/src/bin/bb-replay.rs`)
or `--ignored` integration test consuming a tiny session DSL: `feed <bytes>`,
`split every=N | at-offsets | around-escapes`, `resize WxH`, `scroll N`,
`expect-grid <golden>`, `expect-invariants`. Corpus files live in
`core/tests/goldens/sessions/*.bytes`.

Its killer feature is the **chunk-shredding sweep** (independently proposed by
6 of 8 idea generators — the strongest convergence signal in the whole pass):
for any transcript, enumerate adversarial chunkings — every split point within
±4 bytes of each ESC/CSI/OSC/DCS introducer and terminator (found by a tiny VT
lexer), every UTF-8 continuation byte, immediately before each U+FE0F / U+20E3
/ ZWJ (the VS16 shape: a variation selector arriving in chunk N+1 must still
promote the width of a cell committed in chunk N), fixed sizes
1/2/3/7/17/1024/4096, plus seeded-PRNG chunkings (seed printed on failure).
Optionally interleave `resize2`/`scroll` calls *between* chunks — models
SIGWINCH arriving mid-sequence, which no current test exercises.

- **Oracle (metamorphic):** final snapshot — full grid (char, width flags,
  fg/bg, attrs, hyperlink id), cursor row/col/pending-wrap, mode bits,
  scrollback text via `text_range` — must be byte-identical across ALL
  chunkings of the same transcript. No reference implementation needed.
  **Resize-variant caveat:** for the identity oracle to hold, the
  resize/scroll schedule must be keyed to *absolute byte offsets in the
  transcript* and held constant across all chunkings being compared (only
  the chunk splits vary around the fixed injection points). Variants where
  the schedule itself varies drop the identity oracle and run only the S3
  invariants.
- **Catches:** the `csi_fragmentation_repro` class generalized from one pinned
  repro to every byte stream we own; sync-output BSU/ESU split across chunks;
  OSC/DCS accumulator state bugs; combining marks split from their base char.
- **Start (same-day signal):** apply three fixed strategies (every-1-byte,
  split-after-every-ESC, split-inside-every-multibyte) to the existing goldens
  corpus. Cost: S for the fixed-strategy version, M for the full engine.
- **Safety:** pure headless FFI; one 80×24 term per variant; variant count
  capped (~10k/file, escape-adjacent offsets only).

## S2. `ptyjig`: headless PTY harness with a JSON command protocol

A standalone binary (Rust `core/src/bin/ptyjig.rs` via `nix::pty`, or a Swift
CLI linking BBCore): opens a real `openpty()` pair, spawns exactly one child
(shell, editor, agent CLI), pumps child output into `bb_term_input`, and takes
newline-delimited JSON commands on stdin:

```
{type:"keys", data:...}        # bytes to the PTY master — never OS events
{type:"paste", bytes:...}      # through the real paste pipeline
{type:"resize", cols, rows}    # bb_term_resize2 + TIOCSWINSZ, atomically
{type:"signal", sig:"INT"}     # to the child pid only
{type:"snapshot"}              # full grid+cursor+modes+scrollback as JSON
```

This is the safe, deterministic replacement for "a human using the app": both
scripted scenarios and LLM agents drive it (see Part 8). Sync is deterministic,
not sleep-based — fence on DSR/CPR round-trips or OSC 133 D-marks, or on
150 ms output quiescence.

- **Start:** ~250-line bin + smoke it with `printf` scripts. Cost: M.
- **Safety:** one child per harness process; 60 s / 512 MB watchdog;
  grid capped 300×100; scratch HOME.

## S3. The invariant/oracle library (bolt onto everything) — cost S–M

A *new* shared Rust checker module any harness links (a crate module or
`core/tests/common/` — note that files directly under `tests/` are standalone
test binaries, not linkable; the closest existing patterns are
`redraw_invariants.rs` / `ffi_invariant_props.rs`, but no shared library
exists yet). With it, "no crash" simulations become corruption detectors for
free:

1. **Snapshot idempotence** — snapshot twice, assert identical.
2. **Wide-cell continuity** — every width-2 cell has its spacer; no orphan
   spacers; no cell both wide and spacer; per-row width-sum ≤ cols.
3. **Cursor in bounds; pending-wrap consistent with last-cell occupancy.**
4. **Scrollback immutability** — shadow append-only log of scrolled-off rows
   (via `linesScrolled`); historical rows must stay bit-identical except
   across an explicit reflow event.
5. **OSC 8 integrity** — every link's cell range re-concatenates to the
   original URI, across wraps and resizes (the multi-row URL-wrap class).
6. **Damage honesty** — a shadow framebuffer updated *only* from
   damage-reported rows must equal the authoritative grid every frame
   (under-reported damage = stale cells on screen; also flag >90 %-dirty on
   1-cell changes as a throughput-cliff early warning).
7. **Mark grammar** — OSC 133 stream parses as `(A B C? D{exit=k})*`, one B
   per A, no marks inside command output or alt screen.
8. **Text-extraction consistency** — grid text vs `text_range` for random
   ranges.
9. **Accessibility agreement** — the VoiceOver accessors
   (accessibilityString/range/line) must agree with grid text extraction on
   any snapshot; near-free given the existing accessor surface, and it turns
   every harness into an accessibility regression net.

## S4. `bb-minimize`: escape-aware delta debugging

Not a bug finder — the force multiplier that turns every harness failure and
flight-recorder dump into a checked-in golden. Tokenize the stream with the S1
VT lexer (ESC/CSI/OSC/DCS spans + UTF-8 scalar boundaries as atoms — naive
byte-ddmin dies on VT streams because cuts create new sequences), then
standard ddmin over tokens, then per-token simplification (params → defaults,
long runs → short). Built-in oracles: `panics`, `shred-divergent`,
`differ-divergent`, `damage-divergent`, `grid-contains STRING`.

- **Validation:** plant the known VS16 repro inside 1 MB of fastfetch output;
  bb-minimize must recover the ~40-byte minimal sequence. Cost: M.

---

# Part 2 — Simulated user workflows (scripted developer sessions)

## W1. OSC 133 prompt-mark ledger across scripted sessions

The prompt-mark bug family has shipped three separate bugs (zsh PROMPT_SUBST
B-mark garbage, bash backslash collapse in ST embeds, fish ≥ 4 double marks).
Harness: `ptyjig` runs each shell with the bundled hooks via the *real*
ZDOTDIR/vendor-conf injection path, driving a scripted session: simple
command, failing command, Ctrl-C at empty prompt, Ctrl-C mid-typed-line,
Ctrl-C during a running command, multi-line PS2 continuation, heredoc body,
zsh reverse-i-search redraw, `clear`, `exec zsh` (re-injection must not
double), nested subshell.

- **Oracle 1 (ledger):** raw byte stream matches the mark grammar exactly;
  D exit codes equal the scripted commands' known statuses (Ctrl-C during a
  running command ⇒ 130; Ctrl-C at an *empty prompt* is integration-defined
  across FinalTerm implementations — pin Blackbird's hook behavior for that
  cell explicitly rather than assuming 130).
- **Oracle 2 (placement):** feed the same bytes to BBTerm; mark rows must land
  on rows whose text starts with the known prompt string; PromptNavigator
  enumerates exactly N prompts for N commands.
- **Validation:** the harness must go red if the shipped PROMPT_SUBST fix is
  reverted. Start with zsh + three scenarios. Cost: M.

## W2. EDITOR round-trip: `git rebase -i` through real vim/nvim

Scripted git session in a throwaway repo: `git rebase -i HEAD~3` with
GIT_EDITOR=vim (then nvim with mouse=a and kitty-keys), scripted keystrokes,
`:wq`, plus a rude variant where the editor is SIGKILLed mid-session.

- **Oracles:** (1) primary-screen rows above the prompt identical before/after
  the editor (alt-screen isolation at workflow level); (2) scrollback line
  count unchanged across the editor session; (3) mode restoration — bracketed
  paste, mouse modes, DECSCUSR, kitty flag stack, app cursor keys queried via
  the `current_mode`/DECRQM FFI must equal pre-editor values; (4) ground
  truth — `git log` shows the rebase happened. Cost: M.
- **Catches:** the RIS-doesn't-reset-modifyOtherKeys class generalized to
  every mode an editor touches; alt-screen scrollback pollution; 1047/1048/1049
  semantic drift.

## W3. Resize-storm replay during progress-bar-heavy builds

Tier 1 (headless, deterministic): replay recorded cargo-build / npm-install /
docker-pull transcripts via S1 with resizes injected at adversarial offsets —
inside a `\r…EL` redraw run, between a wide char's pending output, mid-OSC.
Tier 2 (one real PTY): actual `cargo build` of a toy crate with TIOCSWINSZ
fired every 150 ms.

- **Oracles:** (A) every line that scrolled into history *before* the resize
  survives reflow with text intact; (B) convergence — resize W→W′→W equals a
  straight-through replay at W for settled content (note: not a hard property
  of alacritty-style reflow — trailing-space trimming and wide-char boundary
  spacers legitimately differ; budget for a small allowlist from run one);
  (C) S3 invariants (`linesScrolled` monotone, pending-wrap consistent).
  Cost: M.

## W4. Kill-at-every-instant teardown sweep

Lifecycle races never show in happy-path tests because teardown timing is
uncontrolled. Determinism trick: deliver the signal when the child's
cumulative *output byte count* hits chosen offsets (pre-scanned from a
recorded run: mid-OSC-8, mid-synchronized-update (?2026 — a CSI private
mode, not a DCS) block, mid-UTF-8 continuation, between
A and B marks), not at wall-clock times. Workloads: `yes`, cargo build, an
OSC-8-emitting workload (`gls --hyperlink=always` from GNU coreutils —
brew-installable, not currently present — is a guaranteed emitter; verify
whether the installed `gh pr list` emits OSC 8 before relying on it), nvim
(alt screen active at kill time). Signals:
SIGINT/SIGKILL/SIGHUP.

- **Oracles:** (1) TerminalSession reaches terminated state < 2 s (no
  FIFO-hang — watchdog fails the test); (2) BBTerm accepts a post-mortem
  canned feed and renders it (parser not stuck in string-capture state);
  (3) zero fd-leak delta via lsof; (4) surfaced exit status matches the
  signal; (5) alt-screen-kill final-snapshot policy is consistent and
  documented, not flake. Cost: M.
- Complementary FFI-only variant (no processes; CI-able): **truncation
  simulation** — replay a recorded agent/fzf stream but cut it at every
  offset that begins an "armed" state (`?2026h`, `?1049h`, `?2004h`,
  `?1000-1006h`, `CSI > u`), then feed whatever TerminalSession writes on
  child-exit; assert full mode-state reset and a follow-up `echo hello`
  renders on the primary screen at column 0. Cost: S.

## W5. Paste gauntlet: byte-exact round-trip with a ground-truth oracle

Drive the REAL Swift paste pipeline (factor the sanitizer into a pure
function if it isn't one) against hostile payloads: embedded `ESC[201~`
(bracketed-paste terminator smuggling — a real attack class in other
terminals), lone ESC, C1 bytes, NUL, CRLF/CR/LF mixes, VS16 emoji + ZWJ
families, an OSC 52 blob mid-paste, 2 MB blobs, chunked writes that split the
`201~` delimiter itself across write() calls.

- **Oracles:** (1) drive PasteSanitizer's pure static functions directly
  (they already exist — no refactor needed), then the ptyjig child runs
  `stty raw -echo; exec cat > out.txt` — raw mode is load-bearing: with the default canonical line
  discipline, ICRNL translates the CR/LF-mix payloads and ERASE/kill bytes
  (0x7f, ^U, ^W — add them to the corpus, they're a classic paste-mangling
  class) would *edit* the input rather than round-trip, so only in raw mode
  does sha256(out.txt) == sha256(sanitizer(payload)) hold and divergence
  genuinely bisect to sanitizer vs transport (diff against the pre-sanitizer
  payload for attribution). An optional second canonical-mode leg with an
  expected-translation table tests the line-discipline interaction itself; (2) security — the
  embedded-`201~` payload must never cause trailing text to *execute*
  (sentinel `touch pwned` must not exist); (3) delimiters appear exactly once
  each in child-received bytes; (4) Ctrl-C priority — see C5. Cost: S.
- Rotate across line editors (readline, ZLE, fish, reedline, PSReadLine) —
  each handles the 200~/201~ envelope differently; mode 2004 must never be
  latched for shells that don't support it, and RIS must clear it.

## W6. KeyEncoder closed loop: verified by application *effect*

An encoding can match a byte-golden and still be one no real app accepts.
Harness feeds the app's output through BBTerm, reads the current mode state
via FFI before encoding each key (exactly as the app shell does), then calls
the real KeyEncoder and writes the bytes to the PTY.

- **Scenarios + ground-truth oracles:** (a) fzf with `--layout=reverse`
  (default layout is bottom-up, which would invert the arithmetic): pipe 100
  known lines, send Down×3 + Enter, oracle = fzf prints exactly line 4;
  (b) nvim with kitty
  protocol: map `<C-M-f>` to write a sentinel file, send the encoded chord,
  oracle = sentinel exists; (c) zsh vi-mode: Esc,b,b,cw + text, oracle = final
  command line matches; (d) mid-session flip: same logical key before/during/
  after nvim toggles kitty mode must produce the correct effect each time.
  Cost: M. Catches the Ctrl+Opt Meta-drop / flag-4 / keypad classes as
  *behavior*, not bytes.

## W7. ssh-to-localhost loopback against a containerized sshd

The v0.6.0→v0.6.1 TERM fiasco, end-to-end. Throwaway keyed sshd in docker
(ephemeral host port, not a fixed 2222 — avoid collisions; `-F /dev/null`,
scratch known_hosts), ptyjig runs zsh with the bundled ssh wrapper.

- **Oracles:** remote `$TERM` exactly matches the contract per
  `BB_SSH_REMOTE_TERM`; a chalk-style `node -e` sniff behaves; remote
  `stty size` tracks a local TIOCSWINSZ within one round-trip; Ctrl-C kills a
  remote `sleep`; local prompt marks stay unbroken across the ssh boundary;
  BBTerm rendering of the remote color test matches a non-ssh control replay
  of the same bytes. Skip-if-docker-absent. Cost: L.

---

# Part 3 — Weird and alternative shells

## H1. Shell-matrix conformance harness

One harness, every shell: {bash 3.2, `bash --posix`, bash-as-sh, zsh, fish 4,
dash, ksh, tcsh, csh} + brew-lazy {bash 5 (not currently installed), nushell,
xonsh, elvish, pwsh, oils, murex} (skip-if-absent so CI stays green). Replicate the real injection
env *exactly* — `ShellIntegration.envOverrides(...)` plus wherever
TerminalSession assembles the final child environment (replicating it may
mean extracting/reusing that assembly rather than copying values) — because
the injection path is the subject under test. Fixed 9-step session per shell:
cd, ls, failing command, Ctrl-C, a line that wraps, `printf` of a raw ESC,
a PS1 containing `\\` and `\$` with the rendered prompt diffed byte-for-byte
against a bare run (the assertion that would have caught the bash
backslash-collapse bug pre-ship), heredoc, exit.

- **Hook-capable shells:** W1's ledger + placement oracles.
- **Hookless shells (dash/tcsh/csh/ksh — zero current coverage):** the oracle
  *inverts* into degradation contracts: zero 133 bytes (no synthesized false
  marks), zero startup stderr garbage ("command not found", "Badly placed"),
  cwd tracking still works via the fallback path, snapshot shows every prompt
  line uncorrupted, `env` inside the shell shows the scrub contract held (no
  BB_* leakage, ZDOTDIR only for zsh, XDG_DATA_DIRS *prepended* not replaced).
- **First experiment (30 min, likely files a bug day one):** `brew install
  nushell`, run `nu` under the harness and simply count OSC 133 bytes per
  prompt cycle — nushell's shipped `default_config.nu` enables its own marks
  (`osc133: true`), the exact fish ≥ 4 collision class currently deferred in
  KNOWN_ISSUES. Pin which config the scratch HOME uses — the built-in
  default and the shipped config file have historically disagreed on this
  setting (verify the current state at install time) — or the mark count is
  environment-dependent. pwsh does *not* emit marks
  natively — only when an integration-emitting prompt kit (oh-my-posh,
  VS Code's shellIntegration.ps1) is configured, which is itself a worthwhile
  matrix cell. Encode whatever dedupe policy Blackbird chooses as a pinned
  expected event stream. Cost: S–M.

## H2. Hostile-zshrc gauntlet for the ZDOTDIR bootstrap chain

~12 fixtures attacking the injection handoff: `setopt no_rcs`, a `.zshenv`
that itself rewrites ZDOTDIR (chezmoi/nix-darwin users do this), PROMPT_SUBST
with a `$(...)`-bearing PS1, a pre-existing precmd array the hook must append
to (not clobber), `emulate sh`, `setopt nounset`, aliased `print`, oh-my-zsh,
and powerlevel10k with instant-prompt (which replays a cached prompt *before*
any rc runs and does its own console-output capture that can swallow or
reorder injected marks).

- **Oracle (the invisibility contract):** run each fixture twice — with
  Blackbird's injection env and bare. Rendered prompt text through BBTerm must
  be byte-identical; `typeset -p precmd_functions preexec_functions ZDOTDIR`
  shows exactly one __bb hook and the user's ZDOTDIR restored; the p10k
  fixture must not trip the instant-prompt warning banner. Cost: M.

## H3. Locale & environment poisoning matrix

{bash 3.2, zsh, fish 4, dash-control} × {LANG=C + emoji PS1,
LC_CTYPE=ja_JP.eucJP, TERM=dumb, TERM=xterm-kitty, COLUMNS/LINES lying vs the
real winsize, TZ flipped mid-session, a hostile rc pre-populating
PROMPT_COMMAND with its own `ESC]133;A`}. Rides the forkpty-based real-PTY
`TerminalSession` test infrastructure (NOT RecordingPTY, which records only
outgoing IME-commit bytes and drives no shell); the matrix runs strictly
sequentially — one live shell at a time, spawn→drive→reap — per the ground
rule.

- **Oracles:** mark grammar; marks byte-clean (no PROMPT_SUBST residue between
  `133;B` and ST); PromptNavigator count. The LANG=C + emoji-PS1 cell is the
  highest-suspicion one given history. Cost: S.

## H4. RPROMPT + transient-prompt reflow torture

zsh `RPROMPT='%T %~'` and fish transient prompts (native in fish ≥ 4.1 —
version-gate the fixture) rewrite the *previous*
prompt line via absolute cursor motion — reflow must reconcile it. Run 5
commands at 100 cols, then resize 100→72→45→100.

- **Oracles:** (1) canonicalization — but only for content *without*
  absolute-positioned prompt segments (historical RPROMPT rows are physically
  anchored at old-width columns and only rewrapped by reflow, while a fresh
  session right-aligns at the new width — comparing grids there false-fails
  by construction; compare reconstructed logical text streams instead, and
  reserve the grid-equality form for plain wrapped text); (2) every A-mark
  row still contains the prompt's first glyphs after every resize — the
  primary check; (3) occurrence count — the RPROMPT timestamp pattern appears
  exactly N times for N prompts (catches duplication). Start with oracle 3 —
  it's a regex over the snapshot. Cost: M.

## H5. vi-mode cursor-shape and position tracker

`bindkey -v` / `fish_vi_key_bindings`; type a 200-char command wrapping 3
rows; send motions (`0`, `$`, `5w`, `fx`); after each, compare BBTerm's cursor
against ground truth computed from the editor's own belief (zsh exposes
`$CURSOR` in ZLE — bind a probe widget). For the cursor-shape leg the fixture
must install the standard `zle-keymap-select` cursor-shape hook (stock
`bindkey -v` emits no DECSCUSR on mode switches, and fish's vi-cursor is
TERM-heuristic-gated) — then assert beam in viins / block in vicmd and
reversion after `exit`. Re-run the same script with
KeyEncoder's kitty-protocol encodings of the same keys to catch
protocol-specific double-apply. Catches the IME-caret-alignment-adjacent
class. Cost: M.

## H6. Login-shell startup-noise and capability audit

Spawn every shell as a LOGIN shell (dash-prefixed argv[0], exactly as
TerminalSession does) with Blackbird's full child env, scratch HOME.

- **Oracles:** (1) zero non-whitelisted bytes before the first legal prompt
  (grid-grep for error text — the funcsave-wrapper poison class); (2)
  time-to-first-prompt < 500 ms per shell (catches capability-probe hangs);
  (3) `env` diff against the documented contract; (4) a DA1 query round-trips
  (the shell/editor didn't eat the reply path). Budget per shell, not
  globally — pwsh/xonsh cold starts legitimately exceed 500 ms. Cost: S —
  the env-contract oracle for tcsh/dash is runnable today.

## H7. Starship / oh-my-posh cross-shell parity probe

The same starship config renders through five different shell escaping layers
(`%{%}` zsh, `\[\]` bash, fish builtin, nu's ansi). Deterministic config
(clock/battery segments off) + fixture repo.

- **Oracle (cross-check amplifier):** the visible prompt cell-text extracted
  from BBTerm's grid must be *identical across shells* — starship guarantees
  content parity, so any per-shell diff localizes an escaping/width bug in the
  pipeline Blackbird owns. Also: cursor rests exactly one cell after the
  suffix in every shell; A-mark position relative to the first glyph is the
  same constant. Run the set at 40 cols to force right-segment collision.
  Cost: S.

---

# Part 4 — Agent CLIs and demanding TUIs as bug drivers

## A1. Agent-transcript corpus: pi / opencode / codex / claude captures

The traffic class that found the VS16 bug in production, made a standing
asset. Capture once (one at a time, headless CLI modes, sandbox project,
4 MB cap): `script -q` or a tiny openpty recorder around
`claude -p 'render a markdown table with emoji and CJK'`, `codex exec`,
`opencode run`, `pi --print` — plus one scripted interactive run each with
canned stdin. Streams contain the real thing: braille + VS16 spinners,
sync-output 2026 bracketing, 10 Hz CUP+EL redraw loops, OSC 8 links,
streaming markdown, huge single-line writes.

Replay every transcript through S1 with the full shred sweep + mid-transcript
resize schedules + S3 invariants. Also: truncation-fuzz each transcript (cut
at every escape boundary, assert a follow-up canned prompt renders cleanly —
the Ctrl-C-mid-stream race made deterministic). Cost: M.

## A2. Content-preservation oracle — the "random newlines" regression net

The sharpest oracle in this part. Run the same agent prompt twice: once with
stdout to a file (no TTY — pure logical text, the *ground truth*) and once
under a recording openpty harness — the A1 recorder, *not*
RecordingPTY.swift — with the PTY winsize set explicitly to 80 (plain
`script -q` inherits the invoking terminal's size, a subtle nondeterminism
in a width-sensitive oracle). Replay the
presentation stream into BBTerm, reconstruct logical lines from scrollback
by joining on the LINE_WRAP row flag (the surface that exists today is that
flag in `BBCore.h` plus URLDetector's Swift-side wrap-join walk — factor the
walk out for reuse, or do the join in Rust; there is no ready-made
"reconstruction API" to call).

- **Oracle:** reconstructed logical lines == the pipe-mode text (after
  stripping SGR/spinner frames, identifiable via sync-output transactions).
  Any extra line break at a grapheme the pipe version keeps intact = a width
  or wrap-flag bug, with the offending grapheme pinpointed automatically.
  Replay at widths 79/80/81 and assert reconstruction is width-invariant.
- Seed prompt: `'print a paragraph containing ⚠️ 1️⃣ 👨‍👩‍👧‍👦 and a 200-char URL'`.
  Cost: M.

## A3. Synchronized-output (2026) torture from real agent frames

Extract real BSU…ESU transactions from A1 corpora and mutate: drop the ESU
(agent SIGKILLed mid-frame — happens constantly), double the BSU, nest,
splice a `resize2` mid-transaction, delay past the spec timeout.

- **Oracles:** (a) atomicity — mid-transaction snapshots equal the
  pre-transaction grid (no torn frame ever observable); (b) liveness — with a
  dropped ESU, content appears after timeout/next-input (no permanent
  freeze); (c) sync markers are presentation-only — final grid after mutated
  replay equals clean replay when payload bytes are identical. Cost: S.

## A4. nvim as a self-reporting oracle (msgpack-RPC, no keystrokes)

nvim is both the author of the escape stream *and* an independent reporter of
intended screen state. Drive it entirely over RPC (`nvim --listen`,
`nvim_input`, `nvim_command`) through edits, splits, `:terminal htop`
(double-nesting — nvim's libvterm re-emitting into Blackbird), syntax files
with emoji/CJK identifiers. At checkpoints query `screenstring(row,col)` +
`screenattr` for every cell.

- **Oracle:** nvim's declared screen vs BBTerm's grid after the same PTY
  bytes — any mismatch is a Blackbird decode bug *by construction*. Record
  the bytes so CI replays without nvim. Cost: M.

## A5. Multiplexer passthrough matrix (tmux / screen / zellij inside Blackbird)

Claude-Code-inside-tmux-inside-Blackbird is a top real-world config. Under
allow-passthrough, the *application inside tmux* wraps its sequences in
`ESC Ptmux;…ESC \` with doubled ESCs and tmux *unwraps* them toward the
client — direction matters when deciding whose escaping bug a divergence
implicates; the doubled-ESC layer is the same escaping trap as the bash
backslash bug. Note `allow-passthrough` defaults to OFF (verified on the
installed tmux) — the harness config must `set -g allow-passthrough on` or
the mux cell silently tests nothing. For each mux + a no-mux
control, an inner script emits a canonical set: 133 ledger, OSC 8 link,
OSC 0 title `NONCE-<n>`, OSC 52 with known base64. Record the mux's
*client-side* bytes — note `pipe-pane` cannot provide these (it captures the
inner pane stream); attach a real client inside `script -q` to capture what
the mux actually writes toward the terminal — then replay into BBTerm.

- **Oracle:** field-by-field reconciliation against the control run — mark
  count/order, exact link URI, title == NONCE, OSC 52 readback returns the
  exact base64 — with a known-divergence table for what each mux legitimately
  eats (screen drops OSC 8). Flags only Blackbird-side losses. Cost: M.

## A6. Unsupported-protocol residue oracle

ranger/timg/fastfetch/notcurses probe with XTGETTCAP, kitty graphics APC,
sixel DCS, iTerm2 OSC 1337. Unsupported ⇒ the *entire* sequence must be
consumed silently. Generate valid, truncated, oversized, and chunked-m=1
kitty-graphics transmissions.

- **Oracles:** (1) grid text contains zero 8-char substrings of payload
  interiors; (2) cursor position unchanged across each consumed sequence;
  (3) replay time is O(bytes) — a 10 MB truncated APC must not stall (the
  OSC-growth DoS cousin on the APC path); (4) cursor agreement with tmux,
  which consumes these. Fragmented-APC-across-chunks is the high-risk path.
  Cost: S.

## A7. Damage-shadow replay under redraw-heavy TUIs

Replay lazygit popup-over-list redraws, `watch -n0.1` with wide emoji, and
100 htop frames chunk-by-chunk; maintain a shadow framebuffer updated only
from damage-reported rows (exactly what MetalRenderer is entitled to do);
interleave seeded scroll/resize calls, where damage tracking historically
lies. Oracle: S3 #6 every frame. Cost: M.

## A8. Terminfo/TERM truthfulness probe

Invert the v0.6.x capability lesson: treat every advertised capability as a
testable contract. Parse the shipped terminfo (`infocmp`), collect XTGETTCAP/
DA1/DA2/DECRQM replies; for each cap with observable semantics (bce, ritm,
smxx, Tc/RGB, rep, ech, sync, hyperlinks, kitty flags) auto-generate a probe:
emit the sequence terminfo promises, snapshot-assert the semantic effect
(e.g. `setab 1; el` paints red iff bce claimed; `rep` repeats exactly n
times). Then run capability-sniffing programs (node/chalk sniff, emacs -nw
batch, tput scripts, opencode/pi) under Blackbird's TERM vs xterm-256color
and diff behavior forks. **Oracle:** capability claimed ⇔ effect observed,
mechanically, for every entry — plus a coverage report of
advertised-but-untested caps. Cost: L (start with the coverage report + bce/
rep probes: S).

---

# Part 5 — Differential and conformance testing

## D1. Twin-core lockstep differ: vendored core vs pristine upstream

`core/differ/` depends on blackbird_core *and* pristine upstream
`alacritty_terminal`. Dependency wiring is the trap: the workspace root's
`[patch.crates-io]` redirects crates.io `alacritty_terminal` to the vendored
fork, so a naive crates.io dep silently compares the fork against itself
(and building the differ *outside* the workspace un-patches blackbird_core's
own dep — vacuous in the other direction). Depend on upstream via a source
the patch table cannot rewrite: `alacritty_upstream = { package =
"alacritty_terminal", git = "https://github.com/alacritty/alacritty", tag =
<the release matching the vendored base> }`, keeping core/differ a workspace
member so blackbird_core still builds against the fork. Two residual wiring
notes: `[patch.crates-io]` applies workspace-wide, so the git-sourced
upstream still resolves its transitive `vte` dep to the *vendored* vte —
the comparison is fork-vs-(upstream-on-vendored-vte), probably desirable
(the two deliberate vte fixes don't need allowlisting) but know it; and the
alacritty monorepo may not tag individual alacritty_terminal crate releases
— a `rev` pin may be needed instead of `tag`. Feed identical
chunks to both; after each chunk diff a canonical serialization (cell
char/width/fg/bg/flags/link, cursor, mode bitset). Divergences check against `allowlist.toml` keyed by (field,
sequence-class, rationale, introducing commit) — VS16 promotion cites
420c0f9. The allowlist doubles as living documentation of every deliberate
fork behavior. Drive three ways: existing fuzz corpora; a new
`fuzz_differential` cargo-fuzz target whose panic condition is a
non-allowlisted diff (turns the fuzzer from crash-finder into
correctness-finder); the A1/D5 corpora.

- This is the escalation path the 2026-05-28 bug-hunt memory explicitly
  recorded ("areas swept clean, escalate to fuzz/differential next").
- **First run is the wiring tripwire, not just validation:** the VS16
  allowlist entry must be the first hit — if the differ comes back clean on
  run one, the dependency wiring is wrong (fork-vs-fork), not the code
  correct. Cost: M.

## D2. N-version grid jury: + libvterm, vt100 crate, avt

D1 is blind to bugs Blackbird *inherits* from alacritty. Add independent
implementations: libvterm (brew; 150-line C shim: stdin bytes → TSV grid),
the pure-Rust `vt100` crate, and `avt` (asciinema's VT). Caveat to verify
before counting jury votes: if avt/vt100 depend on the same `unicode-width`
crate as alacritty_terminal, their *width* columns are correlated, not
independent — the width jury for that dimension is D7's external references
(utf8proc, kitty's table, string-width). Majority vote: 2-vs-1 flags the odd
one out;
3-way splits go to spec archaeology (xterm ctlseqs citation) + allowlist.
Catches last-column pending-wrap, BS/CR+autowrap, ECH/DCH with straddling
wide chars, tab stops after resize. Cost: M.

## D3. tmux/screen as referee for real workloads

tmux's screen model is a battle-hardened independent implementation, already
installed, and drivable with zero GUI: `tmux -L bbtest -f /dev/null
new-session -d -x 100 -y 30`, `pipe-pane` records the *inner pane byte
stream* (the program's output — which is exactly what we want here: tmux's
model and BBTerm then consume identical bytes), `send-keys` is the input
robot, `capture-pane -p -e` dumps text+SGR. Replay the piped bytes into
BBTerm and diff cell-for-cell (+ screen's `hardcopy` as a third voter where
it supports the feature).

- Also the **reflow referee**: `tmux resize-window -x W2` +
  `capture-pane -J -S -` gives an independent rewrap of the same document —
  compare logical text streams (join on each side's wrap markers). Cost: M.

## D4. Query-matrix wire differ across live terminals

`probe.sh` runs *inside* each terminal (no keystroke injection — the stimulus
originates in-terminal): emits DA1/DA2/DA3, XTVERSION, DECRQM for ~45 modes,
DECRQSS, XTGETTCAP over every bundled-terminfo cap, CPR/DECXCPR, OSC 10/11/12,
OSC 52 readback, `CSI ? u`; reads replies with `read -rs -t 0.3` (fractional
`-t` needs zsh or bash ≥ 4 — probe.sh must not run under macOS system
bash 3.2); hex-logs (query, reply) pairs. Blackbird runs it via the headless
pty-host (D6); kitty via `kitty --start-as=hidden`; wezterm via
`wezterm start -- cmd`; ghostty via `ghostty -e cmd` (no `start` subcommand;
not currently installed) — each skip-if-absent; tmux detached. Render the
N-terminal matrix; flag Blackbird-only
replies, empty replies where terminfo promises the cap, and format deltas
(param order — the kitty flag-4 class; ST vs BEL termination). Cost: M.

## D5. Real-program cast corpus + vttest replay goldens

Record once via detached tmux (input robot) or `script -q`: nvim
scroll/edit, htop 10 s, lazygit, fzf, ranger, fastfetch, cmatrix, plus
expect-driven vttest menus 1/2/7/8 (cursor movements, screen features, VT52,
and VT102 insert/delete — menu 8 is the higher-value one for this corpus) —
Blackbird has never run vttest. Commit recordings as versioned corpus files;
CI replays through D1 (the D2 jury leg lands in Phase 3 — D1 alone suffices
initially) and diffs per-screen. Screens exercising features
Blackbird deliberately lacks (DECDWL/DECDHL) get degrade-gracefully
assertions: no stray cells, cursor where a dropping terminal would put it.
Cost: S–M.

## D6. esctest via DECRQCRA + `bbcore-pty-host`

esctest (iTerm2's conformance suite) verifies screen state over the wire via
DECRQCRA (checksum-of-rectangle) — which Blackbird doesn't implement. Step 1:
implement DECRQCRA in core (xterm's published algorithm; xterm is the
reference implementation, iTerm2 ships it, and WezTerm implements it behind
a config opt-in (reported as `enable_checksum_rectangular_area = true` —
verify the exact option name at build time); kitty does NOT implement it, so
kitty is unusable as the esctest reference here). Genuinely useful shipping feature; lands behind the
existing reply rate caps. Step 2: `tools/bbcore-pty-host` — ~200-line
headless binary: PTY pair, client side pumped into BBTerm, BBTerm's replies
written back. Step 3: run esctest against it; calibrate by also running
esctest against xterm (XQuartz) or WezTerm with the checksum option enabled,
and diff the two failure vectors — reference-passes/Blackbird-fails is a
strong signal; both-fail goes to the allowlist. Budget note: esctest is
aging Python — expect porting/maintenance cost on top of DECRQCRA, which is
part of why this is L (DECRQCRA itself: S–M).

## D7. Exhaustive width-conformance sweep vs a 5-reference jury

The VS16 class made systematic. For every codepoint (~1.1 M) + every sequence
in Unicode's emoji-test.txt + combining clusters: write at column 0 of an
80×2 BBTerm, read the cursor column = effective width. Jury columns:
unicode-width (Rust), utf8proc, kitty's generated wcwidth table, **node's
string-width — the column that predicts real-world breakage, because it's
what Ink/Claude Code actually use** — and Swift's CellWidth (hit-testing/IME
must agree with the core: the triple-agreement requirement, including
clusters *chopped across feed boundaries*).

- **Oracle + artifact:** any row where Blackbird disagrees with string-width
  is a candidate random-newlines regression; reference disagreements get a
  documented policy line ("we follow kitty on VS16"). Commit the matrix as a
  golden so vendored-alacritty and unicode-width bumps turn silent Unicode
  drift into reviewed diffs. Runtime: minutes in-process. Cost: S–M.
- **DoS side-probe:** 100k-ZWJ flood into one cell completes < 500 ms with
  flat RSS (per-cell zero-width storage must be capped).

## D8. Keyboard-protocol encode differential vs the protocol author

kitty's `key_encoding.py` is the normative kitty-protocol implementation.
Generate golden tables for (key × 32 modifier combos × flag combos 0..31 ×
event types), assert KeyEncoder byte-equality; xterm's modifyOtherKeys tables
for the legacy path; ambiguity cases (Ctrl-I vs Tab) in an explicit
equivalence table, never silently skipped. Loop closure: pipe KeyEncoder
output back into a blind-written reference CSI-u decoder (no key-report
decoder exists in core — the core only dispatches the kitty-flag mode
operations) and assert round-trip identity
(per house rules, the decoder is written blind by a separate subagent).
Cost: S. This is precisely the safe alternative to forbidden keystroke
injection.

## D9. Mode-lifecycle conformance matrix

For every private mode × every lifecycle event {RIS, DECSTR, alt-screen
enter/leave, resize}: set → DECRQM confirm → lifecycle op → DECRQM observe →
**probe behaviorally** (2004 set ⇒ a paste actually arrives bracketed; mouse
mode set ⇒ FFI mode bit set). Compare against kitty + tmux columns (each
runs the same byte program hidden/detached). Blackbird-differs-from-both =
presumed bug. Subsumes the static `decrqm.rs` checks with *transitions* —
the exact shape of the RIS/modifyOtherKeys bug. Cost: M.

---

# Part 6 — Record/replay and corpus mining

## R1. PTY flight recorder (`.bbcast`)

Turns every "Connor saw a glitch" moment into a byte-exact repro — the VS16
hunt took days because nobody had the exact bytes. Tee the session read path
into a bounded 8 MiB ring buffer per session, framing RAW bytes, RESIZE,
FOCUS, PASTE boundaries, and periodic SNAPSHOT-CHECKPOINT grid hashes. A
Diagnostics-tab button dumps the ring to a `.bbcast` file (+ converter to
asciinema cast v2 for eyeballing). DEBUG builds or default-off pref;
recordings may contain sensitive text — local-only, with a redaction note in
the UI. Checkpoint hashing must measure < 0.5 ms at 120×40 so it can't dent
the latency gate. Cost: M.

## R2. Checkpoint-verified replay: live-vs-replay self-differential

Replay a `.bbcast` into a fresh BBTerm; at each checkpoint marker, hash the
grid the same way (cross-language golden test proves Swift capture and Rust
replay hash identically) and compare with the recorded live hash. First
divergent checkpoint brackets the offending window to N KiB; S4 minimizes it.
**This catches timing/interleaving state corruption that byte-replay alone
cannot** — the live incremental path diverging from a clean replay of the
same bytes. Run nightly over the day's dumps: every ordinary workday becomes
a soak test with an oracle. Cost: L (rides R1).

## R3. Shipped-bug golden corpus

One `.bytes` + rich golden (full grid serialization + expected terminal
*replies* via the event callback — the kitty/modifyOtherKeys bugs are reply
bugs, not grid bugs) per historical bug: VS16, PROMPT_SUBST, doubled
backslash, fish 4 doubles, URL-wrap, flag-4, RIS/modifyOtherKeys, OSC caps.
Replayed at chunk sizes 1/7/whole per commit — every golden doubles as a
chunk-invariance case. Most repro bytes are recoverable from fix-commit test
fixtures. `--bless` env-var regeneration. Rides default `cargo test`; KB
fixtures. Vendor bumps of alacritty_terminal are exactly when these re-break.
Cost: S.

## R4. Public-cast mining vs avt

`scripts/mine-casts.sh` downloads ~200 popular asciinema.org casts (cached
locally, never committed): thousands of real-world byte streams for free.
Replay through BBTerm + avt (cast parsing is trivial JSON; avt is asciinema's
own Rust VT), diff final grids; reject casts advertising > 500 cols/rows
before allocation. Curated-subset CI stays green via a per-cast/cell
whitelist; new divergences fail loudly. Cost: M.

## R5. Corpus exchange with the fuzzers

`cargo fuzz cmin` every harvested corpus (A1 agents, D5 TUIs, R4 casts) into
the `fuzz_term_input` corpus — and `fuzz_grammar`'s (M2, once built; only
four targets exist today) — and measure the coverage delta — one
capture feeds three oracles (fuzz, shred, differ). Cost: S.

---

# Part 7 — Chaos, fault injection, environmental weirdness

## C1. SIGWINCH storm harness

Standalone binary (never xctest): forkpty + dash child printing
position-encoded ruler lines (`%06d |` + 200 cols of self-describing chars);
TIOCSWINSZ from a second thread at up to 500 Hz for 10 s, random dims
[20..300]×[10..100], always ending at 120×40.

- **Oracles:** liveness under a 30 s watchdog; after quiesce, the child's
  `stty size` == final resize == snapshot dims and a full-width ruler
  occupies exactly one row (no phantom wrap); every numbered line in
  scrollback is intact or wrapped at a width that was *actually current* —
  position-encoding makes misreflow detectable offline. Cost: M.

## C2. Slow-drain / stalled-reader torture

Fast writer, frozen consumer — the FIFO-swap-hang and duplicate-output
classes. Child writes a self-verifying framed stream
(`[seq][len][crc32][payload]`, 32 MB, SHA trailer); harness read loop injects
Pareto-distributed stalls (0–200 ms, occasional 2 s), read sizes alternating
1 byte / 64 KB, everything fed to BBTerm *and* a shadow buffer.

- **Oracles:** byte conservation (shadow == child stream exactly: no
  drop/dup/reorder); child forward-progress bound; final screen matches an
  un-stalled control replay; **during a stall, one keystroke written to the
  master still reaches the child** (the vanished-keystroke concern). Cost: M.

## C3. Process-lifecycle zoo

Purpose-built tiny C children (cheaper and more precise than shells):
(a) SIGHUP-ignorer holding the slave fd — teardown must still complete < 2 s;
(b) child forks a grandchild holding the slave then exits — child exit must
drive teardown via wait/SIGCHLD even though the grandchild keeps the slave
open (the master never sees a read-side signal here — and note Darwin yields
EOF/0 on a fully-closed slave, not Linux-style EIO, so a read-error-driven
teardown design is wrong on this platform twice over); the grandchild must
not keep the session alive; (c) `kill -STOP`
mid-flood 3 s then `-CONT` — no data loss, no watchdog trip; (d) `kill -9`
exactly mid-OSC-payload — parser must recover (sentinel screen golden after).
Oracles: teardown latency, zero zombies with our marker env, lsof fd delta
== 0, sentinel goldens. One child per test method. Cost: M.

## C4. `hostile.c` zoo + RIS-recovery oracle

Pathological-but-legal byte generators (Rust functions for the FFI tier; the
3 nastiest promoted to a real 1-byte-per-write C child with 50 µs sleeps):
escape dribbling; DECCKM/DECAWM toggled at 10 kHz (event-rate-cap workout);
DCS and APC opened, never terminated, followed by 100 MB of noise — a
*boundedness-verification probe*, not a documented open bug: the OSC path
got its 8 MiB cap when the OSC-growth DoS was fixed (2026-06-20), and code
reading says the vendored vte discards SOS/PM/APC payload bytes without
accumulation while the XTGETTCAP DCS buffer is capped at 4 KiB — but no
harness has confirmed flat memory on these paths end-to-end, which is
exactly what this phase does (and then it stays as the regression net);
mode 2026 held forever; OSC 52 with a 10 MB payload; bracketed-paste
toggling under load. Memory budget is explicit: junk must be *discarded* by
the parser, so the harness runs under an RSS watchdog (~32 MB over baseline
fails the test — partly the point).

- **The shared oracle:** after every hostile phase, feed RIS + a fixed
  sentinel pattern and assert (a) snapshot == golden, (b) mode mask ==
  defaults, (c) DECRQM round-trips defaults, (d) event-callback counts
  respected the documented rate caps, (e) recovery feed < 100 ms (starvation
  bound). "Does RIS actually restore a known-good state after X?" is the
  generalized form of the modifyOtherKeys bug. Cost: M.

## C5. Paste-into-a-deaf-child + Ctrl-C priority

Child `exec`s a tiny C program that installs a SIGINT handler (marker to a
side pipe) and never reads stdin. Paste 10 MB through the real sanitizer →
write path.

- **Oracles:** (1) no main-thread stall (write path must be non-blocking
  under a blocked kernel PTY — and the harness must pin the real capacity
  empirically at startup: with a canonical-mode deaf slave, Darwin blocks
  master writes once the canonical queue is non-empty at roughly TTYHOG
  ≈ 1 KiB, nowhere near the folk-wisdom 64 KB); (2) **Ctrl-C priority**, in
  two variants because the kernel dictates what is testable: (a)
  *newline-free single-line payload* — the canonical queue stays empty, the
  master never blocks, and the line discipline's ISIG processing genuinely
  bypasses the full input queue, so "child receives SIGINT < 500 ms" is a
  valid oracle that isolates Blackbird's userspace write-queue policy; (b)
  *newline-bearing payload* — once canq > 0 the kernel refuses further
  master writes (EAGAIN), including the ^C byte itself, so NO terminal can
  pass a child-receipt oracle; the oracle instead moves to Blackbird's
  write-*ordering*: via a DEBUG fd-tap seam (new), assert the ^C bytes are issued
  to the master fd ahead of the remaining userspace-queued paste; (3) when
  the child later drains, what arrives is a clean *prefix* (truncation at a
  chunk boundary is acceptable-and-logged; interior gaps or duplicated
  chunks are the bug); (4) the overflow log latch fired exactly once.
  Cost: M (the Ctrl-C variant (a) alone: S, highest value).

## C6. Metal fault-injection loop (offscreen)

Extend the existing DEBUG reconfigure seam into a FaultPlan: per frame, force
{drawable: nil, commandBuffer: nil, psoRebuild: throw, atlasUpload: fail} for
frames [i, j), then heal. Render offscreen to an MTLTexture — no window, no
CAMetalLayer.

- **Oracles:** recovery within 5 frames of healing (readback vs golden
  render); snapshot refcounts return to baseline (no retention leak while
  frames can't present); no main-thread stall > 50 ms during the fault
  window; exactly-once error logging, not per-frame spam. Catches the
  silent-permanent-black-view class in *execution*, complementing the
  silent-failure-hunter's static reviews. Cost: M.

## C7. SnapshotCoalescer jitter chaos

Real coalescer + BBTerm, fake consumer queue the test suspends/resumes on a
seeded schedule (50–500 ms). Feed a monotonically-numbered screen at high
rate. Oracles: last delivered snapshot is never stale; delivered counters
strictly increase; every `take_snapshot` matched by `release` at quiesce
(leaks under suspension are the likely bug); feed-side throughput during
suspension stays ≥ the garbage floor. The dynamic form of the 8→71 MB/s
cliff. Cost: S.

## C8. Display-topology property fuzzer (the v0.3.2 class)

Pure CGRect math, zero windows: 10k seeded topologies (1–4 screens, origins
in [-5000, 5000], real-hardware size list, random menu-bar/Dock insets) ×
savedFrames {on a removed screen, straddling, in a phantom gap, 1 px
overlapping}.

- **Invariants:** ≥ 200×100 pt of the result intersects some visibleFrame;
  the title-bar strip is grabbable; result ≤ target screen; **idempotent**
  (nudging the result again is a no-op); **no gratuitous moves** (an already-
  valid frame returns unchanged — the "recentered at original size"
  regression). < 1 s for 10k cases. Cost: S.

## C9. Time-warp seam

Audit-then-inject: grep for `Date()`, `CFAbsoluteTimeGetCurrent`,
`DispatchTime`, `Instant::now`; classify needs-monotonic vs needs-wall (the
findings table alone tends to surface a misuse). Then clock-seam tests: wall
steps ±1 h, monotonic pause 60 s (sleep simulation). Oracles: watchdog
reports no stall on a wall step with healthy monotonic progress; LatencyProbe
never emits negative/absurd samples; the FFI rate limiter neither locks out
permanently nor bursts after a backwards jump; DiagnosticReportStore
timestamps stay ordered. Never touches the host clock — fake clocks only.
Cost: S.

---

# Part 8 — Model-based testing, fuzz escalation, agent-driven users, renderer cross-checks

## M1. Stateful grid model machine (proptest state-machine)

~300-line abstract reference model — cursor (row/col/pendingWrap), margins,
tabstop BTreeSet, G0/G1 charset, DECOM/DECAWM/IRM, width map; deliberately NO
scrollback/colors (small enough to trust). Transition enum {Print(ascii|wide|
combining), CUP, cursor moves, SetMargin, IND/RI, HTS/TBC/CHT, DECSET/RST,
Resize(2..=200, 2..=120), ED/EL} serialized to bytes → FFI. Assert model
state == snapshot state after every transition. **Shrinking hands you a
minimal op sequence — the whole payoff vs blind fuzz.** proptest is already a
dependency. 256-case CI budget, 10k locally. Cost: M.

## M2. Grammar-aware fuzz targets

`fuzz_grammar.rs` with `#[derive(Arbitrary)] enum Seq { Osc133{...},
Osc8{id,uri}, Osc7, Osc52{clip,b64}, KittyPushPop{flags,depth},
Decrqm{mode}, Xtgettcap{caps}, Sgr(..), Chunked(Box<Seq>, split_points),
RawNoise }` — valid prefixes are measure-zero for blind byte fuzz, so the
deep OSC/DCS state never gets reached today. The `Chunked` variant is cheap
and lethal. Post-sequence oracle: feeding CAN + plain text must render (the
parser never wedges); mode state round-trips DECRQM. Seed the corpus from the
serializer itself. Cost: M.

## M3. Reply-path conformance fuzzer + echo loop

`fuzz_reply_storm` checks volume; nothing checks *correctness*. A strict
validator for the closed set of replies Blackbird emits (DA1/DA2, DSR-CPR,
DECRPM, DCS XTGETTCAP, OSC 52, kitty `CSI ? u`) rejects anything else; the
generator interleaves questions with state changes, and the harness knows
ground truth from its own state mirror — CPR must equal the model cursor
(honoring DECOM!), DECRPM must match the last DECSET/DECRST, the kitty
report must equal top-of-stack. Plus the **echo loop**: append Blackbird's
own replies back into its input for N ≤ 16 rounds (models a half-configured
remote echoing responses) — parser must reach quiescence with flat RSS and
mode-stack depth. Cost: M.

## M4. FFI call-sequence torture with a snapshot-immutability oracle

`fuzz_ffi_ops.rs`: `Arbitrary` op sequences {Feed(≤4k), Resize(≤300×200 —
60k cells ≈ 2 MB, computed budget stated per the caps-in-code rule),
SnapAcquire, SnapRelease(idx), SnapHashCheck(idx), Scroll, TextRange(stale
coords), Free+Reinit} against the real C API exactly as Swift would call it.
**Core oracle: a held snapshot must never mutate** — hash on acquire,
re-hash on check; any change while held is a torn-snapshot bug even with no
crash (the renderer would draw torn state as visual corruption). ASan
locally; keep a miri-compatible subset as the regression net for the
historical H-5 UB class (fixed + miri-validated 2026-06-20 — this guards the
fix, it is not an open issue). Escalates `sweep_fuzz_ffi` from "does it
crash" to "does the contract hold". Cost: M.

## M5. Reflow text-conservation property

Generate documents as logical lines (ascii + CJK + VS16 + combining +
OSC 8 links spanning wraps), print at W0, random-walk 3–10 resizes
(20..=200), return to W0. Oracles: (A) full text extraction equals the
source document; (B) per-step — the non-space character multiset is
invariant across *every intermediate* resize; (C) every link URI
reconstructs exactly even when its anchor wrapped 3+ rows. Shrinker output =
minimal doc + resize walk, exactly the repro format these bugs historically
needed. Cost: S (ascii-only first).

## M6. OSC 133 semantic model over hostile shell-shaped streams

Shell-agnostic version of W1: proptest generator emits pseudo-sessions
{PromptStart, PromptEnd, PreExec, CmdEnd(exit), Output(text with embedded
fake marks / clears / CUP), AltScreenEnter/Exit, Resize, ChunkSplit} —
*weighted toward the malformed orderings real shells produced*. A ~100-line
reference model implements documented mark semantics (duplicate policy
spec'd from iTerm2/kitty FinalTerm handling). Oracle: no mark-*query* FFI
exists today — marks surface only as PromptMark events (kind, no row) via
`bb_term_set_event_cb` — so either (a) mirror the event stream and derive
each mark's row from a `take_snapshot` cursor read at event time, comparing
that mirror to the model (works now), or (b) add a small mark-query FFI /
row payload on the PromptMark event as an explicit prerequisite build step,
the way D6 does for DECRQCRA. Marks must survive reflow with anchors intact.
Divergences on ill-formed input where no spec exists get an explicit policy
decision → model or KNOWN_ISSUES. Cost: M.

## G1. Typist personas with machine-checkable contracts

Agents drive `ptyjig` — but every action carries a *declared post-condition*,
so monkey-testing becomes falsifiable:

```
{action:"type 'ls -la\r'", post:["echo_matches_input","new_prompt_count:1"]}
{action:"^C",              post:["caret_C_visible","no_partial_command_remains"]}
```

A deterministic observer evaluates ~15 named predicates against the next
quiescent snapshot; the OSC 133 marks Blackbird itself injects are the ground
truth for "where is the prompt". An LLM observer is the fallback judge *only*
for contracts the predicate library can't express — and per oracle rule #6
its verdicts are advisory (triage queue), never an automatic red. Personas:
impatient-dev (interrupts half-typed commands, spams Enter, pastes 500 KB,
resize-storms during nvim), paste-monster, resize-fiend, protocol-adversary,
and focus-flapper (drives `FocusEmitter` — focus-in/out flaps with mode 1004
toggling mid-stream; the historical duplicate-output bug's actual trigger,
098b2d9, was focus handling, and no other harness generates focus
transitions). Rotate across all installed shells — tcsh/ksh/dash have zero
coverage today. Cost: M.

## G2. Claude Code as the workload

Blackbird's number-one real user, run as a real bounded workload:
`claude -p 'write fizzbuzz to x.py' --allowedTools Write` inside ptyjig
(zsh + bundled hooks, sandbox dir, 120 s cap). Three oracles: (1) the W1
mark checker on the live stream; (2) the grid-width oracle — recompute each
glyph's expected column from the raw bytes with a reference width function
and diff against where BBTerm placed it; (3) the transcript oracle —
`claude -p` also logs its output; final scrollback text must contain those
lines *unduplicated* (the v0.2.13 duplicate-output class, directly). Cost: M.

## G3. Render-vs-model cross-check (offscreen Metal)

The entire Rust suite is structurally blind to renderer-only bugs (the
FrameKey atlas bug class). Offscreen MTLTexture — no window needed. Render a
synthetic snapshot full-grid, then re-render each cell *alone* with a fresh
renderer and cold atlas; compare pixel hashes of the corresponding rects.
Full-grid ≠ isolated-cell ⇒ cross-cell state leakage at (row, col, attrs).
Drive with adversarial snapshots: 4,000 distinct CJK/emoji glyphs to force
atlas eviction churn then re-request early glyphs; font-fallback churn
(scripts the primary font lacks — a classic atlas-adjacent bug source
distinct from eviction); ligature/box-drawing seam cells; alternating
underline styles next to wide glyphs. Texture memory computed up front (~100 MB worst
case). Cost: M.

## G4. Cast → PNG pipeline + LLM judge as diff classifier

For "looks wrong to a human" regressions (box-drawing seams, powerline
clipping, color banding). Replay D5/A1 casts, render final + 5 intermediate
snapshots through G3's offscreen path to PNGs. Tier 1 (deterministic):
pixel-hash against the last-green build's PNGs — a strict golden, since the
corpus is deterministic. Tier 2 (only on diffs): a Claude vision call answers
a structured rubric ("are box borders continuous? half-rendered wide glyphs?
duplicated status lines?") to classify benign vs suspicious. The LLM
classifies known-diffs; it is never the primary oracle, so nondeterminism
can't cause silent passes. Cost: M.

## G5. Self-play: generator agent vs referee

Nightly: Agent A reads core/src diffs-from-upstream and writes *targeted*
stream generators aimed at the seams local patches created (mode-interaction
products like DECAWM-off + wide char at right margin + resize; sync-output
spanning RIS; kitty push/pop across alt-screen). Streams run through D1/D2;
non-allowlisted divergences auto-minimize via S4 and land as JSON findings.
Agent B triages: reproduces, classifies bug-vs-intentional, drafts the fix
note or KNOWN_ISSUES entry. Cost: L.

## G6. Nightly autonomous hunt loop

The compounding layer. Each night pick ~6 cells from {persona} × {shell} ×
{workload: plain, nvim, tmux, claude -p, lazygit}; run 10-minute ptyjig
sessions with all deterministic oracles armed; a triage agent minimizes each
anomaly (S4), fingerprints it (SHA of minimized repro + oracle rule id), and
dedupes against a committed ledger *and whatever KNOWN_ISSUES.md currently
marks deferred* (e.g. fish ≥ 4 doubles, the double-⌘G find-anchor race, the
Option+letter-during-CJK-preedit residual — all actually in the file) — the
suppression list must track the file, never a hardcoded snapshot, so a
regression of a since-fixed bug (like the OSC cap) is reported, not
swallowed. Weekly it drafts (never
auto-files) the top finding as a gh issue. Serialized, caffeinate-gated to
idle time, 45-min budget, RSS watchdog, coverage tracking so tcsh/ksh/dash
actually get hit. Cost: M (after S1–S4 exist).

---

# Part 9 — The Swift interaction layer (selection, mouse, find, IME, settings)

Everything above lives at the byte-stream/PTY/core level. But four shipped or
open bugs live in the Swift layer between the core and the user — selection,
mouse encoding, find, IME — and all of it is headless-reachable (the existing
SelectionBlindTests / FindBar tests / IMETests / MouseInsetMappingTests prove
the seams exist). Simulation ideas:

## U1. Selection-semantics property harness

The v0.2.10 double-click-drag word-extend bug lived here, and nothing above
touches selection. Generate grids with adversarial content (wide CJK,
combining marks, VS16 emoji, URLs, tabs, trailing spaces, soft-wrapped
lines), then drive the selection model directly (unit level, no real mouse
events): click points, double-click word seeds, drag paths crossing wrap
boundaries and wide-glyph halves, shift-extends, and selections held across
a reflow-triggering resize.

- **Oracles:** (1) selected text == `text_range` extraction of the same
  cells (the core is the referee); (2) word-boundary rules are symmetric
  (extending left then right lands where right-then-left does); (3) a
  selection anchored on a wide glyph never splits its cell pair; (4) after
  reflow, the selection either tracks its text or clears — never silently
  points at different text. Cost: S–M.

## U2. Mouse-report encode closed loop

`MouseReportEncoder` is a pure function with zero simulation coverage. Two
tiers: (1) unit differential — encode clicks/drags/scrolls/modifiers across
all protocols (X10, normal, button-event, any-event; SGR 1006 vs legacy) and
diff against kitty's/xterm's documented encodings, the D8 pattern applied to
mice; (2) closed loop — ptyjig hosts `nvim` with `mouse=a`, the harness
encodes a click at (row, col) via MouseReportEncoder, writes the bytes to
the PTY, and asks nvim over RPC where its cursor/visual selection landed —
ground truth by construction, including the inset/padding coordinate
mapping. Cost: S (tier 1) / M (tier 2).

## U3. Find-during-live-output simulation

KNOWN_ISSUES carries an open double-⌘G anchor-race residual. Harness: feed a
scripted stream into a session while driving FindController at unit level —
search, rapid repeated find-next, search-while-output-scrolls,
search-spanning-a-wrapped-line, pattern that matches text about to scroll
out.

- **Oracles:** (1) the match set equals grep over the extracted scrollback
  text at quiesce; (2) rapid ⌘G advances visit every match exactly once, in
  order, never skipping or repeating (targets the open residual directly);
  (3) match highlight ranges always reference cells whose text still equals
  the pattern. Cost: S–M.

## U4. IME preedit scripting via NSTextInputClient

The IME Int-trap crash and caret misalignment both shipped; the
Option+letter-during-CJK-preedit residual is open. No AppleScript needed:
call the `NSTextInputClient` surface directly at unit level —
`setMarkedText:` / `insertText:` / `unmarkText` interleaved with raw
keystrokes, Meta chords, Ctrl-C, focus changes, and a resize mid-composition.
Scripts model real IME sessions (romaji→hiragana→kanji candidate cycles,
Korean jamo composition, dead-key sequences).

- **Oracles:** (1) bytes reaching the PTY equal the committed text exactly —
  never preedit intermediates; (2) caret rect column equals the reference
  width function's prediction for the preedit string (the caret-alignment
  class); (3) no crash/trap for any interleaving (the Int-trap class);
  (4) after cancel, the grid contains zero preedit residue. Cost: M.

## U5. URLDetector multi-row wrap gauntlet

The actual v0.3.6 bug site — the Swift join walk, not core reflow. Generate
grids with URLs soft-wrapped across 2/3/4+ rows, including edge-fill
boundaries (URL ends exactly at the last column), wide glyphs straddling the
wrap, and adversarial continuation-row leaders that *look* like URL starts.
Drive URLDetector directly (existing URLDetectorMultiRowWrapTests as
substrate).

- **Oracles:** joined URL equals the source URL byte-for-byte at every
  width; all detection security guards hold at every row boundary; detection
  is stable under reflow (re-detect after resize finds the same URL).
  Cost: S.

## U6. Preferences/settings churn fuzzer

Two shipped bugs live here: the @AppStorage↔UserDefaults feedback-loop
beachball (982b719) and the issue-#28 sink dedupe latch (one write fanned
out as ~17 emissions). Fuzz sequences of preference writes (same-value
rewrites, rapid alternation, concurrent-key writes, migration-shaped
payloads) against the real Preferences object with a counting observer.

- **Oracles:** (1) emission count per write is exactly the documented
  fan-out (latch fires once — pin the number so regressions are loud);
  (2) same-value writes emit zero (the feedback-loop guard); (3) no
  re-entrant objectWillChange cycles (depth counter); (4) UserDefaults
  end-state equals the last write per key. Pure unit level; existing
  PreferencesAdversarialTests are the substrate. Cost: S.

## U7. Hover, drag-out, and file-drop gauntlet

The TerminalView hover/dragging extensions have no simulation coverage, and
file-drop quoting is a classic terminal bug site. Unit-drive the drop-path
insertion with hostile filenames (spaces, quotes, `$(cmd)`, newlines, emoji,
10k-char paths) — oracle: the bytes written to the PTY, when parsed by a
POSIX shell tokenizer, yield exactly one argument equal to the original
path, and nothing executes (sentinel check). Drag-out: the pasteboard text
for a dragged selection must equal the U1 selection extraction. Hover:
link-hover hit-testing over wide-glyph and wrapped-URL cells must agree with
`bb_snap_link_id_at`. Cost: S.

## U8. Sparkle appcast gauntlet (local parse only)

Feed the update flow malformed/adversarial appcast XML parsed from local
fixtures (no network): downgrade versions, non-integer builds, missing
EdDSA signatures, huge/hostile fields. Oracles: the version comparison uses
CFBundleVersion monotonically (the v0.1.1 shipped-broken class), invalid
feeds are rejected without UI side effects, and no update prompt can steal
key window from a terminal tab (the popup-hijacks-tab-1 class, asserted at
the window-ordering-policy level rather than via GUI automation). Cost: S.

Further U-series candidates, unelaborated but real (schedule alongside
Phase 3 so they don't rot): scroll/viewport interaction (selection-drag
autoscroll during live output, scroll-to-bottom-on-input policy),
mid-session palette swaps (OSC 4/10/11/104 *set* side — the query side is
D4's; a cell-color oracle under G3/G4 would close the loop),
occlusion/power-aware rendering throttling (fake occlusion state, assert
cadence + no stale grid on un-occlude), and TSAN-armed variants of the
C-series harnesses to name the cross-thread modality explicitly.

---

# Coverage map: would this have caught our real bugs?

| Historical bug | Harnesses that catch the class |
|---|---|
| VS16 emoji "random newlines" (v0.2.13) | D7 width jury, A2 content-preservation, S1 shred (VS16-split points), D1 differ, R3 golden |
| zsh PROMPT_SUBST B-mark garbage (v0.6.2) | W1 ledger, H2 hostile-zshrc, M6 mark model, H3 locale matrix |
| bash backslash collapse in ST embeds | H1 bash-matrix backslash probe, W1, A5 (same escaping trap, mux edition) |
| fish ≥ 4 double marks (deferred) | H1 native-collision counting (also pre-discovers nushell/pwsh) |
| setenv(NULL) SIGSEGV in PTY child | H6 login-noise audit (spawns via the real TerminalSession env-assembly path, where the bug lived); C3 covers the adjacent teardown side |
| kitty flag-4 wire order (v0.2.10) | D8 encode differential, W6 app-effect loop (output-side wire format — input-chunking harnesses can't reach it) |
| Double-click-drag word-extend (v0.2.10) | U1 selection property harness |
| RIS not resetting modifyOtherKeys (v0.2.9) | D9 mode-lifecycle matrix, C4 RIS-recovery oracle, W2 editor round-trip |
| Ctrl+Opt Meta-drop (v0.4.0) | D8, W6 app-effect loop |
| FIFO-swap hang | C2 slow-drain, W4 kill-at-instant, C5 deaf-child |
| OSC growth DoS (OSC path FIXED 2026-06-20; DCS/APC paths unverified end-to-end) | C4 hostile zoo (verifies DCS/APC boundedness, then serves as the regression net), A6 residue oracle, M2 grammar fuzz; R3 golden guards the shipped OSC cap |
| Multi-row URL-wrap reconstruction (v0.3.6) | U5 URLDetector gauntlet (the actual bug site — the Swift join walk); M5 + S3 #5 + D3 cover the core reflow layer it rides on |
| Snapshot-per-chunk throughput cliff | C7 coalescer chaos, S3 #6 damage honesty |
| Duplicate output replay (v0.2.13 release day) | G1 focus-flapper persona (the historical trigger, 098b2d9, was focus handling), G2 transcript oracle, C2 conservation |
| Window restore across displays (v0.3.2) | C8 topology fuzzer |
| Remote TERM / capability sniffing (v0.6.1) | W7 ssh loopback, A8 terminfo truthfulness, D4 query matrix |
| IME Int-trap / caret alignment | U4 IME preedit scripting, H5 vi-mode tracker (adjacent) |
| FrameKey atlas-gen (v0.2.10) | G3 render-vs-model, G4 PNG goldens |
| Settings beachball (982b719) / #28 sink fan-out | U6 preferences churn fuzzer |
| Sparkle version-compare miss (v0.1.1) / popup→tab 1 | U8 appcast gauntlet |

The one class this catalog genuinely *cannot* reach headlessly:
NSWindowTabGroup / Spaces / Stage Manager behavior (the invisible-tab-bar
RCA class), where the OS itself is the state machine. That stays covered by
the existing TabMover/TabOrderCoordinator DEBUG-seam approach plus asking
Connor to eyeball — by design, not omission. A second by-design gap:
*concurrent* multi-session interaction inside one app process (two live
tabs each running a shell), which the one-live-shell-at-a-time rule forbids
simulating — cover it with sequential-session state assertions and Connor's
eyeballs. Everything else in the Swift layer — selection, mouse encoding,
find, IME, hover/drag/file-drop, settings, appcast parsing — is covered in
Part 9 precisely because it *is* headless-reachable.

---

# Roadmap

**Phase 0 — same-week signal, no new infrastructure (all S):**
1. S1-lite: three fixed shred strategies over the existing goldens
   (`chunk_metamorphic.rs`). Expectation note: the committed goldens corpus
   is currently just two small files, so initial signal is thin — it fattens
   as R3 repro goldens and A1 agent transcripts land.
2. R3: port the VS16 + PROMPT_SUBST repro bytes as rich goldens with reply
   capture + bless mode.
3. H1 first experiment: `brew install nushell`, count native OSC 133 marks
   per prompt cycle with the config pinned, driven via `script -q` (ptyjig
   doesn't exist until Phase 1). 30 min, likely a day-one finding.
4. H6 env-contract oracle for tcsh/dash (pure `env` diffing).
5. C8 display-topology fuzzer (pure geometry, 10k cases < 1 s).
6. M5 ascii-only reflow conservation.
7. W5 sanitizer unit gauntlet with the embedded-`201~` payload
   (PasteSanitizer already exists as pure static functions on Data —
   convertLoneCRToLF, sanitizePasteControls, stripBidiOverrides, … — so this
   is direct unit driving; Phase 0 touches zero app code).
8. D7 width sweep vs unicode-width alone; commit the golden matrix.
9. C9 clock-usage audit table.
10. U5 URLDetector wrap gauntlet + U6 preferences churn fuzzer (both pure
    unit level over existing substrates).

**Phase 1 — substrates:** S1 full engine + S3 invariant library, S2 ptyjig,
D1 twin-core differ (first allowlist falls out of run one), S4 bb-minimize,
R1 flight recorder.

**Phase 2 — the matrices and corpora:** W1–W6 (W5: full ptyjig ground-truth
form — the unit subset shipped in Phase 0), H1–H7, A1–A3, A5–A7, D3, D5,
D7 (full 5-reference jury: utf8proc, kitty table, string-width, CellWidth),
D8, C1–C7, M1–M4, M5 (full Unicode + links form), M6, U1–U4, U7–U8.
Highest expected value first: W1, A1+A2, D3, C1, M1.

**Phase 3 — deep infrastructure:** D6 (DECRQCRA + esctest), D2 jury, D4
query matrix, D9, A4, A8, W7, R2, R4, G3–G4.

**Ongoing:** G1/G2 persona sessions, G5 self-play, G6 nightly hunt loop,
R5 corpus exchange, corpus refreshes when agent CLIs update.

**CI placement:** Phase-0 items ride default `cargo test` / scoped
`scripts/test.sh`. Corpus replays and differs run as `--ignored` nightly
lanes (pattern: the throughput/memory gates). Live-process harnesses
(ptyjig sessions, tmux referees, storms) stay local/nightly, never PR-gating,
until they've demonstrated a season of zero flakes.

**Graduation rule:** every confirmed finding ends as (1) a minimized `.bytes`
golden in R3, (2) an allowlist entry with rationale, or (3) a KNOWN_ISSUES
writeup — never a one-off fix with no regression net.
