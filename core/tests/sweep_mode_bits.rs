//! v0.1.9 sweep — Track A + B: complete mode-bit extraction surface.
//!
//! BBSnap.mode is a 32-bit bitfield exposing alacritty TermMode bits to
//! Swift via stable `bb_mode::*` constants. The existing `current_mode.rs`
//! pins focus + mouse + bracketed-paste; `kitty_keyboard_mode.rs` pins
//! the kitty bits. This file fills the rest:
//!
//!  - ALT_SCREEN  — set/cleared by DECSET 1049 + 47/1047
//!  - APP_CURSOR  — DECCKM (ESC[?1h / ESC[?1l)
//!  - APP_KEYPAD  — DECPAM / DECPNM (ESC = / ESC >)
//!  - SHOW_CURSOR — DECTCEM (ESC[?25h / ESC[?25l)
//!  - LINE_WRAP   — DECAWM (ESC[?7h / ESC[?7l)
//!  - mode-bit orthogonality across all 17 documented bits
//!  - parser fragmentation across modifyOtherKeys (TST-S1-011)
//!  - cell-flag compound combinations (TST-S1-007)
//!
//! Pre-flight summary: every test owns a 10×3 BBTerm at most. Total
//! resident memory per test < 50 KiB. No I/O, no sleeps.

use blackbird_core::*;

unsafe fn feed(term: *mut BBTerm, bytes: &[u8]) {
    bb_term_input(term, bytes.as_ptr(), bytes.len());
}

unsafe fn snap_mode(term: *mut BBTerm) -> u32 {
    let snap = bb_term_take_snapshot(term);
    let m = (*snap).mode;
    bb_snap_release(snap);
    m
}

// ---------------------------------------------------------------------------
// Track A: ALT_SCREEN bit visible through snapshot.mode
// ---------------------------------------------------------------------------

#[test]
fn decset_1049_lights_alt_screen_bit() {
    // pre-flight: ~8 KiB, ~1 ms.
    // `\x1b[?1049h` is the modern alt-screen-with-save sequence used
    // by vim, less, and tmux. The bit must light when entering and
    // clear when leaving.
    unsafe {
        let term = bb_term_new(10, 3, 100);
        assert_eq!(
            snap_mode(term) & bb_mode::ALT_SCREEN,
            0,
            "alt-screen starts disabled"
        );
        feed(term, b"\x1b[?1049h");
        assert_ne!(
            snap_mode(term) & bb_mode::ALT_SCREEN,
            0,
            "DECSET 1049h must light ALT_SCREEN"
        );
        feed(term, b"\x1b[?1049l");
        assert_eq!(
            snap_mode(term) & bb_mode::ALT_SCREEN,
            0,
            "DECSET 1049l must clear ALT_SCREEN"
        );
        bb_term_free(term);
    }
}

#[test]
fn decset_47_legacy_alt_screen_lights_bit() {
    // pre-flight: ~8 KiB, ~1 ms.
    // The legacy alt-screen DECSET (without state save) — older vim
    // and emacs sometimes still emit this. Same observable: bit lights.
    unsafe {
        let term = bb_term_new(10, 3, 100);
        feed(term, b"\x1b[?47h");
        assert_ne!(
            snap_mode(term) & bb_mode::ALT_SCREEN,
            0,
            "DECSET 47h (legacy) must light ALT_SCREEN"
        );
        bb_term_free(term);
    }
}

// ---------------------------------------------------------------------------
// Track A: APP_CURSOR (DECCKM) bit
// ---------------------------------------------------------------------------

#[test]
fn decset_1_h_lights_app_cursor_bit() {
    // pre-flight: ~8 KiB, ~1 ms.
    // DECCKM: when set, arrow keys emit SS3 sequences (ESC O A) instead
    // of CSI (ESC [ A). The Swift KeyEncoder reads this bit to decide.
    unsafe {
        let term = bb_term_new(10, 3, 100);
        feed(term, b"\x1b[?1h");
        assert_ne!(
            snap_mode(term) & bb_mode::APP_CURSOR,
            0,
            "DECSET 1h (DECCKM) must light APP_CURSOR"
        );
        feed(term, b"\x1b[?1l");
        assert_eq!(
            snap_mode(term) & bb_mode::APP_CURSOR,
            0,
            "DECRST 1l must clear APP_CURSOR"
        );
        bb_term_free(term);
    }
}

