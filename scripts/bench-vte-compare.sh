#!/usr/bin/env bash
# bench-vte-compare.sh — run vtebench (+ kitty's benchmark kitten) in
# Terminal.app, Blackbird, Alacritty, kitty, WezTerm, iTerm2, and Ghostty,
# one terminal at a time, then print a side-by-side MB/s table.
#
# vtebench measures PTY-write-blocking time: how long `write(stdout, …)` takes
# when the terminal back-pressures stdin. The kitten benchmark measures
# parser throughput with the terminal's own query-response as the clock.
# Both are throughput benchmarks, not latency benchmarks.
#
# Usage:
#   scripts/bench-vte-compare.sh                 # all terminals
#   scripts/bench-vte-compare.sh alacritty kitty # just these legs
#
# Layout on disk:
#   $BENCH_ROOT/vtebench/                — cloned repo + target/release/vtebench
#   $BENCH_ROOT/results/<term>.dat       — vtebench's gnuplot output per term
#   $BENCH_ROOT/results/<term>.stdout    — runner log (incl. actual cols/rows)
#   $BENCH_ROOT/results/<term>.kitten    — kitten __benchmark__ report per term
#   $BENCH_ROOT/results/<term>.done      — sentinel touched by the runner
#   $BENCH_ROOT/results/run-<term>.sh    — per-terminal runner shim
#
# Window geometry: every leg asks for 200×50 twice — via a CLI/config knob
# where the terminal has one, and via XTWINOPS (CSI 8;50;200 t) from inside
# the runner. The runner then reads the *actual* grid from the tty (stty
# size) and templates the benchmark scripts with those real constants, so a
# terminal that refuses to resize still runs geometry-correct benchmarks
# (the April 2026 run had scroll regions set to rows 1–49 on 24-row windows,
# which is degenerate — see docs/benchmarks/vtebench-2026-04-20.md).
#
# The driver script stays in the caller's terminal the whole time; each
# benchmarked terminal opens in its own window, runs the suite, writes output,
# and exits. For Blackbird we exploit the fact that it reads $SHELL from its
# launchd environment: we inject SHELL=<runner-shim> via `open --env`, so the
# spawned "shell" is actually our benchmark script.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Per-user bench-root under $TMPDIR (macOS gives each user a private
# sandboxed /var/folders/.../T/ dir) so a second user on the same box
# can't symlink-clobber us at /tmp/bb-bench. Audit scripts-release F5.
# Override with BB_BENCH_ROOT=/some/path for CI or cross-user runs.
BENCH_ROOT="${BB_BENCH_ROOT:-${TMPDIR:-/tmp}bb-bench}"
BENCH_ROOT="${BENCH_ROOT%/}"
VTEBENCH_REPO="$BENCH_ROOT/vtebench"
VTEBENCH_BIN="$VTEBENCH_REPO/target/release/vtebench"
BENCHES="$BENCH_ROOT/benchmarks-template"
OUT="$BENCH_ROOT/results"

KITTY_BIN="/Applications/kitty.app/Contents/MacOS/kitty"
KITTEN_BIN="/Applications/kitty.app/Contents/MacOS/kitten"
WEZTERM_BIN="/Applications/WezTerm.app/Contents/MacOS/wezterm"

# Grid every terminal is asked to adopt. Recorded actuals may differ;
# the runner templates benchmarks with the real grid either way.
TARGET_COLS=200
TARGET_ROWS=50

# kitten __benchmark__ knobs. `images` is excluded: not all terminals under
# test implement the kitty graphics protocol, and a failed/ignored image
# upload would skew the comparison.
KITTEN_REPS="${KITTEN_REPS:-100}"
KITTEN_SUITES="ascii unicode csi long_escape_codes"

# vtebench knobs. 3s per benchmark × 12 benchmarks ≈ 40 s of benchmark time
# per terminal (plus kitten time). Each sample is 1 MB (the min-bytes default).
MAX_SECS="${VTEBENCH_MAX_SECS:-3}"
MAX_SAMPLES="${VTEBENCH_MAX_SAMPLES:-30}"

if [[ ! -x "$VTEBENCH_BIN" ]]; then
    echo "vtebench not built at $VTEBENCH_BIN" >&2
    echo "run: git clone https://github.com/alacritty/vtebench $VTEBENCH_REPO && (cd $VTEBENCH_REPO && cargo build --release)" >&2
    exit 1
