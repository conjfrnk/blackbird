//! Blind regression tests for "narrow-then-widen with the cursor on viewport
//! row 0 strands the line in scrollback".
//!
//! Written against the public C FFI surface (`core/include/BBCore.h`) and the
//! documented/conventional terminal behaviour only, never the implementation.
//!
//! Contract under test (primary screen, reflow on, no output between the two
//! resizes):
//!   - A column resize re-wraps the soft-wrapped line the cursor is on
//!     ("reflow"). Narrowing splits it over several rows; widening joins those
//!     rows again. Narrow-then-widen is therefore the identity on a line that
//!     fits the viewport: the text is back on the row it started on, the
//!     cursor is back right after the text (not pending-wrap, not at the
//!     origin) and nothing was pushed into scrollback, because nothing was
//!     ever pushed off the screen -- the viewport has free rows below.
//!   - Consequently the next typed character lands right after the text on
//!     the same row, exactly as before the resizes.
//!
//! How the bug is observed: with the line on viewport ROW 0 (fresh tab, or
//! after a clear), the widen leaves the viewport blank, the line moves to
//! scrollback (`history_size` grows by one, `bb_term_text_range` over negative
//! lines returns it) and the cursor is reported at (0, 0) with
//! `cursor_pending_wrap == 1`, so the next character lands on row 1. Each
//! cycle leaves one more stale duplicate in scrollback. The same line on row 1
//! or lower is reflowed correctly, which the control test pins.
//!
//! Observation path: `bb_term_take_snapshot` read cell by cell into one string
//! per row (blank cells, `ch == 0`, shown as `' '`, trailing blanks trimmed),
//! the snapshot's cursor / pending-wrap / `history_size` / `display_offset`
//! fields, and `bb_term_text_range` over negative (scrollback) lines for the
//! scrollback text. Whole observations are compared at once so a failure
//! prints every measured value next to the expected one.
//!
//! Rig preconditions (asserted in every test via `Rig`): the pre-resize
//! screen holds exactly the typed line with the cursor right after it and no
//! scrollback beyond what the case seeded, each resize is applied unclamped
//! at the requested dims, and the narrow step really wrapped the line over
//! several rows (so the widen has something to join). A green run therefore
//! cannot mean "nothing was ever wrapped".
//!
//! Pre-flight cost: grids <= 20x6 with scrollback <= 100 -> a few KB per
//! terminal; inputs < 200 bytes in total. No sleeps, I/O, or threads.

use blackbird_core as bc;

/// Everything about the terminal that the contract speaks about, in one value
/// so a failing `assert_eq!` prints it whole.
#[derive(Debug, PartialEq, Eq, Clone)]
struct Observed {
    /// One string per viewport row, trailing blanks trimmed.
    rows: Vec<String>,
    /// (cursor_col, cursor_row, cursor_pending_wrap)
    cursor: (u16, u16, u8),
    history_size: u32,
    display_offset: u32,
}

/// A live terminal plus helpers; freed on drop so a failed assertion cannot
/// leak a handle.
struct Rig {
    term: *mut bc::BBTerm,
    cols: u16,
    rows: u16,
}

impl Drop for Rig {
    fn drop(&mut self) {
        unsafe { bc::bb_term_free(self.term) };
    }
}

impl Rig {
    fn new(cols: u16, rows: u16, scrollback: u32) -> Rig {
        let term = unsafe { bc::bb_term_new(cols, rows, scrollback) };
        assert!(
            !term.is_null(),
            "bb_term_new({cols}, {rows}, {scrollback}) returned null"
        );
        Rig { term, cols, rows }
    }

    fn feed(&self, s: &str) {
        unsafe { bc::bb_term_input(self.term, s.as_ptr(), s.len()) };
    }

    /// Resize and assert the request was applied verbatim (unclamped).
    fn resize(&mut self, cols: u16, rows: u16) {
        let r = unsafe { bc::bb_term_resize2(self.term, cols, rows) };
        assert_eq!(
            (r.applied_cols, r.applied_rows, r.clamped),
            (cols, rows, 0),
            "precondition: resize2({cols}, {rows}) must apply unclamped \
             (applied_cols, applied_rows, clamped)"
        );
        self.cols = cols;
        self.rows = rows;
    }

