//! The PTY-input hot path: feed bytes through alacritty's grid processor and
//! the parallel OSC scanner, then resolve deferred OSC 10/11/12 colour-query
//! replies. Pure logic over `&mut BBTerm` (the raw-slice materialization stays
//! in the FFI shell). Extracted from bb_term_input / drain_color_requests
//! (REFACTOR.md Part IV).

use crate::color::palette_default_rgb;
use crate::diag::breadcrumb;
use crate::event::{BBEvent, BBEventKind};
use crate::osc::{osc_scanner, prompt_mark_event};
use crate::rate_limit::{COLOR_QUERY_REPLY_PER_SECOND, COLOR_QUERY_REPLY_WINDOW};
use crate::{BBSyncStatus, BBTerm};

/// A string-introduced function (OSC / DCS / SOS / PM / APC) still open at the
/// end of this many consecutive parser advances is a sender that never closed
/// it, not a string cut by a read boundary. A boundary leaves the count at 1.
/// `bb_term_clear_all` aborts the string at this count.
pub(crate) const WEDGED_STRING_CHUNKS: u32 = 2;

/// DEC 2026 synchronized-update end (`CSI ? 2026 l`), the exact bytes vte's
/// sync handling scans for.
const ESU_CSI: &[u8] = b"\x1b[?2026l";

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
        // The tap runs BEFORE the grid, as in the ESC branch below: an OSC 133
        // mark completed here (the tail of a sequence the read boundary cut)
        // is stamped with the cursor as it stood before this chunk's text
        // moved it.
        //
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
        // `|| bb.osc_tap.in_xtgettcap`: defensive. If a future code path ever
        // clears `osc_possibly_pending` while a DCS is still open
        // (e.g. a ST-only terminator path we haven't needed yet),
        // this keeps the osc_parser alive so our hook/put/unhook
        // state advances. No current fragmentation scenario reaches
        // this branch because `osc_possibly_pending` stays true from
        // the DCS's opening ESC; kept as a safety belt.
        if bb.osc_possibly_pending || has_bel || bb.osc_tap.in_xtgettcap {
            {
                let mut osc = osc_scanner!(bb);
                bb.osc_parser.advance(&mut osc, slice);
            }
            // Clear the latch as soon as the tap parser is back in Ground
            // with no partial UTF-8 — NOT only on a BEL. The bundled prompt
            // marks terminate with ST (ESC \), so the BEL-only clear left the
            // latch set for the rest of the session after the first prompt
            // and every plain-text chunk ran through both parsers.
            bb.osc_possibly_pending = !bb.osc_parser.is_ground();
        }
        advance_grid(bb, slice);
        finish_advance(bb);
        return;
    }
    // Chunk contains ESC — may open a new OSC that terminates in a
    // later chunk, so the latch is refreshed from the tap parser's state
    // after each advance below (see the ESC-free branch above).
    //
    // Replies leave through three paths: the tap fires XTVERSION / DECRQSS
    // / XTGETTCAP the moment it dispatches them, alacritty fires DA / DSR /
    // CPR inline, and OSC 4/10/11/12 answers wait in `color_queue` for the
    // drain. Run whole-chunk, the wire order is tap, processor, colour
    // whatever order the queries were written in, so a DA1 / CPR sentinel
    // overtakes the answers it trails. Advance both parsers in lock-step
    // instead, cutting before every ESC (each sequence starts at one, so a
    // segment holds at most one query sequence) and drain after each
    // segment. An ESC that finds a string open also ends it, which is what
    // dispatches an unterminated OSC colour query, so that ESC is cut off
    // alone: the sequence it begins (a CPR, or an XTVERSION the tap answers
    // on sight) must not run before the colour reply is queued and drained.
    // Both parsers are streaming, so a cut anywhere, even between the ESC and
    // the `\` of an ST, is invisible to them. Bytes inside a DEC 2026
    // synchronized update are replayed whole when it closes, so replies
    // queued there keep the old order (KNOWN_ISSUES.md).
    //
    // The same cuts give OSC 133;A its cursor position: the tap stamps a
    // kind-A mark with the cursor at the moment it parses it (Swift cannot
    // recover that later - a snapshot is taken after the whole burst), and
    // since every segment starts at an ESC the grid has consumed everything
    // before the mark and nothing after it. Inside a DEC 2026 synchronized
    // update the grid only buffers, so the tap holds the marks it parses and
    // `advance_grid` stamps them once the update has been replayed.
    let mut start = 0;
    while start < slice.len() {
        let end = if slice[start] == 0x1B && bb.processor.in_string() {
            start + 1
        } else {
            memchr::memchr(0x1B, &slice[start + 1..])
                .map_or(slice.len(), |next_esc| start + 1 + next_esc)
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

/// The tail every parser-advance path owes: resolve deferred OSC 10/11/12
/// colour-query replies and re-attempt a rate-suppressed title / OSC 52
/// write, all outside any live alacritty borrow.
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
    // Also owed by every advance: how long the grid parser has sat inside an
    // OSC / DCS / SOS / PM / APC string. Cheap (one enum compare per chunk).
    bb.string_state_chunks = if bb.processor.in_string() {
        bb.string_state_chunks.saturating_add(1)
    } else {
        0
    };
    drain_color_requests(bb);
    bb.callback.flush_suppressed_title();
    bb.callback.flush_suppressed_osc52();
    // The grid refuses an OSC 8 link past its live-byte budget by printing the
    // text unattributed. Take the flag on every advance so it never goes
    // stale, and log only the first: a flood refuses one link per row.
    //
    // What an erase frees depends on WHICH SCREEN holds the links, not on how
    // many rows the grid keeps: `Grid::clear_history` truncates, so the rows an
    // erase reaches are released at once. `osc8_refusal_log_truth_blind.rs`
    // measures each case and reads every clause below that names a remedy as a
    // claim about the screen holding the links, which it checks against the
    // measurement; keep them in step (a changed claim also needs the test's
    // `SHIPPED_LOG` fixture updated).
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

/// Advance the grid parser over `bytes`, delivering the OSC 133 marks the tap
/// held as soon as this advance replays the synchronized update they sit in.
///
/// While a DEC 2026 synchronized update is open, `Processor::advance` only
/// appends to its sync buffer, so the grid lags the stream and a mark the tap
/// parses meanwhile cannot be stamped from it (see `OscScanner::sync_pending`).
/// The advance that replays the buffer is the one that moves the grid past
/// those marks, and a mark is stamped from the grid right after it. So while
/// marks are held, `bytes` is advanced in two steps at the first ESU: bytes
/// after the ESU (the command's output, say) then cannot move the cursor before
/// the held marks read it. A pure append grows the buffer by exactly the bytes
/// fed; any other outcome, or the update no longer being open, means a replay
/// happened. That also covers the replays the ESU scan cannot see: the 2 MiB
/// cap, an ESU split across feeds, and an ESU followed by a further BSU, which
/// leaves that BSU's bytes buffered.
///
/// Marks held by `flush_sync_update` are released there instead.
///
/// # Safety
/// Same single-thread discipline as `process_input`.
unsafe fn advance_grid(bb: &mut BBTerm, mut bytes: &[u8]) {
    while !bytes.is_empty() && !bb.osc_tap.held_prompt_marks.is_empty() {
        let (step, rest) = match memchr::memmem::find(bytes, ESU_CSI) {
            Some(at) => bytes.split_at(at + ESU_CSI.len()),
            None => (bytes, &bytes[bytes.len()..]),
        };
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

/// Deliver the OSC 133 marks the tap held while a DEC 2026 synchronized
/// update was open, oldest first, now that the update has been replayed into
/// the grid.
///
/// The tap parsed each mark when its bytes arrived, but the grid only catches
/// up at the replay, so the cursor position a kind-A mark carries is read here
/// instead, from the grid as the replay left it. That is exact for a single
/// prompt in an update. vte replays the whole buffer in one go, so several
/// prompts inside ONE update share the position the grid holds after the
/// replay (a position between them is never observable); prompts in separate
/// updates, or outside any, are each exact.
///
/// # Safety
/// Same single-thread discipline as `process_input`; fires events, so the
/// caller must not be inside an event dispatch.
unsafe fn release_held_prompt_marks(bb: &mut BBTerm) {
    let held = std::mem::take(&mut bb.osc_tap.held_prompt_marks);
    for mark in &held {
        let ev = prompt_mark_event(&bb.term, mark.kind, &mark.payload);
        // `fire` delivers synchronously, so `mark.payload` outlives the
        // callback that borrows it.
        bb.callback.fire(ev);
    }
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
    // already fired. Re-feeding would double-fire them. (The one thing a mark
    // parsed inside the update is owed is its grid position, which only the
    // replay provides: the tap held it, and it is delivered just below.)
    bb.processor.stop_sync(&mut bb.term);
    // The update is closed (post-condition above), so the marks the tap held
    // inside it can be stamped from the replayed grid.
    release_held_prompt_marks(bb);
    finish_advance(bb);
    true
}

/// Resolve every pending OSC 10/11/12 response and emit it as a PtyWrite
/// event. Called after every `processor.advance` in `bb_term_input`
/// returns — at that point we're no longer inside alacritty's `&mut Term`
/// borrow. Each entry carries its colour as of the query, so draining late
/// does not change the answer.
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
    // `theme_colors` is alacritty's fixed-width `Colors` table. Its length is a
    // public `COUNT` constant (269 today — 256 indexed + 13 named). The
    // `Index` impl panics on out-of-bounds, so bound-check first. A
    // direct index was sound for every value the current alacritty/vte
    // surface can emit, but future widenings must not panic into
    // `BBEventKind::Fatal` (rust-core-2 F2).
    for entry in entries {
        // Bug #17 sliding-window gate: cap PtyWrite replies at
        // COLOR_QUERY_REPLY_PER_SECOND across the rolling
        // COLOR_QUERY_REPLY_WINDOW. The ColorRequestQueue cap only bounds
        // one drain (one ESC-delimited segment), so this window is what
        // bounds a flood of separate queries, in one chunk or across many.
        let now = std::time::Instant::now();
        if now.duration_since(bb.color_query_reply_window_start) >= COLOR_QUERY_REPLY_WINDOW {
            bb.color_query_reply_window_start = now;
            bb.color_query_reply_window_count = 0;
            bb.color_query_reply_drop_logged = false;
        }
        if bb.color_query_reply_window_count >= COLOR_QUERY_REPLY_PER_SECOND {
            // Per-drop logging would amplify the flood, but the first drop
            // in each window leaves one breadcrumb: a client that never
            // gets its colour answer needs something to find.
            if crate::osc::once(&mut bb.color_query_reply_drop_logged) {
                breadcrumb!(
                    "blackbird_core: OSC 4/10/11/12 colour-query replies hit the \
                     {COLOR_QUERY_REPLY_PER_SECOND}/s cap; further queries in this window dropped"
                );
            }
            continue;
        }

        // `entry.current` is the program's override as of the query, captured
        // by the vendored `dynamic_color_sequence`. Re-reading
        // `bb.term.colors()` here would see the END of the chunk, so a set or
        // OSC 104/110-112 reset after the query in the same read would change
        // the reply.
        let slot: Option<alacritty_terminal::vte::ansi::Rgb> =
            if entry.index < alacritty_terminal::term::color::COUNT {
                entry.current.or(bb.theme_colors[entry.index])
            } else {
                None
            };
        // `current` is Option<Rgb>. None means no program had overridden
        // this slot (or it was reset): use the host's theme, then a
        // sensible default so we still reply rather than leaving the TUI
        // timing out.
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
            cursor_row: 0,
            lines_scrolled: 0,
        });
        // Audit fix-#14 (2026-05-21): increment AFTER successful fire so
        // a user-callback panic (caught by guard_with_term's outer
        // catch_unwind) doesn't leave the rate-limit counter desynced
        // from actual deliveries. Cumulative count over the window now
        // reflects only replies that the callback observed.
        bb.color_query_reply_window_count += 1;
    }
}
