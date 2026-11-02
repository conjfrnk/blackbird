//! Blind regression tests for the kitty keyboard protocol "set" command,
//! `CSI = flags ; mode u`.
//!
//! The protocol keeps a stack of flag entries. `CSI > flags u` pushes a new
//! entry, `CSI < n u` pops entries, and `CSI = flags ; mode u` *modifies the
//! entry currently on top of the stack* (`mode` 1 = replace all bits, 2 = set
//! the given bits, 3 = reset the given bits; omitted = 1). `CSI ? u` asks the
//! terminal which flags are active and it answers `CSI ? flags u`.
//!
//! The consequence that matters to programs: whatever `CSI = ... u` wrote is
//! "the active flags", so
//!
//!   * `CSI ? u` right after must report it (not a stale value),
//!   * a later push followed by a pop must land back on it, and
//!   * a round trip through the alternate screen (`?1049h` / `?1049l`) must
//!     leave it intact (the main screen's keyboard state is saved and restored
//!     across the swap).
//!
//! Two independent observation channels are used so a failure pinpoints the
//! contradiction a probing program would see:
//!
//!   * the `CSI ? u` reply that surfaces as a `PtyWrite` event, and
//!   * the live key-encoding flags, reconstructed from the `bb_mode`
//!     kitty bits in the snapshot (flag 1 = DISAMBIGUATE_ESC_CODES,
//!     2 = REPORT_EVENT_TYPES, 4 = REPORT_ALTERNATE_KEYS,
//!     8 = REPORT_ALL_KEYS_AS_ESC, 16 = REPORT_ASSOCIATED_TEXT).
//!
//! The live-flag assertions that run BEFORE the query / push / pop / swap are
//! deliberate preconditions: they prove the `=` command did take effect, so the
//! later assertions can only fail because the saved state diverged from it.
//!
//! Cost: each test feeds a few dozen bytes into an 80x24 grid with 100 lines
//! of scrollback and takes at most six replies (far below the 128-reply PTY
//! write burst cap). Nothing allocates at grid scale.

use std::os::raw::c_void;
use std::sync::{Arc, Mutex};

use blackbird_core as bc;
use blackbird_core::bb_mode;

const COLS: u16 = 80;
const ROWS: u16 = 24;
const SCROLLBACK: u32 = 100;

/// Everything the tests need to see from the event callback.
#[derive(Default)]
struct Captured {
    /// Bytes the terminal wants written back to the shell (`CSI ? u` replies).
    pty_writes: Vec<Vec<u8>>,
    /// Panic messages surfaced by the FFI's `catch_unwind`. MUST stay empty.
    fatals: Vec<String>,
}

unsafe extern "C" fn capture_cb(ev: bc::BBEvent, ctx: *mut c_void) {
    let cap = &*(ctx as *const Mutex<Captured>);
    let bytes: &[u8] = if ev.payload.is_null() || ev.len == 0 {
        &[]
    } else {
        std::slice::from_raw_parts(ev.payload, ev.len)
    };
    let mut guard = cap.lock().unwrap();
    match ev.kind {
        bc::BBEventKind::PtyWrite => guard.pty_writes.push(bytes.to_vec()),
        bc::BBEventKind::Fatal => guard
            .fatals
            .push(String::from_utf8_lossy(bytes).into_owned()),
        _ => {}
    }
}

/// One terminal plus its event capture, torn down on drop.
struct Harness {
    term: *mut bc::BBTerm,
    cap: Arc<Mutex<Captured>>,
    /// The `Arc` clone handed to the C callback as `ctx`; reclaimed in `Drop`.
    cap_ctx: *mut c_void,
}

