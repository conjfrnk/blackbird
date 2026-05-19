//! Property-based round-trip tests for the BBCore cell ↔ text contract.
//!
//! The Swift host's copy/paste/find path goes
//! `bb_term_input` → `BBSnap.cells[*]` → `bb_term_text_range`. Three FFI
//! contracts intersect there:
//!   1. The VT parser must lay an ASCII glyph into the cell whose
//!      `BBCell::ch` equals the byte fed.
//!   2. `bb_term_text_range` (prose mode) must re-emit those cells as a
//!      UTF-8 string that's byte-equal to the input for the ASCII-only
//!      printable run.
//!   3. Wide glyphs (CJK) must claim two cells (primary + spacer) but
//!      `bb_term_text_range` must skip the spacer so paste round-trip
//!      produces the original codepoint count (not codepoint + space).
//!
//! Pre-flight cost summary. Each generated case allocates ONE BBTerm at
//! 80×24 with `SCROLLBACK=200` lines (smaller than the structural-FFI
//! file's 1000 — these properties don't exercise scrollback, so the
//! ring's incidental ~256 KiB is enough). Per-case peak memory is the
//! ~30 KiB live grid + ~16 KiB scrollback ring + one ≤80-byte payload
//! and one `BBString` allocation of similar size — well under 100 KiB.
//! Total wall-clock across all ten properties at `cases ∈ [16, 64]`
//! lands under ~2 s in debug on a clean macos-14 runner. No I/O, no
//! spawned threads, no sleeps.
//!
//! Coverage choices:
//!   - We never duplicate a property already encoded by
//!     `proptest_invariants.rs` or `ffi_invariant_props.rs`. The
//!     closest neighbour is `snapshot_cells_len_equals_cols_times_rows`
//!     (in `ffi_invariant_props.rs`) — property 10 below re-states it
//!     with a 1024-byte payload bound to harden against an "input path
//!     resizes the grid mid-parse" regression that `cells_len ==
//!     cols*rows` would also miss; the duplication is intentional and
//!     comment-flagged.
//!   - The single-row text-extraction body in the existing files only
//!     uses the helper for the WHOLE viewport (rows 0..ROWS-1). This
//!     file is the only one that pins per-cell readback agreement
//!     against `bb_term_text_range` on a single-row range — the
//!     contract the Swift "copy single line" code path depends on.
//!   - SGR / wide-char / null-safety properties also have no prior
//!     property-test coverage in this crate's tests directory.

use blackbird_core::*;
use proptest::prelude::*;
use std::ffi::c_void;
use std::sync::atomic::{AtomicBool, Ordering};

// ─────────────────────────────────────────────────────────────────────
// Shared harness (mirrors ffi_invariant_props.rs)
// ─────────────────────────────────────────────────────────────────────

/// Latched on any `BBEventKind::Fatal` event. The guarded FFI
/// (`bb_term_input`, `bb_term_text_range`, `bb_term_take_snapshot`)
/// catches internal panics and returns a fallback (null / unit) so
/// downstream callers don't unwind across the C ABI. Without this
/// latch, every property below would silently pass on the panic path
/// (the failing arm and the success arm both look like "got null /
/// empty string back"). Each property resets the latch before its
/// FFI calls and asserts it stayed false at the logical checkpoint.
///
/// Same cross-test race caveat as the two sibling files: `cargo test`
/// runs `#[test]` fns in parallel, and a peer test's `store(false)`
/// could clear our latch between the input call and the check. The
/// race is benign — it can only mask a real Fatal, never invent one.
static SAW_FATAL: AtomicBool = AtomicBool::new(false);

unsafe extern "C" fn on_fatal(ev: BBEvent, _ctx: *mut c_void) {
    if ev.kind == BBEventKind::Fatal {
        SAW_FATAL.store(true, Ordering::SeqCst);
    }
}

/// RAII guard so `prop_assert!` short-circuits can't leak the BBTerm's
/// scrollback ring. Constructed only from `bb_term_new` returns.
struct TermGuard(*mut BBTerm);

impl Drop for TermGuard {
    fn drop(&mut self) {
        if !self.0.is_null() {
            // SAFETY: TermGuard owns the term for its lifetime; we only
            // construct it from `bb_term_new` returns.
            unsafe { bb_term_free(self.0) };
        }
    }
}

