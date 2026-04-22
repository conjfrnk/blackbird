//! Regression for rust-tests F29. The goldens file already pins the
//! OUTBOUND direction of alt-screen isolation (main-buffer content
//! survives an alt-screen round-trip). This file pins the INVERSE:
//! scrollback from the main buffer must NOT be reachable from the alt
//! screen. This is a known iTerm2-class pitfall where users scrolling
//! on alt-screen could see the content the alt-screen app was trying
//! to hide.

use blackbird_core as bc;

/// Render the visible grid to a single newline-joined string (trailing
/// spaces per row stripped). Does NOT include scrollback — we want to
/// see what's CURRENTLY visible in the viewport.
unsafe fn visible_text(term: *mut bc::BBTerm) -> String {
    let snap = bc::bb_term_take_snapshot(term);
    let cols = (*snap).cols as usize;
    let rows = (*snap).rows as usize;
    let cells = std::slice::from_raw_parts((*snap).cells, (*snap).cells_len);
    let mut out = String::with_capacity((cols + 1) * rows);
    for r in 0..rows {
        let mut row = String::with_capacity(cols);
        for c in 0..cols {
            let ch = cells[r * cols + c].ch;
            row.push(if ch == 0 {
                ' '
            } else {
                char::from_u32(ch).unwrap_or('?')
            });
        }
        while row.ends_with(' ') {
            row.pop();
        }
        out.push_str(&row);
        out.push('\n');
    }
    bc::bb_snap_release(snap);
    out
}

#[test]
fn alt_screen_does_not_expose_main_buffer_scrollback() {
    // Regression for rust-tests F29. Feed 100 distinct main-buffer lines
    // into a small viewport so the first 80-ish get pushed into scrollback.
    // Then enter alt-screen via DECSET 1049 and attempt to scroll up. The
    // alt-screen viewport must stay blank (or show only alt-screen
    // content) — main-buffer history must NOT be reachable from the alt
    // screen.
    unsafe {
        let term = bc::bb_term_new(20, 10, 1_000);
        assert!(!term.is_null());

        // Feed 100 distinct lines so the main buffer has a meaningful
        // scrollback tail. Each line is "MAINxxx" (6 chars) followed by
        // a newline — small enough to run fast, distinctive enough to
        // detect any leak.
        for i in 0..100 {
            let line = format!("MAIN{:03}\n", i);
            bc::bb_term_input(term, line.as_ptr(), line.len());
        }

        // Switch to alt screen. DECSET 1049 saves main + switches.
        let enter = b"\x1b[?1049h";
        bc::bb_term_input(term, enter.as_ptr(), enter.len());

        // Try to scroll up inside the alt screen. Alacritty's
        // `scroll_display` shouldn't offer any scrollback on the alt
        // screen — alt screens are traditionally a single-viewport
        // buffer with no history. This call must not panic, and must
        // not reveal main-buffer content.
        bc::bb_term_scroll(term, 50);

        let alt_view = visible_text(term);
        // Exit alt screen for the test term's cleanup.
        let exit = b"\x1b[?1049l";
        bc::bb_term_input(term, exit.as_ptr(), exit.len());
        bc::bb_term_free(term);

        // The alt-screen view must NOT contain any MAIN* token. If a
        // "MAIN" string appears, main-buffer scrollback leaked into the
        // alt-screen viewport.
        assert!(
            !alt_view.contains("MAIN"),
            "main-buffer scrollback must not be visible on alt-screen; \
             got alt_view: {alt_view:?}"
        );
    }
}

#[test]
fn alt_screen_display_offset_is_zero_after_enter() {
    // Regression for rust-tests F29 (companion). Even before any scroll
    // attempt, entering alt-screen must reset display_offset to 0 — a
    // regression that let the alt screen inherit the main buffer's
    // mid-scroll display_offset would reveal scrollback immediately.
    unsafe {
        let term = bc::bb_term_new(20, 10, 1_000);
        // Seed scrollback-bearing content on main.
        for i in 0..100 {
            let line = format!("MAIN{:03}\n", i);
            bc::bb_term_input(term, line.as_ptr(), line.len());
        }
        // Scroll main up to a non-zero offset.
        bc::bb_term_scroll(term, 20);
        let snap = bc::bb_term_take_snapshot(term);
        let off_main = (*snap).display_offset;
        bc::bb_snap_release(snap);
        assert!(
            off_main > 0,
            "precondition: main buffer must be mid-scroll; got offset {off_main}"
        );

        // Enter alt screen.
        let enter = b"\x1b[?1049h";
        bc::bb_term_input(term, enter.as_ptr(), enter.len());
        let snap = bc::bb_term_take_snapshot(term);
        let off_alt = (*snap).display_offset;
        bc::bb_snap_release(snap);
        assert_eq!(
            off_alt, 0,
            "alt-screen display_offset must reset to 0; got {off_alt}"
        );

        let exit = b"\x1b[?1049l";
        bc::bb_term_input(term, exit.as_ptr(), exit.len());
        bc::bb_term_free(term);
    }
}
