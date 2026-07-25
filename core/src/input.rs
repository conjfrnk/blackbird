//! The PTY-input hot path: feed bytes through alacritty's grid processor and
//! the parallel OSC scanner, then resolve deferred OSC 10/11/12 colour-query
//! replies. Pure logic over `&mut BBTerm` (the raw-slice materialization stays
//! in the FFI shell). Extracted from bb_term_input / drain_color_requests
//! (REFACTOR.md Part IV).

use crate::color::palette_default_rgb;
use crate::event::{BBEvent, BBEventKind};
use crate::osc::osc_scanner;
use crate::rate_limit::{COLOR_QUERY_REPLY_PER_SECOND, COLOR_QUERY_REPLY_WINDOW};
use crate::{BBSyncStatus, BBTerm};

/// Feed one chunk of PTY bytes through the grid processor + parallel OSC tap.
///
/// # Safety
/// Single-threaded access to `bb` per the BBTerm thread discipline.
pub(crate) unsafe fn process_input(bb: &mut BBTerm, slice: &[u8]) {
    // `CSI 2 J` (ED All — erase visible viewport) is NOT augmented with
    // `CSI 3 J` (erase scrollback). A previous revision auto-injected 3J
    // on every top-level 2J so `clear(1)` would also wipe scrollback,
    // matching `clear -x` / iTerm2's optional behavior. That heuristic
    // misfired in the field: TUIs (Claude Code's Ink renderer, ratatui
    // spinners, fzf full-screen redraws) emit 2J on every redraw cycle,
    // and the injected 3J wiped the user's scrollback on each frame.
    // Users now have ⌘K (`bb_term_clear_all`) for the explicit
    // viewport+scrollback wipe; `clear(1)` is viewport-only, matching
    // xterm / Alacritty / Terminal.app.
    //
    // Fast path: if the chunk contains no ESC byte at all, we can't have
    // any CSI sequence, so the OSC-parser is only needed when a prior
    // chunk left one pending.
    if memchr::memchr(0x1B, slice).is_none() {
        bb.processor.advance(&mut bb.term, slice);
        // OSC parser skip: pure-text chunks don't need the parallel
        // state machine UNLESS (a) a prior chunk opened an OSC that
        // may still be open, or (b) this chunk contains a BEL that
        // could be an OSC terminator. For streams with zero ESC / BEL
        // (the plain_text / `yes(1)` / `cat log` case), we skip
        // vte::Parser entirely after the first ESC-free chunk.
        //
        // Clearing the latch: after an ESC-free advance, any
        // ST-terminated (ESC \) OSC is still pending by definition
        // (ST requires an ESC, which we didn't see). Only a BEL in
        // this chunk can have terminated the pending sequence, so we
        // clear the latch only then. Unterminated sequences stay
        // pending forever — pathological but harmless.
        let has_bel = memchr::memchr(0x07, slice).is_some();
        // Also drive the parallel parser while we are mid-XTGETTCAP:
        // a `put`-heavy hex payload can be pure ASCII with no ESC/BEL,
        // so the `hook` latch is what keeps us here.
        //
        // `|| bb.in_xtgettcap`: defensive. If a future code path ever
        // clears `osc_possibly_pending` while a DCS is still open
        // (e.g. a ST-only terminator path we haven't needed yet),
        // this keeps the osc_parser alive so our hook/put/unhook
        // state advances. No current fragmentation scenario reaches
        // this branch because `osc_possibly_pending` stays true from
        // the DCS's opening ESC; kept as a safety belt.
        if bb.osc_possibly_pending || has_bel || bb.in_xtgettcap {
            let mut osc = osc_scanner!(bb);
            bb.osc_parser.advance(&mut osc, slice);
            if has_bel {
                bb.osc_possibly_pending = false;
            }
        }
        finish_advance(bb);
        return;
    }
    // Chunk contains ESC — may open a new OSC that terminates in a
    // later chunk. Set the latch so subsequent ESC-free chunks still
    // reach the parser.
    bb.osc_possibly_pending = true;
    // Drive the parallel OSC parser whole-chunk: it watches for OSC 7,
    // OSC 133, and the modify-other-keys CSI. None of those need byte-
    // precise dispatch positions, so a single `advance` is enough.
    let mut osc = osc_scanner!(bb);
    bb.osc_parser.advance(&mut osc, slice);
    bb.processor.advance(&mut bb.term, slice);
    finish_advance(bb);
}

/// The tail every parser-advance path owes: resolve deferred OSC 10/11/12
/// colour-query replies and re-attempt a rate-suppressed title, both outside
/// any live alacritty borrow.
///
/// Shared by `process_input` and `flush_sync_update` — the flush replays
/// buffered bytes through the SAME handler, so it incurs the same debt. If
/// the flush skipped this, an `OSC 11 ?` issued inside a stalled sync region
/// would sit in `color_queue` until the next `bb_term_input`, and on a dead
/// producer there is no next input: a silent-failure sibling of the freeze
/// this whole path exists to fix.
///
/// # Safety
/// Same single-thread discipline as `process_input`.
pub(crate) unsafe fn finish_advance(bb: &mut BBTerm) {
    drain_color_requests(bb);
    bb.callback.flush_suppressed_title();
}