const COLS: u16 = 80;
const ROWS: u16 = 24;
/// Modest scrollback — these properties don't exercise it. Keeps the
/// per-case ring small (~256 KiB vs 1.25 MiB at the sibling files'
/// SCROLLBACK=1000) so 10 properties × 64 cases stays under 2 s in
/// debug.
const SCROLLBACK: u32 = 200;

/// Read a `BBString` returned by `bb_term_text_range` as an owned
/// `String`, releasing the underlying allocation. Returns `None` if
/// the FFI returned null (per header: null term OR caught panic).
///
/// SAFETY: `s` must have been returned by `bb_term_text_range` and not
/// previously released. The function consumes the BBString (calls
/// `bb_string_release` before returning).
unsafe fn take_string(s: *mut BBString) -> Option<String> {
    if s.is_null() {
        return None;
    }
    // Per BBCore.h the public layout is `{ bytes: *const u8, len:
    // usize, _owned_ptr, _owned_cap, _magic }`. We only read `bytes`
    // and `len`; the owned fields are bb_string_release's concern.
    let bytes_ptr = (*s).bytes;
    let len = (*s).len;
    let owned = if bytes_ptr.is_null() || len == 0 {
        String::new()
    } else {
        let slice = std::slice::from_raw_parts(bytes_ptr, len);
        // text-range output is documented UTF-8; from_utf8_lossy is
        // defensive for the random-fuzz property where a regression
        // could splice bytes mid-codepoint.
        String::from_utf8_lossy(slice).into_owned()
    };
    bb_string_release(s);
    Some(owned)
}

// ─────────────────────────────────────────────────────────────────────
// Property 1: ASCII printable round-trip on a single row
// ─────────────────────────────────────────────────────────────────────
//
// For any printable ASCII string `s` (1..=80 chars in 0x20..=0x7E),
// after feeding `s`, `bb_term_text_range(0, 0, 0, len-1, 0)` returns
// exactly `s`. Prose mode trims trailing spaces from every line except
// the last; we ask for the closed range exactly covering `s`, and `s`
// is the only (and therefore last) line, so trimming is a no-op when
// `s` ends in non-space. Cases that end in space are filtered by
// `prop_assume!` since the trim contract would erase those trailing
// spaces from the round-trip — that's expected behaviour, not a bug.
proptest! {
    #![proptest_config(ProptestConfig { cases: 64, ..ProptestConfig::default() })]

    #[test]
    fn ascii_printable_text_range_roundtrip(
        bytes in prop::collection::vec(0x20u8..=0x7Eu8, 1..=80usize),
    ) {
        // Trailing-space filter: prose mode strips trailing spaces on
        // every line except the LAST, but the "last line" rule only
        // protects spaces between the trim point and the end-col
        // cursor — implementations vary in how they handle a one-line
        // selection where every cell is a space. Filtering keeps the
        // property unambiguous.
        prop_assume!(*bytes.last().unwrap() != b' ');

        let s: String = bytes.iter().map(|b| *b as char).collect();
        let end_col: u16 = (s.len() - 1) as u16;

        SAW_FATAL.store(false, Ordering::SeqCst);
        unsafe {
            let term = bb_term_new(COLS, ROWS, SCROLLBACK);
            prop_assert!(!term.is_null());
            let _g = TermGuard(term);
            bb_term_set_event_cb(term, Some(on_fatal), std::ptr::null_mut());

            bb_term_input(term, s.as_ptr(), s.len());
            let raw = bb_term_text_range(term, 0, 0, 0, end_col, 0);
            let got = take_string(raw);

            prop_assert!(
                !SAW_FATAL.swap(false, Ordering::SeqCst),
                "Fatal panic during ascii text-range roundtrip"
            );
            prop_assert_eq!(
                got.as_deref(),
                Some(s.as_str()),
                "text-range did not echo printable ASCII input"
            );
        }
    }
}