    fn observe(&self) -> Observed {
        unsafe {
            let snap = bc::bb_term_take_snapshot(self.term);
            assert!(!snap.is_null(), "bb_term_take_snapshot returned null");
            let cols = (*snap).cols;
            let rows = (*snap).rows;
            assert_eq!(
                (cols, rows),
                (self.cols, self.rows),
                "snapshot dims must equal the dims last applied"
            );
            let n = cols as usize * rows as usize;
            assert_eq!((*snap).cells_len, n, "snapshot cells_len must be cols*rows");
            let cells = std::slice::from_raw_parts((*snap).cells, n);
            let row_texts: Vec<String> = (0..rows as usize)
                .map(|r| {
                    let line: String = cells[r * cols as usize..(r + 1) * cols as usize]
                        .iter()
                        .map(|c| {
                            if c.ch == 0 {
                                ' '
                            } else {
                                char::from_u32(c.ch).unwrap_or('\u{FFFD}')
                            }
                        })
                        .collect();
                    line.trim_end().to_string()
                })
                .collect();
            let obs = Observed {
                rows: row_texts,
                cursor: (
                    (*snap).cursor_col,
                    (*snap).cursor_row,
                    (*snap).cursor_pending_wrap,
                ),
                history_size: (*snap).history_size,
                display_offset: (*snap).display_offset,
            };
            bc::bb_snap_release(snap);
            obs
        }
    }

    /// Scrollback AND viewport text in one prose-mode copy (soft-wrapped rows
    /// are rejoined by the copy path, so a wrapped line reads back whole),
    /// trimmed at both ends. Independent of where the narrow step put the
    /// wrapped rows (viewport or scrollback).
    fn whole_buffer_text(&self) -> String {
        unsafe {
            let raw =
                bc::bb_term_text_range(self.term, -500, 0, self.rows as i32 - 1, self.cols - 1, 0);
            assert!(!raw.is_null(), "bb_term_text_range returned null");
            let bytes: &[u8] = if (*raw).len == 0 || (*raw).bytes.is_null() {
                &[]
            } else {
                std::slice::from_raw_parts((*raw).bytes, (*raw).len)
            };
            let s = std::str::from_utf8(bytes)
                .expect("text_range reply must be valid UTF-8")
                .to_string();
            bc::bb_string_release(raw);
            s.trim().to_string()
        }
    }

    /// All scrollback text (prose mode, one `\n`-joined string), via the copy
    /// path. Asks for far more history than any case can hold; lines outside
    /// the buffer are skipped silently by the API.
    fn scrollback_text(&self) -> String {
        unsafe {
            let raw = bc::bb_term_text_range(self.term, -500, 0, -1, self.cols - 1, 0);
            assert!(!raw.is_null(), "bb_term_text_range returned null");
            let bytes: &[u8] = if (*raw).len == 0 || (*raw).bytes.is_null() {
                &[]
            } else {
                std::slice::from_raw_parts((*raw).bytes, (*raw).len)
            };
            let s = std::str::from_utf8(bytes)
                .expect("text_range reply must be valid UTF-8")
                .to_string();
            bc::bb_string_release(raw);
            s.trim_end().to_string()
        }
    }
}

/// `rows` padded with blank rows to `n` entries.
fn padded(rows: &[&str], n: usize) -> Vec<String> {
    let mut v: Vec<String> = rows.iter().map(|s| s.to_string()).collect();
    assert!(
        v.len() <= n,
        "bad case: {} rows given for a {n}-row grid",
        v.len()
    );
    v.resize(n, String::new());
    v
}

/// Precondition shared by the history-free cases, asserted right after the
/// narrow step: the typed `line` has really been wrapped (no viewport row holds
/// it whole) and nothing was lost (scrollback + viewport together still read
/// back exactly `line`). Deliberately silent about WHERE the wrapped rows sit
/// (viewport vs scrollback): only the state after the widen is the contract.
fn assert_wrapped(t: &Rig, line: &str, label: &str) {
    let obs = t.observe();
    assert!(
        !obs.rows.iter().any(|r| r == line),
        "{label}: precondition: after narrowing, no viewport row may hold {line:?} whole (it \
         must have wrapped); observed {obs:?}"
    );
    assert_eq!(
        t.whole_buffer_text(),
        line,
        "{label}: precondition: after narrowing, scrollback + viewport must still read back \
         exactly the typed line; observed {obs:?}"
    );
}

/// The pre-resize rig for the smallest reported case: a 10x4 grid whose top
/// row holds "hello" with the cursor right after it, then a narrow step to 4
/// columns. Returns the rig AFTER the narrow step with its preconditions
/// asserted.
fn hello_narrowed() -> Rig {
    let mut t = Rig::new(10, 4, 100);
    t.feed("hello");
    assert_eq!(
        t.observe(),
        Observed {
            rows: padded(&["hello"], 4),
            cursor: (5, 0, 0),
            history_size: 0,
            display_offset: 0,
        },
        "precondition: 'hello' typed on the top row of a fresh 10x4 grid"
    );
    t.resize(4, 4);
    assert_wrapped(&t, "hello", "10->4");
    t
}

