//! Pins `bb_term_grid_state`: the O(1), snapshot-free read of the live grid's
//! frame facts (`lines_scrolled`, `history_size`, shape, mode). Its reason to
//! exist is that `bb_term_take_snapshot` drains the damage set, so a reader
//! that is not the frame pipeline (copy, Services) must not use it to learn
//! how far the core has scrolled past the displayed frame.

use blackbird_core::*;

unsafe fn feed(term: *mut BBTerm, bytes: &[u8]) {
    bb_term_input(term, bytes.as_ptr(), bytes.len());
}

#[test]
fn layout_is_24_bytes_with_no_implicit_padding() {
    assert_eq!(std::mem::size_of::<BBGridState>(), 24);
    assert_eq!(std::mem::align_of::<BBGridState>(), 8);
}

#[test]
fn null_term_returns_all_zero() {
    unsafe {
        let s = bb_term_grid_state(std::ptr::null_mut());
        assert_eq!(s, BBGridState::default());
        assert_eq!(s.cols, 0, "cols == 0 is the host's 'unreadable' signal");
    }
}

#[test]
fn fields_match_the_snapshot_taken_at_the_same_moment() {
    unsafe {
        let term = bb_term_new(20, 4, 100);
        // Scroll 10 lines on the primary screen (4 rows) into history.
        let mut out = Vec::new();
        for i in 0..14 {
            out.extend_from_slice(format!("line{i}\r\n").as_bytes());
        }
        feed(term, &out);

        let state = bb_term_grid_state(term);
        let snap = bb_term_take_snapshot(term);
        assert!(!snap.is_null());
        let s = &*snap;
        assert_eq!(state.cols, s.cols);
        assert_eq!(state.rows, s.rows);
        assert_eq!(state.history_size, s.history_size);
        assert_eq!(state.lines_scrolled, s.lines_scrolled);
        assert_eq!(state.mode, s.mode);
        assert!(state.lines_scrolled > 0, "the feed must have scrolled");
        assert!(state.history_size > 0, "the feed must have filled history");
        bb_snap_release(snap);

        // Alt-screen: the mode bit follows, and the primary counter holds.
        let before = state.lines_scrolled;
        feed(term, b"\x1b[?1049h");
        let alt = bb_term_grid_state(term);
        assert_ne!(alt.mode & bb_mode::ALT_SCREEN, 0);
        assert_eq!(alt.lines_scrolled, before);
        bb_term_free(term);
    }
}

#[test]
fn reading_the_state_leaves_the_next_snapshots_damage_intact() {
    unsafe {
        let term = bb_term_new(20, 6, 100);
        feed(term, b"first");
        // The "published frame": drains the initial full damage.
        let published = bb_term_take_snapshot(term);
        bb_snap_release(published);

        // In-place rewrite of row 3 (no scroll), then the read under test.
        feed(term, b"\x1b[4;1H\x1b[2Kchanged");
        for _ in 0..3 {
            let _ = bb_term_grid_state(term);
        }

        let next = bb_term_take_snapshot(term);
        let damaged: Vec<u16> = if bb_snap_damage_is_full(next) != 0 {
            (0..6).collect()
        } else {
            let total = bb_snap_damage_rows(next, std::ptr::null_mut(), 0);
            let mut rows = vec![0u16; total];
            bb_snap_damage_rows(next, rows.as_mut_ptr(), rows.len());
            rows
        };
        assert!(
            damaged.contains(&3),
            "grid_state must not consume damage; got {damaged:?}"
        );
        assert_eq!(
            bb_snap_damage_is_full(next),
            0,
            "in-place output must still give a partial damage set"
        );
        bb_snap_release(next);
        bb_term_free(term);
    }
}
