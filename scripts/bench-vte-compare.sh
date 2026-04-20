#!/usr/bin/env bash
# bench-vte-compare.sh — run vtebench in iTerm2, Terminal.app, Ghostty, and
# Blackbird, one terminal at a time, then print a side-by-side MB/s table.
#
# vtebench measures PTY-write-blocking time: how long `write(stdout, …)` takes
# when the terminal back-pressures stdin. It is a throughput benchmark, not a
# latency benchmark.
#
# Layout on disk:
#   /tmp/bb-bench/vtebench/                — cloned repo + target/release/vtebench
#   /tmp/bb-bench/results/<term>.dat       — vtebench's gnuplot output per term
#   /tmp/bb-bench/results/<term>.stdout    — vtebench's textual table per term
#   /tmp/bb-bench/results/<term>.done      — sentinel touched by the runner
#   /tmp/bb-bench/results/run-<term>.sh    — per-terminal runner shim
#
# The driver script stays in the caller's terminal the whole time; each
# benchmarked terminal opens in its own window, runs the suite, writes output,
# and exits. For Blackbird we exploit the fact that it reads $SHELL from its
# launchd environment: we inject SHELL=<runner-shim> via `open --env`, so the
# spawned "shell" is actually our benchmark script.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BENCH_ROOT="/tmp/bb-bench"
VTEBENCH_REPO="$BENCH_ROOT/vtebench"
VTEBENCH_BIN="$VTEBENCH_REPO/target/release/vtebench"
# Patched benchmarks: vtebench's stock scripts use `tput cols`/`tput lines`
# to size their payload. When vtebench spawns the benchmark as a subprocess
# via `Command::output()`, stdin/stdout are pipes (no tty), so `tput` returns
# nothing and `cursor_motion` + `light_cells` emit 0 bytes and get silently
# dropped. We substitute 200×50 constants so every benchmark produces payload.
BENCHES="$BENCH_ROOT/benchmarks-fixed"
OUT="$BENCH_ROOT/results"