/// The expected state once the widen has restored the original geometry.
fn hello_restored() -> Observed {
    Observed {
        rows: padded(&["hello"], 4),
        cursor: (5, 0, 0),
        history_size: 0,
        display_offset: 0,
    }
}

/// Smallest case: the line must be back on viewport row 0 and the scrollback
/// must be empty again. (The bug blanks the viewport and leaves the line in
/// scrollback.)
#[test]
fn widen_after_narrow_keeps_top_row_line_in_the_viewport() {
    let mut t = hello_narrowed();
    t.resize(10, 4);
    let got = t.observe();
    assert_eq!(
        got,
        hello_restored(),
        "narrow 10->4 then widen 4->10 on a 10x4 grid whose top row holds 'hello' must be the \
         identity: the line on row 0, the cursor at (5, 0) not pending-wrap, no scrollback"
    );
}

/// The stale-duplicate half of the impact: nothing may be left in scrollback
/// by the round trip (scrollback text read through the copy path).
#[test]
fn widen_after_narrow_leaves_nothing_in_scrollback() {
    let mut t = hello_narrowed();
    t.resize(10, 4);
    let obs = t.observe();
    assert_eq!(
        (obs.history_size, t.scrollback_text()),
        (0, String::new()),
        "the line is back on screen after the widen, so history_size must be 0 and no scrollback \
         text may remain; observed {obs:?}"
    );
}

/// The wrong-cursor half of the impact: the cursor must sit right after the
/// restored text, and the next typed character must land there (the bug puts
/// it at the origin with pending-wrap, so the next character lands on row 1).
#[test]
fn typing_after_narrow_then_widen_continues_the_top_row_line() {
    let mut t = hello_narrowed();
    t.resize(10, 4);
    let after_resize = t.observe();
    assert_eq!(
        after_resize.cursor,
        (5, 0, 0),
        "cursor (col, row, pending_wrap) after narrow+widen must be right after 'hello'; \
         observed {after_resize:?}"
    );
    t.feed("X");
    let typed = t.observe();
    assert_eq!(
        typed,
        Observed {
            rows: padded(&["helloX"], 4),
            cursor: (6, 0, 0),
            history_size: 0,
            display_offset: 0,
        },
        "typing 'X' after narrow+widen must extend the line on row 0"
    );
}

/// The reported FFI shape: an 80x6 grid with a shell-prompt-like line, narrowed
/// to 8 columns and widened back, no redraw in between.
#[test]
fn prompt_line_survives_80_to_8_to_80_round_trip_on_row_0() {
    let line = "$ abcdefghij";
    let mut t = Rig::new(80, 6, 100);
    t.feed(line);
    assert_eq!(
        t.observe(),
        Observed {
            rows: padded(&[line], 6),
            cursor: (12, 0, 0),
            history_size: 0,
            display_offset: 0,
        },
        "precondition: the prompt line on the top row of a fresh 80x6 grid"
    );
    t.resize(8, 6);
    assert_wrapped(&t, line, "80->8");
    t.resize(80, 6);
    assert_eq!(
        t.observe(),
        Observed {
            rows: padded(&[line], 6),
            cursor: (12, 0, 0),
            history_size: 0,
            display_offset: 0,
        },
        "80->8->80 round trip must restore the prompt line on row 0 with the cursor after it"
    );
}

/// Other narrow widths and widen targets (including one wider than the
/// original): each must rejoin the row-0 line onto one row with the cursor
/// after it and no scrollback. All combinations are checked and reported
/// together.
#[test]
fn widen_to_any_width_that_fits_rejoins_the_top_row_line() {
    let mut failures: Vec<String> = Vec::new();
    for (narrow, wide) in [(3u16, 10u16), (2, 10), (4, 16), (4, 6)] {
        let mut t = Rig::new(10, 4, 100);
        t.feed("hello");
        t.resize(narrow, 4);
        assert_wrapped(&t, "hello", &format!("narrow {narrow}"));
        t.resize(wide, 4);
        let got = t.observe();
        let want = Observed {
            rows: padded(&["hello"], 4),
            cursor: (5, 0, 0),
            history_size: 0,
            display_offset: 0,
        };
        if got != want {
            failures.push(format!(
                "narrow {narrow} then widen {wide}: want {want:?}, got {got:?}"
            ));
        }
        let scrollback = t.scrollback_text();
        if !scrollback.is_empty() {
            failures.push(format!(
                "narrow {narrow} then widen {wide}: scrollback text must be empty, got \
                 {scrollback:?}"
            ));
        }
    }
    assert_eq!(
        failures,
        Vec::<String>::new(),
        "narrow-then-widen with the line on row 0 must be the identity for every width pair"
    );
}

