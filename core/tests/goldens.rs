use std::fs;
use std::path::PathBuf;

/// Render the current grid as a plain-text string (rows joined by '\n',
/// trailing spaces per line stripped, trailing newlines stripped at end).
unsafe fn render_grid(term: *mut blackbird_core::BBTerm) -> String {
    let snap = blackbird_core::bb_term_take_snapshot(term);
    assert!(!snap.is_null(), "snapshot was null");
    let cols = (*snap).cols as usize;
    let rows = (*snap).rows as usize;
    let cells = std::slice::from_raw_parts((*snap).cells, (*snap).cells_len);

    let mut out = String::with_capacity((cols + 1) * rows);
    for r in 0..rows {
        let mut row = String::with_capacity(cols);
        for c in 0..cols {
            let idx = r * cols + c;
            let ch = cells[idx].ch;
            let glyph = if ch == 0 {
                ' '
            } else {
                char::from_u32(ch).unwrap_or('?')
            };
            row.push(glyph);
        }
        // Trim trailing spaces so the golden stays stable under cell-fill
        // quirks.
        while row.ends_with(' ') {
            row.pop();
        }
        out.push_str(&row);
        out.push('\n');
    }
    // Strip the final newline block from the bottom of the grid.
    while out.ends_with('\n') {
        out.pop();
    }

    blackbird_core::bb_snap_release(snap);
    out
}

fn golden_path(name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/goldens")
        .join(name)
}

fn assert_golden(name: &str, actual: &str) {
    let path = golden_path(&format!("{name}.golden"));
    let update = std::env::var("UPDATE_GOLDENS").is_ok();
    let exists = path.exists();
    if update || !exists {
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(&path, actual).unwrap();
        panic!(
            "golden '{name}.golden' written — rerun the test. Path: {:?}",
            path
        );
    }
    let expected = fs::read_to_string(&path).unwrap();
    assert_eq!(
        actual, expected,
        "golden '{name}.golden' mismatch — set UPDATE_GOLDENS=1 to regenerate"
    );
}

fn feed_fixture(term: *mut blackbird_core::BBTerm, fixture: &str) {
    let path = golden_path(fixture);
    let bytes = fs::read(&path).unwrap_or_else(|e| panic!("read {fixture}: {e}"));
    unsafe {
        blackbird_core::bb_term_input(term, bytes.as_ptr(), bytes.len());
    }
}

#[test]
fn golden_plain_ascii() {
    unsafe {
        let term = blackbird_core::bb_term_new(20, 5, 100);
        feed_fixture(term, "plain_ascii.bytes");
        let out = render_grid(term);
        assert_golden("plain_ascii", &out);
        blackbird_core::bb_term_free(term);
    }
}

#[test]
fn golden_csi_box() {
    unsafe {
        let term = blackbird_core::bb_term_new(20, 5, 100);
        feed_fixture(term, "csi_box.bytes");
        let out = render_grid(term);
        assert_golden("csi_box", &out);
        blackbird_core::bb_term_free(term);
    }
}

/// Cursor save / restore (DECSC / DECRC, ESC 7 / ESC 8) around a popup
/// must land the cursor back where it started. A common TUI pattern:
/// 1. ESC 7 (save cursor position)
/// 2. reposition + draw popup
/// 3. ESC 8 (restore) — user keeps typing at the original column
///
/// If alacritty ever drifts on this, the user's next keystroke would
/// echo in the wrong column.
#[test]
fn cursor_save_restore_around_popup() {
    unsafe {
        let term = blackbird_core::bb_term_new(40, 5, 100);
        // Type some text ending at col 6.
        let prefix = "hello ";
        blackbird_core::bb_term_input(term, prefix.as_ptr(), prefix.len());
        // Save cursor (ESC 7), draw popup elsewhere, restore (ESC 8).
        let popup = "\x1b7\x1b[3;1H[popup]\x1b[K\x1b8";
        blackbird_core::bb_term_input(term, popup.as_ptr(), popup.len());
        // Type "world" where the cursor should now be.
        let suffix = "world";
        blackbird_core::bb_term_input(term, suffix.as_ptr(), suffix.len());

        let out = render_grid(term);
        // Row 0 should read "hello world" — cursor was correctly restored.
        assert_eq!(
            out.lines().next().unwrap_or(""),
            "hello world",
            "cursor restored to saved position so suffix lands correctly"
        );
        blackbird_core::bb_term_free(term);
    }
}

