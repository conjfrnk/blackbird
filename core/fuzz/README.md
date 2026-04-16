# blackbird_core fuzz harness

Covers `bb_term_input` — the PTY-output → VT-parser boundary. Never run
as part of CI's quick loop; invoke manually or in nightly campaigns.

## Quickstart (macOS)

```sh
rustup install nightly
cd core/fuzz
cargo +nightly fuzz run fuzz_term_input -- -max_total_time=60
```

Crashes land in `artifacts/fuzz_term_input/`. Reproduce with:

```sh
cargo +nightly fuzz run fuzz_term_input artifacts/fuzz_term_input/crash-XXXX
```

The harness spins up a fresh 80×24 terminal per iteration, feeds the
input bytes, takes a snapshot, and tears everything down. Covers
`bb_term_new`, `bb_term_input`, `bb_term_take_snapshot`, `bb_snap_release`,
`bb_term_free`.
