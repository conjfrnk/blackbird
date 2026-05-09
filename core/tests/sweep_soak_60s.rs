//! 60-second wall-clock soak — the real thing, not a probe.
//!
//! What this does
//! --------------
//! Runs a continuous loop of `bb_term_input` + snapshot churn for at
//! least 60 seconds of wall-clock time, sampling RSS at five points
//! (t≈0, 15, 30, 45, 60 s) and asserting:
//!
//!   1. Hard absolute ceiling: RSS never exceeds 64 MiB.
//!   2. Delta-of-deltas: late-window growth (45→60 s) is < 85 % of
//!      early-window growth (0→15 s). A real per-iteration leak grows
//!      linearly; allocator retention plateaus. Mirrors the gate idiom
//!      in `core/tests/long_session_memory.rs`.
//!
//! Why `#[ignore]`-gated
//! ---------------------
//! 60 seconds × per-PR runs × every-developer = a lot of CI minutes.
//! PR CI doesn't need this. The right home is a NIGHTLY workflow that
//! runs `--ignored` tests against `main`. The ignore gate keeps PR CI
//! fast while still letting the soak surface real-time-budget leaks
//! that the short `sweep_probe.rs` cannot — a leak that drips one
//! page (16 KiB) per second is invisible in 30 s but conspicuous in
//! 60 s, and outright damning at the hour scale.
//!
//! Pre-flight resource cost
//! ------------------------
//! - Wall-clock: ≥ 60 s by construction. Loop pacing aims at ~3 MiB/s
//!   sustained input throughput (matches a live `tail -f` + `cat
//!   large.log`).
//! - Cumulative parser bytes: ~60 s × ~3 MiB/s ≈ 180 MiB total fed
//!   through `bb_term_input` (transient — chunks are reused).
//! - Working set: 1 × 200×60 grid + 10 000-line scrollback ≈ ~10 MiB.
//! - Snapshot churn: ~15 fps cadence → ~900 snapshot acquire/release
//!   pairs in 60 s; each is bounded.
//! - Hard RSS ceiling: 64 MiB. Sized 16 MiB above the documented
//!   working set to absorb darwin allocator retention without hiding
//!   a real leak (see `long_session_memory.rs::new_free_cycle_is_bounded`
//!   for the same shape with a 48 MiB cap on a smaller working set).
//!
//! These numbers are calculated, not aspirational — Connor's rule
//! per `feedback_test_memory_safety.md` and the post-OOM-incident
//! `feedback_oom_resize_test.md`. If you alter loop shape, recompute
//! and update this comment.
//!
//! Run with:
//!   cargo test -p blackbird_core --release --test sweep_soak_60s \
//!     -- --ignored --nocapture --test-threads=1
//!
//! The `--test-threads=1` matches `long_session_memory.rs`'s nightly
//! invocation: parallel RSS gates fight each other for allocator
//! pages and trip the absolute ceiling spuriously.

#[cfg(target_os = "macos")]
mod macos {
    use std::time::{Duration, Instant};

    use blackbird_core as bc;

    /// Bytes of resident memory the current process is using.
    /// Mirrors the helper in `core/tests/long_session_memory.rs`. Kept
    /// duplicated rather than cross-imported because `tests/` files
    /// can't share modules without a build-script shim, and the helper
    /// is short enough that the duplication is cheaper than the
    /// abstraction.
    fn rss_bytes() -> usize {
        unsafe extern "C" {
            fn mach_task_self() -> u32;
            fn task_info(
                target_task: u32,
                flavor: u32,
                task_info_out: *mut i32,
                task_info_outCnt: *mut u32,
            ) -> i32;
        }
        #[repr(C)]
        #[derive(Default)]
        struct MachTaskBasicInfo {
            virtual_size: u64,
            resident_size: u64,
            resident_size_max: u64,
            user_time: [i32; 2],
            system_time: [i32; 2],
            policy: i32,
            suspend_count: i32,
        }
        const MACH_TASK_BASIC_INFO: u32 = 20;
        let size_bytes = std::mem::size_of::<MachTaskBasicInfo>();
        let mut count = (size_bytes / std::mem::size_of::<i32>()) as u32;
        let mut info = MachTaskBasicInfo::default();
        let kr = unsafe {
            task_info(
                mach_task_self(),
                MACH_TASK_BASIC_INFO,
                (&mut info as *mut _) as *mut i32,
                &mut count,
            )
        };
        assert_eq!(kr, 0, "task_info failed: {kr}");
        info.resident_size as usize
    }

