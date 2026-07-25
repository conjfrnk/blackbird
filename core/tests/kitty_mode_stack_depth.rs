//! Depth-cap regression tests for the kitty keyboard-mode stack.
//!
//! A TUI enables the kitty keyboard protocol by pushing an entry onto the
//! terminal's keyboard-mode stack with `CSI > {flags} u`, pops with
//! `CSI < {n} u`, and asks which mode is active with `CSI ? u` (the terminal
//! answers `CSI ? {flags} u` back down the PTY). `kitty_keyboard: true` is set
//! in `bb_term_new`'s `Config`, so every one of these paths is live in the
//! shipping app — Claude Code, nvim 0.10+ and WezTerm-aware shells all drive
//! them at startup.
//!
//! alacritty bounds the stack at `KEYBOARD_MODE_STACK_MAX_DEPTH` (4096, aliased
//! to `TITLE_STACK_MAX_DEPTH`) so a program that only ever pushes can't retain
//! unbounded memory. These tests pin the two properties that cap must have:
//!
//!   * pushing past the cap must never take the VT down, and must not eat the
//!     *title* stack — a separate, unrelated stack that `CSI 22 t` / `CSI 23 t`
//!     own; and
//!   * the cap must actually bound the keyboard-mode stack, so popping the
//!     cap's worth of entries returns the reported mode to the base state.
//!
//! Everything here goes through the public FFI (`bb_term_new`,
//! `bb_term_input`, `bb_term_set_event_cb`, `bb_term_text_range`,
//! `bb_term_free`) — the core exposes no stack-depth accessor, so depth is
//! observed indirectly through the `CSI ? u` reply that alacritty writes back
//! to the PTY as a `BBEventKind::PtyWrite` event.
//!
//! ## Why the oracles look the way they do
//!
//! `bb_term_input` routes its body through `guard_with_term`, which
//! `catch_unwind`s a core panic and converts it into a `BBEventKind::Fatal`
//! event instead of unwinding across the C boundary. A test that merely feeds
//! bytes and returns therefore passes even when the VT panicked mid-chunk. Two
//! oracles are used instead, both of which can only hold when no panic
//! occurred:
//!
//!   1. the registered callback latches every `Fatal` event, and
//!   2. a printable marker is appended to the SAME `bb_term_input` chunk as the
//!      overflowing pushes and read back out of the grid — a panic aborts
//!      `Processor::advance` for the remainder of that chunk, so the marker
//!      never reaches the grid.
//!
//! Cost: the largest payload built here is 5000 five-byte escapes (~25 KB) fed
//! into an 80x24 grid with 100 lines of scrollback. Nothing allocates at grid
//! scale.

use std::os::raw::c_void;
use std::sync::{Arc, Mutex};

use blackbird_core as bc;

const COLS: u16 = 80;
const ROWS: u16 = 24;
const SCROLLBACK: u32 = 100;

/// alacritty's `KEYBOARD_MODE_STACK_MAX_DEPTH` (`term/mod.rs`), which is
/// defined as `TITLE_STACK_MAX_DEPTH`. Not exported by the crate, so it is
/// mirrored here; if upstream ever changes it these tests fail loudly rather
/// than silently stopping at the wrong depth.
const KEYBOARD_MODE_STACK_MAX_DEPTH: usize = 4096;

/// Every event kind this file cares about, in arrival order.
#[derive(Default)]
struct Captured {
    /// Bytes the terminal wants written back to the shell — the `CSI ? u`
    /// replies live here.
    pty_writes: Vec<Vec<u8>>,
    /// OSC 2 / `pop_title` title changes, decoded lossily.
    titles: Vec<String>,
    /// Panic messages surfaced by `guard_with_term`'s `catch_unwind`. MUST stay
    /// empty in every test here.
    fatals: Vec<String>,
}

