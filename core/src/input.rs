use crate::color::palette_default_rgb;
use crate::diag::breadcrumb;
use crate::event::{BBEvent, BBEventKind};
use crate::osc::{osc_scanner, prompt_mark_event};
use crate::rate_limit::{COLOR_QUERY_REPLY_PER_SECOND, COLOR_QUERY_REPLY_WINDOW};
use crate::{BBSyncStatus, BBTerm};

/// An OSC / DCS / SOS / PM / APC string cut by a read boundary leaves the count at 1.
pub(crate) const WEDGED_STRING_CHUNKS: u32 = 2;

/// # Safety
/// Single-threaded access to `bb` per the BBTerm thread discipline.
pub(crate) unsafe fn process_input(bb: &mut BBTerm, slice: &[u8]) {
    if memchr::memchr(0x1B, slice).is_none() {
        // Tap BEFORE grid: an OSC 133 mark completed here is stamped with the pre-chunk cursor.
        let has_bel = memchr::memchr(0x07, slice).is_some();
        if bb.osc_possibly_pending || has_bel || bb.osc_tap.in_xtgettcap {
            {
                let mut osc = osc_scanner!(bb);
                bb.osc_parser.advance(&mut osc, slice);
            }
            // Clear on Ground, NOT only on a BEL: the bundled prompt marks terminate with ST.
            bb.osc_possibly_pending = !bb.osc_parser.is_ground();
        }
        advance_grid(bb, slice);
        finish_advance(bb);
        return;
    }
    // Lock-step, cut before each ESC that can start a query and drained per segment, so replies
    // leave in the order the queries were written.
    let mut start = 0;
    while start < slice.len() {
        let synchronized = bb.processor.sync_timeout().sync_timeout().is_some()
            || !bb.osc_tap.held_prompt_marks.is_empty();
        // An ESC that finds a string open dispatches an unterminated OSC colour query: cut it
        // off alone so that reply is queued and drained before the sequence the ESC begins.
        let end = if slice[start] == 0x1B && bb.processor.in_string() {
            start + 1
        } else if synchronized {
            memchr::memchr(0x1B, &slice[start + 1..])
                .map_or(slice.len(), |next_esc| start + 1 + next_esc)
        } else {
            next_cut(slice, start + 1)
        };
        let segment = &slice[start..end];
        {
            let mut osc = osc_scanner!(bb);
            bb.osc_parser.advance(&mut osc, segment);
        }
        bb.osc_possibly_pending = !bb.osc_parser.is_ground();
        advance_grid(bb, segment);
        drain_color_requests(bb);
        start = end;
    }
    finish_advance(bb);
}

fn next_cut(slice: &[u8], from: usize) -> usize {
    let mut at = from;
    while let Some(offset) = memchr::memchr(0x1B, &slice[at..]) {
        let esc = at + offset;
        if !is_inert_csi(&slice[esc..]) {
            return esc;
        }
        at = esc + 1;
    }
    slice.len()
}

/// SGR, cursor movement, erase, insert / delete, scroll and DECSTBM.
const INERT_CSI_FINALS: &[u8] = b"mHfABCDEFGdJKLMPX@STr";

/// `c` (DA), `n` (DSR), `t`, and any private marker or intermediate may reply or fire: not inert.
fn is_inert_csi(bytes: &[u8]) -> bool {
    if !bytes.starts_with(b"\x1b[") {
        return false;
    }
    bytes[2..]
        .iter()
        .find(|byte| !matches!(byte, b'0'..=b'9' | b';' | b':'))
        .is_some_and(|last| INERT_CSI_FINALS.contains(last))
}

/// # Safety
/// As `process_input`. Owed by EVERY parser-advance path, `flush_sync_update`'s replay included.
pub(crate) unsafe fn finish_advance(bb: &mut BBTerm) {
    bb.string_state_chunks = if bb.processor.in_string() {
        bb.string_state_chunks.saturating_add(1)
    } else {
        0
    };
    drain_color_requests(bb);
    bb.callback.flush_suppressed_title();
    bb.callback.flush_suppressed_osc52();
    if bb.term.take_hyperlink_over_budget() && crate::osc::once(&mut bb.osc8_live_cap_logged) {
        breadcrumb!(
            "[blackbird_core] OSC 8 hyperlink live-byte budget exhausted — new hyperlinks \
             are refused (printed without a link) until the cells holding links are \
             overwritten or scroll out of the retained scrollback. Erasing the screen \
             and then its scrollback (ESC[2J, ESC[3J) frees the links held by the \
             screen that is showing, but a plain erase does not reach the other \
             screen's rows; ⌘K (bb_term_clear_all) also frees the other screen's \
             links, but it does not reach the shell's visible rows while the alternate \
             screen is up. Symptom: 'links stopped working'. One-shot per session."
        );
    }
}

