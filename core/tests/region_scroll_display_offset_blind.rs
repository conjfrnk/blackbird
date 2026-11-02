//! Blind regression for BUG VT-3: a scroll that happens inside a region
//! whose top margin is below the first screen row (DECSTBM with top >= 2, or
//! DL/IL-style scrolls started from a cursor row > 0) must not disturb a
//! viewport that the user has scrolled back into history.
//!
//! Terminal conventions this file pins (independent of any implementation):
//!
//!   1. `display_offset` is "how many lines the viewport sits above the live
//!      grid". It can never exceed `history_size`, the number of lines that
//!      actually exist above the live grid. `display_offset <= history_size`
//!      is a hard invariant of every snapshot.
//!   2. A scroll whose region does not start at the very top row discards the
//!      line that falls off the region top; it does NOT push that line into
//!      scrollback. So `history_size` must not change, and a viewport parked
//!      in history has nothing to follow: `display_offset` and the history
//!      text on screen must stay exactly where they were.
//!   3. Whatever a program prints, the tab must stay alive: the snapshot
//!      call must return a snapshot (not NULL), the handle must not become
//!      poisoned, and no `Fatal` event may be delivered. A thousand-odd
//!      region scrolls is ordinary output volume (`yes | head`, a TUI
//!      repainting a status region, a scrolling log pane).
//!
//! Trigger recipe: primary screen, history shorter than the scrollback cap,
//! the user scrolled back (host called `bb_term_scroll`) and has not typed or
//! wheeled since, then the program installs a scroll region whose top margin
//! is row 2 or lower and scrolls it (LF at the region bottom, CSI S, or
//! CSI M with the cursor below row 1).
//!
//! Cost: one 40x24 terminal per test with a 1000-line scrollback cap
//! (~1000 x 40 cells, about 1 MiB), 60 seed lines, at most 1500 one-to-four
//! byte scroll steps per test. A few milliseconds each.

use std::ffi::c_void;
use std::sync::Mutex;

use blackbird_core::*;

const COLS: u16 = 40;
const ROWS: u16 = 24;
/// Scrollback cap. Seed output stays far below it so history never saturates
/// (the bug needs `history_size < cap`).
const SCROLLBACK_CAP: u32 = 1_000;
/// Distinct lines `R000`..`R059` written before the test begins. On a 24-row
/// screen this leaves a few dozen lines in history, oldest line `R000`.
const SEED_LINES: usize = 60;
/// Past the ~1000-step point at which the original defect made the snapshot
/// path panic, with margin.
const LONG_RUN_STEPS: usize = 1_500;

// ---------------------------------------------------------------- event sink

struct Sink {
    events: Mutex<Vec<u32>>,
}

impl Sink {
    fn new() -> Self {
        Sink {
            events: Mutex::new(Vec::new()),
        }
    }
    fn count(&self, kind: BBEventKind) -> usize {
        self.events
            .lock()
            .unwrap()
            .iter()
            .filter(|&&k| k == kind as u32)
            .count()
    }
    fn kinds(&self) -> Vec<u32> {
        self.events.lock().unwrap().clone()
    }
}

extern "C" fn cb(ev: BBEvent, ctx: *mut c_void) {
    let sink = unsafe { &*(ctx as *const Sink) };
    sink.events.lock().unwrap().push(ev.kind as u32);
}

// ------------------------------------------------------------------- helpers

/// Everything the assertions need from one snapshot.
#[derive(Debug, Clone)]
struct View {
    display_offset: u32,
    history_size: u32,
    /// Viewport row 0, trailing blanks trimmed.
    row0: String,
}

/// `None` when `bb_term_take_snapshot` returned NULL (the poisoned-tab
/// symptom). Never dereferences a NULL snapshot.
unsafe fn view(term: *mut BBTerm) -> Option<View> {
    let snap = bb_term_take_snapshot(term);
    if snap.is_null() {
        return None;
    }
    let cols = (*snap).cols as usize;
    let mut row0 = String::new();
    for i in 0..cols {
        let ch = (*(*snap).cells.add(i)).ch;
        row0.push(if ch == 0 {
            ' '
        } else {
            char::from_u32(ch).unwrap_or('?')
        });
    }
    let v = View {
        display_offset: (*snap).display_offset,
        history_size: (*snap).history_size,
        row0: row0.trim_end().to_string(),
    };
    bb_snap_release(snap);
    Some(v)
}

unsafe fn feed(term: *mut BBTerm, bytes: &[u8]) {
    bb_term_input(term, bytes.as_ptr(), bytes.len());
}

/// Where in history the test parks the viewport before the trigger.
#[derive(Clone, Copy, Debug)]
enum Park {
    /// As far back as the history allows (`display_offset == history_size`).
    Top,
    /// Exactly this many lines back.
    Lines(i32),
}

