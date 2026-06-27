//! Sliding/tumbling-window rate limiters guarding the event-dispatch and
//! OSC reply paths (audit S1-002 / S5-009 / M-7 / synthesis #17). Each shares
//! the same window algorithm; the caps are sized per concern. Moved out of the
//! monolith verbatim (REFACTOR.md Wave 1); behavior unchanged.

use std::cell::UnsafeCell;

/// Rate-limiter state for PtyWrite reply events. Mutated only on the
/// BBTerm-owning thread; the Send/Sync impls below upgrade the
/// `Arc<…>` to thread-safe under that discipline (same pattern as
/// `ColorRequestQueue`).
#[derive(Debug)]
pub(crate) struct PtyWriteRateState {
    window_start: std::time::Instant,
    pub(crate) window_count: u32,
}

/// Send+Sync wrapper around `UnsafeCell<PtyWriteRateState>` so it can
/// live behind an `Arc` shared with `RoutingListener`. The wrapper is
/// the same shape `ColorRequestQueue` uses; both rely on the
/// single-thread-per-BBTerm contract documented in `RoutingListener`.
pub(crate) struct PtyWriteRateCell {
    pub(crate) state: UnsafeCell<PtyWriteRateState>,
}

// SAFETY: BBTerm's single-thread-per-handle contract (see
// `RoutingListener` doc) forbids concurrent access to the listener,
// and PtyWriteRateCell is reachable only via that listener.
unsafe impl Send for PtyWriteRateCell {}
unsafe impl Sync for PtyWriteRateCell {}

impl PtyWriteRateCell {
    pub(crate) fn new() -> Self {
        Self {
            state: UnsafeCell::new(PtyWriteRateState::new()),
        }
    }

    /// Returns true if the dispatch is allowed; false if the cap has
    /// been hit and the caller should drop the event silently.
    ///
    /// # Safety
    /// Caller must respect the single-thread-per-BBTerm discipline —
    /// no concurrent calls.
    pub(crate) unsafe fn allow(&self) -> bool {
        (*self.state.get()).allow()
    }

    /// Reset the sliding window so the next `allow()` starts a fresh
    /// 1-second budget. Used by `bb_term_clear_all` (audit H-3) so a
    /// pre-clear PtyWrite flood doesn't eat the post-clear session's
    /// PTY-write budget.
    ///
    /// # Safety
    /// Caller must respect the single-thread-per-BBTerm discipline —
    /// no concurrent calls.
    pub(crate) unsafe fn reset(&self) {
        *self.state.get() = PtyWriteRateState::new();
    }
}

pub(crate) const PTY_WRITE_REPLY_PER_SECOND: u32 = 32;
pub(crate) const PTY_WRITE_REPLY_WINDOW: std::time::Duration = std::time::Duration::from_secs(1);

/// Tumbling-window state for the Title/Bell event caps (audit S1-002).
/// ("Tumbling", not sliding: `window_start` resets on expiry, so up to
/// 2×cap can cross a window boundary — same algorithm as the sibling
/// limiters, named honestly.) The cap/window POLICY is bound at
/// construction (review follow-up): an `allow(cap, window)` signature
/// let the two call sites be cross-wired silently. Lives inside
/// `CallbackCell` behind the same mutual-exclusion discipline as
/// `slot`.
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
}

/// Title-event cap (audit S1-002). Every `Event::Title`/`Event::Bell`
/// used to dispatch uncapped — only PtyWrite had a budget — and the
/// Swift side enqueues one main-queue hop per event (titles amplify
/// further through @Published → window.title → KVO → tab-bar refresh
/// broadcast). A stream of `ESC]0;x BEL` (`yes $'\e]0;x\a'`, a hostile
/// remote, or catting a binary full of BEL bytes) therefore saturated
/// the main queue with an unbounded backlog of retained Strings — the
/// same flood class the F1 snapshot coalescer and M1 PtyWrite cap
/// already closed on their paths. 32/sec matches the PtyWrite budget:
/// legitimate shells emit a couple of titles per prompt and animated
/// build tools stay well under. Suppressed titles are NOT plain-dropped
/// — title is last-writer-wins state and nothing re-emits in the
/// default configuration (the bundled shell integration sends no
/// OSC 0/2), so dropping the newest would pin a stale title
/// indefinitely. They coalesce to the latest via `suppressed_title`
/// and deliver on the first input chunk after the window rolls.
pub(crate) const TITLE_EVENT_PER_SECOND: u32 = 32;
/// Bell-event cap (audit S1-002, same rationale as the title cap).
/// 16/sec is far above perception — the Swift bell flash visually
/// coalesces long before that.
pub(crate) const BELL_EVENT_PER_SECOND: u32 = 16;
pub(crate) const EVENT_RATE_WINDOW: std::time::Duration = std::time::Duration::from_secs(1);

impl PtyWriteRateState {
    pub(crate) fn new() -> Self {
        Self {
            window_start: std::time::Instant::now(),
            window_count: 0,
        }
    }

    /// Returns true if the dispatch is allowed; false if the cap has
    /// been hit and the caller should drop the event silently.
    pub(crate) fn allow(&mut self) -> bool {
        let now = std::time::Instant::now();
        if now.duration_since(self.window_start) >= PTY_WRITE_REPLY_WINDOW {
            self.window_start = now;
            self.window_count = 0;
        }
        if self.window_count >= PTY_WRITE_REPLY_PER_SECOND {
            return false;
        }
        self.window_count += 1;
        true
    }
}