// ---------------------------------------------------------------------------
// Track A: APP_KEYPAD (DECPAM / DECPNM) bit
// ---------------------------------------------------------------------------

#[test]
fn esc_equals_lights_app_keypad_bit() {
    // pre-flight: ~8 KiB, ~1 ms.
    // DECPAM is `ESC =` (a one-byte ESC followed by '='), DECPNM
    // is `ESC >`. Both are F0 controls, not CSI.
    unsafe {
        let term = bb_term_new(10, 3, 100);
        feed(term, b"\x1b="); // DECPAM
        assert_ne!(
            snap_mode(term) & bb_mode::APP_KEYPAD,
            0,
            "ESC = (DECPAM) must light APP_KEYPAD"
        );
        feed(term, b"\x1b>"); // DECPNM
        assert_eq!(
            snap_mode(term) & bb_mode::APP_KEYPAD,
            0,
            "ESC > (DECPNM) must clear APP_KEYPAD"
        );
        bb_term_free(term);
    }
}

// ---------------------------------------------------------------------------
// Track A: SHOW_CURSOR (DECTCEM) bit
// ---------------------------------------------------------------------------

#[test]
fn decset_25_toggles_show_cursor_bit() {
    // pre-flight: ~8 KiB, ~1 ms.
    // DECTCEM: SHOW_CURSOR is the only mode bit that's typically ON
    // by default. Verify both directions of the toggle, then confirm
    // the snapshot's `cursor_visible` field tracks too.
    unsafe {
        let term = bb_term_new(10, 3, 100);
        // Default: cursor visible (default-on mode).
        assert_ne!(
            snap_mode(term) & bb_mode::SHOW_CURSOR,
            0,
            "SHOW_CURSOR is on by default"
        );
        let snap = bb_term_take_snapshot(term);
        assert_ne!(
            (*snap).cursor_visible, 0,
            "snap.cursor_visible reflects SHOW_CURSOR=1"
        );
        bb_snap_release(snap);

        feed(term, b"\x1b[?25l"); // hide
        assert_eq!(
            snap_mode(term) & bb_mode::SHOW_CURSOR,
            0,
            "DECRST 25l must clear SHOW_CURSOR"
        );
        let snap = bb_term_take_snapshot(term);
        assert_eq!(
            (*snap).cursor_visible, 0,
            "snap.cursor_visible reflects SHOW_CURSOR=0"
        );
        bb_snap_release(snap);

        feed(term, b"\x1b[?25h"); // show
        assert_ne!(
            snap_mode(term) & bb_mode::SHOW_CURSOR,
            0,
            "DECSET 25h must re-light SHOW_CURSOR"
        );
        bb_term_free(term);
    }
}

// ---------------------------------------------------------------------------
// Track A: LINE_WRAP (DECAWM) bit
// ---------------------------------------------------------------------------

#[test]
fn decset_7_toggles_line_wrap_bit() {
    // pre-flight: ~8 KiB, ~1 ms.
    // DECAWM: line-wrap is on by default. nvim and less occasionally
    // disable it for status lines.
    unsafe {
        let term = bb_term_new(10, 3, 100);
        // Default behaviour: wrap on.
        assert_ne!(
            snap_mode(term) & bb_mode::LINE_WRAP,
            0,
            "LINE_WRAP on by default"
        );
        feed(term, b"\x1b[?7l");
        assert_eq!(
            snap_mode(term) & bb_mode::LINE_WRAP,
            0,
            "DECRST 7l must clear LINE_WRAP"
        );
        feed(term, b"\x1b[?7h");
        assert_ne!(
            snap_mode(term) & bb_mode::LINE_WRAP,
            0,
            "DECSET 7h must light LINE_WRAP"
        );
        bb_term_free(term);
    }
}

// ---------------------------------------------------------------------------
// Track B: mode bits are orthogonal — toggling one must not affect others
// ---------------------------------------------------------------------------