/// A fresh 40x24 terminal with `SEED_LINES` of output, scrolled back per
/// `park`, then `setup` bytes applied (margins / cursor placement). Returns
/// the view captured AFTER setup, with the preconditions asserted so the
/// scenario can never be vacuous.
unsafe fn scrolled_back_term(sink: &Sink, park: Park, setup: &[u8]) -> (*mut BBTerm, View) {
    let term = bb_term_new(COLS, ROWS, SCROLLBACK_CAP);
    assert!(!term.is_null(), "bb_term_new returned NULL");
    bb_term_set_event_cb(term, Some(cb), sink as *const Sink as *mut c_void);

    for i in 0..SEED_LINES {
        let line = format!("R{:03}\r\n", i);
        feed(term, line.as_bytes());
    }

    let seeded = view(term).expect("snapshot after seeding must exist");
    assert_eq!(seeded.display_offset, 0, "fresh output is pinned to bottom");
    assert!(
        seeded.history_size > 12 && seeded.history_size < SCROLLBACK_CAP,
        "precondition: history must be non-trivial and below the cap {} \
         (the bug needs history_size < cap); got history_size={}",
        SCROLLBACK_CAP,
        seeded.history_size
    );

    let delta = match park {
        Park::Top => i32::MAX,
        Park::Lines(n) => n,
    };
    bb_term_scroll(term, delta);
    let parked = view(term).expect("snapshot after scroll-back must exist");
    match park {
        Park::Top => assert_eq!(
            parked.display_offset, parked.history_size,
            "precondition: scroll(i32::MAX) must park the viewport at the top of history"
        ),
        Park::Lines(n) => assert_eq!(
            parked.display_offset, n as u32,
            "precondition: scroll({n}) must park the viewport {n} lines back; got {:?}",
            parked
        ),
    }
    assert!(
        parked.display_offset > 0,
        "precondition: viewport must be scrolled back"
    );
    assert_eq!(
        parked.history_size, seeded.history_size,
        "precondition: scrolling the viewport must not change history"
    );

    feed(term, setup);
    let ready = view(term).expect("snapshot after region setup must exist");
    assert_eq!(
        ready.display_offset,
        parked.display_offset,
        "precondition: installing margins / moving the cursor (no output, no \
         keystroke) must leave the scrolled-back viewport where it was; \
         setup={:?} before={:?} after={:?}",
        String::from_utf8_lossy(setup),
        parked,
        ready
    );
    assert_eq!(
        ready.history_size, parked.history_size,
        "precondition: setup must not change history"
    );
    if matches!(park, Park::Top) {
        assert!(
            ready.row0.starts_with("R000"),
            "precondition: viewport parked at the top of history must show the \
             oldest seeded line R000 on row 0; got {:?}",
            ready.row0
        );
    }
    (term, ready)
}

/// The invariant every snapshot must satisfy, with measured values printed.
fn assert_offset_within_history(v: &View, what: &str) {
    assert!(
        v.display_offset <= v.history_size,
        "{what}: display_offset ({}) must never exceed history_size ({}); view={:?}",
        v.display_offset,
        v.history_size,
        v
    );
}

/// Shared body: park the viewport, install `setup`, run `step` `steps` times,
/// then demand the viewport is exactly where it was.
unsafe fn assert_region_scroll_leaves_viewport_alone(
    park: Park,
    setup: &[u8],
    step: &[u8],
    steps: usize,
) {
    let sink = Sink::new();
    let (term, before) = scrolled_back_term(&sink, park, setup);

    let burst: Vec<u8> = step
        .iter()
        .copied()
        .cycle()
        .take(step.len() * steps)
        .collect();
    feed(term, &burst);

    let label = format!(
        "park={:?} setup={:?} step={:?} x{}",
        park,
        String::from_utf8_lossy(setup),
        String::from_utf8_lossy(step),
        steps
    );

    let after = view(term);
    let poisoned = bb_term_is_poisoned(term);
    let fatals = sink.count(BBEventKind::Fatal);
    // Release the callback before any assert can unwind past it.
    bb_term_set_event_cb(term, None, std::ptr::null_mut());

    let after = match after {
        Some(v) => v,
        None => {
            bb_term_free(term);
            panic!(
                "{label}: bb_term_take_snapshot returned NULL (poisoned={poisoned}, \
                 Fatal events={fatals}, all events={:?}); the tab is dead",
                sink.kinds()
            );
        }
    };
    assert_eq!(
        poisoned, 0,
        "{label}: tab must not be poisoned; view={after:?}"
    );
    assert_eq!(
        fatals,
        0,
        "{label}: no Fatal event may be delivered; events={:?}",
        sink.kinds()
    );

    assert_offset_within_history(&after, &label);
    assert_eq!(
        after.history_size, before.history_size,
        "{label}: a scroll whose region top margin is below row 1 must not \
         push lines into scrollback; before={before:?} after={after:?}"
    );
    assert_eq!(
        after.display_offset, before.display_offset,
        "{label}: the viewport parked in history must not move when nothing \
         enters history; before={before:?} after={after:?}"
    );
    assert_eq!(
        after.row0, before.row0,
        "{label}: history text on the top viewport row must be unchanged \
         (blank/stale row means the viewport ran past the history); \
         before={before:?} after={after:?}"
    );

    // Poisoning is sticky and silent (all later input is dropped), so also
    // prove liveness directly: fresh output after the burst must land.
    assert_tab_still_alive(term, &label);

    bb_term_free(term);
}

