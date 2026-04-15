//! blackbird_core — C ABI around `alacritty_terminal`.

use alacritty_terminal::event::{Event, EventListener};
use alacritty_terminal::term::{Config, Term};
use alacritty_terminal::vte::ansi::Processor;
use alacritty_terminal::grid::Dimensions;

/// Dimensions struct required by `Term::new`.
#[derive(Clone, Copy)]
struct TermSize {
    cols: usize,
    rows: usize,
}

impl Dimensions for TermSize {
    fn columns(&self) -> usize { self.cols }
    fn screen_lines(&self) -> usize { self.rows }
    fn total_lines(&self) -> usize { self.rows }
}

/// We don't listen to `alacritty_terminal` events yet — events we care about
/// are re-emitted to Swift via `bb_term_set_event_cb` in a later task.
#[derive(Clone, Default)]
struct NoopListener;

impl EventListener for NoopListener {
    fn send_event(&self, _event: Event) {}
}

/// Opaque handle exposed to Swift.
#[allow(dead_code)]
pub struct BBTerm {
    term: Term<NoopListener>,
    processor: Processor,
}

/// Create a new terminal. Returns null on invalid input.
///
/// # Safety
/// The returned pointer must be freed exactly once via `bb_term_free`.
#[no_mangle]
pub unsafe extern "C" fn bb_term_new(
    cols: u16,
    rows: u16,
    scrollback: u32,
) -> *mut BBTerm {
    if cols == 0 || rows == 0 {
        return std::ptr::null_mut();
    }
    let size = TermSize { cols: cols as usize, rows: rows as usize };
    let mut config = Config::default();
    config.scrolling_history = scrollback as usize;

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
        unsafe { bb_term_free(std::ptr::null_mut()); }
    }

    #[test]
    fn new_with_zero_dims_returns_null() {
        unsafe {
            assert!(bb_term_new(0, 24, 1000).is_null());
            assert!(bb_term_new(80, 0, 1000).is_null());
        }
    }
}
