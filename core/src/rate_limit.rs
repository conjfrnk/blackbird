//! Rate limiters for the event-dispatch and OSC reply paths.

use std::cell::UnsafeCell;

/// Token bucket for PTY-write replies (DA1, CPR, DECRQM, kitty `CSI ?u`, XTGETTCAP, colour
/// queries). A startup burst must pass: a dropped DA1/CPR stalls the TUI until its own timeout.
#[derive(Debug)]
pub(crate) struct PtyWriteRateState {
    last_refill: std::time::Instant,
    tokens: f64,
    /// Replies allowed since construction / `reset`.
    pub(crate) window_count: u32,
}

pub(crate) struct PtyWriteRateCell {
    pub(crate) state: UnsafeCell<PtyWriteRateState>,
}

// SAFETY: reachable only via the listener, and BBTerm's single-thread-per-handle contract
// forbids concurrent access to it.
unsafe impl Send for PtyWriteRateCell {}
unsafe impl Sync for PtyWriteRateCell {}

impl PtyWriteRateCell {
    pub(crate) fn new() -> Self {
        Self {
            state: UnsafeCell::new(PtyWriteRateState::new()),
        }
    }

    /// # Safety
    /// Caller must respect the single-thread-per-BBTerm discipline — no concurrent calls.
    pub(crate) unsafe fn allow(&self) -> bool {
        (*self.state.get()).allow()
    }

    /// # Safety
    /// Caller must respect the single-thread-per-BBTerm discipline — no concurrent calls.
    pub(crate) unsafe fn reset(&self) {
        *self.state.get() = PtyWriteRateState::new();
    }
}

pub(crate) const PTY_WRITE_REPLY_PER_SECOND: u32 = 32;
pub(crate) const PTY_WRITE_REPLY_BURST: u32 = 128;

/// Tumbling window: `window_start` resets on expiry, so up to 2×cap can cross a window boundary.
pub(crate) struct EventRateState {
    cap: u32,
    window: std::time::Duration,
    window_start: std::time::Instant,
    pub(crate) window_count: u32,
}

impl EventRateState {
    pub(crate) fn new(cap: u32, window: std::time::Duration) -> Self {
        Self {
            cap,
            window,
            window_start: std::time::Instant::now(),
            window_count: 0,
        }
    }

    pub(crate) fn allow(&mut self) -> bool {
        let now = std::time::Instant::now();
        if now.duration_since(self.window_start) >= self.window {
            self.window_start = now;
            self.window_count = 0;
        }
        if self.window_count >= self.cap {
            return false;
        }
        self.window_count += 1;
        true
    }

    pub(crate) fn retry_after(&self) -> Option<std::time::Duration> {
        let elapsed = std::time::Instant::now().duration_since(self.window_start);
        if elapsed >= self.window || self.window_count < self.cap {
            return None;
        }
        Some(self.window - elapsed)
    }
}

/// Suppressed titles coalesce to the latest via `suppressed_title`, not drop: title is
/// last-writer-wins state and nothing re-emits it.
pub(crate) const TITLE_EVENT_PER_SECOND: u32 = 32;
pub(crate) const BELL_EVENT_PER_SECOND: u32 = 16;
pub(crate) const NOTIFICATION_EVENT_PER_SECOND: u32 = 4;
/// Suppressed clipboard writes coalesce to the latest via `suppressed_osc52`, like titles.
pub(crate) const OSC52_EVENT_PER_SECOND: u32 = 32;
pub(crate) const EVENT_RATE_WINDOW: std::time::Duration = std::time::Duration::from_secs(1);

impl PtyWriteRateState {
    pub(crate) fn new() -> Self {
        Self {
            last_refill: std::time::Instant::now(),
            tokens: f64::from(PTY_WRITE_REPLY_BURST),
            window_count: 0,
        }
    }

    pub(crate) fn allow(&mut self) -> bool {
        let now = std::time::Instant::now();
        let elapsed = now.duration_since(self.last_refill).as_secs_f64();
        self.last_refill = now;
        self.tokens = (self.tokens + elapsed * f64::from(PTY_WRITE_REPLY_PER_SECOND))
            .min(f64::from(PTY_WRITE_REPLY_BURST));
        if self.tokens < 1.0 {
            return false;
        }
        self.tokens -= 1.0;
        self.window_count = self.window_count.saturating_add(1);
        true
    }
}

/// OSC 133 prompt-mark cap, shared by all four kinds (A/B/C/D). Sized ~2× the fastest typeable
/// rate (key-repeat ~33 Hz × 4 marks); a lower cap drops legitimate marks.
pub(crate) const PROMPT_MARK_PER_SECOND: u32 = 240;
pub(crate) const PROMPT_MARK_WINDOW: std::time::Duration = std::time::Duration::from_secs(1);

pub(crate) const COLOR_QUERY_REPLY_PER_SECOND: u32 = 32;
pub(crate) const COLOR_QUERY_REPLY_WINDOW: std::time::Duration = std::time::Duration::from_secs(1);

/// Each delivered OSC 7 costs a main-thread process-tree walk on the Swift side.
pub(crate) const OSC7_INGEST_PER_SECOND: u32 = 32;
pub(crate) const OSC7_INGEST_WINDOW: std::time::Duration = std::time::Duration::from_secs(1);