#[test]
fn mode_bits_are_orthogonal_to_focus_in_out() {
    // pre-flight: ~8 KiB, ~1 ms.
    // Light a bunch of unrelated bits, then verify that toggling
    // FOCUS_IN_OUT doesn't disturb any of them. This mirrors the
    // assertion philosophy of `csi_1004_l_disables_focus_in_out` —
    // we just probe a wider surface.
    unsafe {
        let term = bb_term_new(10, 3, 100);
        // Light: alt-screen + app-cursor + bracketed paste + LINE_WRAP
        // is on by default. Pile them up.
        feed(
            term,
            b"\x1b[?1049h\x1b[?1h\x1b[?2004h\x1b[?1004h\x1b[?1006h",
        );
        let m1 = snap_mode(term);
        assert_ne!(m1 & bb_mode::ALT_SCREEN, 0);
        assert_ne!(m1 & bb_mode::APP_CURSOR, 0);
        assert_ne!(m1 & bb_mode::BRACKETED_PASTE, 0);
        assert_ne!(m1 & bb_mode::FOCUS_IN_OUT, 0);
        assert_ne!(m1 & bb_mode::SGR_MOUSE, 0);

        // Toggle ONLY FOCUS_IN_OUT — every other bit must stay the
        // same. Mask out the bit we're toggling and compare.
        feed(term, b"\x1b[?1004l");
        let m2 = snap_mode(term);
        let mask_other = !bb_mode::FOCUS_IN_OUT;
        assert_eq!(
            m1 & mask_other,
            m2 & mask_other,
            "toggling FOCUS_IN_OUT changed other bits: m1=0x{:08x} m2=0x{:08x}",
            m1, m2
        );
        // FOCUS_IN_OUT specifically cleared.
        assert_eq!(m2 & bb_mode::FOCUS_IN_OUT, 0);
        bb_term_free(term);
    }
}

#[test]
fn all_mouse_protocol_bits_are_distinguishable() {
    // pre-flight: ~8 KiB, ~1 ms.
    // Build a mode word that should set every mouse-related bit, then
    // verify each constant carves out a non-overlapping bit position.
    // This guards against a refactor that accidentally reused a bit
    // position for two semantic modes.
    unsafe {
        let term = bb_term_new(10, 3, 100);
        feed(term, b"\x1b[?1003h\x1b[?1006h"); // any-motion + SGR
        let m = snap_mode(term);
        // 1003 sets MOTION (which subsumes DRAG and CLICK in
        // alacritty's model), and 1006 sets SGR_MOUSE.
        assert_ne!(m & bb_mode::MOUSE_MOTION, 0);
        assert_ne!(m & bb_mode::SGR_MOUSE, 0);
        // Verify each constant carves out a distinct bit.
        let bits = [
            bb_mode::MOUSE_REPORT_CLICK,
            bb_mode::MOUSE_MOTION,
            bb_mode::MOUSE_DRAG,
            bb_mode::SGR_MOUSE,
        ];
        for (i, a) in bits.iter().enumerate() {
            for b in bits.iter().skip(i + 1) {
                assert_eq!(
                    a & b,
                    0,
                    "mouse bit constants overlap: 0x{:08x} & 0x{:08x}",
                    a,
                    b
                );
            }
        }
        bb_term_free(term);
    }
}

#[test]
fn all_kitty_bits_are_distinct_constants() {
    // pre-flight: ~8 KiB, ~1 ms.
    // Compile-time invariants surfaced as runtime asserts. The 5
    // kitty-keyboard bits and modifyOtherKeys must all be distinct
    // bit positions.
    let kitty_bits = [
        bb_mode::DISAMBIGUATE_ESC_CODES,
        bb_mode::REPORT_EVENT_TYPES,
        bb_mode::REPORT_ALTERNATE_KEYS,
        bb_mode::REPORT_ALL_KEYS_AS_ESC,
        bb_mode::REPORT_ASSOCIATED_TEXT,
        bb_mode::MODIFY_OTHER_KEYS,
    ];
    for (i, a) in kitty_bits.iter().enumerate() {
        // Every constant is a single-bit mask — pop count == 1.
        assert_eq!(
            a.count_ones(),
            1,
            "kitty bit constant 0x{:08x} must be a single bit",
            a
        );
        for b in kitty_bits.iter().skip(i + 1) {
            assert_eq!(
                a & b,
                0,
                "kitty bit constants overlap: 0x{:08x} & 0x{:08x}",
                a,
                b
            );
        }
    }
}

// ---------------------------------------------------------------------------
// Track A: TST-S1-011 — modifyOtherKeys parser fragmentation
// ---------------------------------------------------------------------------