/// Alt-screen enter / exit cycle: DECSET 1049 saves main-buffer +
/// switches to the alt screen; DECRST 1049 swaps back and restores
/// the saved cursor. Apps like `less`, `man`, `vim` use this pattern.
/// After exit, main-buffer content must be exactly as it was —
/// nothing leaked from the alt screen, scrollback intact.
#[test]
fn alt_screen_enter_exit_restores_main_buffer() {
    unsafe {
        let term = blackbird_core::bb_term_new(40, 5, 100);
        // Prime main buffer.
        let prime = b"\x1b[1;1HMAIN hello";
        blackbird_core::bb_term_input(term, prime.as_ptr(), prime.len());
        // DECSET 1049 — switch to alt screen.
        let enter = b"\x1b[?1049h";
        blackbird_core::bb_term_input(term, enter.as_ptr(), enter.len());
        // Draw junk on the alt screen.
        let alt = b"\x1b[1;1HALT garbage";
        blackbird_core::bb_term_input(term, alt.as_ptr(), alt.len());
        // DECRST 1049 — switch back. Main content should reappear.
        let exit = b"\x1b[?1049l";
        blackbird_core::bb_term_input(term, exit.as_ptr(), exit.len());

        let out = render_grid(term);
        let row0 = out.lines().next().unwrap_or("");
        assert_eq!(
            row0, "MAIN hello",
            "main buffer row 0 must restore after alt-screen exit; got {row0:?}"
        );
        assert!(
            !out.contains("ALT"),
            "alt-screen garbage must not leak into the main buffer"
        );
        blackbird_core::bb_term_free(term);
    }
}

/// Multi-row popup repaint: Claude Code-style `/btw` modal covers 5
/// rows. Dismissal repaints each row over the popup frame. Verify
/// every restored row matches the original content — this is the
/// shape of repaint the `/btw` bug report hinges on.
#[test]
fn multi_row_popup_dismissal_restores_all_rows() {
    unsafe {
        let term = blackbird_core::bb_term_new(40, 10, 100);
        // Prime 10 rows of distinct content.
        let bases: Vec<String> = (0..10).map(|i| format!("row {} base content", i)).collect();
        for (i, line) in bases.iter().enumerate() {
            let seq = format!("\x1b[{};1H{}", i + 1, line);
            blackbird_core::bb_term_input(term, seq.as_ptr(), seq.len());
        }
        // Draw a 5-row popup over rows 3–7 with varying widths.
        for (i, bar) in [
            "╭──────────── /btw ────────────╮",
            "│  Q: how do I paginate in ls? │",
            "│  A: use less                 │",
            "│  [Enter] dismiss             │",
            "╰──────────────────────────────╯",
        ]
        .iter()
        .enumerate()
        {
            let seq = format!("\x1b[{};1H{}\x1b[K", 3 + i, bar);
            blackbird_core::bb_term_input(term, seq.as_ptr(), seq.len());
        }
        // Dismiss by repainting each original row with a trailing EL.
        for i in 2..7 {
            let seq = format!("\x1b[{};1H{}\x1b[K", i + 1, bases[i]);
            blackbird_core::bb_term_input(term, seq.as_ptr(), seq.len());
        }
        let out = render_grid(term);
        for (i, expected) in bases.iter().enumerate() {
            let line = out.lines().nth(i).unwrap_or("");
            assert_eq!(
                line, expected,
                "row {i} must fully restore after multi-row popup dismissal; got {line:?}"
            );
        }
        blackbird_core::bb_term_free(term);
    }
}

/// Reproduce a Claude Code-style inline popup open / close cycle:
/// draw base text, overwrite a middle row with a "popup" bar using
/// cursor positioning + EL, then dismiss by re-emitting the original
/// row over the popup. Alacritty must land on the restored base text
/// — no ghost characters, no misplaced cursor. Without this, a bug
/// class like CVE-fix-candidate "partial-line EL leaves stale cells"
/// would silently regress under an alacritty_terminal upgrade.
#[test]
fn popup_open_close_restores_original_row() {
    unsafe {
        let term = blackbird_core::bb_term_new(40, 5, 100);
        // Draw 5 rows of visible content.
        for (i, line) in [
            "row 0 original content here",
            "row 1 original content here",
            "row 2 original content here",
            "row 3 original content here",
            "row 4 original content here",
        ]
        .iter()
        .enumerate()
        {
            // CUP (cursor position): ESC [ row+1 ; 1 H, then the line.
            let seq = format!("\x1b[{};1H{}", i + 1, line);
            blackbird_core::bb_term_input(term, seq.as_ptr(), seq.len());
        }
        // Claude Code-style popup: overwrite row 2 with a narrow "POPUP" bar
        // using CUP + text + EL (clear to end of line).
        let popup_open = "\x1b[3;1H╭─POPUP─╮\x1b[K";
        blackbird_core::bb_term_input(term, popup_open.as_ptr(), popup_open.len());
        // "Close" by rewriting the original content over the popup row,
        // again with EL to clear the residue.
        let popup_close = "\x1b[3;1Hrow 2 original content here\x1b[K";
        blackbird_core::bb_term_input(term, popup_close.as_ptr(), popup_close.len());

        let out = render_grid(term);
        for i in 0..5 {
            let expected = format!("row {} original content here", i);
            let line = out.lines().nth(i).unwrap_or("");
            assert_eq!(
                line, expected,
                "row {} must restore to original after popup close; got {:?}",
                i, line
            );
        }
        blackbird_core::bb_term_free(term);
    }
}
