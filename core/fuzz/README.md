# blackbird_core fuzz harness

Covers the PTY-output → VT-parser boundary and adjacent FFI entry
points. CI's `rust-fuzz-smoke` job runs every target for 30 s on every
push/PR — a fast regression gate, not an exhaustive campaign. For
serious bug hunting, invoke manually with a larger `-max_total_time`
budget, or run nightly against a committed seed corpus.

## Targets

| Target | Surface |
|--------|---------|
| `fuzz_term_input` | `bb_term_input` byte feed — the canonical VT parser ingest. Spins up a fresh 80×24 terminal per iteration, feeds the input bytes, takes a snapshot, and tears everything down. |
| `fuzz_reply_storm` | Inputs that synthesize host-bound replies (DA1, XTGETTCAP, OSC 10/11/12 queries, CSI 20t/21t). Stresses the reply-rate limiter and the reply-channel back-pressure. |
| `fuzz_resize2` | Adversarial `bb_term_resize2` sequences interleaved with feed bytes. Stresses the grid-resize alloc path and the snapshot reborrow surface. |
| `fuzz_text_range` | Random `bb_term_text_range` queries against an arbitrary feed history. Stresses the row-clamp + cap-row logic that v0.2.6 fixed (S5-002/S5-003 + the S1-002/S4-001 regression tail). |

## Quickstart (macOS)

```sh
rustup install nightly
cd core/fuzz
cargo +nightly fuzz run fuzz_term_input -- -max_total_time=60
# or any other target:
cargo +nightly fuzz run fuzz_text_range -- -max_total_time=60
```

Crashes land in `artifacts/<target>/`. Reproduce with:

```sh
cargo +nightly fuzz run <target> artifacts/<target>/crash-XXXX
```