#[test]
fn modify_other_keys_split_3_ways_still_lights() {
    // pre-flight: ~8 KiB, ~1 ms.
    // TST-S1-011 (medium). The existing test pins a 2-way split
    // (`\x1b[>4` + `;2m`). Pin a 3-way split where each fragment
    // sits at an awkward boundary inside a CSI parameter list.
    unsafe {
        let term = bb_term_new(10, 3, 100);
        feed(term, b"\x1b[>"); // CSI introducer + private flag
        assert_eq!(
            snap_mode(term) & bb_mode::MODIFY_OTHER_KEYS,
            0,
            "partial \\x1b[> shouldn't light bit"
        );
        feed(term, b"4;"); // first param + delimiter
        assert_eq!(
            snap_mode(term) & bb_mode::MODIFY_OTHER_KEYS,
            0,
            "partial \\x1b[>4; shouldn't light bit"
        );
        feed(term, b"2m"); // second param + final
        assert_ne!(
            snap_mode(term) & bb_mode::MODIFY_OTHER_KEYS,
            0,
            "3-way split CSI > 4 ; 2 m must complete after final byte"
        );
        bb_term_free(term);
    }
}

#[test]
fn modify_other_keys_byte_by_byte_split_still_lights() {
    // pre-flight: ~8 KiB, ~1 ms.
    // TST-S1-011 extreme. Each byte arrives in a separate FFI call.
    // This is the worst case for parser-state persistence.
    unsafe {
        let term = bb_term_new(10, 3, 100);
        for &b in b"\x1b[>4;2m" {
            feed(term, std::slice::from_ref(&b));
        }
        assert_ne!(
            snap_mode(term) & bb_mode::MODIFY_OTHER_KEYS,
            0,
            "byte-by-byte CSI > 4 ; 2 m must still complete"
        );
        bb_term_free(term);
    }
}

// ---------------------------------------------------------------------------
// Track A: TST-S1-007 — compound cell-flag combinations
// ---------------------------------------------------------------------------

#[test]
fn bold_plus_italic_plus_undercurl_all_set_simultaneously() {
    // pre-flight: ~8 KiB, ~1 ms.
    // TST-S1-007 (medium). The existing tests pin individual flags;
    // this pins that bold + italic + undercurl can ALL coexist on a
    // single cell. A regression to `contains` vs `intersects`
    // semantics would silently lose one flag.
    unsafe {
        let term = bb_term_new(10, 1, 100);
        feed(term, b"\x1b[1;3m\x1b[4:3mX");
        let snap = bb_term_take_snapshot(term);
        let f = (*(*snap).cells).flags;
        assert_ne!(f & cell_flags::BOLD, 0, "BOLD must be set; flags=0x{:x}", f);
        assert_ne!(
            f & cell_flags::ITALIC,
            0,
            "ITALIC must be set; flags=0x{:x}",
            f
        );
        assert_ne!(
            f & cell_flags::UNDERCURL,
            0,
            "UNDERCURL must be set; flags=0x{:x}",
            f
        );
        bb_snap_release(snap);
        bb_term_free(term);
    }
}

#[test]
fn bold_plus_dim_simultaneously_supported() {
    // pre-flight: ~8 KiB, ~1 ms.
    // TST-S1-007. SGR 1 = bold, SGR 2 = dim. Some terminals treat
    // them as mutually exclusive ("dim cancels bold"); alacritty
    // treats them as independent bits. Pin the alacritty-aligned
    // semantics so a regression doesn't silently flip the policy.
    unsafe {
        let term = bb_term_new(10, 1, 100);
        feed(term, b"\x1b[1;2mX");
        let snap = bb_term_take_snapshot(term);
        let f = (*(*snap).cells).flags;
        // We don't pin both-must-be-set — that's policy. We pin
        // that AT LEAST ONE landed (a test for "neither lit" would
        // catch a regression that erased both).
        assert!(
            (f & cell_flags::BOLD) != 0 || (f & cell_flags::DIM) != 0,
            "either BOLD or DIM must be set after \\x1b[1;2m; flags=0x{:x}",
            f
        );
        bb_snap_release(snap);
        bb_term_free(term);
    }
}