prepare_benches() {
    local src="$VTEBENCH_REPO/benchmarks"
    rm -rf "$BENCHES"
    # -L dereferences symlinks (several benchmarks symlink to ../scrolling/…);
    # macOS `sed -i` refuses to rewrite through a symlink.
    cp -RL "$src" "$BENCHES"
    for d in "$BENCHES"/*/; do
        for f in "$d"/benchmark "$d"/setup; do
            [[ -f "$f" ]] || continue
            sed -i '' \
                -e 's#columns=$(tput cols < $tty)#columns=200#' \
                -e 's#lines=$(tput lines < $tty)#lines=50#' \
                "$f"
        done
    done
}

# vtebench knobs. 3s per benchmark × 12 benchmarks × 4 terminals ≈ 2.5 min
# of actual benchmark time. Each sample is 1 MB (the min-bytes default).
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
# Blackbird right now). Fix: clone Release/Blackbird.app into /tmp with a
# rewritten CFBundleIdentifier and an ad-hoc re-sign, so LaunchServices
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

mkdir -p "$OUT"
rm -f "$OUT"/*.dat "$OUT"/*.stdout "$OUT"/*.done "$OUT"/run-*.sh

make_runner() {
    local name="$1"
    local path="$OUT/run-$name.sh"
    cat > "$path" <<RUNNER
#!/usr/bin/env bash
# Per-terminal runner. Runs inside the terminal under test.
# Request a 50×200 cell size via XTWINOPS (CSI 8;H;W t). iTerm2 / Ghostty /
# Terminal.app honour it; Blackbird ignores it (no XTWINOPS handler) and
# stays at its default size. Skipping the resize would let scroll-region
# benches explode in terminals whose default is 24 lines.
printf '\\e[8;50;200t'
# Give the window a beat to finish layout before we start blasting escape
# sequences at it.
sleep 1.0
{
    echo "== $name =="
    echo "cols=\$(tput cols 2>/dev/null || echo ?) rows=\$(tput lines 2>/dev/null || echo ?)"
    echo "tty=\$(tty 2>/dev/null || echo ?)"
    echo "pid=\$\$"
    echo
} >> "$OUT/$name.stdout"
# CRITICAL: stdout must stay connected to the PTY — that *is* the benchmark.
# Only stderr is redirected to the log file. --silent suppresses the human-
# readable "Results:" table that would otherwise also go to the PTY.
"$VTEBENCH_BIN" \\
    -b "$BENCHES" \\
    --max-secs $MAX_SECS \\
    --max-samples $MAX_SAMPLES \\
    --silent \\
    --dat "$OUT/$name.dat" \\
    2>> "$OUT/$name.stdout"
rc=\$?
# Reset the terminal so the window doesn't end inside a weird color state.
printf '\\033c' || true
echo "rc=\$rc" >> "$OUT/$name.stdout"
touch "$OUT/$name.done"
sleep 0.3
exit 0
RUNNER
    chmod +x "$path"
    echo "$path"
}

# A "fake shell" wrapper just for Blackbird. Blackbird execs whatever is in
# \$SHELL as its child process; a bare runner script exits immediately after
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
    local timeout="${2:-120}"
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
    # iTerm at its default 80×24 chokes on scroll-region benches (one sample
    # can take 100s+), so allow up to 10 min. vtebench's per-bench budget
    # still caps single-benchmark time to MAX_SECS.
    wait_done iterm 600
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
    wait_done terminal 180
}

run_ghostty() {
    local runner; runner=$(make_runner ghostty)
    # Ghostty on macOS refuses to execute `-e <cmd>`, `--command=…`, or even a
    # config-file `command = …` when launched via `open -a`: the process
    # starts but never spawns a surface unless the user explicitly opens one
    # from the GUI. The `ghostty` helper binary also refuses CLI launch on
    # macOS. So we fall back to the clipboard-paste pattern (same as iTerm).
    printf "exec bash '%s'\n" "$runner" | pbcopy
    open -a Ghostty.app
    cat <<INSTR
  -> Ghostty focused. If a new window didn't appear, press Cmd-N.
     Then paste (Cmd-V) + Enter. The runner command is on the clipboard:
        exec bash '$runner'
INSTR
    wait_done ghostty 600
}

prepare_blackbird_clone() {
    # Build-once: clone Blackbird.app to /tmp with a unique bundle id, so
    # LaunchServices can keep both it and the user's live instance open.
    rm -rf "$BLACKBIRD_APP"
    cp -R "$BLACKBIRD_SRC" "$BLACKBIRD_APP"
    /usr/libexec/PlistBuddy \
        -c 'Set :CFBundleIdentifier dev.conjfrnk.blackbirdbench' \
        "$BLACKBIRD_APP/Contents/Info.plist" >/dev/null
    # Re-sign ad-hoc so the modified bundle isn't rejected by Gatekeeper.
    codesign --force --deep --sign - "$BLACKBIRD_APP" >/dev/null 2>&1 || true
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
    "$bin" -e /bin/bash "$runner" &
    local alac_pid=$!
    wait_done alacritty 300
    # The -e command exits; Alacritty closes its window on child-exit, so
    # normally nothing to clean up. Guard against a stuck process anyway.
    if kill -0 "$alac_pid" 2>/dev/null; then
        kill "$alac_pid" 2>/dev/null || true
    fi
}

run_blackbird() {
    local runner; runner=$(make_runner blackbird)
    local shell_shim; shell_shim=$(make_blackbird_shell "$runner")
    prepare_blackbird_clone
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
    wait_done blackbird 180
    # Politely terminate *only* the bench instance, leaving the user's window
    # (where Claude is running) alive. If new_pid is empty we do nothing.
    if [[ -n "$new_pid" ]]; then
        kill "$new_pid" 2>/dev/null || true
    fi
}

summarize() {
    python3 "$REPO_ROOT/scripts/bench-vte-summarize.py" "$OUT"/*.dat
}

main() {
    prepare_benches
    echo "=== vtebench comparison: Terminal.app, Blackbird, Alacritty, Ghostty, iTerm2 ==="
    echo "Benchmarks: $(ls "$BENCHES" | wc -l | tr -d ' '); max-secs=$MAX_SECS; max-samples=$MAX_SAMPLES"
    echo
    # Fully automated first (no user input required).
    echo "[1/5] Terminal.app (automated via .command file)..."; run_terminal
    echo "[2/5] Blackbird (automated via SHELL= injection)..."; run_blackbird
    echo "[3/5] Alacritty (automated via -e)..."; run_alacritty
    echo "[4/5] iTerm2 (automated via ZDOTDIR)..."; {
        if [[ "${SKIP_ITERM:-0}" != "1" ]]; then
            run_iterm
        else
            echo "  iTerm2 skipped (SKIP_ITERM=1)"
        fi
    }
    # Ghostty resists CLI-driven command execution on macOS without the
    # Automation permission Blackbird lacks, so it's the only handler that
    # still requires a paste.
    if [[ "${SKIP_GHOSTTY:-0}" != "1" ]]; then
        echo "[5/5] Ghostty (requires manual paste; set SKIP_GHOSTTY=1 to skip)..."; run_ghostty
    else
        echo "[5/5] Ghostty skipped (SKIP_GHOSTTY=1)"
    fi
    echo
    echo "=== summary ==="
    summarize
}

main "$@"