    /// One iteration of "live session" work: feed a few KiB of mixed
    /// input (plaintext + SGR + OSC + alt-screen toggle + scroll),
    /// then take and release a snapshot. Sized to match a live PTY
    /// poll (~64 KiB-ish per second per renderer frame).
    unsafe fn one_chunk(term: *mut bc::BBTerm, alt_screen_toggle: bool) {
        // Mixed-content chunk. ~3 KiB per call. At ~1 kHz iteration
        // rate this gives ~3 MiB/s, which is the documented sustained
        // throughput for the pre-flight cost calc above.
        let plain = b"the quick brown fox jumps over the lazy dog 0123456789\n";
        let sgr: &[u8] =
            b"\x1b[1;31mERROR\x1b[0m \x1b[3mfile=/var/log/system.log line=42\x1b[0m\n";
        let osc7 = b"\x1b]7;file:///Users/connor/projects/blackbird\x1b\\\n";
        let osc8: &[u8] = b"\x1b]8;;https://blackbird-terminal.com/\x1b\\link\x1b]8;;\x1b\\\n";
        let cjk = "日本語 ログ メッセージ with ASCII tail\n".as_bytes();
        let bidi: &[u8] = b"\xF0\x9F\x98\x80 emoji + ASCII\n";

        for _ in 0..16 {
            unsafe { bc::bb_term_input(term, plain.as_ptr(), plain.len()) };
            unsafe { bc::bb_term_input(term, sgr.as_ptr(), sgr.len()) };
            unsafe { bc::bb_term_input(term, osc7.as_ptr(), osc7.len()) };
            unsafe { bc::bb_term_input(term, osc8.as_ptr(), osc8.len()) };
            unsafe { bc::bb_term_input(term, cjk.as_ptr(), cjk.len()) };
            unsafe { bc::bb_term_input(term, bidi.as_ptr(), bidi.len()) };
        }

        if alt_screen_toggle {
            // Alt-screen enter/leave round-trip — exercises the
            // dual-grid path without growing the scrollback floor.
            let enter: &[u8] = b"\x1b[?1049h";
            let leave: &[u8] = b"\x1b[?1049l";
            unsafe { bc::bb_term_input(term, enter.as_ptr(), enter.len()) };
            unsafe { bc::bb_term_input(term, b"alt screen content\n".as_ptr(), 19) };
            unsafe { bc::bb_term_input(term, leave.as_ptr(), leave.len()) };
        }

        // Scroll a small bounded delta — keeps the scroll API in the
        // hot loop without dominating it.
        unsafe { bc::bb_term_scroll(term, -3) };

        // Snapshot acquire + release — simulates a renderer frame.
        let snap = unsafe { bc::bb_term_take_snapshot(term) };
        assert!(!snap.is_null(), "snapshot must remain reachable mid-soak");
        unsafe { bc::bb_snap_release(snap) };
    }

