# Throughput — seven-way comparison, 2026-06-09

Supersedes `vtebench-2026-04-20.md`. Two benchmarks, run back-to-back in
the same window for every terminal via `scripts/bench-vte-compare.sh`:

- [`vtebench`](https://github.com/alacritty/vtebench) (Alacritty's
  suite) — PTY-drain throughput: how fast `write(2)` to the terminal's
  TTY completes under back-pressure.
- `kitten __benchmark__` (kitty's suite) — end-to-end parse throughput:
  payload goes to `/dev/tty` and the clock stops on the terminal's own
  query response, so buffering can't flatter anyone.

Neither measures input latency, frame pacing, or scroll smoothness
(end-to-end latency comparison via Typometer is planned separately).

## Results

Blackbird v0.3.4 + the feed coalescing fix (`84f9970`). Higher is
faster; geomean across rows.

### vtebench (median MB/s per benchmark)

```
benchmark                            alacritty         blackbird           ghostty             iterm             kitty          terminal           wezterm
----------------------------------------------------------------------------------------------------------------------------------------------------------
cursor_motion                             55.6              41.7              29.4               5.2              16.7               4.9              27.8
dense_cells                               12.0              24.1               7.8               4.9               8.8               2.1               8.4
light_cells                               62.5             100.0              55.6              29.4             100.0              32.3              22.2
medium_cells                              71.4             166.7              50.0               1.4              45.5              18.9              22.2
scrolling                                 26.3              69.0              21.3              16.0               6.0               3.6              10.2
scrolling_bottom_region                   41.7              83.3              25.0               0.0              13.8               4.3               8.8
scrolling_bottom_small_region              31.2              76.9              20.4               0.0              14.4               4.1               8.1
scrolling_fullscreen                      66.7             111.1              66.7              58.8              27.8              39.2              23.8
scrolling_top_region                      20.0              76.9              23.8               0.0              13.6               4.4               9.2
scrolling_top_small_region                32.3              66.7              25.0               0.0              14.2               4.4               8.1
sync_medium_cells                         66.7             117.6              41.7               1.4              23.8              18.0              17.1
unicode                                  100.0             111.1              95.2               9.8             142.9              39.2               9.1

geomean MB/s                              41.9              78.5              31.9               1.0              22.2               8.8              13.0

ranking:  1. blackbird 78.5   2. alacritty 41.9   3. ghostty 31.9
          4. kitty 22.2       5. wezterm 13.0     6. terminal 8.8
          7. iterm 1.0
```

### kitten __benchmark__ (MB/s per suite)

```
suite                       alacritty  blackbird    ghostty      iterm      kitty   terminal    wezterm
-------------------------------------------------------------------------------------------------------
Only ASCII chars                 95.8       74.9       85.6       13.8       89.4       25.8       22.5
Unicode chars                   130.5       82.2      111.7        6.7      121.7       45.3       34.4
CSI codes with few chars         61.6       43.3       41.0        1.3       42.7       29.1       13.6
Long escape codes               171.3       96.3       76.7       44.7      279.4      116.1      206.3

geomean MB/s                    107.2       71.2       74.1        8.6      106.7       44.6       38.4

ranking:  1. alacritty 107.2   2. kitty 106.7   3. ghostty 74.1
          4. blackbird 71.2    5. terminal 44.6 6. wezterm 38.4
          7. iterm 8.6
```

## Reading the two tables together

- **Blackbird is #1 on vtebench by 1.9×** over second-place Alacritty,
  winning 10 of 12 rows (losses: `cursor_motion` to Alacritty,
  `unicode` to kitty).
- **On kitty's own benchmark Blackbird is 4th**, statistically tied
  with Ghostty (71.2 vs 74.1; run-to-run variance is ±5% — Ghostty
  measured 65.0 in the same-day pass-1 run) and ~1.5× behind
  kitty/Alacritty (~107).
- The two Blackbird numbers (78.5 drain / 71.2 end-to-end) now
  corroborate each other. Before `84f9970` they did not: drain was
  ~50 MB/s while true end-to-end throughput was **8.0 MB/s**, because
  `feed()` paid a full grid snapshot per 128 KiB chunk and the PTY read
  loop isn't back-pressured by parsing — vtebench was partly measuring
  buffer absorption. `kitten __benchmark__` exposed it (flat ~8 MB/s
  across all payload types = fixed per-chunk cost), and is the reason
  both benchmarks are now in the harness permanently.

## What we can and cannot claim

Supported by this data: *"fastest macOS terminal on vtebench"* (with
date, versions, methodology); *"top-tier parser throughput"* on kitten
(top-4, within 1.5× of the leaders). NOT supported: *"fastest terminal"*
unqualified — kitty and Alacritty lead the end-to-end parse benchmark,
and input latency has not yet been cross-measured.

## Methodology

- Driver: `scripts/bench-vte-compare.sh` (per-leg verification: rc=0
  enforced from runner logs, failed legs quarantined; geometry
  templating — each terminal's real grid is substituted into the
  vtebench scripts at run time, fixing both the 2026-04-20 run's
  degenerate scroll regions and a bare-`$(tput lines)` fallback in
  `scrolling_top_region/setup` that mis-sized that region to 24 rows
  in every prior run, ours and presumably others').
- Target grid 200×50, requested via CLI/config knob per terminal plus
  XTWINOPS. Actuals: alacritty/ghostty/kitty/terminal/wezterm 200×50,
  blackbird 199×49 (seeded window frame, cell rounding), iterm 140×50
  (clamped its window to the screen).
- vtebench: `--max-secs 3 --max-samples 30`, ≥1 MiB per sample.
  kitten: `--repetitions 100`, suites ascii/unicode/csi/
  long_escape_codes (`images` excluded — not all terminals implement
  the kitty graphics protocol).
- **iTerm2 exception**: could not complete the full budget (two
  attempts saturated its main thread for 15+ minutes, window
  beachballing, vtebench blocked on write); measured with
  `VTEBENCH_MAX_SECS=1 KITTEN_REPS=10` (665 s wall). Same metric,
  fewer samples; its scroll-region rows print 0.0 because per-sample
  times are minutes — that is its real parse rate at its real grid,
  not a harness artifact this time.
- Versions: Alacritty 0.17.0 (cargo release build), Ghostty 1.3.1,
  kitty 0.47.2, WezTerm 20240203-110809, iTerm2 3.6.10, Terminal.app
  (macOS 26.5/25F71), Blackbird v0.3.4 Release + `84f9970`.
- Hardware: Apple Silicon MacBook Pro, ProMotion display, AC power.
- One full pass (same-day pass-1 archive corroborates every number
  within ~±5% except where the harness fixes changed the workload).
  Single machine. Order-of-magnitude-plus confidence, not lab-grade.

## Caveats, not hidden

- Ghostty's window is launched via a manual clipboard paste (its CLI
  launch paths are ignored under `open -a`); all other legs are fully
  automated. Ghostty's grid honored `window-width/height` via a seeded
  `XDG_CONFIG_HOME`.
- Blackbird's PTY read loop still ACKs ahead of parsing; under
  sustained flood the backlog is bounded by parse rate (~71 MB/s) not
  drain rate (~78 MB/s) — the gap is now small, but vtebench remains
  the friendlier of the two benchmarks for us. We publish both.
- Input latency is a separate axis. Blackbird's CI latency gate
  (markKeystroke→markPresented, p50 ≤ 6 ms / p99 ≤ 20 ms) is an
  internal pipeline probe and is NOT comparable to other terminals'
  numbers. Cross-terminal Typometer measurement pending.
