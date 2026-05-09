#![no_main]

use libfuzzer_sys::fuzz_target;
use std::sync::atomic::{AtomicBool, Ordering};

// Focused libFuzzer target for `bb_term_text_range`.
//
// Why a dedicated target: `fuzz_term_input.rs` already exercises
// `bb_term_text_range` as ONE tuple-from-input alongside the parser, the
// snapshot lifecycle, resize, scroll, and palette setters. libFuzzer's
// coverage feedback there is split across the union of all those code paths,
// so the row-range cliff at scrollback boundaries (`MAX_TEXT_RANGE_ROWS =
// 65_536` clamp at lib.rs:1697 / 3458, plus the i32::MIN/MAX saturating-add
// at 3459) is only sampled anecdotally.
//
// This target inverts the budget: a small, REALISTIC corpus is fed once
// before the fuzz body runs, and the fuzzer-controlled bytes drive ONLY the
// 4D coord space `(s_line: i32, e_line: i32, s_col: u16, e_col: u16, rect:
// u8)`. libFuzzer can therefore concentrate its coverage feedback on the
// text_range body — swap/inverse normalisation (lib.rs:3429), column-clamp
// against `last_col` (3433), the scrollback clamp at `topmost`/`bottommost`
// (3443), the row-cliff cap at `MAX_TEXT_RANGE_ROWS` (3458), and the
// rectangular vs single-line vs multi-line column-selection branch tree
// (3474..=3491).

static SAW_FATAL: AtomicBool = AtomicBool::new(false);

unsafe extern "C" fn on_event(ev: blackbird_core::BBEvent, _ctx: *mut std::ffi::c_void) {
    if ev.kind == blackbird_core::BBEventKind::Fatal {
        SAW_FATAL.store(true, Ordering::SeqCst);
    }
}

// Pre-fed corpus, ~4 KiB assembled from constant fragments. Stable across
// fuzz iterations so libFuzzer's coverage feedback is purely a function of
// the coord tuples it generates.
//
// Shape (in feed order):
//   1. SGR colour run + ASCII text                           (paints attrs)
//   2. OSC 8 hyperlink open / payload / close                (link cells)
//   3. CJK characters (wide-char + WIDE_CHAR_SPACER cells)   (3505..=3511)
//   4. Emoji (multi-codepoint clusters)
//   5. Alt-screen enter/exit (DECSET 1049)                   (grid swap)
//   6. Many CR/LF pairs to push lines into scrollback        (cliff feeder)
//   7. Repeat block N times until we cross ~4 KiB so the grid is densely
//      populated with mixed cell kinds across both screens and across the
//      visible/scrollback boundary.
//
// 4 KiB is a deliberate ceiling: enough rows to push the visible viewport
// into scrollback (so iter_start > topmost is reachable AND iter_end >
// bottommost is reachable), but small enough that pre-feed cost stays well
// under one fuzz iteration's budget.
const PREFED_BLOCK: &[u8] = concat!(
    // SGR colour + bold + ASCII payload — populates non-trivial cell flags.
    "\x1b[1;31mhello \x1b[32mworld \x1b[0m",
    // OSC 8 hyperlink (open id=1 url=https://example.com, text, close).
    "\x1b]8;id=1;https://example.com\x1b\\link-text\x1b]8;;\x1b\\",
    // Second OSC 8 with different id and longer URL — exercises link table
    // bookkeeping and `bb_snap_link_id_at` lookup paths under the populated
    // grid.
    "\x1b]8;id=2;https://blackbird-terminal.com/docs/text-range\x1b\\docs\x1b]8;;\x1b\\",
    // CJK — alacritty stores wide chars in a primary cell + spacer; the
    // text_range body skips spacers (lib.rs:3505..=3511) so we want them
    // present in the grid.
    "中文测试 ",
    // Emoji + ZWJ sequence.
    "👨‍💻🚀 ",
    // Alt-screen toggle: enter, write a line, exit. Forces grid swap so
    // the test_range coords cross both surfaces during the run.
    "\x1b[?1049hON-ALT\r\n\x1b[?1049l",
    // CR/LF pairs to push lines into scrollback. We need scrollback rows so
    // `iter_start > topmost` and `iter_end > bottommost` are both reachable
    // by negative i32 inputs from the fuzzer.
    "\r\nA\r\nB\r\nC\r\nD\r\nE\r\nF\r\nG\r\nH\r\nI\r\nJ\r\n",
)
.as_bytes();

