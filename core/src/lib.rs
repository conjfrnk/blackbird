//! blackbird_core — C ABI around `alacritty_terminal`.

use alacritty_terminal::event::{Event, EventListener};
use alacritty_terminal::grid::Dimensions;
use alacritty_terminal::term::{Config, Term};
use alacritty_terminal::vte::ansi::Processor;

/// Dimensions struct required by `Term::new`.
///
/// `total_lines` returns only the visible rows here, not `rows + scrollback`.
/// In 0.26's grid model, `Dimensions::total_lines` is the number of lines
/// currently allocated in the ring buffer (screen + accumulated history). When
/// sizing a *new* terminal the buffer starts at `screen_lines` rows; the grid
/// grows into the scrollback region lazily as output scrolls off-screen.
/// `Term::new` reads `scrolling_history` from `Config` (not from
/// `Dimensions::total_lines`) to set `Grid::max_scroll_limit`.  The only
/// methods `Term::new` calls on `Dimensions` are `screen_lines()` and
/// `columns()`, which is confirmed by alacritty's own internal `TermSize`
/// test helper (term/mod.rs:2436-2439) doing the same thing.
#[derive(Clone, Copy)]
struct TermSize {
    cols: usize,
    rows: usize,
}

impl Dimensions for TermSize {
    fn columns(&self) -> usize {
        self.cols
    }
    fn screen_lines(&self) -> usize {
        self.rows
    }
    fn total_lines(&self) -> usize {
        self.rows
    }
}

/// We don't listen to `alacritty_terminal` events yet — events we care about
/// are re-emitted to Swift via `bb_term_set_event_cb` in a later task.
#[derive(Clone, Default)]
struct NoopListener;

impl EventListener for NoopListener {
    fn send_event(&self, _event: Event) {}
}

/// Opaque handle exposed to Swift.
// TODO(task-3): remove #[allow(dead_code)] once fields are read
#[allow(dead_code)]
pub struct BBTerm {
    term: Term<NoopListener>,
    processor: Processor,
}

/// Create a new terminal. Returns null on invalid input.
///
/// # Safety
/// The returned pointer must be freed exactly once via `bb_term_free`.
///
/// Until `catch_unwind` is added to FFI entry points (Task 7), the caller must
/// ensure no Rust panic can unwind through this function (UB to unwind through
/// `extern "C"`).
#[no_mangle]
pub unsafe extern "C" fn bb_term_new(cols: u16, rows: u16, scrollback: u32) -> *mut BBTerm {
    if cols == 0 || rows == 0 {
        return std::ptr::null_mut();
    }
    let size = TermSize {
        cols: cols as usize,
        rows: rows as usize,
    };
    let config = Config {
        scrolling_history: scrollback as usize,
        ..Default::default()
    };

    let term = Term::new(config, &size, NoopListener);
    let bb = Box::new(BBTerm {
        term,
        processor: Processor::new(),
    });
    Box::into_raw(bb)
}

/// Free a terminal handle created by `bb_term_new`.
///
/// # Safety
/// `term` must have been returned by `bb_term_new` and not previously freed.
/// Passing null is a no-op.
///
/// Until `catch_unwind` is added to FFI entry points (Task 7), the caller must
/// ensure no Rust panic can unwind through this function (UB to unwind through
/// `extern "C"`).
#[no_mangle]
pub unsafe extern "C" fn bb_term_free(term: *mut BBTerm) {
    if term.is_null() {
        return;
    }
    drop(Box::from_raw(term));
}

#[cfg(test)]
mod tests {
    use super::*;
    use alacritty_terminal::grid::Dimensions;
    use alacritty_terminal::vte::ansi::Handler;

    #[test]
    fn alacritty_terminal_is_linked() {
        let _ = std::mem::size_of::<alacritty_terminal::term::Config>();
    }

    #[test]
    fn new_and_free_roundtrip() {
        unsafe {
            let term = bb_term_new(80, 24, 10_000);
            assert!(!term.is_null(), "bb_term_new returned null");
            bb_term_free(term);
        }
    }

    #[test]
    fn free_null_is_noop() {
        unsafe {
            bb_term_free(std::ptr::null_mut());
        }
    }

    #[test]
    fn new_with_zero_dims_returns_null() {
        unsafe {
            assert!(bb_term_new(0, 24, 1000).is_null());
            assert!(bb_term_new(80, 0, 1000).is_null());
        }
    }

    /// Verify that scrollback is wired up: after feeding enough newlines to
    /// push lines off-screen the grid's history grows up to the scrollback
    /// limit, confirming `Config::scrolling_history` was applied correctly.
    #[test]
    fn scrollback_is_retained() {
        let scrollback: usize = 5;
        let rows: usize = 3;
        let cols: usize = 10;

        let size = TermSize { cols, rows };
        let config = Config {
            scrolling_history: scrollback,
            ..Default::default()
        };
        let mut term = Term::new(config, &size, NoopListener);

        // Feed (rows + scrollback) newlines so that exactly `scrollback` lines
        // are pushed into history.
        let total_newlines = rows + scrollback;
        for _ in 0..total_newlines {
            term.linefeed();
        }

        // `history_size()` = total_lines - screen_lines (from the grid model).
        // It should equal the scrollback limit once fully populated.
        let history = term.history_size();
        assert_eq!(
            history, scrollback,
            "expected {} scrollback lines, got {}",
            scrollback, history
        );
    }
}