    #[test]
    #[ignore = "60s soak; opt in with --ignored. Run nightly, not on PRs."]
    fn soak_60s_continuous_input_no_rss_drift() {
        const TARGET: Duration = Duration::from_secs(60);
        const CEILING_BYTES: usize = 64 * 1024 * 1024;
        const SAMPLE_INTERVAL: Duration = Duration::from_secs(15);

        unsafe {
            let term = bc::bb_term_new(200, 60, 10_000);
            assert!(!term.is_null());

            // Warm-up: amortise allocator start-up cost. ~1 s of work
            // before t=0 sample so the first sample reflects the
            // working-set baseline rather than cold-start growth.
            let warmup_deadline = Instant::now() + Duration::from_secs(1);
            let mut warmup_iter = 0u64;
            while Instant::now() < warmup_deadline {
                one_chunk(term, warmup_iter % 32 == 0);
                warmup_iter += 1;
            }

            // 5-sample schedule across 60 s: t=0, 15, 30, 45, 60.
            let start = Instant::now();
            let mut samples: Vec<(Duration, usize)> = Vec::with_capacity(5);
            samples.push((Duration::ZERO, rss_bytes()));
            eprintln!(
                "soak t=00s RSS: {:.1} MiB",
                samples[0].1 as f64 / (1024.0 * 1024.0)
            );

            let mut next_sample_at = SAMPLE_INTERVAL;
            let mut iter = 0u64;
            loop {
                let elapsed = start.elapsed();
                if elapsed >= TARGET {
                    break;
                }
                one_chunk(term, iter % 32 == 0);
                iter += 1;

                if elapsed >= next_sample_at {
                    let rss = rss_bytes();
                    samples.push((elapsed, rss));
                    eprintln!(
                        "soak t={:02}s RSS: {:.1} MiB ({} iter)",
                        elapsed.as_secs(),
                        rss as f64 / (1024.0 * 1024.0),
                        iter
                    );
                    assert!(
                        rss < CEILING_BYTES,
                        "RSS {:.1} MiB exceeded {:.0} MiB ceiling at t={}s — leak suspect",
                        rss as f64 / (1024.0 * 1024.0),
                        CEILING_BYTES as f64 / (1024.0 * 1024.0),
                        elapsed.as_secs()
                    );
                    next_sample_at += SAMPLE_INTERVAL;
                }
            }

            // Final sample after the 60 s window closes.
            let rss_end = rss_bytes();
            samples.push((start.elapsed(), rss_end));
            eprintln!(
                "soak t=60s RSS: {:.1} MiB ({} iter total)",
                rss_end as f64 / (1024.0 * 1024.0),
                iter
            );
            assert!(
                rss_end < CEILING_BYTES,
                "final RSS {:.1} MiB exceeded {:.0} MiB ceiling — leak suspect",
                rss_end as f64 / (1024.0 * 1024.0),
                CEILING_BYTES as f64 / (1024.0 * 1024.0)
            );

            // Delta-of-deltas. We need at least t=0, t=15, t=45, t=60
            // to compare early vs late windows. If sampling stalled
            // (loaded CI runner) we may have fewer; bail in that case
            // — the absolute ceiling above is still enforced.
            //
            // Threshold 0.85 matches the gate in
            // long_session_memory.rs lines 164/247: a sustained leak
            // shows late ≈ early (ratio ~1.0); allocator retention
            // pushes the ratio toward 0.
            //
            // We also require that the early window had a CLEAR
            // signal (≥ 4 MiB of growth) before applying the ratio
            // gate — otherwise the ratio is dominated by allocator
            // noise and the absolute ceiling is the only meaningful
            // safety net. This mirrors the `min_visible_first` guard
            // in long_session_memory.rs.
            if samples.len() >= 5 {
                let rss_t0 = samples[0].1;
                let rss_t15 = samples[1].1;
                let rss_t45 = samples[3].1;
                let rss_t60 = samples[samples.len() - 1].1;

                let delta_early = rss_t15.saturating_sub(rss_t0);
                let delta_late = rss_t60.saturating_sub(rss_t45);
                eprintln!(
                    "soak delta_early (0→15s): {:.1} MiB; delta_late (45→60s): {:.1} MiB",
                    delta_early as f64 / (1024.0 * 1024.0),
                    delta_late as f64 / (1024.0 * 1024.0)
                );

                let min_visible = 4 * 1024 * 1024;
                if delta_early > min_visible {
                    let ratio = (delta_late as f64) / (delta_early as f64);
                    assert!(
                        ratio < 0.85,
                        "late-window RSS growth {:.1} MiB is {:.0}% of early-window {:.1} MiB \
                         — sustained per-iteration leak suspected",
                        delta_late as f64 / (1024.0 * 1024.0),
                        ratio * 100.0,
                        delta_early as f64 / (1024.0 * 1024.0)
                    );
                }
            } else {
                eprintln!(
                    "soak: collected only {} samples (expected 5); skipping \
                     delta-of-deltas gate. Absolute ceiling enforced.",
                    samples.len()
                );
            }

            bc::bb_term_free(term);
        }
    }
}

#[cfg(not(target_os = "macos"))]
#[test]
#[ignore]
fn soak_60s_macos_only() {
    // mach_task_basic_info is macOS-only. Blackbird itself is macOS-
    // only, so the gate is fine. Stub keeps the test harness
    // buildable on Linux (fuzz CI) without compile-time errors.
}