impl Harness {
    fn new() -> Self {
        let cap: Arc<Mutex<Captured>> = Arc::new(Mutex::new(Captured::default()));
        let cap_ctx = Arc::into_raw(cap.clone()) as *mut c_void;
        let term = unsafe { bc::bb_term_new(COLS, ROWS, SCROLLBACK) };
        assert!(!term.is_null(), "bb_term_new returned null");
        unsafe { bc::bb_term_set_event_cb(term, Some(capture_cb), cap_ctx) };
        Harness { term, cap, cap_ctx }
    }

    fn feed(&self, bytes: &[u8]) {
        unsafe { bc::bb_term_input(self.term, bytes.as_ptr(), bytes.len()) };
    }

    /// Raw `bb_mode` bitfield from a fresh snapshot.
    fn mode_bits(&self) -> u32 {
        unsafe {
            let snap = bc::bb_term_take_snapshot(self.term);
            assert!(!snap.is_null(), "bb_term_take_snapshot returned null");
            let m = (*snap).mode;
            bc::bb_snap_release(snap);
            m
        }
    }

    /// The kitty key-encoding flags the terminal is encoding keys with right
    /// now, reassembled from the snapshot's mode bits.
    fn live_flags(&self) -> u32 {
        let m = self.mode_bits();
        let mut flags: u32 = 0;
        if m & bb_mode::DISAMBIGUATE_ESC_CODES != 0 {
            flags |= 1;
        }
        if m & bb_mode::REPORT_EVENT_TYPES != 0 {
            flags |= 2;
        }
        if m & bb_mode::REPORT_ALTERNATE_KEYS != 0 {
            flags |= 4;
        }
        if m & bb_mode::REPORT_ALL_KEYS_AS_ESC != 0 {
            flags |= 8;
        }
        if m & bb_mode::REPORT_ASSOCIATED_TEXT != 0 {
            flags |= 16;
        }
        flags
    }

    fn pty_writes(&self) -> Vec<Vec<u8>> {
        self.cap.lock().unwrap().pty_writes.clone()
    }

    fn fatals(&self) -> Vec<String> {
        self.cap.lock().unwrap().fatals.clone()
    }

    /// Drop all replies captured so far, so each query is judged on its own.
    fn clear_writes(&self) {
        self.cap.lock().unwrap().pty_writes.clear();
    }

    /// Send `CSI ? u` and return exactly the reply it produced, as text.
    fn query_flags_reply(&self) -> String {
        self.clear_writes();
        self.feed(b"\x1b[?u");
        let writes = self.pty_writes();
        assert_eq!(
            writes.len(),
            1,
            "CSI ? u must produce exactly one reply; got {writes:?}"
        );
        String::from_utf8_lossy(&writes[0]).into_owned()
    }
}

impl Drop for Harness {
    fn drop(&mut self) {
        unsafe {
            bc::bb_term_set_event_cb(self.term, None, std::ptr::null_mut());
            bc::bb_term_free(self.term);
            drop(Arc::from_raw(self.cap_ctx as *const Mutex<Captured>));
        }
    }
}

/// The reply a correct terminal gives to `CSI ? u` when `flags` are active.
fn reply_for(flags: u32) -> String {
    format!("\x1b[?{flags}u")
}

// ---------------------------------------------------------------------------
// 1. The reply to `CSI ? u` must agree with what `CSI = ... u` just set.
// ---------------------------------------------------------------------------

#[test]
fn query_after_set_reports_the_flags_that_were_set() {
    let h = Harness::new();

    // Sanity: a fresh terminal has no kitty flags and says so.
    assert_eq!(h.live_flags(), 0, "fresh terminal has kitty flags lit");
    assert_eq!(
        h.query_flags_reply(),
        reply_for(0),
        "fresh terminal must report flags 0"
    );

    // `CSI = 5 u`: disambiguate (1) | report alternate keys (4).
    h.feed(b"\x1b[=5u");

    // Precondition: the set really changed the keys' encoding state.
    assert_eq!(
        h.live_flags(),
        5,
        "after ESC[=5u the live key-encoding flags must be 5 (mode bits 0x{:x})",
        h.mode_bits()
    );

    // The contradiction under test: keys are encoded with flags 5, so the
    // reply to the probe must say 5 too.
    assert_eq!(
        h.query_flags_reply(),
        reply_for(5),
        "ESC[?u after ESC[=5u must report 5 (live flags are {})",
        h.live_flags()
    );
    assert!(h.fatals().is_empty(), "VT panicked: {:?}", h.fatals());
}

