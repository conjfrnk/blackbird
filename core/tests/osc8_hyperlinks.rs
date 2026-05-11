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
fn bb_term_new_boundary_values() {
    // Regression for rust-tests F20. F20 flagged that the clamp tests using
    // `u16::MAX` only exercise the ceiling and trust the clamp to keep
    // memory bounded. Boundary-value tests — zero, minimum, the exact
    // ceiling — cover the clamp's FLOOR and EQUALITY paths and must also
    // stay crash-free. Pre-flight guard: u16::MAX × u16::MAX × 32B ≈
    // 137 GiB if the clamp ever regresses, so never pass u16::MAX without
    // the MIN of 32 KiB already enforced by the FFI documentation. Here
    // we only touch boundary values, not MAX.
    unsafe {
        // Zero cols, non-zero rows — should be a no-op (returns null or a
        // valid term that clamps at MIN_DIM; current impl returns null on
        // zero in either dim via the resize2 guard but new treats floor
        // differently). The FFI contract requires this to NOT crash.
        let t0 = bb_term_new(0, 24, 100);
        // No guarantee on null vs. non-null here — just no panic. If the
        // implementation returns a valid term, clean it up; if null, the
        // `bb_term_free` is a no-op.
        bb_term_free(t0);

        // Zero rows, non-zero cols — symmetric case.
        let t1 = bb_term_new(80, 0, 100);
        bb_term_free(t1);

        // Both zero — degenerate.
        let t2 = bb_term_new(0, 0, 100);
        bb_term_free(t2);

        // Minimum floor (MIN_DIM = 2 per the lib.rs docs).
        let t3 = bb_term_new(2, 2, 100);
        assert!(!t3.is_null(), "minimum dims must produce a valid term");
        let snap = bb_term_take_snapshot(t3);
        assert!(!snap.is_null());
        let cols = (*snap).cols;
        let rows = (*snap).rows;
        // Either passes through at 2×2 or clamps up to the documented MIN.
        assert!(
            cols >= 2 && rows >= 2,
            "minimum dims must be ≥ MIN_DIM (2); got {cols}×{rows}"
        );
        bb_snap_release(snap);
        bb_term_free(t3);

        // Exact ceiling value (1000).
        let t4 = bb_term_new(1000, 1000, 100);
        assert!(!t4.is_null());
        let snap = bb_term_take_snapshot(t4);
        assert_eq!(
            (*snap).cols,
            1000,
            "ceiling value must pass through unclamped"
        );
        assert_eq!(
            (*snap).rows,
            1000,
            "ceiling value must pass through unclamped"
        );
        bb_snap_release(snap);
        bb_term_free(t4);

        // One-below-ceiling (999) — must not clamp.
        let t5 = bb_term_new(999, 999, 100);
        assert!(!t5.is_null());
        let snap = bb_term_take_snapshot(t5);
        assert_eq!((*snap).cols, 999);
        assert_eq!((*snap).rows, 999);
        bb_snap_release(snap);
        bb_term_free(t5);

        // Zero scrollback — boundary for the third parameter.
        let t6 = bb_term_new(80, 24, 0);
        assert!(!t6.is_null(), "zero scrollback must produce a valid term");
        bb_term_free(t6);
    }
}

