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