/// Per-iter cap on text_range calls. With each tuple costing 13 bytes,
/// `data.len() / 13` already bounds it; we additionally cap at 64 so a
/// pathological large input doesn't burn one fuzz iter scanning a single
/// 1 MB blob — libFuzzer prefers many short iters.
const MAX_TEXT_RANGE_CALLS_PER_ITER: usize = 64;

/// Tuple stride: 4 (s_line) + 4 (e_line) + 2 (s_col) + 2 (e_col) + 1 (rect).
const TUPLE_STRIDE: usize = 13;

fuzz_target!(|data: &[u8]| {
    // Empty input: nothing to do. Mirrors `fuzz_term_input.rs:29`.
    if data.is_empty() {
        return;
    }
    // Need at least one full coord tuple before we'll do any text_range
    // work. Pre-feed cost without a payoff would just waste cycles.
    if data.len() < TUPLE_STRIDE {
        return;
    }

    SAW_FATAL.store(false, Ordering::SeqCst);
    unsafe {
        // 80×24 with 1000-line scrollback — same shape as `fuzz_term_input`
        // so the corpora share a baseline grid geometry. Scrollback is the
        // critical knob: a larger value exposes more `topmost..0` rows that
        // a fuzz-generated negative s_line can reach.
        let term = blackbird_core::bb_term_new(80, 24, 1_000);
        if term.is_null() {
            return;
        }
        // Register Fatal oracle BEFORE feeding so a panic during pre-feed
        // (which would itself be a bug worth surfacing) gets latched.
        blackbird_core::bb_term_set_event_cb(term, Some(on_event), std::ptr::null_mut());

        // -- Stage 1: pre-feed the stable corpus -----------------------------
        //
        // Repeat the block until we've fed roughly 4 KiB. The block is 227
        // bytes, so 18 full repeats land at 4086 bytes; a final partial
        // block fills the remaining 10 bytes. We feed the whole thing as
        // ONE call rather than fragmenting — fragmentation is what
        // `fuzz_term_input` is for; here we just need a populated grid as
        // fast as possible so the fuzz body has a non-empty target.
        let mut prefed: Vec<u8> = Vec::with_capacity(4096);
        while prefed.len() + PREFED_BLOCK.len() <= 4096 {
            prefed.extend_from_slice(PREFED_BLOCK);
        }
        // Fill the tail with a final partial block so the grid is densely
        // packed. This also pushes the scroll position deeper into
        // scrollback, which is exactly what we want for the row-cliff
        // exercise.
        if prefed.len() < 4096 {
            let remaining = 4096 - prefed.len();
            prefed.extend_from_slice(&PREFED_BLOCK[..remaining.min(PREFED_BLOCK.len())]);
        }
        blackbird_core::bb_term_input(term, prefed.as_ptr(), prefed.len());

        // Sanity: take + release a snapshot so the Term's internal "did we
        // populate?" state is observable (and so any pre-feed-only panics
        // surface via the Fatal oracle before we enter the hot loop).
        let snap0 = blackbird_core::bb_term_take_snapshot(term);
        if !snap0.is_null() {
            blackbird_core::bb_snap_release(snap0);
        }

        // -- Stage 2: hot loop — pump coord tuples through text_range -------
        //
        // Each tuple is 13 bytes:
        //   bytes  0..3   = s_line (i32 LE)
        //   bytes  4..7   = e_line (i32 LE)
        //   bytes  8..9   = s_col  (u16 LE)
        //   bytes 10..11  = e_col  (u16 LE)
        //   byte  12      = rect (low bit only)
        //
        // We read tuples back-to-back from `data`, capped at
        // MAX_TEXT_RANGE_CALLS_PER_ITER so libFuzzer can sample the input
        // space rather than burn one iter on a giant blob. The pre-fed
        // grid is shared across all tuples within one iter, so each tuple
        // is a fresh probe of the (s_line, e_line, s_col, e_col, rect)
        // space against the SAME state — exactly what coverage-guided
        // fuzzing wants.
        let tuple_count = (data.len() / TUPLE_STRIDE).min(MAX_TEXT_RANGE_CALLS_PER_ITER);

        for i in 0..tuple_count {
            let off = i * TUPLE_STRIDE;
            let s_line = i32::from_le_bytes([
                data[off],
                data[off + 1],
                data[off + 2],
                data[off + 3],
            ]);
            let e_line = i32::from_le_bytes([
                data[off + 4],
                data[off + 5],
                data[off + 6],
                data[off + 7],
            ]);
            let s_col = u16::from_le_bytes([data[off + 8], data[off + 9]]);
            let e_col = u16::from_le_bytes([data[off + 10], data[off + 11]]);
            let rect = data[off + 12] & 1;

            // Every 8th iter, perturb the grid with a resize. This pins
            // the "text_range across a recent resize that may have
            // truncated rows" path — after a shrink, formerly-valid
            // (line, col) pairs land off-grid, and the clamps at
            // lib.rs:3433 (col) and 3443/3444 (row) have to absorb them.
            //
            // Resize dims come from the NEXT tuple's bytes
            // (off+TUPLE_STRIDE..off+TUPLE_STRIDE+4) rather than the
            // current tuple's e_line — coupling them would tie the
            // (s_line,e_line,...) coord coverage to the (rcols,rrows)
            // resize coverage and degrade libFuzzer's ability to find
            // resize-only or coord-only minimisations. Same fix as the
            // F4 audit on `fuzz_term_input.rs:118`. If the next tuple
            // doesn't fit (we're at the last tuple), skip the resize
            // for this iter — the resize-coverage signal lands on the
            // many iters where a next tuple does exist.
            if i % 8 == 7 {
                let next_off = off + TUPLE_STRIDE;
                if data.len() >= next_off + 4 {
                    let rcols =
                        u16::from_le_bytes([data[next_off], data[next_off + 1]]);
                    let rrows = u16::from_le_bytes([
                        data[next_off + 2],
                        data[next_off + 3],
                    ]);
                    blackbird_core::bb_term_resize(term, rcols, rrows);
                }
            }

            // text_range proper. The function's contract on a populated
            // grid: returns a non-null BBString (possibly empty) on
            // success, null only on (a) null term — which we ruled out
            // above — or (b) a guarded panic that the Fatal callback
            // will have latched. Either way, the release is null-safe.
            let s = blackbird_core::bb_term_text_range(term, s_line, s_col, e_line, e_col, rect);
            if !s.is_null() {
                blackbird_core::bb_string_release(s);
            }

            // Snapshot churn between text_range calls. Forces the
            // snapshot lifetime tracking under a grid that's
            // simultaneously being read by text_range and being
            // re-snapshotted. Catches any aliasing between the two.
            let snap = blackbird_core::bb_term_take_snapshot(term);
            if !snap.is_null() {
                blackbird_core::bb_snap_release(snap);
            }
        }

        blackbird_core::bb_term_free(term);
    }

    // Fatal oracle. Identical contract to `fuzz_term_input`: any panic
    // caught by `guard_with_term` inside text_range / resize / snapshot
    // gets routed to BBEventKind::Fatal, latched, and we promote it to a
    // libFuzzer crash so cargo-fuzz minimises and persists a reproducer.
    if SAW_FATAL.swap(false, Ordering::SeqCst) {
        panic!("blackbird_core routed a BBEventKind::Fatal — panic inside a guarded FFI");
    }
});