#[test]
fn query_after_explicit_replace_mode_reports_the_flags_that_were_set() {
    // `CSI = flags ; 1 u` is the spelled-out form of the default mode
    // ("replace all bits"). Use a value with a different bit pattern than the
    // other tests (event types + all-keys = 2 | 8 = 10).
    let h = Harness::new();
    h.feed(b"\x1b[=10;1u");

    assert_eq!(
        h.live_flags(),
        10,
        "after ESC[=10;1u the live key-encoding flags must be 10 (mode bits 0x{:x})",
        h.mode_bits()
    );
    assert_eq!(
        h.query_flags_reply(),
        reply_for(10),
        "ESC[?u after ESC[=10;1u must report 10 (live flags are {})",
        h.live_flags()
    );
    assert!(h.fatals().is_empty(), "VT panicked: {:?}", h.fatals());
}

// ---------------------------------------------------------------------------
// 2. A later push/pop must land back on the flags that `=` set.
// ---------------------------------------------------------------------------

#[test]
fn flags_set_with_equals_survive_a_push_then_pop() {
    let h = Harness::new();

    h.feed(b"\x1b[=5u");
    assert_eq!(
        h.live_flags(),
        5,
        "precondition: ESC[=5u must light flags 5 (mode bits 0x{:x})",
        h.mode_bits()
    );

    // Push an entry with flags 1: the active flags become exactly 1.
    h.feed(b"\x1b[>1u");
    assert_eq!(
        h.live_flags(),
        1,
        "after ESC[>1u the live flags must be exactly 1 (mode bits 0x{:x})",
        h.mode_bits()
    );
    assert_eq!(
        h.query_flags_reply(),
        reply_for(1),
        "ESC[?u while the pushed entry is on top must report 1"
    );

    // Pop it: the entry beneath (flags 5, set with `=`) is active again.
    h.feed(b"\x1b[<u");
    assert_eq!(
        h.live_flags(),
        5,
        "after ESC[=5u ESC[>1u ESC[<u the live key-encoding flags must be back \
         to 5 (kitty keeps 5); got {} (mode bits 0x{:x})",
        h.live_flags(),
        h.mode_bits()
    );
    assert_eq!(
        h.query_flags_reply(),
        reply_for(5),
        "ESC[?u after the pop must report 5"
    );
    assert!(h.fatals().is_empty(), "VT panicked: {:?}", h.fatals());
}

#[test]
fn set_modifies_the_top_entry_and_leaves_the_entry_below_alone() {
    let h = Harness::new();

    // Push flags 1, then change the top entry to 3 with `=`.
    h.feed(b"\x1b[>1u\x1b[=3u");
    assert_eq!(
        h.live_flags(),
        3,
        "precondition: ESC[>1u ESC[=3u must leave live flags 3 (mode bits 0x{:x})",
        h.mode_bits()
    );
    assert_eq!(
        h.query_flags_reply(),
        reply_for(3),
        "ESC[?u after ESC[>1u ESC[=3u must report the modified top entry (3), \
         not the value it was pushed with (1); live flags are {}",
        h.live_flags()
    );

    // Pop the (modified) entry: the base entry was never touched by `=`, so
    // the terminal is back at flags 0.
    h.feed(b"\x1b[<u");
    assert_eq!(
        h.live_flags(),
        0,
        "after popping the modified entry the base flags (0) must be active \
         (mode bits 0x{:x})",
        h.mode_bits()
    );
    assert_eq!(
        h.query_flags_reply(),
        reply_for(0),
        "ESC[?u after popping the only pushed entry must report 0"
    );
    assert!(h.fatals().is_empty(), "VT panicked: {:?}", h.fatals());
}