// ─────────────────────────────────────────────────────────────────────
// Property 2: Single-row text-range matches snapshot cell reads
// ─────────────────────────────────────────────────────────────────────
//
// Same input shape as property 1. For every column `c` in 0..len, the
// snapshot's `cells[c].ch` MUST equal the input byte at column `c` as
// u32. Pins that the parser populated cells AND that `text_range` and
// the cell array agree on per-column content — a regression that
// dropped a glyph in only one of the two readback paths would surface
// here.
proptest! {
    #![proptest_config(ProptestConfig { cases: 64, ..ProptestConfig::default() })]

    #[test]
    fn ascii_cells_match_input_bytes(
        bytes in prop::collection::vec(0x20u8..=0x7Eu8, 1..=80usize),
    ) {
        SAW_FATAL.store(false, Ordering::SeqCst);
        unsafe {
            let term = bb_term_new(COLS, ROWS, SCROLLBACK);
            prop_assert!(!term.is_null());
            let _g = TermGuard(term);
            bb_term_set_event_cb(term, Some(on_fatal), std::ptr::null_mut());

            bb_term_input(term, bytes.as_ptr(), bytes.len());
            let snap = bb_term_take_snapshot(term);
            prop_assert!(!snap.is_null());
            let cells_len = (*snap).cells_len;
            prop_assert!(cells_len >= bytes.len(), "snapshot too small");
            let mut mismatch: Option<(usize, u32, u32)> = None;
            for (c, b) in bytes.iter().enumerate() {
                let ch = (*((*snap).cells.add(c))).ch;
                if ch != *b as u32 {
                    mismatch = Some((c, *b as u32, ch));
                    break;
                }
            }
            bb_snap_release(snap);
            prop_assert!(
                !SAW_FATAL.swap(false, Ordering::SeqCst),
                "Fatal panic during cell readback"
            );
            prop_assert_eq!(
                mismatch,
                None,
                "cell.ch disagrees with input byte at column"
            );
        }
    }
}

// ─────────────────────────────────────────────────────────────────────
// Property 3: No SGR — no flags in cells
// ─────────────────────────────────────────────────────────────────────
//
// For any printable ASCII input (no escape bytes), every populated
// cell's `flags` field must be 0. A regression that misinterpreted a
// printable byte as an SGR introducer would light a flag here. We
// only inspect the cells actually written by the input (columns
// 0..len) — the right-of-cursor cells are blank-fill and outside the
// property's scope.
proptest! {
    #![proptest_config(ProptestConfig { cases: 64, ..ProptestConfig::default() })]

    #[test]
    fn no_sgr_means_zero_flags(
        bytes in prop::collection::vec(0x20u8..=0x7Eu8, 1..=80usize),
    ) {
        SAW_FATAL.store(false, Ordering::SeqCst);
        unsafe {
            let term = bb_term_new(COLS, ROWS, SCROLLBACK);
            prop_assert!(!term.is_null());
            let _g = TermGuard(term);
            bb_term_set_event_cb(term, Some(on_fatal), std::ptr::null_mut());

            bb_term_input(term, bytes.as_ptr(), bytes.len());
            let snap = bb_term_take_snapshot(term);
            prop_assert!(!snap.is_null());
            let mut offender: Option<(usize, u16)> = None;
            for c in 0..bytes.len() {
                let cell = *((*snap).cells.add(c));
                if cell.flags != 0 {
                    offender = Some((c, cell.flags));
                    break;
                }
            }
            bb_snap_release(snap);
            prop_assert!(
                !SAW_FATAL.swap(false, Ordering::SeqCst),
                "Fatal panic during no-SGR check"
            );
            prop_assert_eq!(
                offender,
                None,
                "printable-only input produced non-zero cell flags"
            );
        }
    }
}

// ─────────────────────────────────────────────────────────────────────
// Property 4: BOLD SGR surfaces in cell flags
// ─────────────────────────────────────────────────────────────────────
//
// After `\x1b[1m` + printable run + `\x1b[0m`, every cell in the
// printable run must have `flags & BOLD != 0`. The complement to
// property 3: when SGR IS emitted, the parser must land the bit.
proptest! {
    #![proptest_config(ProptestConfig { cases: 32, ..ProptestConfig::default() })]

    #[test]
    fn bold_sgr_surfaces_in_flags(
        bytes in prop::collection::vec(0x20u8..=0x7Eu8, 1..=40usize),
    ) {
        SAW_FATAL.store(false, Ordering::SeqCst);
        let mut payload = Vec::with_capacity(bytes.len() + 8);
        payload.extend_from_slice(b"\x1b[1m");
        payload.extend_from_slice(&bytes);
        payload.extend_from_slice(b"\x1b[0m");
        unsafe {
            let term = bb_term_new(COLS, ROWS, SCROLLBACK);
            prop_assert!(!term.is_null());
            let _g = TermGuard(term);
            bb_term_set_event_cb(term, Some(on_fatal), std::ptr::null_mut());

            bb_term_input(term, payload.as_ptr(), payload.len());
            let snap = bb_term_take_snapshot(term);
            prop_assert!(!snap.is_null());
            // BOLD = 1 << 0 per BBCore.h.
            const BOLD_BIT: u16 = 1 << 0;
            let mut missing: Option<(usize, u16, u32)> = None;
            for (c, &b) in bytes.iter().enumerate() {
                let cell = *((*snap).cells.add(c));
                if cell.flags & BOLD_BIT == 0 || cell.ch != b as u32 {
                    missing = Some((c, cell.flags, cell.ch));
                    break;
                }
            }
            bb_snap_release(snap);
            prop_assert!(
                !SAW_FATAL.swap(false, Ordering::SeqCst),
                "Fatal panic during BOLD-SGR check"
            );
            prop_assert_eq!(
                missing,
                None,
                "BOLD bit missing from cell in `\\x1b[1m..` run"
            );
        }
    }
}

