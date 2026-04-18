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
