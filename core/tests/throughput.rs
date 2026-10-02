//! Parser throughput regression gate.
//!
//! Spec § 9 aspires to >200 MB/s. These tests measure three representative
//! workloads and fail the build if any falls below a conservative floor —
//! their job is to catch *regressions*, not to prove the aspirational number.
//! Floors sit at roughly 35-75% of the CI medians (see each workload below)
//! so GitHub macOS runner variance doesn't flake the build. Each workload is
//! gated on the best of up to `MAX_ATTEMPTS` runs, with the three tests
//! serialised: a shared VM can only ever slow a run down, so the maximum is a
//! sound estimate of what the parser can do, while a real regression slows
//! every attempt and still fails. Because the best attempt is what is judged,
//! sensitivity is measured against the CI *max*, not the median: a regression
//! must cost roughly 3.7x on plain, 2.9x on ansi and 1.6x on garbage to trip
//! the gate. A slowdown confined to some attempts (cold start only) is
//! invisible by design.
//!
//! Run with: `cargo test -p blackbird_core --test throughput --release -- --nocapture`

use std::sync::{Mutex, PoisonError};
use std::thread::sleep;
use std::time::{Duration, Instant};

/// 64 MiB per workload is enough to dwarf one-shot FFI / setup overhead
/// without ballooning CI wall time.
const PAYLOAD_BYTES: usize = 64 * 1024 * 1024;
/// 64 KiB matches TerminalSession's PTY read batch size — so the throughput
/// we measure here reflects what the real hot path sees.
const CHUNK_BYTES: usize = 64 * 1024;

unsafe fn feed_and_time(bytes: &[u8]) -> f64 {
    let term = blackbird_core::bb_term_new(200, 60, 10_000);
    assert!(!term.is_null());

    let start = Instant::now();
    for chunk in bytes.chunks(CHUNK_BYTES) {
        blackbird_core::bb_term_input(term, chunk.as_ptr(), chunk.len());
    }
    // Snapshot once at the end — the renderer pulls once per frame, not per
    // chunk, so this is the realistic workload.
    let snap = blackbird_core::bb_term_take_snapshot(term);
    assert!(!snap.is_null());
    blackbird_core::bb_snap_release(snap);
    let elapsed = start.elapsed();

    blackbird_core::bb_term_free(term);

    bytes.len() as f64 / elapsed.as_secs_f64()
}

fn mib(bytes_per_sec: f64) -> f64 {
    bytes_per_sec / (1024.0 * 1024.0)
}

fn assert_floor(bps: f64, floor_mib: f64, label: &str) {
    eprintln!("{label} throughput: {:.1} MiB/s", mib(bps));
    let floor = floor_mib * 1024.0 * 1024.0;
    assert!(
        bps >= floor,
        "{label} throughput {:.1} MiB/s below floor {:.1} MiB/s",
        mib(bps),
        floor_mib
    );
}

/// Nightly 2026-10-01 measured plain 26.7 / ansi 27.0 / garbage 12.1 MiB/s
/// (medians ~71 / ~69 / ~20.5) with no core/ change since 2026-09-15: a
/// noisy-neighbour burst on the runner, which a single 64 MiB shot cannot
/// ride out.
const MAX_ATTEMPTS: usize = 5;
/// Pause after a missed attempt so the retries are spread past a multi-second
/// noise burst instead of all landing inside it. Healthy runs never sleep.
const RETRY_PAUSE: Duration = Duration::from_secs(2);

/// libtest runs the three tests as parallel threads; on a small CI VM they
/// steal CPU and memory bandwidth from each other mid-measurement. Serialise
/// the timed sections (this also holds one payload + one BBTerm live at a
/// time instead of three).
static SERIAL: Mutex<()> = Mutex::new(());

/// Gate `floor_mib` on the best of up to `MAX_ATTEMPTS` runs, stopping at the
/// first pass. The `{label} throughput:` line is printed once, by
/// `assert_floor`, from the best attempt.
fn run_gate(label: &str, floor_mib: f64, build_payload: impl FnOnce() -> Vec<u8>) {
    // A failed assert in another test poisons the lock; the guard protects
    // nothing but timing, so keep going.
    let _serial = SERIAL.lock().unwrap_or_else(PoisonError::into_inner);
    let payload = build_payload();
    let floor_bps = floor_mib * 1024.0 * 1024.0;
    let mut best = 0.0_f64;
    for attempt in 1..=MAX_ATTEMPTS {
        let bps = unsafe { feed_and_time(&payload) };
        eprintln!(
            "{label} attempt {attempt}/{MAX_ATTEMPTS}: {:.1} MiB/s",
            mib(bps)
        );
        best = best.max(bps);
        if best >= floor_bps {
            break;
        }
        if attempt < MAX_ATTEMPTS {
            sleep(RETRY_PAUSE);
        }
    }
    assert_floor(best, floor_mib, label);
}

