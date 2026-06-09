//! Pins long-session non-memory resource behaviour. Catches file-descriptor
//! leaks and thread accumulation across many `bb_term_new` / `bb_term_free`
//! cycles. Sibling of `long_session_memory.rs` — that file gates RSS, this
//! one gates FDs and live thread count, the two non-memory resources a
//! per-term regression would silently exhaust over a long session.
//!
//! Why this gate exists, separately from RSS:
//!   * A regression that `mem::forget`s an `Arc<File>` per term wouldn't
//!     necessarily show up in RSS within the 128-iteration window of
//!     `long_session_memory.rs`, but every cycle would burn an FD until the
//!     process hits `ulimit -n` mid-session.
//!   * The debug-only busy flag on `CallbackCell` (audit S1-004)
//!     encodes a mutual-exclusion (one-thread-at-a-time) contract.
//!     A future regression that spawns a worker thread per `BBTerm`
//!     (e.g. an internal background task on the listener) would compile,
//!     pass debug-thread-check (each new BBTerm owns its own latch), and
//!     only show up as runaway thread count in production — exactly what
//!     this gate catches at CI time.
//!
//! Strategy: warm up to absorb first-time DispatchQueue / allocator startup
//! costs, snapshot baseline FD + thread counts, run 1024 churn cycles, then
//! assert both end inside a small absolute slop above baseline. Unlike RSS
//! (where allocator retention forces a delta-of-deltas approach), FDs and
//! live threads must return *exactly* to baseline modulo a few-unit slop —
//! a per-iteration leak of either would dwarf the slop after 1024 cycles.
//!
//! Pre-flight cost (Connor's `feedback_test_memory_safety.md` rule):
//!   * 1024 cycles × ~150 KiB transient alloc per cycle = ~150 MiB cumulative
//!     transient (each cycle frees before the next), peak working set ~150 KiB.
//!     The 80×24×1000-line scrollback grid + a single 16 KiB input chunk +
//!     one snapshot is far smaller than `long_session_memory.rs`'s 4 MiB
//!     payload × 200×60×10000 grid.
//!   * 16 KiB input × 1024 cycles = 16 MiB cumulative parser work.
//!   * Wall clock: ~5–15 s on macos-14 GHA in `--release`.
//!   * No multi-MB transient state at any point — safe for shared CI runner.
//!
//! Run with (`--test-threads=1` matters: parallel tests would share the
//! process-wide FD table and thread list, cross-contaminating measurements):
//!
//!   cargo test -p blackbird_core --test long_session_resources --release \
//!       -- --ignored --nocapture --test-threads=1

#[cfg(target_os = "macos")]
mod macos {
    use blackbird_core as bc;

    // -----------------------------------------------------------------------
    // Mach + libproc shims
    //
    // Same pattern as `long_session_memory.rs` — declare just the C entry
    // points we need via `extern "C"` rather than dragging in `mach2` /
    // `libproc` crates as dev-deps. Keeps the dev tree exactly as it is in
    // `Cargo.toml` (only `alacritty_terminal` + `memchr`).
    // -----------------------------------------------------------------------

    /// Live thread count for the current process.
    ///
    /// Wraps `task_threads(mach_task_self(), &out, &out_count)` and
    /// `vm_deallocate`s the returned port array. The Mach API hands back an
    /// allocation that the caller is contractually required to release;
    /// without the `vm_deallocate` we'd be leaking the very thing this test
    /// exists to catch.
    ///
    /// Returns 0 on syscall failure so the caller's `assert!(count > 0)`
    /// surfaces a silent failure as a test failure rather than a 0-vs-0 pass.
    fn task_threads_count() -> u32 {
        // task_t = mach_port_t = u32; thread_act_array_t = *mut mach_port_t.
        // mach_msg_type_number_t = u32. kern_return_t = i32. KERN_SUCCESS = 0.
        // vm_address_t / vm_size_t are uintptr_t (kernel-pointer-sized).
        unsafe extern "C" {
            fn mach_task_self() -> u32;
            fn task_threads(
                target_task: u32,
                act_list: *mut *mut u32,
                act_list_cnt: *mut u32,
            ) -> i32;
            fn vm_deallocate(target_task: u32, address: usize, size: usize) -> i32;
        }
        let mut act_list: *mut u32 = std::ptr::null_mut();
        let mut act_count: u32 = 0;
        let kr = unsafe { task_threads(mach_task_self(), &mut act_list, &mut act_count) };
        if kr != 0 {
            return 0;
        }
        // Free the port array. Size is count × sizeof(mach_port_t) where
        // mach_port_t is 4 bytes. Failure here is ignored — we already have
        // the count we wanted; an unfreed port array would itself leak FDs
        // and trip the test, which is the right outcome.
        if !act_list.is_null() && act_count > 0 {
            let bytes = (act_count as usize) * std::mem::size_of::<u32>();
            unsafe {
                vm_deallocate(mach_task_self(), act_list as usize, bytes);
            }
        }
        act_count
    }