/// Repeated cycles: each narrow-then-widen must be the identity, so nothing
/// accumulates in scrollback (the bug leaves one more stale duplicate per
/// cycle).
#[test]
fn repeated_narrow_widen_cycles_do_not_accumulate_scrollback() {
    let mut t = hello_narrowed();
    for cycle in 1..=3 {
        t.resize(10, 4);
        let got = t.observe();
        assert_eq!(
            got,
            hello_restored(),
            "cycle {cycle}: after widening, the grid must be exactly the original; scrollback \
             text {:?}",
            t.scrollback_text()
        );
        t.resize(4, 4);
        assert_wrapped(&t, "hello", &format!("cycle {cycle} narrow"));
    }
}

/// After a clear that leaves real scrollback behind (the "Ctrl-L / clear"
/// trigger), a new line on row 0 must still survive the round trip with the
/// scrollback exactly as it was before the resizes.
#[test]
fn line_on_row_0_after_a_clear_survives_narrow_then_widen_with_scrollback_intact() {
    let mut t = Rig::new(20, 4, 100);
    // Fill past the viewport so real scrollback exists; every line is short
    // enough (<= 7 cells) to never wrap at the narrow width used below.
    for i in 0..8 {
        t.feed(&format!("ln{i}\r\n"));
    }
    let seeded_history = t.observe().history_size;
    assert!(
        seeded_history >= 4,
        "precondition: seeding must create scrollback; history_size = {seeded_history}"
    );
    // Home the cursor and clear the visible screen only (ED 2, not ED 3).
    t.feed("\x1b[H\x1b[2J");
    t.feed("$ abcdefghij");
    let before = t.observe();
    assert_eq!(
        (before.rows.clone(), before.cursor, before.display_offset),
        (padded(&["$ abcdefghij"], 4), (12, 0, 0), 0),
        "precondition: after the clear, the new line sits on viewport row 0 with the cursor \
         after it; observed {before:?}"
    );
    let scrollback_before = t.scrollback_text();
    assert!(
        scrollback_before.contains("ln0") && scrollback_before.contains("ln7"),
        "precondition: scrollback text must hold the seeded lines; got {scrollback_before:?}"
    );

    t.resize(8, 4);
    let narrowed = t.observe();
    assert!(
        !narrowed.rows.iter().any(|r| r == "$ abcdefghij"),
        "precondition: after narrowing 20->8 no viewport row may hold the new line whole; \
         observed {narrowed:?}"
    );
    assert!(
        t.whole_buffer_text().ends_with("$ abcdefghij"),
        "precondition: after narrowing 20->8 the new line must still read back whole through \
         the copy path (soft wraps rejoined); got {:?}",
        t.whole_buffer_text()
    );
    t.resize(20, 4);
    let after = t.observe();
    assert_eq!(
        (
            after.rows.clone(),
            after.cursor,
            after.history_size,
            after.display_offset
        ),
        (
            padded(&["$ abcdefghij"], 4),
            (12, 0, 0),
            before.history_size,
            0
        ),
        "narrow 20->8 then widen 8->20 must restore the row-0 line, cursor and history size \
         exactly as before the resizes; observed {after:?}, before {before:?}"
    );
    assert_eq!(
        t.scrollback_text(),
        scrollback_before,
        "scrollback text must be unchanged by the round trip (no stale duplicate of the line)"
    );
}

/// Control (expected to pass on the unfixed code): the same round trip with
/// the line on viewport row 1 is reflowed correctly. Pins that the
/// expectations above are the behaviour every other row already has, and that
/// the rig is not vacuous. Only the viewport, cursor and the absence of the
/// text from scrollback are asserted (the blank row above may legitimately
/// pass through scrollback during the narrow step).
#[test]
fn control_same_round_trip_with_the_line_on_row_1_is_the_identity() {
    let mut t = Rig::new(10, 4, 100);
    t.feed("\r\nhello");
    let want_rows = padded(&["", "hello"], 4);
    let before = t.observe();
    assert_eq!(
        (before.rows.clone(), before.cursor, before.history_size),
        (want_rows.clone(), (5, 1, 0), 0),
        "precondition: 'hello' on row 1 of a fresh 10x4 grid; observed {before:?}"
    );
    t.resize(4, 4);
    let narrowed = t.observe();
    assert!(
        !narrowed.rows.iter().any(|r| r == "hello"),
        "precondition: after narrowing 10->4 no viewport row may hold 'hello' whole; observed \
         {narrowed:?}"
    );
    t.resize(10, 4);
    let after = t.observe();
    assert_eq!(
        (
            after.rows.clone(),
            after.cursor,
            after.display_offset,
            t.scrollback_text()
        ),
        (want_rows, (5, 1, 0), 0, String::new()),
        "narrow 10->4 then widen 4->10 with the line on row 1 must restore the viewport and \
         cursor and leave no copy of the line in scrollback; observed {after:?}"
    );
}