// ---------------------------------------------------------------------------
// Workload 1 — plain text (`yes`, `cat` a log file, tail -f).
// Most common real workload: newline-separated UTF-8 with no control sequences.
// Local M-series ~80 MiB/s. GitHub macos-14/15 runners (82 nightly + PR samples,
// Jul-Sep 2026): min 43 / median 71 / max 93 MiB/s. Floor 25 MiB/s is ~35% of
// the median, so it rides out noisy-neighbour variance. Judged on the best
// attempt (~max 93), it catches a ~3.7x or worse regression in the fast path.
// ---------------------------------------------------------------------------

#[test]
#[ignore = "throughput gate; run explicitly with: cargo test --release --test throughput -- --ignored --nocapture"]
fn throughput_plain_text() {
    run_gate("plain_text", 25.0, || {
        let line = b"The quick brown fox jumps over the lazy dog.\n";
        let mut payload = Vec::with_capacity(PAYLOAD_BYTES);
        while payload.len() < PAYLOAD_BYTES {
            payload.extend_from_slice(line);
        }
        payload.truncate(PAYLOAD_BYTES);
        payload
    });
}

// ---------------------------------------------------------------------------
// Workload 2 — binary/garbage stream (`cat /dev/urandom`, `hexdump`).
// Exercises the parser's bail paths: most bytes look like the *start* of a
// control sequence but aren't. Deterministic PRNG so CI runs are reproducible.
// Local M-series ~25 MiB/s. CI samples: min 15.1 / median 20.5 / max 24.5 MiB/s.
// Floor 15 MiB/s is ~73% of the CI median, which leaves almost no headroom for
// a single shot (the 2026-10-01 nightly read 12.1), so the gate rides on the
// best-of-`MAX_ATTEMPTS` retries in `run_gate` rather than a lower floor. A
// regression slows every attempt: against the CI max (24.5) the floor trips
// at ~1.6x.
// ---------------------------------------------------------------------------

#[test]
#[ignore = "throughput gate; run explicitly with: cargo test --release --test throughput -- --ignored --nocapture"]
fn throughput_binary_garbage() {
    run_gate("binary_garbage", 15.0, || {
        let mut payload = Vec::with_capacity(PAYLOAD_BYTES);
        let mut state: u32 = 0x9E3779B9;
        while payload.len() < PAYLOAD_BYTES {
            state = state.wrapping_mul(0x85EBCA77).wrapping_add(0x1B873593);
            payload.push(((state >> 16) & 0xFF) as u8);
        }
        payload
    });
}

// ---------------------------------------------------------------------------
// Workload 3 — realistic ANSI output (a colored build log).
// SGR foreground/background + reset per line, no full-screen redraws. This is
// what `cargo build`, `grc tail`, and most TUI logs generate. Local M-series
// ~80 MiB/s; CI samples min 44 / median 69 / max 86 MiB/s → floor 30 MiB/s
// (~43% of the median; trips on a ~2.9x regression from the max).
//
// NOT benchmarked here: pathological full-screen clear spam. ESC[2J on its
// own is cheap (alacritty just walks the visible grid), so a synthetic test
// clearing at multi-MHz would measure the parser overhead rather than any
// realistic workload.
// ---------------------------------------------------------------------------

#[test]
#[ignore = "throughput gate; run explicitly with: cargo test --release --test throughput -- --ignored --nocapture"]
fn throughput_ansi_log() {
    let frame: &[u8] = b"\
        \x1b[38;5;244m[2026-04-17T10:22:11Z]\x1b[39m \
        \x1b[1;32mINFO\x1b[0m  handler accepted request id=42 user=connor\n\
        \x1b[38;5;244m[2026-04-17T10:22:11Z]\x1b[39m \
        \x1b[1;33mWARN\x1b[0m  retrying upstream after \x1b[31m503\x1b[0m (attempt 2/5)\n\
        \x1b[38;5;244m[2026-04-17T10:22:11Z]\x1b[39m \
        \x1b[1;31mERROR\x1b[0m handler failed: \x1b[3mconnection refused\x1b[0m\n";
    run_gate("ansi_log", 30.0, || {
        let mut payload = Vec::with_capacity(PAYLOAD_BYTES);
        while payload.len() < PAYLOAD_BYTES {
            payload.extend_from_slice(frame);
        }
        payload.truncate(PAYLOAD_BYTES);
        payload
    });
}