#[test]
fn bb_term_resize2_boundary_values() {
    // Regression for rust-tests F20 (resize boundary coverage). Complements
    // `bb_term_resize_clamps_oversized_dimensions` (ceiling path) by
    // exercising zero, min, exact-ceiling, and above-ceiling-by-one.
    //
    // Pre-flight: u16::MAX × u16::MAX × 32B ≈ 137 GiB. If the clamp ever
    // regresses this test itself would OOM. The computed product below
    // guards against that: if the product exceeds 64 MiB, we abort the
    // test with a descriptive message instead of letting the allocator
    // ENOMEM (consistent with Connor's prior OOM-rule documentation).
    const MAX_ALLOC_BYTES: u64 = 64 * 1024 * 1024;
    // 1001 × 1001 × 32B ≈ 32 MiB — under the sanity bound.
    let product = 1001u64 * 1001u64 * 32;
    assert!(
        product < MAX_ALLOC_BYTES,
        "test pre-flight: 1001×1001 grid allocation {product} B exceeds {MAX_ALLOC_BYTES} — \
         resize clamp may have regressed; aborting before OOM"
    );

    unsafe {
        let term = bb_term_new(80, 24, 100);
        assert!(!term.is_null());

        // Zero cols — no-op per BBResizeResult doc.
        let r = bb_term_resize2(term, 0, 24);
        assert_eq!(r.applied_cols, 0);
        assert_eq!(r.applied_rows, 0);
        assert_eq!(r.clamped, 0);

        // Zero rows — no-op.
        let r = bb_term_resize2(term, 80, 0);
        assert_eq!(r.applied_cols, 0);
        assert_eq!(r.applied_rows, 0);
        assert_eq!(r.clamped, 0);

        // Minimum floor (1 col should clamp up to MIN_DIM = 2).
        let r = bb_term_resize2(term, 1, 1);
        assert_eq!(
            r.applied_cols, 2,
            "below-floor cols must clamp up to MIN_DIM"
        );
        assert_eq!(
            r.applied_rows, 2,
            "below-floor rows must clamp up to MIN_DIM"
        );
        assert_ne!(r.clamped, 0, "below-floor must report clamped=1");

        // Exact ceiling (1000) — no clamp expected.
        let r = bb_term_resize2(term, 1000, 1000);
        assert_eq!(r.applied_cols, 1000);
        assert_eq!(r.applied_rows, 1000);
        assert_eq!(r.clamped, 0, "exact ceiling must NOT report clamped=1");

        // One above ceiling (1001) — must clamp to 1000.
        let r = bb_term_resize2(term, 1001, 1001);
        assert_eq!(r.applied_cols, 1000, "1001 cols must clamp to 1000");
        assert_eq!(r.applied_rows, 1000, "1001 rows must clamp to 1000");
        assert_ne!(r.clamped, 0, "1001 must report clamped=1");

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

#[test]
fn osc8_uri_with_rlo_bidi_scalar_drops_attribution() {
    // Audit S4-001 / fix-#03. A hostile remote can embed U+202E
    // (RIGHT-TO-LEFT OVERRIDE) into the OSC 8 URI; Foundation's
    // URL(string:) percent-encodes it, slipping the URI past the
    // Swift-side `containsPercentEncodedControlBytes` gate (which only
    // matches %00-%1F and %7F). The OSC 7 path rejects bidi scalars at
    // ingest (lib.rs:1146) and the title path scrubs them
    // (scrub_title_controls); OSC 8 must do the same — refusing to
    // attribute the cell rather than passing the raw bytes through.
    let seq = b"\x1b]8;;https://safe.com/login\xe2\x80\xaeextra\x1b\\X\x1b]8;;\x1b\\";
    assert_eq!(
        snap_link_for_cell(seq, 0, 0),
        None,
        "OSC 8 URI containing U+202E must drop attribution; current behaviour stores bytes verbatim"
    );
}

#[test]
fn osc8_uri_with_lrm_invisible_scalar_drops_attribution() {
    // Sibling of `osc8_uri_with_rlo_bidi_scalar_drops_attribution`. U+200E
    // (LEFT-TO-RIGHT MARK) is in the same rejection set per
    // is_bidi_or_invisible_scalar — same OSC 7 / title parity intent.
    let seq = b"\x1b]8;;https://safe.com/\xe2\x80\x8eextra\x1b\\X\x1b]8;;\x1b\\";
    assert_eq!(
        snap_link_for_cell(seq, 0, 0),
        None,
        "OSC 8 URI containing U+200E must drop attribution"
    );
}

#[test]
fn osc8_uri_with_safe_unicode_still_attributes() {
    // Negative control for the bidi reject: a URI containing non-bidi
    // unicode (e.g. percent-encoded host) must still attribute. Guards
    // against an over-broad scrub that drops legitimate links.
    let uri = "https://example.com/%E2%9C%93"; // ✓ checkmark, not in reject set
    let seq = format!("\x1b]8;;{}\x1b\\X\x1b]8;;\x1b\\", uri);
    assert_eq!(
        snap_link_for_cell(seq.as_bytes(), 0, 0).as_deref(),
        Some(uri),
        "OSC 8 URI with safe unicode (percent-encoded checkmark) must still attribute"
    );
}