fi

# We want the *Release* (optimized) Blackbird build — throughput under -Onone
# is not representative. But `open -n` won't spawn a second instance of the
# exact bundle that's already running (Claude Code is running in the user's
# Blackbird right now). Fix: clone Release/Blackbird.app into the bench root
# with a rewritten CFBundleIdentifier and an ad-hoc re-sign, so LaunchServices
# treats it as a separate app bundle.
BLACKBIRD_SRC="$(find ~/Library/Developer/Xcode/DerivedData -type d -path '*/Build/Products/Release/Blackbird.app' 2>/dev/null | head -1)"
if [[ -z "$BLACKBIRD_SRC" ]]; then
    # Fall back to Debug if Release isn't built — still honest, just slower.
    BLACKBIRD_SRC="$(find ~/Library/Developer/Xcode/DerivedData -type d -path '*/Build/Products/Debug/Blackbird.app' 2>/dev/null | head -1)"
fi
if [[ -z "$BLACKBIRD_SRC" ]]; then
    echo "No Blackbird.app in DerivedData; build it first." >&2
    exit 1
fi
BLACKBIRD_APP="$BENCH_ROOT/BlackbirdBench.app"

prepare_benches() {
    local src="$VTEBENCH_REPO/benchmarks"
    rm -rf "$BENCHES"
    # -L dereferences symlinks (several benchmarks symlink to ../scrolling/…);
    # macOS `sed -i` refuses to rewrite through a symlink.
    cp -RL "$src" "$BENCHES"
    # vtebench's stock scripts use `tput cols`/`tput lines` against the
    # controlling tty. When vtebench spawns the benchmark via
    # `Command::output()` those lookups fail (no tty on the pipe), so
    # `cursor_motion` + `light_cells` emit 0 bytes and get silently dropped.
    # Substitute placeholders here; each terminal's runner substitutes its
    # *measured* grid at run time.
    for d in "$BENCHES"/*/; do
        for f in "$d"/benchmark "$d"/setup; do
            [[ -f "$f" ]] || continue
            # Two idioms exist upstream: most scripts read the controlling
            # tty (`$(tput cols < $tty)`), but scrolling_top_region/setup
            # uses a BARE `$(tput lines)` — which, under vtebench's
            # pipe-spawned sh, falls back to the terminfo default of 24
            # rows. That one silently mis-sized the scroll region in every
            # run before 2026-06-09 (caught by the hard template check
            # below).
            sed -i '' \
                -e 's#columns=$(tput cols < $tty)#columns=__BB_COLS__#' \
                -e 's#lines=$(tput lines < $tty)#lines=__BB_ROWS__#' \
                -e 's#$(tput cols)#__BB_COLS__#g' \
                -e 's#$(tput lines)#__BB_ROWS__#g' \
                "$f"
        done
    done
    # If a future vtebench revision changes the tput idiom, fail loudly
    # instead of silently benchmarking with a broken geometry (the
    # affected benchmarks would emit 0 bytes or a wrong region and be
    # silently dropped/mis-measured). Scope to EXECUTED files: payload
    # recordings (vim_session) legitimately contain the string 'tput'.
    if grep -l 'tput' "$BENCHES"/*/setup "$BENCHES"/*/benchmark >/dev/null 2>&1; then
        echo "ERROR: un-substituted tput remains in $BENCHES — vtebench scripts changed?" >&2
        grep -l 'tput' "$BENCHES"/*/setup "$BENCHES"/*/benchmark >&2
        exit 1
    fi
}

make_runner() {
    local name="$1"
    local path="$OUT/run-$name.sh"
    cat > "$path" <<RUNNER
#!/usr/bin/env bash
# Per-terminal runner. Runs inside the terminal under test.
# Ask for ${TARGET_ROWS}×${TARGET_COLS} cells via XTWINOPS (CSI 8;H;W t) —
# Terminal.app honours it; most others were already sized via CLI/config.
printf '\\e[8;${TARGET_ROWS};${TARGET_COLS}t'
# Give the window a beat to finish layout before measuring the grid.
sleep 1.2
# Read the *actual* grid from the tty. stty needs no terminfo (\$TERM may be
# odd in some launch paths); fall back to tput, then to 80×24.
sz=\$(stty size </dev/tty 2>/dev/null || true)
rows=\${sz%% *}
cols=\${sz##* }
if ! [[ "\$rows" =~ ^[0-9]+\$ && "\$cols" =~ ^[0-9]+\$ ]]; then
    cols=\$(tput cols 2>/dev/null || echo 80)
    rows=\$(tput lines 2>/dev/null || echo 24)
fi
: "\${cols:=80}" "\${rows:=24}"
# A grid that differs from the target is valid (the benchmarks below are
# templated with the real grid) but must be loud, not a passive log line
# the operator has to remember to diff — the driver echoes this marker.
if [ "\$cols" -ne $TARGET_COLS ] || [ "\$rows" -ne $TARGET_ROWS ]; then
    echo "GRID MISMATCH: target=${TARGET_COLS}x${TARGET_ROWS} actual=\${cols}x\${rows}" >> "$OUT/$name.stdout"
fi
{
    echo "== $name =="
    echo "cols=\$cols rows=\$rows"
    echo "tty=\$(tty 2>/dev/null || echo ?)"
    echo "pid=\$\$"
    echo
} >> "$OUT/$name.stdout"
# Template this terminal's benchmark tree with its real geometry so scroll
# regions and payload sizes match the actual window.
BDIR="$OUT/benches-$name"
rm -rf "\$BDIR"
cp -R "$BENCHES" "\$BDIR"
find "\$BDIR" -type f \\( -name benchmark -o -name setup \\) -exec \\
    sed -i '' -e "s/__BB_COLS__/\$cols/g" -e "s/__BB_ROWS__/\$rows/g" {} +
# Verify the substitution actually landed: an unsubstituted placeholder
# makes that benchmark emit 0 bytes, and vtebench silently drops it with
# rc=0 — the leg's geomean would then cover a smaller, systematically
# faster subset (the exact failure mode the templating exists to fix).
if grep -rEq '__BB_COLS__|__BB_ROWS__' "\$BDIR" 2>/dev/null; then
    echo "TEMPLATE ERROR: unsubstituted geometry placeholders in \$BDIR" >> "$OUT/$name.stdout"
    touch "$OUT/$name.done"
    exit 1
fi
# CRITICAL: stdout must stay connected to the PTY — that *is* the benchmark.
# Only stderr is redirected to the log file. --silent suppresses the human-
# readable "Results:" table that would otherwise also go to the PTY.
"$VTEBENCH_BIN" \\
    -b "\$BDIR" \\
    --max-secs $MAX_SECS \\
    --max-samples $MAX_SAMPLES \\
    --silent \\
    --dat "$OUT/$name.dat" \\
    2>> "$OUT/$name.stdout"
rc=\$?
# Reset the terminal so the kitten phase starts from a clean state.
printf '\\033c' || true
echo "vtebench rc=\$rc" >> "$OUT/$name.stdout"
# Phase 2: kitty's benchmark kitten. It opens /dev/tty directly for the
# benchmark payload and query round-trips, and prints its report to stdout —
# so redirecting stdout captures the report without touching the measurement.
if [[ -x "$KITTEN_BIN" ]]; then
    "$KITTEN_BIN" __benchmark__ --repetitions $KITTEN_REPS $KITTEN_SUITES \\
        > "$OUT/$name.kitten" 2>&1
    echo "kitten rc=\$?" >> "$OUT/$name.stdout"
    printf '\\033c' || true
else
    # Loud skip: a leg with no kitten phase must be distinguishable from
    # a deleted .kitten file when the driver verifies the leg.
    echo "kitten skipped: $KITTEN_BIN not installed" >> "$OUT/$name.stdout"
fi
touch "$OUT/$name.done"
sleep 0.3
exit 0
RUNNER
    chmod +x "$path"
    echo "$path"
}

# A "fake shell" wrapper just for Blackbird. Blackbird execs whatever is in
# $SHELL as its child process; a bare runner script exits immediately after
# the bench, which leaves the PTY without a running shell. That's fine because
# we sample the .done sentinel from the driver and then kill the app.
make_blackbird_shell() {
    local runner_path="$1"
    local path="$OUT/run-blackbird-shell.sh"
    cat > "$path" <<SHELL
#!/usr/bin/env bash
# Impersonates a login shell for Blackbird. All it does is dispatch to the
# benchmark runner.
exec /bin/bash "$runner_path"
SHELL
    chmod +x "$path"
    echo "$path"
}

wait_done() {
    local name="$1"
    local timeout="${2:-900}"
    local t=0
    while [[ ! -f "$OUT/$name.done" ]] && [[ $t -lt $timeout ]]; do
        sleep 1
        t=$((t + 1))
    done
    if [[ ! -f "$OUT/$name.done" ]]; then
        echo "  TIMEOUT: $name did not finish in ${timeout}s" >&2
        return 1
    fi
    echo "  $name: done in ${t}s"
}

run_iterm() {
    local runner; runner=$(make_runner iterm)
    # iTerm2 refuses to run as a second instance of the same bundle id: if
    # the user's iTerm is already open, `open -na` is swallowed by the
    # running copy and the ZDOTDIR hook below never fires (the 2026-06-09
    # run lost this leg to a silent 900s timeout). Detect and ask.
    local waited=0
    while ps -Axo comm | grep -q '/iTerm.app/Contents/MacOS/iTerm2$'; do
        if [[ $waited -eq 0 ]]; then
            echo "  -> iTerm2 is already running; quit it (Cmd-Q) so the bench can launch a clean instance. Waiting up to 120s..."
        fi
        if [[ $waited -ge 120 ]]; then
            echo "  iTerm2 still running after ${waited}s — skipping leg" >&2
            return 1
        fi
        sleep 2
        waited=$((waited + 2))
    done
    # iTerm2's extended AppleScript dictionary needs TCC Automation, which
    # Blackbird (the app driving this bench) lacks. Route around that by
    # hijacking zsh's login flow via ZDOTDIR: iTerm spawns `zsh -l`, zsh
    # reads `$ZDOTDIR/.zprofile` before the interactive prompt, and our
    # `.zprofile` runs the benchmark and exits. `open --env ZDOTDIR=…`
    # propagates the env var to iTerm's shell at fork time.
    local zdot="$OUT/iterm-zdot"
    rm -rf "$zdot"; mkdir -p "$zdot"
    cat > "$zdot/.zprofile" <<ZRC
exec bash '$runner'
ZRC
    # -n forces a new process instance, which is required for --env to take
    # effect. Without it, a running iTerm instance silently ignores the env
    # override and our ZDOTDIR trick never fires.
    open -na iTerm --env "ZDOTDIR=$zdot"
    wait_done iterm 900
}

run_terminal() {
    local runner; runner=$(make_runner terminal)
    # Terminal.app is the registered opener for *.command files. The AppleScript
    # route (`do script`) requires Automation permission from the driving app,
    # which Blackbird lacks — so we rename the runner to *.command and let
    # LaunchServices route it.
    local cmd_path="$OUT/run-terminal.command"
    cp "$runner" "$cmd_path"
    chmod +x "$cmd_path"
    open "$cmd_path"
    wait_done terminal 900
}

run_ghostty() {
    local runner; runner=$(make_runner ghostty)
    # Ghostty on macOS refuses to execute `-e <cmd>`, `--command=…`, or even a
    # config-file `command = …` when launched via `open -a`: the process
    # starts but never spawns a surface unless the user explicitly opens one
    # from the GUI. The `ghostty` helper binary also refuses CLI launch on
    # macOS. So we fall back to the clipboard-paste pattern (same as iTerm).
    # Window size: Ghostty reads $XDG_CONFIG_HOME/ghostty/config, and `open
    # --env` propagates the variable — seed a config asking for the target
    # grid. If this Ghostty build ignores it, the runner records the real
    # grid and templates the benchmarks accordingly, so results stay valid.
    local xdg="$OUT/ghostty-xdg"
    rm -rf "$xdg"; mkdir -p "$xdg/ghostty"
    printf 'window-width = %s\nwindow-height = %s\n' \
        "$TARGET_COLS" "$TARGET_ROWS" > "$xdg/ghostty/config"
    printf "exec bash '%s'\n" "$runner" | pbcopy
    open -na Ghostty.app --env "XDG_CONFIG_HOME=$xdg"
    cat <<INSTR
  -> Ghostty focused. If a new window didn't appear, press Cmd-N.
     Then paste (Cmd-V) + Enter. The runner command is on the clipboard:
        exec bash '$runner'
INSTR
    wait_done ghostty 900
}

prepare_blackbird_clone() {
    # Build-once: clone Blackbird.app to the bench root with a unique bundle
    # id, so LaunchServices can keep both it and the user's live instance open.
    rm -rf "$BLACKBIRD_APP"
    cp -R "$BLACKBIRD_SRC" "$BLACKBIRD_APP"
    /usr/libexec/PlistBuddy \
        -c 'Set :CFBundleIdentifier dev.conjfrnk.blackbirdbench' \
        "$BLACKBIRD_APP/Contents/Info.plist" >/dev/null
    # Re-sign ad-hoc so the modified bundle isn't rejected by Gatekeeper.
    codesign --force --deep --sign - "$BLACKBIRD_APP" >/dev/null 2>&1 || true
}

seed_blackbird_frame() {
    # Blackbird has no XTWINOPS resize handler, but it restores its frame
    # from `NSWindow Frame BlackbirdMainWindow` in its own defaults domain
    # (dev.conjfrnk.blackbirdbench for the bench clone). Seed a frame big
    # enough for roughly the target grid; the v0.3.2 nudge logic clamps it
    # to the visible screen if it overshoots, and the runner records the
    # actual grid either way. Frame format: "x y w h screenX screenY screenW
    # screenH" — reuse the live app's screen rect so the restore isn't
    # rejected as off-screen.
    local main_frame sx sy sw sh
    main_frame="$(defaults read dev.conjfrnk.blackbird 'NSWindow Frame BlackbirdMainWindow' 2>/dev/null || true)"
    if [[ -n "$main_frame" ]]; then
        read -r sx sy sw sh <<<"$(awk '{print $(NF-3), $(NF-2), $(NF-1), $NF}' <<<"$main_frame")"
    else
        sx=0; sy=0; sw=1512; sh=982
    fi
    # Calibrated 2026-06-09: 1680×980 produced a 208×62 grid (cell ≈
    # 8.08×15.8 pt + fixed chrome), so 200×50 wants ≈ 1615×790.
    local w=1615 h=790
    if (( w > sw )); then w=$sw; fi
    if (( h > sh )); then h=$sh; fi
    defaults write dev.conjfrnk.blackbirdbench "NSWindow Frame BlackbirdMainWindow" \
        "20 40 $w $h $sx $sy $sw $sh"
    # No Sparkle first-launch prompt in the bench window.
    defaults write dev.conjfrnk.blackbirdbench SUEnableAutomaticChecks -bool false
}

run_alacritty() {
    local runner; runner=$(make_runner alacritty)
    # Alacritty has first-class `-e <command>` support — simplest handler in
    # the suite. Cargo-installed binary lives in ~/.cargo/bin.
    local bin="$HOME/.cargo/bin/alacritty"
    if [[ ! -x "$bin" ]]; then
        bin="$(command -v alacritty 2>/dev/null || true)"
    fi
    if [[ -z "$bin" || ! -x "$bin" ]]; then
        echo "  alacritty binary not found — skipping" >&2
        return 0
    fi
    "$bin" \
        -o "window.dimensions.columns=$TARGET_COLS" \
        -o "window.dimensions.lines=$TARGET_ROWS" \
        -e /bin/bash "$runner" &
    local alac_pid=$!
    wait_done alacritty 900
    # The -e command exits; Alacritty closes its window on child-exit, so
    # normally nothing to clean up. Guard against a stuck process anyway.
    if kill -0 "$alac_pid" 2>/dev/null; then
        kill "$alac_pid" 2>/dev/null || true
    fi
}

run_kitty() {
    local runner; runner=$(make_runner kitty)
    if [[ ! -x "$KITTY_BIN" ]]; then
        echo "  kitty not found at $KITTY_BIN — skipping" >&2
        return 0
    fi
    # kitty takes the command to run as positional args and `-o` overrides.
    # confirm_os_window_close=0 stops a close-confirmation dialog from
    # keeping the window alive after the runner exits.
    "$KITTY_BIN" \
        -o remember_window_size=no \
        -o "initial_window_width=${TARGET_COLS}c" \
        -o "initial_window_height=${TARGET_ROWS}c" \
        -o confirm_os_window_close=0 \
        /bin/bash "$runner" &
    local kitty_pid=$!
    wait_done kitty 900
    if kill -0 "$kitty_pid" 2>/dev/null; then
        kill "$kitty_pid" 2>/dev/null || true
    fi
}

run_wezterm() {
    local runner; runner=$(make_runner wezterm)
    if [[ ! -x "$WEZTERM_BIN" ]]; then
        echo "  wezterm not found at $WEZTERM_BIN — skipping" >&2
        return 0
    fi
    # `wezterm start -- <cmd>` opens a GUI window running cmd; exit_behavior
    # Close tears the window down when the runner exits.
    "$WEZTERM_BIN" \
        --config "initial_cols=$TARGET_COLS" \
        --config "initial_rows=$TARGET_ROWS" \
        --config 'exit_behavior="Close"' \
        start -- /bin/bash "$runner" &
    local wez_pid=$!
    wait_done wezterm 900
    if kill -0 "$wez_pid" 2>/dev/null; then
        kill "$wez_pid" 2>/dev/null || true
    fi
}

run_blackbird() {
    local runner; runner=$(make_runner blackbird)
    local shell_shim; shell_shim=$(make_blackbird_shell "$runner")
    prepare_blackbird_clone
    seed_blackbird_frame
    # Claude Code may be running inside a Blackbird window *right now*, so we
    # must not quit "Blackbird" as an app. Instead:
    #   -n              force a new PID-separate instance
    #   -F              discard saved state so we don't inherit a prior window
    #   --env SHELL=…   hijack the child process Blackbird forks for this
    #                   window; no real user shell is invoked.
    # When the shim's runner exits the window just reads "[Process completed]";
    # we leave it open and the user closes it manually. The driver only needs
    # the .done sentinel.
    # macOS `pgrep -x Blackbird` is unreliable — `ps -o comm=` sometimes
    # returns the full executable path, which breaks exact-match. Use a
    # basename-anchored awk filter instead.
    list_blackbird_pids() {
        ps -Axo pid,comm 2>/dev/null | awk '$2 ~ /\/Blackbird$/ {print $1}' | sort -u
    }
    local before_pids after_pids
    before_pids=$(list_blackbird_pids | tr '\n' ' ')
    open -n -F "$BLACKBIRD_APP" --env "SHELL=$shell_shim"
    sleep 1.5
    after_pids=$(list_blackbird_pids | tr '\n' ' ')
    local new_pid=""
    for p in $after_pids; do
        case " $before_pids " in
            *" $p "*) ;;
            *) new_pid=$p; break ;;
        esac
    done
    echo "  spawned Blackbird pid=${new_pid:-<unknown>} (pre-existing: $before_pids)"
    wait_done blackbird 900
    # Politely terminate *only* the bench instance, leaving the user's window
    # (where Claude is running) alive. If new_pid is empty we do nothing.
    if [[ -n "$new_pid" ]]; then
        kill "$new_pid" 2>/dev/null || true
    fi
}

# A leg only counts if its runner recorded rc=0 for every phase it ran.
# The runner touches .done unconditionally (so the driver never hangs on
# a mid-suite crash); the DRIVER is responsible for refusing to rank a
# failed leg — a partial .dat flowing into the headline table looks
# plausible and is exactly the silent failure this data cannot afford
# (it backs public performance claims).
verify_leg() {
    local name="$1"
    local log="$OUT/$name.stdout"
    local ok=1
    if [[ ! -f "$log" ]]; then
        echo "  $name: runner never started (no $name.stdout)" >&2
        ok=0
    else
        if ! grep -q '^vtebench rc=0$' "$log"; then
            echo "  $name: vtebench did not report rc=0" >&2; ok=0
        fi
        # -E: BSD grep (what /bin/bash sees on PATH) does not support \|
        # alternation in BRE — it matches nothing, silently.
        if ! grep -Eq '^kitten rc=0$|^kitten skipped' "$log"; then
            echo "  $name: kitten did not report rc=0 (and was not skipped)" >&2; ok=0
        fi
        if grep -q '^TEMPLATE ERROR' "$log"; then
            echo "  $name: benchmark templating failed" >&2; ok=0
        fi
        # Mismatched grid is valid (benchmarks are templated with the real
        # grid) but must be loud at the driver level.
        grep '^GRID MISMATCH' "$log" 2>/dev/null | sed "s/^/  $name: /" || true
    fi
    if [[ $ok -eq 0 ]]; then
        # Quarantine partial results so summarize() can't rank them.
        [[ -f "$OUT/$name.dat" ]] && mv "$OUT/$name.dat" "$OUT/$name.dat.failed"
        [[ -f "$OUT/$name.kitten" ]] && mv "$OUT/$name.kitten" "$OUT/$name.kitten.failed"
        return 1
    fi
    return 0
}

summarize() {
    echo "--- .dat files in the table (check mtimes: stale legs from an"
    echo "    older run/build accumulate here by design) ---"
    ls -lt "$OUT"/*.dat 2>/dev/null | awk '{print "  " $6, $7, $8, $NF}' || true
    echo
    python3 "$REPO_ROOT/scripts/bench-vte-summarize.py" "$OUT"/*.dat
    if ls "$OUT"/*.kitten >/dev/null 2>&1; then
        echo
        echo "=== kitten __benchmark__ (parser end-to-end MB/s) ==="
        python3 "$REPO_ROOT/scripts/bench-kitten-summarize.py" "$OUT"/*.kitten || true
    fi
    echo
    echo "=== actual grids (cols×rows per terminal) ==="
    grep -H "^cols=" "$OUT"/*.stdout 2>/dev/null || true
}

run_leg() {
    case "$1" in
        terminal)  run_terminal ;;
        blackbird) run_blackbird ;;
        alacritty) run_alacritty ;;
        kitty)     run_kitty ;;
        wezterm)   run_wezterm ;;
        iterm)     run_iterm ;;
        ghostty)   run_ghostty ;;
        *) echo "unknown terminal '$1' (expected: terminal blackbird alacritty kitty wezterm iterm ghostty)" >&2; return 1 ;;
    esac
}

main() {
    local legs=()
    if [[ $# -gt 0 ]]; then
        legs=("$@")
    else
        # Fully automated first; Ghostty last (needs a manual paste).
        legs=(terminal blackbird alacritty kitty wezterm)
        if [[ "${SKIP_ITERM:-0}" != "1" ]]; then legs+=(iterm); fi
        if [[ "${SKIP_GHOSTTY:-0}" != "1" ]]; then legs+=(ghostty); fi
    fi

    # Validate every leg name BEFORE any cleanup: a typo'd leg would
    # otherwise clean nothing, "fail (continuing)", and let a STALE .dat
    # from a previous run/build masquerade as a fresh result in the
    # summary table.
    local known=" terminal blackbird alacritty kitty wezterm iterm ghostty "
    for leg in "${legs[@]}"; do
        case "$known" in
            *" $leg "*) ;;
            *) echo "unknown terminal '$leg' (expected one of:$known)" >&2; exit 2 ;;
        esac
    done

    prepare_benches
    mkdir -p "$OUT"
    # Clean only the legs we're about to run, so single-leg re-runs don't
    # wipe earlier results. Includes quarantined artifacts.
    for leg in "${legs[@]}"; do
        rm -rf "$OUT/$leg.dat" "$OUT/$leg.stdout" "$OUT/$leg.kitten" \
               "$OUT/$leg.dat.failed" "$OUT/$leg.kitten.failed" \
               "$OUT/$leg.done" "$OUT/run-$leg.sh" "$OUT/benches-$leg"
    done

    echo "=== terminal throughput comparison: ${legs[*]} ==="
    echo "vtebench: $(ls "$BENCHES" | wc -l | tr -d ' ') benchmarks; max-secs=$MAX_SECS; max-samples=$MAX_SAMPLES"
    echo "kitten __benchmark__: $KITTEN_SUITES (reps=$KITTEN_REPS)"
    echo

    local i=1 n=${#legs[@]}
    for leg in "${legs[@]}"; do
        echo "[$i/$n] $leg..."
        if run_leg "$leg"; then
            verify_leg "$leg" || \
                echo "  $leg leg FAILED verification (results quarantined)" >&2
        else
            echo "  $leg leg FAILED (continuing)" >&2
            # Quarantine whatever partials the failed/timed-out leg left.
            verify_leg "$leg" >/dev/null 2>&1 || true
        fi
        i=$((i + 1))
    done

    echo
    echo "=== summary ==="
    summarize
}

main "$@"