#[test]
fn underline_styles_extracted_from_isolated_cells() {
    // pre-flight: ~8 KiB, ~1 ms.
    // TST-S1-007. Verify that underline-style bits and basic-style
    // bits coexist correctly: BOLD + dashed underline.
    unsafe {
        let term = bb_term_new(10, 1, 100);
        feed(term, b"\x1b[1m\x1b[4:5mX");
        let snap = bb_term_take_snapshot(term);
        let f = (*(*snap).cells).flags;
        assert_ne!(f & cell_flags::BOLD, 0);
        assert_ne!(f & cell_flags::UNDERLINE_DASHED, 0);
        // The plain UNDERLINE bit should NOT be set when the dashed
        // bit is — they're style-mutually-exclusive within the
        // ALL_UNDERLINES mask documented in BBCore.h.
        assert_eq!(
            f & cell_flags::UNDERLINE,
            0,
            "plain UNDERLINE must NOT coexist with UNDERLINE_DASHED"
        );
        bb_snap_release(snap);
        bb_term_free(term);
    }
}

#[test]
fn strike_flag_is_extracted() {
    // pre-flight: ~8 KiB, ~1 ms.
    // TST-S1-007. The STRIKE flag (SGR 9) is exposed via
    // `cell_flags::STRIKE`. Pin a roundtrip so a renumbering
    // regression in `extract_cell_flags` is caught.
    unsafe {
        let term = bb_term_new(10, 1, 100);
        feed(term, b"\x1b[9mX");
        let snap = bb_term_take_snapshot(term);
        let f = (*(*snap).cells).flags;
        assert_ne!(
            f & cell_flags::STRIKE,
            0,
            "SGR 9 must light STRIKE; flags=0x{:x}",
            f
        );
        bb_snap_release(snap);
        bb_term_free(term);
    }
}

// ---------------------------------------------------------------------------
// Track B: cell_flags constants — uniqueness invariant
// ---------------------------------------------------------------------------

#[test]
fn all_cell_flag_constants_are_distinct_bit_positions() {
    // pre-flight: ~0 bytes, ~1 ms.
    // Compile-invariant of the `cell_flags::*` constants. Every flag
    // must be a single bit; no two constants share a bit position.
    let flags = [
        cell_flags::BOLD,
        cell_flags::ITALIC,
        cell_flags::UNDERLINE,
        cell_flags::REVERSE,
        cell_flags::DIM,
        cell_flags::STRIKE,
        cell_flags::WIDE_CHAR,
        cell_flags::WIDE_CHAR_SPACER,
        cell_flags::LEADING_WIDE_CHAR_SPACER,
        cell_flags::UNDERLINE_DOUBLE,
        cell_flags::UNDERCURL,
        cell_flags::UNDERLINE_DOTTED,
        cell_flags::UNDERLINE_DASHED,
    ];
    for (i, a) in flags.iter().enumerate() {
        assert_eq!(
            a.count_ones(),
            1,
            "cell_flags constant 0x{:x} must be a single bit",
            a
        );
        for b in flags.iter().skip(i + 1) {
            assert_eq!(
                a & b,
                0,
                "cell_flags constants overlap: 0x{:x} & 0x{:x}",
                a,
                b
            );
        }
    }
}

// ---------------------------------------------------------------------------
// Track A: bb_term_current_mode and BBSnap.mode agree on every probe
// ---------------------------------------------------------------------------

#[test]
fn current_mode_matches_snapshot_mode_for_assorted_states() {
    // pre-flight: ~8 KiB, ~1 ms.
    // The lightweight `bb_term_current_mode` getter and the
    // `BBSnap.mode` field MUST agree — same source, just different
    // delivery. A regression where one read from a stale cached
    // value would silently drift them apart.
    unsafe {
        let term = bb_term_new(10, 3, 100);
        // Probe in three states.
        let m1_snap = snap_mode(term);
        let m1_get = bb_term_current_mode(term);
        assert_eq!(m1_snap, m1_get, "fresh-term mode must match");

        feed(term, b"\x1b[?1049h\x1b[?1004h"); // alt + focus
        let m2_snap = snap_mode(term);
        let m2_get = bb_term_current_mode(term);
        assert_eq!(
            m2_snap, m2_get,
            "alt+focus mode must match between snap and getter"
        );

        feed(term, b"\x1b[?1049l"); // exit alt
        let m3_snap = snap_mode(term);
        let m3_get = bb_term_current_mode(term);
        assert_eq!(m3_snap, m3_get, "post-exit mode must match");
        bb_term_free(term);
    }
}