    /// Open file-descriptor count for the current process via
    /// `proc_pidinfo(PROC_PIDLISTFDS, …)`.
    ///
    /// The `proc_pidinfo` ABI: pass buffer=NULL, size=0 to learn the byte
    /// length the kernel would write, then allocate and ask again. The
    /// returned byte length divided by `sizeof(struct proc_fdinfo)` (8 on
    /// macOS — `int32_t fd; uint32_t fdtype`) is the live FD count.
    ///
    /// Returns 0 on syscall failure; caller asserts `count > 0` to surface
    /// silent failures.
    fn proc_pidlistfds_count() -> u32 {
        unsafe extern "C" {
            fn getpid() -> i32;
            fn proc_pidinfo(
                pid: i32,
                flavor: i32,
                arg: u64,
                buffer: *mut std::ffi::c_void,
                buffersize: i32,
            ) -> i32;
        }
        const PROC_PIDLISTFDS: i32 = 1;
        // `struct proc_fdinfo { int32_t fd; uint32_t fdtype; }` — 8 bytes.
        const PROC_FDINFO_SIZE: usize = 8;

        let pid = unsafe { getpid() };
        // Probe call: ask the kernel how big a buffer we need.
        let probe = unsafe { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, std::ptr::null_mut(), 0) };
        if probe <= 0 {
            return 0;
        }
        // Pad the buffer slightly: between probe and second call, the FD
        // table can grow (e.g. a runtime thread might open a kqueue). The
        // kernel will simply truncate the write to fit, so over-allocating
        // is harmless. 16-entry headroom is plenty for any race window.
        let buf_size = (probe as usize) + 16 * PROC_FDINFO_SIZE;
        let mut buf = vec![0u8; buf_size];
        let written = unsafe {
            proc_pidinfo(
                pid,
                PROC_PIDLISTFDS,
                0,
                buf.as_mut_ptr() as *mut std::ffi::c_void,
                buf_size as i32,
            )
        };
        if written <= 0 {
            return 0;
        }
        ((written as usize) / PROC_FDINFO_SIZE) as u32
    }

    // -----------------------------------------------------------------------
    // The gate
    // -----------------------------------------------------------------------

    /// One churn cycle: allocate, drive ~16 KiB of input, take + release a
    /// single snapshot, free. Mirrors the short-session/window-cycle traffic
    /// pattern (a user opening + closing tabs over hours), in contrast to
    /// `long_session_memory.rs::one_iteration` which exercises one long-lived
    /// term with heavy payload + 16 snapshots. A per-cycle FD or thread leak
    /// would manifest equally in either pattern; this one is cheaper per
    /// cycle so we can afford the 1024-cycle multiplier that makes the
    /// signal unmissable.
    unsafe fn one_cycle(payload: &[u8]) {
        let term = bc::bb_term_new(80, 24, 1_000);
        assert!(!term.is_null());
        // Single 16 KiB push — matches the realistic per-frame PTY-read
        // batch size. Splitting into smaller chunks doesn't change the
        // resource shape (the parser is allocation-free at chunk boundaries).
        bc::bb_term_input(term, payload.as_ptr(), payload.len());
        let s = bc::bb_term_take_snapshot(term);
        if !s.is_null() {
            bc::bb_snap_release(s);
        }
        bc::bb_term_free(term);
    }

    #[test]
    #[ignore = "resource leak gate; run with: cargo test --release --test long_session_resources -- --ignored --nocapture --test-threads=1"]
    fn resources_return_to_baseline_after_term_churn() {
        // 16 KiB payload — enough to exercise the parser (mixed plain text +
        // SGR + CJK so the OSC/CSI/UTF-8 paths all light up) without making
        // each iteration heavy. Cumulative parser work is 16 MiB across the
        // 1024-cycle run, well inside CI's tolerance.
        let mut payload = Vec::with_capacity(16 * 1024);
        let line_plain = b"the quick brown fox jumps over the lazy dog\n";
        let line_ansi: &[u8] =
            b"\x1b[38;5;244m[timestamp]\x1b[39m \x1b[32minfo\x1b[0m message with data\n";
        let line_cjk = "日本語 テキスト mixed ASCII + CJK content per line\n".as_bytes();
        while payload.len() < 16 * 1024 {
            payload.extend_from_slice(line_plain);
            payload.extend_from_slice(line_ansi);
            payload.extend_from_slice(line_cjk);
        }

        // Warm-up: 8 cycles to absorb first-time costs. Anything created on
        // the FIRST `bb_term_new` (lazy DispatchQueue spin-up, allocator
        // arena init, lazy `OnceLock` populations on the static side) shows
        // up as a one-shot delta that would falsely look like a leak if we
        // measured baseline before it.
        for _ in 0..8 {
            unsafe { one_cycle(&payload) };
        }

        let baseline_threads = task_threads_count();
        let baseline_fds = proc_pidlistfds_count();
        // Surface silent syscall failure as a test failure — a 0 here would
        // otherwise mask any later non-zero count as "growth from 0", which
        // would trip the gate spuriously and obscure the real diagnostic.
        assert!(
            baseline_threads > 0,
            "task_threads syscall failed at baseline (returned 0)"
        );
        assert!(
            baseline_fds > 0,
            "proc_pidinfo syscall failed at baseline (returned 0)"
        );
        eprintln!("baseline threads: {baseline_threads}  baseline FDs: {baseline_fds}");

        // Churn: 1024 cycles. A per-iteration FD leak burns 1024 FDs (well
        // beyond the +8 slop). A per-iteration worker-thread spawn burns
        // 1024 threads (well beyond the +4 slop). A busy-flag/guard
        // bug that leaks the first-thread latch's containing Arc would
        // manifest as RSS in the sibling test, not here — this gate's job
        // is the OS-resource handles specifically.
        const ITERATIONS: usize = 1024;
        for _ in 0..ITERATIONS {
            unsafe { one_cycle(&payload) };
        }

        let final_threads = task_threads_count();
        let final_fds = proc_pidlistfds_count();
        assert!(
            final_threads > 0,
            "task_threads syscall failed at end of run (returned 0)"
        );
        assert!(
            final_fds > 0,
            "proc_pidinfo syscall failed at end of run (returned 0)"
        );
        eprintln!("final    threads: {final_threads}  final    FDs: {final_fds}");

        let thread_delta = (final_threads as i64) - (baseline_threads as i64);
        let fd_delta = (final_fds as i64) - (baseline_fds as i64);
        eprintln!(
            "delta    threads: {thread_delta:+}  delta    FDs: {fd_delta:+}  iterations: {ITERATIONS}"
        );

        // Absolute caps: the slop absorbs benign growth from runtime threads
        // and FDs that lazy-init during the test (e.g. the test harness'
        // own logging buffer, libdispatch's per-QoS worker threads warming
        // up under load). +4 / +8 leaves room for that without admitting a
        // per-iteration leak: a cycle-leaked FD or thread would push the
        // delta to ITERATIONS-scale (1024+), three orders of magnitude
        // above the slop.
        const THREAD_SLOP: i64 = 4;
        const FD_SLOP: i64 = 8;

        assert!(
            final_threads as i64 <= baseline_threads as i64 + THREAD_SLOP,
            "thread count leaked: baseline={baseline_threads} final={final_threads} \
             delta={thread_delta} limit=+{THREAD_SLOP} iterations={ITERATIONS} — \
             a per-iteration thread spawn would push delta to ITERATIONS-scale; \
             {thread_delta} threads above baseline suggests a regression in the \
             mutual-exclusion contract (CallbackCell.busy debug flag, audit S1-004)"
        );
        assert!(
            final_fds as i64 <= baseline_fds as i64 + FD_SLOP,
            "file descriptor count leaked: baseline={baseline_fds} final={final_fds} \
             delta={fd_delta} limit=+{FD_SLOP} iterations={ITERATIONS} — \
             a per-iteration FD leak would push delta to ITERATIONS-scale; \
             {fd_delta} FDs above baseline suggests a missing close in the \
             bb_term_new / bb_term_free path"
        );
    }
}

#[cfg(not(target_os = "macos"))]
#[test]
#[ignore]
fn resources_test_macos_only() {
    // task_threads / proc_pidinfo are macOS-only. Blackbird itself is
    // macOS-only, so this restriction is fine. Keep the test harness
    // buildable on Linux (for fuzz CI) by stubbing out — same pattern as
    // long_session_memory.rs.
}