/// Per-terminal sliding-window rate limiter for OSC 133 prompt marks.
///
/// Mitigates audit synthesis bug #10: an attacker emitting `OSC 133;A`
/// thousands of times per second floods Swift's `recordPromptStart` ring
/// (cap 200) and rotates legitimate prompt marks out, so ⌘↑/⌘↓ navigation
/// lands on attacker-authored "fake prompts" — a phishing primitive.
///
/// Policy: at most `PROMPT_MARK_PER_SECOND` dispatches per rolling
/// 1-second window across ALL FOUR kinds (A/B/C/D — see the gate in
/// `handle_osc133` for why D is included; RC-03).
///
/// The window resets when `Instant::now()` is more than 1 second past
/// `window_start`. Excess fires within an active window are dropped;
/// the first drop per session leaves a one-shot breadcrumb (see
/// `osc133_rate_limited_logged`).
///
/// Sizing (audit S5-009, 2026-06-09): the original 16/sec budget was
/// sized for hostile floods but dropped LEGITIMATE marks at ordinary
/// interactive rates — the bundled integration emits D+A (precmd) +
/// B (PS1) per empty prompt cycle and +C per command, so holding
/// Return at a shell prompt (macOS key-repeat up to ~33 Hz × 3 marks)
/// produces ~100 marks/sec and cycle 6+'s A marks vanished from ⌘
/// navigation while their paired Ds desynced. 240/sec is ~2× the
/// fastest physically-typeable mark rate (33 Hz × 4 marks + margin)
/// while still bounding a hostile flood to 240 small main-thread hops
/// per second on the Swift side — the phishing/DoS mitigation #10
/// cares about is preserved.
#[derive(Clone, Copy)]
pub(crate) struct PromptMarkRateState {
    window_start: std::time::Instant,
    pub(crate) window_count: u32,
}

pub(crate) const PROMPT_MARK_PER_SECOND: u32 = 240;
pub(crate) const PROMPT_MARK_WINDOW: std::time::Duration = std::time::Duration::from_secs(1);

/// OSC 10/11/12 color-query reply rate limit (audit synthesis bug #17).
/// `ColorRequestQueue::push` already caps at 256 entries per `bb_term_input`
/// chunk, but a hostile shell can split queries across many tight chunks to
/// bypass that per-call cap and amplify replies through the PTY. This
/// sliding-window cap covers the cross-chunk case using the same pattern as
/// `PromptMarkRateState`. 32/sec is generous (legitimate apps probe at most
/// a handful per second); excess replies are dropped silently.
pub(crate) const COLOR_QUERY_REPLY_PER_SECOND: u32 = 32;
pub(crate) const COLOR_QUERY_REPLY_WINDOW: std::time::Duration = std::time::Duration::from_secs(1);

/// OSC 7 (CWD reporting) ingest rate limit (audit M-7, 2026-04-29).
/// Legitimate shells emit one OSC 7 per `cd` — typically far fewer than
/// 1/sec interactively. A hostile remote streaming OSC 7s in a tight
/// loop forces `TerminalSession.handleCwdChanged` (Swift) to run
/// `classifyForegroundNamespace()` on every event, which does a
/// `proc_listpids(PROC_PPID_ONLY)` BFS up to 256 nodes — main-thread
/// work that beachballs the UI. 32/sec mirrors the existing PtyWrite
/// cap; well above any realistic interactive shell, well below the
/// flood-amplification threshold. Excess OSC 7s are dropped silently.
pub(crate) const OSC7_INGEST_PER_SECOND: u32 = 32;
pub(crate) const OSC7_INGEST_WINDOW: std::time::Duration = std::time::Duration::from_secs(1);

impl PromptMarkRateState {
    pub(crate) fn new() -> Self {
        Self {
            window_start: std::time::Instant::now(),
            window_count: 0,
        }
    }

    /// Returns true if the dispatch is allowed; false if the window cap
    /// has been hit and the caller should drop the event.
    pub(crate) fn allow(&mut self) -> bool {
        let now = std::time::Instant::now();
        if now.duration_since(self.window_start) >= PROMPT_MARK_WINDOW {
            self.window_start = now;
            self.window_count = 0;
        }
        if self.window_count >= PROMPT_MARK_PER_SECOND {
            return false;
        }
        self.window_count += 1;
        true
    }
}

/// Per-terminal sliding-window rate limiter for OSC 7 (CWD) ingest.
/// See `OSC7_INGEST_PER_SECOND` for sizing rationale (audit M-7).
/// Same shape as `PromptMarkRateState` — kept as a separate type so the
/// constants are independent and the `clear_all` reset can target each
/// limiter individually (audit H-3).
#[derive(Clone, Copy)]
pub(crate) struct Osc7RateState {
    window_start: std::time::Instant,
    pub(crate) window_count: u32,
}

impl Osc7RateState {
    pub(crate) fn new() -> Self {
        Self {
            window_start: std::time::Instant::now(),
            window_count: 0,
        }
    }

    pub(crate) fn allow(&mut self) -> bool {
        let now = std::time::Instant::now();
        if now.duration_since(self.window_start) >= OSC7_INGEST_WINDOW {
            self.window_start = now;
            self.window_count = 0;
        }
        if self.window_count >= OSC7_INGEST_PER_SECOND {
            return false;
        }
        self.window_count += 1;
        true
    }
}