unsafe extern "C" fn capture_cb(ev: bc::BBEvent, ctx: *mut c_void) {
    let cap = &*(ctx as *const Mutex<Captured>);
    // The header contract is `payload == NULL <=> len == 0`; honour both halves
    // so `from_raw_parts` never sees a null pointer.
    let bytes: &[u8] = if ev.payload.is_null() || ev.len == 0 {
        &[]
    } else {
        std::slice::from_raw_parts(ev.payload, ev.len)
    };
    let mut guard = cap.lock().unwrap();
    match ev.kind {
        bc::BBEventKind::PtyWrite => guard.pty_writes.push(bytes.to_vec()),
        bc::BBEventKind::Title => guard
            .titles
            .push(String::from_utf8_lossy(bytes).into_owned()),
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
    /// The `Arc` clone handed to the C callback as its `ctx`. Reclaimed in
    /// `Drop` so the refcount balances.
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

    /// Read one whole grid row back as text, trailing blanks trimmed.
    ///
    /// This is the load-bearing half of the no-panic oracle: it observes what
    /// actually reached the grid, not merely that the FFI call returned.
    fn row_text(&self, row: i32) -> String {
        unsafe {
            let raw = bc::bb_term_text_range(self.term, row, 0, row, COLS - 1, 0);
            assert!(
                !raw.is_null(),
                "bb_term_text_range returned null (row {row})"
            );
            let bytes: &[u8] = if (*raw).len == 0 || (*raw).bytes.is_null() {
                &[]
            } else {
                std::slice::from_raw_parts((*raw).bytes, (*raw).len)
            };
            let out = String::from_utf8_lossy(bytes).trim_end().to_string();
            bc::bb_string_release(raw);
            out
        }
    }

    fn pty_writes(&self) -> Vec<Vec<u8>> {
        self.cap.lock().unwrap().pty_writes.clone()
    }

    fn titles(&self) -> Vec<String> {
        self.cap.lock().unwrap().titles.clone()
    }

    fn fatals(&self) -> Vec<String> {
        self.cap.lock().unwrap().fatals.clone()
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

/// `n` copies of `CSI > 1 u` — push "disambiguate escape codes" onto the
/// keyboard-mode stack.
fn pushes(n: usize) -> Vec<u8> {
    let seq = b"\x1b[>1u";
    let mut out = Vec::with_capacity(n * seq.len());
    for _ in 0..n {
        out.extend_from_slice(seq);
    }
    out
}

// ---------------------------------------------------------------------------
// 1. Overflowing the stack must not take the VT down.
// ---------------------------------------------------------------------------

#[test]
fn overflowing_the_keyboard_mode_stack_does_not_kill_the_vt() {
    // Comfortably past the 4096 cap. At 5 bytes per escape this is ~25 KB.
    const PUSH_COUNT: usize = 5000;
    // Printable payload appended to the SAME chunk as the pushes. If the depth
    // guard panics, `Processor::advance` unwinds and every byte after the
    // offending push — including this marker — is discarded, so its presence
    // in the grid is a direct "the whole chunk was processed" witness. 16 ASCII
    // columns, well inside the 80-column grid, so it can't wrap.
    const MARKER: &str = "KBSTACK-SURVIVED";

    let h = Harness::new();

    let mut chunk = pushes(PUSH_COUNT);
    chunk.extend_from_slice(MARKER.as_bytes());
    h.feed(&chunk);

    // Oracle A: the FFI's catch_unwind reports a swallowed panic as Fatal.
    assert!(
        h.fatals().is_empty(),
        "pushing {PUSH_COUNT} kitty keyboard modes panicked the VT: {:?}",
        h.fatals()
    );
    // Oracle B: the rest of the chunk really was parsed.
    assert_eq!(
        h.row_text(0),
        MARKER,
        "input following {PUSH_COUNT} keyboard-mode pushes was dropped; \
         the depth guard aborted the chunk"
    );

    // ...and the session keeps working for input that arrives afterwards.
    h.feed(b"\r\nSTILL-ALIVE");
    assert_eq!(
        h.row_text(1),
        "STILL-ALIVE",
        "terminal stopped accepting input after the keyboard-mode overflow"
    );
    assert!(
        h.fatals().is_empty(),
        "post-overflow input panicked the VT: {:?}",
        h.fatals()
    );
}

// ---------------------------------------------------------------------------
// 2. The cap must actually bound the stack.
// ---------------------------------------------------------------------------

#[test]
fn depth_cap_bounds_the_keyboard_mode_stack() {
    // Number of entries parked on the *title* stack before the overflow.
    //
    // This is deliberate, not incidental. The depth guard is the code under
    // test, and one way to get it wrong is to trim the wrong stack; when it
    // trims `title_stack` instead, an EMPTY title stack turns the guard into a
    // panic and the run never reaches the assertion below — which would make
    // this test a duplicate of the no-panic test rather than a statement about
    // the bound. Pre-loading the title stack with more entries than the
    // overflow needs keeps the buggy build alive all the way to the assertion,
    // so what is measured here really is the keyboard-mode stack's depth.
    const TITLE_RESERVE: usize = 256;
    // How far past the cap we push. Must stay < TITLE_RESERVE (see above).
    const OVERFLOW_BY: usize = 128;
    const PUSH_COUNT: usize = KEYBOARD_MODE_STACK_MAX_DEPTH + OVERFLOW_BY;

    let h = Harness::new();

    // `CSI 22 t` = XTPUSHTITLE. The title is unset, so each entry is a cheap
    // `None`; 256 of them cost nothing.
    let mut chunk = Vec::new();
    for _ in 0..TITLE_RESERVE {
        chunk.extend_from_slice(b"\x1b[22t");
    }
    chunk.extend_from_slice(&pushes(PUSH_COUNT));
    h.feed(&chunk);

    assert!(
        h.fatals().is_empty(),
        "overflowing the keyboard-mode stack panicked: {:?}",
        h.fatals()
    );
    assert!(
        h.pty_writes().is_empty(),
        "pushes and title-stack pushes must not write to the PTY; got {:?}",
        h.pty_writes()
    );

    // Pop exactly the cap's worth of entries, then ask which mode is active.
    // `CSI ? u` makes the terminal write `CSI ? {flags} u` back to the PTY,
    // which surfaces as a PtyWrite event — the only observation channel the
    // FFI offers for the stack's depth.
    //
    // A correctly-capped stack holds at most KEYBOARD_MODE_STACK_MAX_DEPTH
    // entries no matter how many pushes arrived, so this drains it completely
    // and the reported mode falls back to NO_MODE (`ESC [ ? 0 u`). An
    // unbounded stack still has OVERFLOW_BY flag-1 entries left and reports
    // `ESC [ ? 1 u`.
    h.feed(format!("\x1b[<{KEYBOARD_MODE_STACK_MAX_DEPTH}u\x1b[?u").as_bytes());

    assert_eq!(
        h.pty_writes(),
        vec![b"\x1b[?0u".to_vec()],
        "after {PUSH_COUNT} pushes and {KEYBOARD_MODE_STACK_MAX_DEPTH} pops the stack must be \
         empty — the cap did not bound it to {KEYBOARD_MODE_STACK_MAX_DEPTH} entries"
    );
    assert!(
        h.fatals().is_empty(),
        "pop / report panicked: {:?}",
        h.fatals()
    );
}

// ---------------------------------------------------------------------------
// 3. The title stack is a different stack.
// ---------------------------------------------------------------------------

#[test]
fn keyboard_mode_overflow_does_not_consume_the_title_stack() {
    const SENTINEL: &str = "bb-sentinel-title";
    const SCRATCH: &str = "bb-scratch-title";
    // Exactly one push past the cap: the depth guard trims exactly once, so a
    // guard that trims the title stack removes exactly the single sentinel
    // entry — and, having emptied it, does not go on to panic. That keeps this
    // test's failure mode "wrong title", not "crash".
    const PUSH_COUNT: usize = KEYBOARD_MODE_STACK_MAX_DEPTH + 1;

    let h = Harness::new();

    // Set a title, save it with XTPUSHTITLE, then overwrite the live title.
    h.feed(format!("\x1b]2;{SENTINEL}\x07").as_bytes());
    h.feed(b"\x1b[22t");
    h.feed(format!("\x1b]2;{SCRATCH}\x07").as_bytes());

    h.feed(&pushes(PUSH_COUNT));
    assert!(
        h.fatals().is_empty(),
        "overflowing the keyboard-mode stack panicked: {:?}",
        h.fatals()
    );

    // `CSI 23 t` = XTPOPTITLE. It restores the saved title, which fires a
    // Title event; an empty title stack is a silent no-op, so the absence of a
    // third Title event is exactly the "the overflow ate my saved title"
    // symptom.
    h.feed(b"\x1b[23t");

    assert_eq!(
        h.titles(),
        vec![
            SENTINEL.to_string(),
            SCRATCH.to_string(),
            SENTINEL.to_string()
        ],
        "XTPOPTITLE after a keyboard-mode-stack overflow must restore the pushed title"
    );
}

// ---------------------------------------------------------------------------
// 4. The ordinary path still works.
// ---------------------------------------------------------------------------

#[test]
fn small_push_pop_sequences_round_trip_the_reported_mode() {
    // Query, push flag 1, query, push flags 3 (disambiguate | report event
    // types), query, pop one, query, pop one, query. Five replies, comfortably
    // under the 32/sec PtyWrite reply cap.
    let h = Harness::new();
    h.feed(b"\x1b[?u\x1b[>1u\x1b[?u\x1b[>3u\x1b[?u\x1b[<1u\x1b[?u\x1b[<1u\x1b[?u");

    assert_eq!(
        h.pty_writes(),
        vec![
            b"\x1b[?0u".to_vec(),
            b"\x1b[?1u".to_vec(),
            b"\x1b[?3u".to_vec(),
            b"\x1b[?1u".to_vec(),
            b"\x1b[?0u".to_vec(),
        ],
        "push/pop must report the mode on top of the stack at each step"
    );
    assert!(
        h.fatals().is_empty(),
        "ordinary push/pop panicked: {:?}",
        h.fatals()
    );
}