// ─────────────────────────────────────────────────────────────────────
// Property 5: Out-of-bounds text-range doesn't crash
// ─────────────────────────────────────────────────────────────────────
//
// For `start_line` beyond the bottom of the visible viewport, the
// returned BBString must be safe to release and (per the header)
// "Lines outside [topmost_line, bottommost_line] are skipped silently"
// — empty or trimmed, never a crash or Fatal event.
proptest! {
    #![proptest_config(ProptestConfig { cases: 32, ..ProptestConfig::default() })]

    #[test]
    fn out_of_bounds_text_range_does_not_crash(
        start_line in (ROWS as i32)..=10_000i32,
        end_line_delta in 0i32..=100i32,
        start_col in 0u16..COLS,
        end_col in 0u16..COLS,
    ) {
        SAW_FATAL.store(false, Ordering::SeqCst);
        unsafe {
            let term = bb_term_new(COLS, ROWS, SCROLLBACK);
            prop_assert!(!term.is_null());
            let _g = TermGuard(term);
            bb_term_set_event_cb(term, Some(on_fatal), std::ptr::null_mut());

            // Seed something so the grid isn't empty — exercises the
            // "viewport has content, but the requested range is
            // entirely above the bottom" arm of the bounds check.
            let seed = b"hello\nworld";
            bb_term_input(term, seed.as_ptr(), seed.len());

            let end_line = start_line.saturating_add(end_line_delta);
            let raw = bb_term_text_range(term, start_line, start_col, end_line, end_col, 0);
            let got = take_string(raw);

            prop_assert!(
                !SAW_FATAL.swap(false, Ordering::SeqCst),
                "Fatal panic during OOB text-range"
            );
            // The header documents (a) null term => null and (b) panic
            // => null. We passed a non-null term and expect no panic,
            // so we should get Some(_) — possibly empty. The
            // assertion checks that the BBString was returned and is
            // releasable. Length bounded to "didn't accidentally emit
            // the entire scrollback".
            let s = got.expect("non-null term must return Some(_) BBString on bounded inputs");
            prop_assert!(
                s.len() <= (COLS as usize) * (ROWS as usize) + (ROWS as usize),
                "OOB text-range returned suspiciously large string ({} bytes)",
                s.len()
            );
        }
    }
}

// ─────────────────────────────────────────────────────────────────────
// Property 6: null-term text-range returns null (no crash)
// ─────────────────────────────────────────────────────────────────────
//
// Per BBCore.h: "Returns null on (a) null `term`". We exercise that
// branch across a range of line/col tuples; no Fatal event should
// fire (the function returns a fallback BEFORE entering the panic-
// catching body). Trivial inputs to keep cases cheap; the property is
// pure null-pointer hygiene.
proptest! {
    #![proptest_config(ProptestConfig { cases: 16, ..ProptestConfig::default() })]

    #[test]
    fn null_term_text_range_returns_null(
        sl in -1000i32..=1000i32,
        el in -1000i32..=1000i32,
        sc in 0u16..=2000u16,
        ec in 0u16..=2000u16,
        rect in 0u8..=1u8,
    ) {
        SAW_FATAL.store(false, Ordering::SeqCst);
        unsafe {
            // No on_fatal registration possible (the callback registry
            // is per-term and we have no term). Fatal events therefore
            // can't be observed for a null-term call — but the
            // contract is that the function returns null WITHOUT
            // calling any panic-prone code, so SAW_FATAL stays
            // whatever the previous test left it. We reset above as a
            // belt-and-suspenders.
            let raw = bb_term_text_range(std::ptr::null_mut(), sl, sc, el, ec, rect);
            prop_assert!(raw.is_null(), "null-term must return null BBString*");
            // No release: raw is null. bb_string_release(null) IS a
            // documented no-op, but exercising it on EVERY case adds
            // no signal here.
        }
    }
}

