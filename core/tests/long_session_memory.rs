//! Pins long-session memory behaviour. Catches leaks in the snapshot
//! acquire/release cycle, scrollback ring-buffer accumulation, and the
//! FFI-level allocation dance.
//!
//! Strategy: measure resident set size (RSS) via `task_info` after a warm-up
//! period, then do a long run of terminal activity and require that RSS
//! didn't grow beyond a bounded multiple of the warm-up size. An actual leak
//! would cause linear growth with the number of iterations; a bounded-growth
//! assertion catches that without needing a perfect 0-delta check (darwin's
//! allocator can hold on to pages opportunistically).
//!
//! Run with: `cargo test -p blackbird_core --test long_session_memory --release -- --ignored --nocapture`

#[cfg(target_os = "macos")]
mod macos {
    use blackbird_core as bc;

    /// Bytes of resident memory the current process is using.
    /// Uses Mach's `task_info(MACH_TASK_BASIC_INFO)`; robust and quick.
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
        // Layout of mach_task_basic_info from <mach/task_info.h>.
        // integer_t = i32; mach_vm_size_t = u64; time_value_t = {i32,i32}.
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
        // Count is in sizeof(int) units per Mach API convention.
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

    /// One simulated iteration: allocate terminal, feed a chunk of mixed
    /// content, take / release snapshots, clear, free. This is the pattern a
    /// long session actually exercises — PTY output, snapshot read per frame,
    /// occasional `clear`, many window cycles over hours of use.
    unsafe fn one_iteration(payload: &[u8]) {
        let term = bc::bb_term_new(200, 60, 10_000);
        assert!(!term.is_null());
        // Feed in 64 KiB chunks matching the real PTY-read batch size.
        for chunk in payload.chunks(64 * 1024) {
            bc::bb_term_input(term, chunk.as_ptr(), chunk.len());
        }
        // Take and release 16 snapshots — simulates ~15 fps of rendering.
        for _ in 0..16 {
            let s = bc::bb_term_take_snapshot(term);
            if !s.is_null() {
                bc::bb_snap_release(s);
            }
        }
        bc::bb_term_clear_all(term);
        bc::bb_term_free(term);
    }

    #[test]
    #[ignore = "memory growth gate; run with: cargo test --release --test long_session_memory -- --ignored --nocapture"]
    fn new_free_cycle_is_bounded() {
        // 4 MiB payload per iteration mixing plain text + ANSI + CJK. Big
        // enough to trigger scrollback churn (10k lines at ~80 cols ≈ 800 KB
        // of live text) without making the test take minutes.
        let mut payload = Vec::with_capacity(4 * 1024 * 1024);
        let line_plain = b"the quick brown fox jumps over the lazy dog\n";
        let line_ansi: &[u8] =
            b"\x1b[38;5;244m[timestamp]\x1b[39m \x1b[32minfo\x1b[0m message with data\n";
        let line_cjk = "日本語 テキスト mixed ASCII + CJK content per line\n".as_bytes();
        while payload.len() < 4 * 1024 * 1024 {
            payload.extend_from_slice(line_plain);
            payload.extend_from_slice(line_ansi);
            payload.extend_from_slice(line_cjk);
        }

        // Warm-up: amortise allocator start-up cost and hit a steady state.
        for _ in 0..4 {
            unsafe { one_iteration(&payload) };
        }
        let rss_warm = rss_bytes();
        eprintln!(
            "warm-up RSS: {:.1} MiB",
            rss_warm as f64 / (1024.0 * 1024.0)
        );

        // Sustained load: many iterations of the full new/input/snap/free
        // cycle. An unbounded snapshot leak would reveal itself here as
        // linear growth with N.
        for _ in 0..64 {
            unsafe { one_iteration(&payload) };
        }

        let rss_end = rss_bytes();
        eprintln!(
            "post-run RSS: {:.1} MiB",
            rss_end as f64 / (1024.0 * 1024.0)
        );
        let growth = rss_end.saturating_sub(rss_warm);
        eprintln!(
            "growth over 64 iterations: {:.1} MiB",
            growth as f64 / (1024.0 * 1024.0)
        );

        // A real leak would add ~scrollback-worth of memory per iteration
        // (at least hundreds of KB). 64 iterations → tens of MB. Observed
        // on M2 Pro: ~0-2 MiB variance. Observed on macos-14 CI runners:
        // up to ~26 MiB variance under load — the 16 MiB gate tripped on
        // a clean run with no code leak (local repro: 1.3 MiB). Bump to
        // 48 MiB so a real 1 MB/iter leak still fails (64 MiB) while
        // allocator retention under runner pressure doesn't.
        assert!(
            growth < 48 * 1024 * 1024,
            "RSS grew by {:.1} MiB over 64 iterations — suspect leak",
            growth as f64 / (1024.0 * 1024.0)
        );
    }

    #[test]
    #[ignore = "memory growth gate; run with: cargo test --release --test long_session_memory -- --ignored --nocapture"]
    fn snapshot_churn_is_bounded() {
        // Single long-lived terminal, many many snapshots. If bb_snap_release
        // drops the wrong ref, we'd leak one snapshot's worth of cells per
        // call — a 200x60 grid is ~96 KB, so 50k snapshots of leak would be
        // ~4.8 GB.
        let term = unsafe { bc::bb_term_new(200, 60, 10_000) };
        assert!(!term.is_null());

        let payload = b"\
            \x1b[1;31mred\x1b[0m \x1b[4munderline\x1b[24m \x1b[42mgreen bg\x1b[0m\n";
        // Seed a full scrollback's worth of content.
        for _ in 0..12_000 {
            unsafe { bc::bb_term_input(term, payload.as_ptr(), payload.len()) };
        }

        let rss_seed = rss_bytes();
        eprintln!("seed RSS: {:.1} MiB", rss_seed as f64 / (1024.0 * 1024.0));

        for _ in 0..50_000 {
            let s = unsafe { bc::bb_term_take_snapshot(term) };
            assert!(!s.is_null());
            unsafe { bc::bb_snap_release(s) };
        }

        let rss_end = rss_bytes();
        eprintln!(
            "after 50k snapshots RSS: {:.1} MiB",
            rss_end as f64 / (1024.0 * 1024.0)
        );

        // 50k snapshot acquire/release. A real ref-count bug in bb_snap_release
        // leaks ~96 KB per call (one 200x60 grid) → 4.8 GiB total, dwarfing any
        // threshold. macos-14 runners observed up to ~16.5 MiB of allocator
        // retention noise here, so the limit sits at 32 MiB — still 100×+ below
        // the smallest interesting leak rate (1-in-100 calls leaking).
        let growth = rss_end.saturating_sub(rss_seed);
        assert!(
            growth < 32 * 1024 * 1024,
            "RSS grew by {:.1} MiB over 50k snapshots — suspect snapshot leak",
            growth as f64 / (1024.0 * 1024.0)
        );

        unsafe { bc::bb_term_free(term) };
    }
}

#[cfg(not(target_os = "macos"))]
#[test]
#[ignore]
fn memory_test_macos_only() {
    // mach_task_basic_info is macOS-only. Blackbird itself is macOS-only, so
    // this restriction is fine. Keep the test harness buildable on Linux
    // (for fuzz CI) by stubbing out.
}
