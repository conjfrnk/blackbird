//! Round-trip tests for the kitty keyboard protocol mode bits. The TUI enables
//! the protocol by emitting `ESC[>{flags}u` (push) or `ESC[={flags};{mode}u`
//! (set). alacritty_terminal's parser translates those into `TermMode` bits;
//! our FFI then mirrors them into `bb_mode`. Without these bits reaching Swift,
//! `KeyEncoder` cannot disambiguate Shift+Enter from plain Enter.

use blackbird_core::bb_mode;

unsafe fn feed(term: *mut blackbird_core::BBTerm, bytes: &[u8]) {
    blackbird_core::bb_term_input(term, bytes.as_ptr(), bytes.len());
}

unsafe fn mode(term: *mut blackbird_core::BBTerm) -> u32 {
    let snap = blackbird_core::bb_term_take_snapshot(term);
    assert!(!snap.is_null());
    let m = (*snap).mode;
    blackbird_core::bb_snap_release(snap);
    m
}

#[test]
fn push_flag_1_enables_disambiguate_only() {
    unsafe {
        let term = blackbird_core::bb_term_new(80, 24, 100);
        assert!(!term.is_null());

        // Before the TUI asks for anything, none of the kitty bits are lit.
        let before = mode(term);
        assert_eq!(before & bb_mode::DISAMBIGUATE_ESC_CODES, 0);
        assert_eq!(before & bb_mode::REPORT_EVENT_TYPES, 0);

        // `ESC[>1u` pushes a keyboard mode entry with flags=1 (disambiguate
        // escape codes). This is exactly what Claude Code, nvim 0.10+, and
        // WezTerm's kitty-aware shells send on startup.
        feed(term, b"\x1b[>1u");

        let after = mode(term);
        assert!(
            after & bb_mode::DISAMBIGUATE_ESC_CODES != 0,
            "disambiguate-esc-codes bit must light after ESC[>1u; mode=0x{:x}",
            after
        );
        // The other kitty bits must stay off — we only asked for flag 1.
        assert_eq!(after & bb_mode::REPORT_EVENT_TYPES, 0);
        assert_eq!(after & bb_mode::REPORT_ALTERNATE_KEYS, 0);
        assert_eq!(after & bb_mode::REPORT_ALL_KEYS_AS_ESC, 0);
        assert_eq!(after & bb_mode::REPORT_ASSOCIATED_TEXT, 0);

        blackbird_core::bb_term_free(term);
    }
}

#[test]
fn push_flag_31_enables_all_kitty_bits() {
    unsafe {
        let term = blackbird_core::bb_term_new(80, 24, 100);
        feed(term, b"\x1b[>31u");
        let m = mode(term);
        assert!(m & bb_mode::DISAMBIGUATE_ESC_CODES != 0);
        assert!(m & bb_mode::REPORT_EVENT_TYPES != 0);
        assert!(m & bb_mode::REPORT_ALTERNATE_KEYS != 0);
        assert!(m & bb_mode::REPORT_ALL_KEYS_AS_ESC != 0);
        assert!(m & bb_mode::REPORT_ASSOCIATED_TEXT != 0);
        blackbird_core::bb_term_free(term);
    }
}

#[test]
fn pop_restores_previous_state() {
    unsafe {
        let term = blackbird_core::bb_term_new(80, 24, 100);
        feed(term, b"\x1b[>1u"); // push flags=1
        assert!(mode(term) & bb_mode::DISAMBIGUATE_ESC_CODES != 0);

        // `ESC[<1u` pops one entry off the stack.
        feed(term, b"\x1b[<1u");
        assert_eq!(mode(term) & bb_mode::DISAMBIGUATE_ESC_CODES, 0);

        blackbird_core::bb_term_free(term);
    }
}