// ---------------------------------------------------------------------------
// 3. A round trip through the alternate screen must preserve `=` flags.
// ---------------------------------------------------------------------------

#[test]
fn flags_set_with_equals_survive_an_alt_screen_round_trip() {
    let h = Harness::new();

    h.feed(b"\x1b[=5u");
    assert_eq!(
        h.live_flags(),
        5,
        "precondition: ESC[=5u must light flags 5 (mode bits 0x{:x})",
        h.mode_bits()
    );

    // Enter the alternate screen and prove we really are on it, so the
    // return trip below is a real swap and not a no-op.
    h.feed(b"\x1b[?1049h");
    assert!(
        h.mode_bits() & bb_mode::ALT_SCREEN != 0,
        "ESC[?1049h did not enter the alternate screen (mode bits 0x{:x})",
        h.mode_bits()
    );

    // Back to the main screen.
    h.feed(b"\x1b[?1049l");
    assert_eq!(
        h.mode_bits() & bb_mode::ALT_SCREEN,
        0,
        "ESC[?1049l did not leave the alternate screen (mode bits 0x{:x})",
        h.mode_bits()
    );

    assert_eq!(
        h.live_flags(),
        5,
        "after ESC[=5u ESC[?1049h ESC[?1049l the live key-encoding flags must \
         still be 5 (kitty keeps 5); got {} (mode bits 0x{:x})",
        h.live_flags(),
        h.mode_bits()
    );
    assert_eq!(
        h.query_flags_reply(),
        reply_for(5),
        "ESC[?u after the alt-screen round trip must report 5"
    );
    assert!(h.fatals().is_empty(), "VT panicked: {:?}", h.fatals());
}

// ---------------------------------------------------------------------------
// 4. The bit-wise modes (2 = set bits, 3 = reset bits) edit the same entry.
// ---------------------------------------------------------------------------

#[test]
fn bitwise_set_and_reset_modes_are_visible_to_query_and_survive_push_pop() {
    let h = Harness::new();

    // Start from 5 (1|4), then OR in 2 (mode 2): 5 | 2 = 7.
    h.feed(b"\x1b[=5u\x1b[=2;2u");
    assert_eq!(
        h.live_flags(),
        7,
        "precondition: ESC[=5u ESC[=2;2u must leave live flags 7 (mode bits 0x{:x})",
        h.mode_bits()
    );
    assert_eq!(
        h.query_flags_reply(),
        reply_for(7),
        "ESC[?u after ESC[=5u ESC[=2;2u must report 7; live flags are {}",
        h.live_flags()
    );

    // Clear bit 1 (mode 3): 7 & !1 = 6.
    h.feed(b"\x1b[=1;3u");
    assert_eq!(
        h.live_flags(),
        6,
        "precondition: ESC[=1;3u must clear bit 1 leaving live flags 6 (mode bits 0x{:x})",
        h.mode_bits()
    );
    assert_eq!(
        h.query_flags_reply(),
        reply_for(6),
        "ESC[?u after ESC[=1;3u must report 6; live flags are {}",
        h.live_flags()
    );

    // And the edited value is what a push/pop returns to.
    h.feed(b"\x1b[>1u\x1b[<u");
    assert_eq!(
        h.live_flags(),
        6,
        "after ESC[>1u ESC[<u the flags edited with modes 2/3 must be back to 6; \
         got {} (mode bits 0x{:x})",
        h.live_flags(),
        h.mode_bits()
    );
    assert_eq!(
        h.query_flags_reply(),
        reply_for(6),
        "ESC[?u after the push/pop must report 6"
    );
    assert!(h.fatals().is_empty(), "VT panicked: {:?}", h.fatals());
}