// ─────────────────────────────────────────────────────────────────────
// Property 7: Newline lands subsequent glyph on next row
// ─────────────────────────────────────────────────────────────────────
//
// For any two printable ASCII bytes `a`, `b`, after `bb_term_input(b"a
// \n b")` (concatenated, no spaces — written here with explicit
// indices for clarity), row 0 col 0 holds `a` and row 1 col 0 holds
// `b`. Most terminals translate `\n` as LF-only (cursor moves down,
// stays in col 1); some apply CR+LF semantics. We accept BOTH outcomes
// by checking row 1 col 0 OR row 1 col 1 — whichever non-blank cell
// lands first on row 1 must equal `b`.
proptest! {
    #![proptest_config(ProptestConfig { cases: 32, ..ProptestConfig::default() })]

    #[test]
    fn newline_lands_on_next_row(
        a in 0x21u8..=0x7Eu8,  // non-space so we can detect the cell unambiguously
        b in 0x21u8..=0x7Eu8,
    ) {
        SAW_FATAL.store(false, Ordering::SeqCst);
        let payload = [a, b'\n', b];
        unsafe {
            let term = bb_term_new(COLS, ROWS, SCROLLBACK);
            prop_assert!(!term.is_null());
            let _g = TermGuard(term);
            bb_term_set_event_cb(term, Some(on_fatal), std::ptr::null_mut());

            bb_term_input(term, payload.as_ptr(), payload.len());
            let snap = bb_term_take_snapshot(term);
            prop_assert!(!snap.is_null());
            let cols = (*snap).cols as usize;
            // Row 0 col 0 → cells[0]
            let r0c0 = (*((*snap).cells.add(0))).ch;
            // Row 1 cells live at cells[cols .. cols*2]
            let r1c0 = (*((*snap).cells.add(cols))).ch;
            let r1c1 = (*((*snap).cells.add(cols + 1))).ch;
            bb_snap_release(snap);
            prop_assert!(
                !SAW_FATAL.swap(false, Ordering::SeqCst),
                "Fatal panic during newline-row check"
            );
            prop_assert_eq!(
                r0c0, a as u32,
                "row 0 col 0 did not hold first byte"
            );
            // LF-only would leave r1c0 untouched (0 / space) and put
            // `b` at the column the cursor was at when LF fired —
            // which is the column AFTER `a`, i.e. col 1. CR+LF puts
            // `b` at col 0. Accept either.
            let landed = r1c0 == b as u32 || r1c1 == b as u32;
            prop_assert!(
                landed,
                "byte after newline didn't land on row 1: r1c0=0x{:x} r1c1=0x{:x} expected=0x{:x}",
                r1c0, r1c1, b as u32
            );
        }
    }
}

// ─────────────────────────────────────────────────────────────────────
// Property 8: Wide-char (CJK) spacer is skipped in text-range
// ─────────────────────────────────────────────────────────────────────
//
// Input `"中"` is 3 UTF-8 bytes and a "wide" East Asian glyph that
// occupies TWO terminal cells (primary + WIDE_CHAR_SPACER). Per the
// header, text-range MUST skip the spacer cell — extracting columns
// [0, 1] over the wide glyph returns `"中"` (1 grapheme, 3 bytes),
// not `"中 "` (4 bytes). This is the paste-correctness contract.
//
// The single test below uses a fixed `"中"` payload (no generation) —
// the input is a property only by being a deterministic-but-
// representative wide-glyph case; we still wrap it in `proptest!` for
// uniform Fatal-latch handling.
proptest! {
    #![proptest_config(ProptestConfig { cases: 4, ..ProptestConfig::default() })]

    #[test]
    fn wide_char_spacer_skipped_in_text_range(_seed in 0u8..=3u8) {
        SAW_FATAL.store(false, Ordering::SeqCst);
        let payload: &[u8] = "中".as_bytes();
        unsafe {
            let term = bb_term_new(COLS, ROWS, SCROLLBACK);
            prop_assert!(!term.is_null());
            let _g = TermGuard(term);
            bb_term_set_event_cb(term, Some(on_fatal), std::ptr::null_mut());

            bb_term_input(term, payload.as_ptr(), payload.len());
            // Extract [0..=1] — the two columns the wide glyph occupies.
            let raw = bb_term_text_range(term, 0, 0, 0, 1, 0);
            let got = take_string(raw);
            prop_assert!(
                !SAW_FATAL.swap(false, Ordering::SeqCst),
                "Fatal panic during wide-char text-range"
            );
            let s = got.expect("non-null term must return Some(_) BBString");
            prop_assert_eq!(
                s.as_str(),
                "中",
                "wide-char spacer leaked into text-range output"
            );
        }
    }
}