/// Current DEC 2026 synchronized-update state.
///
/// `BBTerm::processor` is `Processor` with the default type parameter
/// `T = StdSyncHandler`, so `Processor::sync_timeout()` yields
/// `&StdSyncHandler` and its inherent `sync_timeout()` yields the ABSOLUTE
/// `Option<Instant>` deadline. We read the deadline rather than the `Timeout`
/// trait's `pending_timeout()` because the latter is literally
/// `self.timeout.is_some()` — it is not expiry-aware; upstream deliberately
/// leaves expiry to the embedder. Reading the deadline also keeps vte's
/// private 150 ms constant from being duplicated on the Swift side.
///
/// If someone later parameterises `BBTerm::processor` away from
/// `StdSyncHandler`, this stops compiling — a loud failure, by design.
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

/// Terminate a pending synchronized update, replaying its buffered bytes into
/// the grid. Returns true iff one was open and has now been closed.
///
/// `force == false` consults the core's own deadline and declines while the
/// update is still live, so this can never tear a frame a TUI legitimately
/// asked for. `force == true` aborts unconditionally.
///
/// Post-condition, unconditional: `sync_status(bb).pending == 0`.
/// `stop_sync_internal`'s `bsu_offset == None` arm always ends by clearing
/// both the timeout and the buffer, even if the replayed bytes contained an
/// interior BSU that re-armed the deadline mid-replay. So the post-flush
/// state is deterministic and a caller's re-arm loop provably terminates.
///
/// # Safety
/// Same single-thread discipline as `process_input`. The replay drives
/// alacritty's `Term` and CAN fire events through `CallbackCell::fire`, so
/// the caller must not already be inside an event dispatch — the FFI entry
/// point gates on `ffi_reentry_blocked`.
pub(crate) unsafe fn flush_sync_update(bb: &mut BBTerm, force: bool) -> bool {
    let Some(deadline) = bb.processor.sync_timeout().sync_timeout() else {
        return false;
    };
    if !force && std::time::Instant::now() < deadline {
        return false;
    }
    // Disjoint two-field borrow — same shape `bb_term_clear_all` already uses.
    //
    // Note this replays ONLY through the Processor's own parser into `Term`.
    // It must never re-feed the buffer to `bb.osc_parser`: that parser is
    // advanced over the raw chunk at feed time regardless of sync state, so
    // OSC 7 (cwd), OSC 133 (prompt marks) and the modifyOtherKeys CSI have
    // already fired. Re-feeding would double-fire them.
    bb.processor.stop_sync(&mut bb.term);
    finish_advance(bb);
    true
}

/// Resolve every pending OSC 10/11/12 response and emit it as a PtyWrite
/// event. Called after every `processor.advance` in `bb_term_input`
/// returns — at that point we're no longer inside alacritty's `&mut Term`
/// borrow, so the palette is readable.
///
/// # Safety
/// Caller must ensure single-threaded access to `bb.color_queue` and
/// `bb.callback` (the usual BBTerm thread discipline).
unsafe fn drain_color_requests(bb: &mut BBTerm) {
    let entries = (*bb.color_queue).drain();
    if entries.is_empty() {
        return;
    }
    // Security default: drop the queue silently unless the user has
    // explicitly enabled replies. Ignoring here rather than blocking the
    // push keeps the wire path identical in both modes — a future
    // always-enable would only need to flip this flag.
    if !bb.color_query_enabled {
        return;
    }
    let palette = bb.term.colors();
    // `palette` is alacritty's fixed-width `Colors` table. Its length is a
    // public `COUNT` constant (269 today — 256 indexed + 13 named). The
    // `Index` impl panics on out-of-bounds, so bound-check first. A
    // direct index was sound for every value the current alacritty/vte
    // surface can emit, but future widenings must not panic into
    // `BBEventKind::Fatal` (rust-core-2 F2).
    for entry in entries {
        // Bug #17 sliding-window gate: cap PtyWrite replies at
        // COLOR_QUERY_REPLY_PER_SECOND across the rolling
        // COLOR_QUERY_REPLY_WINDOW. The per-chunk
        // ColorRequestQueue cap stops in-call amplification; this
        // covers the cross-chunk case.
        let now = std::time::Instant::now();
        if now.duration_since(bb.color_query_reply_window_start) >= COLOR_QUERY_REPLY_WINDOW {
            bb.color_query_reply_window_start = now;
            bb.color_query_reply_window_count = 0;
        }
        if bb.color_query_reply_window_count >= COLOR_QUERY_REPLY_PER_SECOND {
            // Drop silently — matching the PromptMarkRateState pattern.
            continue;
        }

        let slot: Option<alacritty_terminal::vte::ansi::Rgb> =
            if entry.index < alacritty_terminal::term::color::COUNT {
                palette[entry.index]
            } else {
                None
            };
        // palette[idx] is Option<Rgb>. None means the theme hasn't set
        // this slot; fall back to a sensible default so we still reply
        // rather than leaving the TUI timing out.
        let rgb = slot.unwrap_or_else(|| palette_default_rgb(entry.index));
        let reply = (entry.formatter)(rgb);
        // The `reply` String owns its bytes for the duration of this
        // scope; `fire` is synchronous (calls the registered C callback
        // which must copy bytes if it wants to outlive the call).
        let bytes = reply.as_bytes();
        bb.callback.fire(BBEvent {
            kind: BBEventKind::PtyWrite,
            payload: bytes.as_ptr(),
            len: bytes.len(),
            i32_arg: 0,
        });
        // Audit fix-#14 (2026-05-21): increment AFTER successful fire so
        // a user-callback panic (caught by guard_with_term's outer
        // catch_unwind) doesn't leave the rate-limit counter desynced
        // from actual deliveries. Cumulative count over the window now
        // reflects only replies that the callback observed.
        bb.color_query_reply_window_count += 1;
    }
}
