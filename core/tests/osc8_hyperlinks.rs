//! OSC 8 hyperlink attribution on snapshots.

use std::ffi::CStr;

use blackbird_core::*;

fn snap_link_for_cell(bytes: &[u8], row: u16, col: u16) -> Option<String> {
    unsafe {
        let term = bb_term_new(80, 24, 1000);
        bb_term_input(term, bytes.as_ptr(), bytes.len());
        let snap = bb_term_take_snapshot(term);
        let id = bb_snap_link_id_at(snap, row, col);
        let out = if id == 0 {
            None
        } else {
            let c = bb_snap_link_url(snap, id);
            assert!(!c.is_null(), "link id {id} must resolve");
            Some(CStr::from_ptr(c as *const _).to_string_lossy().into_owned())
        };
        bb_snap_release(snap);
        bb_term_free(term);
        out
    }
}

#[test]
fn osc8_attributes_wrapped_cells() {
    // ESC]8;;https://example.com ESC\  "hi"  ESC]8;; ESC\
    let seq = b"\x1b]8;;https://example.com\x1b\\hi\x1b]8;;\x1b\\";
    assert_eq!(
        snap_link_for_cell(seq, 0, 0).as_deref(),
        Some("https://example.com")
    );
    assert_eq!(
        snap_link_for_cell(seq, 0, 1).as_deref(),
        Some("https://example.com")
    );
    assert_eq!(snap_link_for_cell(seq, 0, 2), None);
}

#[test]
fn osc8_empty_href_clears_attribution() {
    let seq = b"\x1b]8;;\x1b\\plain\x1b]8;;\x1b\\";
    assert_eq!(snap_link_for_cell(seq, 0, 0), None);
}

#[test]
fn osc8_drops_attribution_when_uri_exceeds_cap() {
    // A remote can emit a megabyte-long URL as the OSC 8 target; the
    // cap limits the per-snapshot CString allocation. Over-long URIs
    // drop to "no attribution" rather than truncate — a truncated URL
    // that opens would go to a different destination than the user
    // expected. Pick a URI at 4 KiB + 1 to land just past the cap.
    let long_uri: String = "https://example.com/?q=".to_string() + &"a".repeat(4096);
    let seq = format!("\x1b]8;;{}\x1b\\X\x1b]8;;\x1b\\", long_uri);
    assert_eq!(
        snap_link_for_cell(seq.as_bytes(), 0, 0),
        None,
        "URI longer than 4 KiB must not produce a live link"
    );
}

#[test]
fn osc8_accepts_uri_at_cap_boundary() {
    // 4 KiB exactly must still work — the cap is inclusive on 4096.
    let uri: String =
        "https://example.com/?q=".to_string() + &"a".repeat(4096 - "https://example.com/?q=".len());
    assert_eq!(uri.len(), 4096);
    let seq = format!("\x1b]8;;{}\x1b\\X\x1b]8;;\x1b\\", uri);
    assert_eq!(
        snap_link_for_cell(seq.as_bytes(), 0, 0).as_deref(),
        Some(uri.as_str()),
        "URI exactly at 4 KiB must survive"
    );
}

#[test]
fn bb_term_new_clamps_oversized_dimensions() {
    // Verifies that a caller passing UInt16.max for cols / rows can't
    // accidentally request hundreds of GB of cell allocation. Construction
    // must still succeed (clamped to the internal MAX_DIM), not block or
    // allocate more than a few tens of MB. If this test ever takes more
    // than a second, the clamp was removed.
    unsafe {
        let term = bb_term_new(u16::MAX, u16::MAX, 1000);
        assert!(!term.is_null(), "huge cols/rows must clamp, not fail");
        // Verify the snapshot reflects a sane clamped grid — cells_len
        // capped at something well under 65535 × 65535.
        let snap = bb_term_take_snapshot(term);
        assert!(!snap.is_null());
        let len = (*snap).cells_len;
        assert!(len <= 1_000 * 1_000, "cells_len {} must be clamped", len);
        bb_snap_release(snap);
        bb_term_free(term);
    }
}

#[test]
fn bb_term_resize_clamps_oversized_dimensions() {
    // Same class of bug via resize. UInt16.max was documented to crash
    // a developer's machine by requesting ~68 GB of cell allocation —
    // the clamp here makes that impossible regardless of what a future
    // caller passes through the FFI.
    unsafe {
        let term = bb_term_new(80, 24, 100);
        assert!(!term.is_null());
        // Massive resize — must land on the clamped ceiling, not OOM.
        bb_term_resize(term, u16::MAX, u16::MAX);
        let snap = bb_term_take_snapshot(term);
        let len = (*snap).cells_len;
        assert!(len <= 1_000 * 1_000, "resize cells_len {} must clamp", len);
        bb_snap_release(snap);
        bb_term_free(term);
    }
}

#[test]
fn bb_term_new_clamp_ceiling_is_exactly_1000() {
    // Regression guard: the clamp is 1000 × 1000. A future refactor
    // that silently bumped it to, say, 10 000 would multiply the
    // worst-case allocation by 100. Verify via the observable snapshot
    // that the ceiling lands exactly where SECURITY.md documents.
    unsafe {
        let term = bb_term_new(u16::MAX, u16::MAX, 10);
        assert!(!term.is_null());
        let snap = bb_term_take_snapshot(term);
        let cols = (*snap).cols as usize;
        let rows = (*snap).rows as usize;
        assert_eq!(cols, 1000, "clamp ceiling on cols must stay 1000");
        assert_eq!(rows, 1000, "clamp ceiling on rows must stay 1000");
        bb_snap_release(snap);
        bb_term_free(term);
    }
}

#[test]
fn bb_term_new_clamps_oversized_scrollback() {
    // u32::MAX would tell alacritty to allocate unbounded history.
    // Construction must still succeed (clamped silently to a sane cap)
    // so a caller that passes a huge value doesn't strand the terminal.
    unsafe {
        let term = bb_term_new(80, 24, u32::MAX);
        assert!(!term.is_null(), "huge scrollback must clamp, not fail");
        bb_term_free(term);
    }
}

#[test]
fn osc8_invalid_link_id_returns_null() {
    unsafe {
        let term = bb_term_new(80, 24, 1000);
        let snap = bb_term_take_snapshot(term);
        assert!(bb_snap_link_url(snap, 0).is_null());
        assert!(bb_snap_link_url(snap, 12345).is_null());
        bb_snap_release(snap);
        bb_term_free(term);
    }
}