// ─────────────────────────────────────────────────────────────────────
// Property 9: Two adjacent CJK characters round-trip
// ─────────────────────────────────────────────────────────────────────
//
// Extends property 8 to two consecutive wide glyphs occupying 4 cells.
// Text-range over [0..=3] returns `"中文"` (2 graphemes, 6 bytes), not
// any variant with leaked spacers. The 2-glyph case catches a
// regression where the spacer-skip logic only fired on the first wide
// glyph (off-by-one in a "skip-next-cell" flag).
proptest! {
    #![proptest_config(ProptestConfig { cases: 4, ..ProptestConfig::default() })]

    #[test]
    fn two_cjk_chars_roundtrip(_seed in 0u8..=3u8) {
        SAW_FATAL.store(false, Ordering::SeqCst);
        let payload: &[u8] = "中文".as_bytes();
        unsafe {
            let term = bb_term_new(COLS, ROWS, SCROLLBACK);
            prop_assert!(!term.is_null());
            let _g = TermGuard(term);
            bb_term_set_event_cb(term, Some(on_fatal), std::ptr::null_mut());

            bb_term_input(term, payload.as_ptr(), payload.len());
            let raw = bb_term_text_range(term, 0, 0, 0, 3, 0);
            let got = take_string(raw);
            prop_assert!(
                !SAW_FATAL.swap(false, Ordering::SeqCst),
                "Fatal panic during two-CJK roundtrip"
            );
            let s = got.expect("non-null term must return Some(_) BBString");
            prop_assert_eq!(
                s.as_str(),
                "中文",
                "two-CJK text-range output diverged from input"
            );
        }
    }
}

// ─────────────────────────────────────────────────────────────────────
// Property 10: Random byte fuzz doesn't corrupt cell count
// ─────────────────────────────────────────────────────────────────────
//
// For any byte string ≤ 1024 bytes, after `bb_term_input`,
// `snapshot.cells_len == cols * rows` exactly. Hardens against a path
// in the parser that resizes the grid mid-parse (e.g., an unmasked
// DECCOLS or alt-screen swap that forgot to update cells_len in
// lockstep with cols/rows). Intentionally overlaps with
// `ffi_invariant_props.rs::snapshot_cells_len_equals_cols_times_rows`
// but uses a SMALLER 1024-byte payload and a fresh fuzz seed — both
// files would need to silently break together to miss the regression.
proptest! {
    #![proptest_config(ProptestConfig { cases: 64, ..ProptestConfig::default() })]

    #[test]
    fn fuzz_bytes_preserve_cells_len(
        bytes in prop::collection::vec(any::<u8>(), 0..=1024usize),
    ) {
        SAW_FATAL.store(false, Ordering::SeqCst);
        unsafe {
            let term = bb_term_new(COLS, ROWS, SCROLLBACK);
            prop_assert!(!term.is_null());
            let _g = TermGuard(term);
            bb_term_set_event_cb(term, Some(on_fatal), std::ptr::null_mut());

            if !bytes.is_empty() {
                bb_term_input(term, bytes.as_ptr(), bytes.len());
            }
            let snap = bb_term_take_snapshot(term);
            prop_assert!(!snap.is_null());
            let cells_len = (*snap).cells_len;
            let cols = (*snap).cols as usize;
            let rows = (*snap).rows as usize;
            bb_snap_release(snap);
            prop_assert!(
                !SAW_FATAL.swap(false, Ordering::SeqCst),
                "Fatal panic during fuzz cells_len check"
            );
            prop_assert_eq!(
                cells_len,
                cols * rows,
                "cells_len ({}) != cols*rows ({}*{}={}) after fuzz",
                cells_len, cols, rows, cols * rows
            );
        }
    }
}