/// # Safety
/// Same single-thread discipline as `process_input`.
unsafe fn advance_grid(bb: &mut BBTerm, mut bytes: &[u8]) {
    // While marks are held, advance one step per `l` (an ESU ends in `l`), so bytes after the ESU
    // cannot move the cursor before the held marks read it.
    while !bytes.is_empty() && !bb.osc_tap.held_prompt_marks.is_empty() {
        let step_len = memchr::memchr(b'l', bytes).map_or(bytes.len(), |at| at + 1);
        let (step, rest) = bytes.split_at(step_len);
        let buffered_if_appended = bb.processor.sync_bytes_count() + step.len();
        bb.processor.advance(&mut bb.term, step);
        let still_buffering = bb.processor.sync_timeout().sync_timeout().is_some()
            && bb.processor.sync_bytes_count() == buffered_if_appended;
        if !still_buffering {
            release_held_prompt_marks(bb);
        }
        bytes = rest;
    }
    bb.processor.advance(&mut bb.term, bytes);
}

/// # Safety
/// As `process_input`; fires events, so the caller must not be inside an event dispatch.
unsafe fn release_held_prompt_marks(bb: &mut BBTerm) {
    let held = std::mem::take(&mut bb.osc_tap.held_prompt_marks);
    for mark in &held {
        let ev = prompt_mark_event(&bb.term, mark.kind, &mark.payload);
        bb.callback.fire(ev);
    }
}

/// Reads the ABSOLUTE deadline: the `Timeout` trait's `pending_timeout()` is not expiry-aware.
pub(crate) fn sync_status(bb: &BBTerm) -> BBSyncStatus {
    let Some(deadline) = bb.processor.sync_timeout().sync_timeout() else {
        return BBSyncStatus::idle();
    };
    let remaining = deadline.saturating_duration_since(std::time::Instant::now());
    BBSyncStatus {
        remaining_ns: u64::try_from(remaining.as_nanos()).unwrap_or(u64::MAX),
        buffered_bytes: u64::try_from(bb.processor.sync_bytes_count()).unwrap_or(u64::MAX),
        pending: 1,
        expired: u8::from(remaining.is_zero()),
        _pad: [0; 6],
    }
}

/// # Safety
/// As `process_input`; the replay CAN fire events, so the caller must not be inside a dispatch.
pub(crate) unsafe fn flush_sync_update(bb: &mut BBTerm, force: bool) -> bool {
    let Some(deadline) = bb.processor.sync_timeout().sync_timeout() else {
        return false;
    };
    if !force && std::time::Instant::now() < deadline {
        return false;
    }
    // Replay ONLY through the Processor into `Term`, never through `bb.osc_parser`: the tap
    // saw these bytes at feed time, so re-feeding would double-fire OSC 7 / OSC 133.
    bb.processor.stop_sync(&mut bb.term);
    release_held_prompt_marks(bb);
    finish_advance(bb);
    true
}

/// # Safety
/// Caller must ensure single-threaded access to `bb.color_queue` and `bb.callback`.
unsafe fn drain_color_requests(bb: &mut BBTerm) {
    let entries = (*bb.color_queue).drain();
    if entries.is_empty() {
        return;
    }
    if !bb.color_query_enabled {
        return;
    }
    for entry in entries {
        let now = std::time::Instant::now();
        if now.duration_since(bb.color_query_reply_window_start) >= COLOR_QUERY_REPLY_WINDOW {
            bb.color_query_reply_window_start = now;
            bb.color_query_reply_window_count = 0;
            bb.color_query_reply_drop_logged = false;
        }
        if bb.color_query_reply_window_count >= COLOR_QUERY_REPLY_PER_SECOND {
            if crate::osc::once(&mut bb.color_query_reply_drop_logged) {
                breadcrumb!(
                    "blackbird_core: OSC 4/10/11/12 colour-query replies hit the \
                     {COLOR_QUERY_REPLY_PER_SECOND}/s cap; further queries in this window dropped"
                );
            }
            continue;
        }

        // `entry.current` is the override as of the query; `bb.term.colors()` here would see
        // the END of the chunk. `Colors` indexing panics out of bounds: check `COUNT` first.
        let slot: Option<alacritty_terminal::vte::ansi::Rgb> =
            if entry.index < alacritty_terminal::term::color::COUNT {
                entry.current.or(bb.theme_colors[entry.index])
            } else {
                None
            };
        let rgb = slot.unwrap_or_else(|| palette_default_rgb(entry.index));
        let reply = (entry.formatter)(rgb);
        let bytes = reply.as_bytes();
        bb.callback.fire(BBEvent {
            kind: BBEventKind::PtyWrite,
            payload: bytes.as_ptr(),
            len: bytes.len(),
            i32_arg: 0,
            cursor_row: 0,
            lines_scrolled: 0,
        });
        // Count after the fire: a panicking callback must not consume budget.
        bb.color_query_reply_window_count += 1;
    }
}