/// After the burst the tab must still do real work: reset margins, return to
/// the live grid, repaint, and see the marker in the snapshot.
unsafe fn assert_tab_still_alive(term: *mut BBTerm, label: &str) {
    feed(term, b"\x1b[r\x1b[H\x1b[2JLIVE");
    bb_term_scroll_to_bottom(term);
    let v = view(term)
        .unwrap_or_else(|| panic!("{label}: snapshot NULL when probing liveness; tab is dead"));
    assert_eq!(
        v.display_offset, 0,
        "{label}: scroll_to_bottom must pin the live grid; view={v:?}"
    );
    assert_eq!(
        v.row0, "LIVE",
        "{label}: input after the region scrolls must still reach the grid; view={v:?}"
    );
}

// ---------------------------------------------------------------- single steps

#[test]
fn one_lf_at_bottom_of_top_margin_region_keeps_history_viewport_put() {
    // "\x1b[2;24r\x1b[24;1H" + one LF: the exact one-step overshoot from the
    // report (display_offset became history_size + 1 with a blank top row).
    unsafe {
        assert_region_scroll_leaves_viewport_alone(Park::Top, b"\x1b[2;24r\x1b[24;1H", b"\n", 1);
    }
}

#[test]
fn csi_s_in_top_margin_region_keeps_history_viewport_put() {
    unsafe {
        assert_region_scroll_leaves_viewport_alone(
            Park::Top,
            b"\x1b[2;24r\x1b[24;1H",
            b"\x1b[S",
            3,
        );
    }
}

#[test]
fn csi_m_with_cursor_below_first_row_keeps_history_viewport_put() {
    // No DECSTBM at all: DL with the cursor on row 10 scrolls the sub-region
    // [row 10, bottom] up, which is the same top-margin > 0 situation.
    unsafe {
        assert_region_scroll_leaves_viewport_alone(Park::Top, b"\x1b[10;1H", b"\x1b[M", 3);
    }
}

#[test]
fn mid_history_viewport_does_not_drift_during_top_margin_region_scrolls() {
    // Parked only 5 lines back (well inside history): the overshoot is not
    // reachable in 3 steps, but the viewport must still not creep, because no
    // line entered history. Pins the "anchored" half of the convention.
    unsafe {
        assert_region_scroll_leaves_viewport_alone(
            Park::Lines(5),
            b"\x1b[2;24r\x1b[24;1H",
            b"\n",
            3,
        );
    }
}

#[test]
fn many_steps_report_case_offset_stays_within_history() {
    // The report saw display_offset 91 with history 31 after ~60 steps.
    unsafe {
        assert_region_scroll_leaves_viewport_alone(Park::Top, b"\x1b[2;24r\x1b[24;1H", b"\n", 60);
    }
}

// ------------------------------------------------------------------- long runs

#[test]
fn long_run_of_lf_in_top_margin_region_does_not_poison_the_tab() {
    unsafe {
        let setup: &[u8] = b"\x1b[2;24r\x1b[24;1H";
        assert_region_scroll_leaves_viewport_alone(Park::Top, setup, b"\n", LONG_RUN_STEPS);
    }
}

#[test]
fn long_run_of_csi_s_in_top_margin_region_does_not_poison_the_tab() {
    unsafe {
        let setup: &[u8] = b"\x1b[2;24r\x1b[24;1H";
        assert_region_scroll_leaves_viewport_alone(Park::Top, setup, b"\x1b[S", LONG_RUN_STEPS);
    }
}

#[test]
fn long_run_of_csi_m_below_first_row_does_not_poison_the_tab() {
    unsafe {
        assert_region_scroll_leaves_viewport_alone(
            Park::Top,
            b"\x1b[6;1H",
            b"\x1b[M",
            LONG_RUN_STEPS,
        );
    }
}

// --------------------------------------------------------------------- control

#[test]
fn control_full_screen_lf_flow_still_grows_history_and_follows_content() {
    // Not part of the defect: with the default full-screen region, output
    // that scrolls the screen DOES push lines into history, and a viewport
    // parked in history keeps showing the same content (offset grows with
    // history), clamped at history_size. Guards against a "fix" that simply
    // freezes display_offset for every scroll.
    unsafe {
        let sink = Sink::new();
        let (term, before) = scrolled_back_term(&sink, Park::Lines(5), b"\x1b[24;1H");
        feed(term, &b"\n".repeat(10));

        let after = view(term).expect("snapshot must exist after full-screen scrolling");
        bb_term_set_event_cb(term, None, std::ptr::null_mut());
        assert_eq!(
            after.history_size,
            before.history_size + 10,
            "10 full-screen scrolls must add 10 lines of history; before={before:?} after={after:?}"
        );
        assert_offset_within_history(&after, "control");
        assert_eq!(
            after.display_offset,
            before.display_offset + 10,
            "viewport parked in history must follow its content as history grows; \
             before={before:?} after={after:?}"
        );
        bb_term_free(term);
    }
}
