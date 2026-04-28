//! blackbird_core — C ABI around `alacritty_terminal`.

use std::cell::UnsafeCell;
use std::os::raw::c_void;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;

use alacritty_terminal::event::{Event, EventListener};
use alacritty_terminal::grid::Dimensions;
use alacritty_terminal::term::cell::Flags as CellFlags;
use alacritty_terminal::term::{Config, Term, TermMode};
use alacritty_terminal::vte::ansi::{Color, NamedColor, Processor, Rgb};
use alacritty_terminal::vte::{Params, Parser, Perform};

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

// ---------------------------------------------------------------------------
// Public event-callback types
// ---------------------------------------------------------------------------

/// Kind of terminal event forwarded to the C caller.
#[repr(u32)]
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum BBEventKind {
    Title = 1,
    Bell = 2,
    /// Reserved for future use. Not currently emitted by RoutingListener —
    /// alacritty 0.26 doesn't surface cursor-shape changes as events. Swift
    /// readers should consume cursor state from snapshots.
    CursorShape = 3,
    Osc52Clipboard = 4,
    /// Bytes that should be written BACK to the PTY (terminal → shell).
    /// alacritty_terminal generates these in response to DSR queries (ESC[6n),
    /// DA1/DA2, DECRPM, and similar terminal-identification sequences. If the
    /// host ignores these, apps like nvim that probe terminal capabilities
    /// will time out waiting for a response.
    PtyWrite = 5,
    /// New in 2026-04-17 gaps plan. Payload: UTF-8 bytes of the local
    /// filesystem path decoded from an OSC 7 `file://` URL. Only emitted
    /// when scheme is `file` and authority is empty or `localhost`.
    ///
    /// OSC 7 is not parsed by `alacritty_terminal` 0.26 / `vte` 0.15 —
    /// the sequence falls through vte's `osc_dispatch` unhandled branch.
    /// We run a parallel `vte::Parser` in `bb_term_input` against an
    /// `Osc7Scanner` that fires only on this one sequence. See the
    /// scanner impl and the fragmentation test for details.
    CwdChanged = 6,
    /// OSC 133 prompt/command mark emitted by a shell-integration snippet
    /// (bash/zsh/fish). `i32_arg` carries the kind: 1=A (prompt start),
    /// 2=B (command start), 3=C (command output start), 4=D (command end).
    /// `payload` is the ASCII decimal exit code for kind D, empty otherwise.
    PromptMark = 7,
    Fatal = 99,
}

/// Event forwarded to the C callback.
///
/// `payload` is valid **only for the duration of the callback**; callers must
/// copy the bytes if they need them after the callback returns.
#[repr(C)]
pub struct BBEvent {
    pub kind: BBEventKind,
    /// Borrowed pointer into Rust-owned memory; null when `len == 0`.
    pub payload: *const u8,
    pub len: usize,
    /// Cursor-shape variant: 0 = block, 1 = bar, 2 = underline; 0 otherwise.
    pub i32_arg: i32,
}

/// C callback signature for terminal events.
pub type BBEventCb = unsafe extern "C" fn(BBEvent, *mut c_void);

// ---------------------------------------------------------------------------
// CallbackCell — shared mutable slot between BBTerm and RoutingListener
// ---------------------------------------------------------------------------

/// Interior-mutable storage for the registered C callback and its context
/// pointer.  Both `BBTerm` and `RoutingListener` reference the same cell;
/// `BBTerm` owns it via `Arc`.
///
/// # Thread-safety contract
/// All access to `CallbackCell` is restricted to the single thread that owns
/// the `BBTerm`.  `Term<RoutingListener>` and `Processor` are not `Sync`; the
/// FFI contract already forbids concurrent calls on the same `term` handle
/// (documented on `bb_term_input`).  Under this single-thread discipline no
/// data race can occur, making the `UnsafeCell` sound.
///
/// In debug builds, the first thread to touch the cell is latched into
/// `owner`; subsequent cross-thread access trips a `debug_assert_eq` — a
/// runtime diagnostic for the otherwise-silent UB if the Swift side
/// accidentally ships a handle across threads, or if a future
/// `alacritty_terminal` point release spawns a background thread that calls
/// `send_event`. Zero cost in release (rust-core-1 F2/F10).
struct CallbackCell {
    slot: UnsafeCell<(Option<BBEventCb>, *mut c_void)>,
    #[cfg(debug_assertions)]
    owner: std::sync::OnceLock<std::thread::ThreadId>,
}

// SAFETY: the owning BBTerm is never shared across threads; see contract above.
unsafe impl Send for CallbackCell {}
// SAFETY: same — no concurrent access is ever made.
unsafe impl Sync for CallbackCell {}

impl CallbackCell {
    fn new() -> Self {
        CallbackCell {
            slot: UnsafeCell::new((None, std::ptr::null_mut())),
            #[cfg(debug_assertions)]
            owner: std::sync::OnceLock::new(),
        }
    }

    #[cfg(debug_assertions)]
    fn debug_check_thread(&self) {
        let current = std::thread::current().id();
        let owner = *self.owner.get_or_init(|| current);
        debug_assert_eq!(
            owner, current,
            "blackbird_core: BBTerm handle used from multiple threads \
             (CallbackCell) — single-thread-per-handle contract violated",
        );
    }

    #[cfg(not(debug_assertions))]
    #[inline(always)]
    fn debug_check_thread(&self) {}

    /// Update the stored callback and context.
    ///
    /// # Safety
    /// Caller must ensure no concurrent access.
    unsafe fn set(&self, cb: Option<BBEventCb>, ctx: *mut c_void) {
        self.debug_check_thread();
        *self.slot.get() = (cb, ctx);
    }

    /// Invoke the stored callback if one is registered.
    ///
    /// # Safety
    /// Caller must ensure no concurrent access and that the `BBEvent` fields
    /// are valid for the duration of the call.
    unsafe fn fire(&self, event: BBEvent) {
        self.debug_check_thread();
        let (cb, ctx) = *self.slot.get();
        if let Some(f) = cb {
            f(event, ctx);
        }
    }
}

// ---------------------------------------------------------------------------
// ColorRequestQueue — deferred OSC 10/11/12 color-query responses
// ---------------------------------------------------------------------------

/// Parked `Event::ColorRequest` events. Alacritty fires these from inside
/// `term.dynamic_color_sequence`, which holds `&mut Term`; we can't re-borrow
/// the term to read the palette from the listener. Instead the listener
/// pushes `(index, formatter)` pairs here, and `bb_term_input` drains the
/// queue after `processor.advance` returns (releasing the mutable borrow),
/// resolves the palette value, calls the formatter, and fires a PtyWrite.
///
/// # DoS backstop
/// `push` is hard-capped at `COLOR_REQUEST_QUEUE_CAP` entries. A hostile
/// stream spamming `ESC]4;N;?BEL` across a single `bb_term_input` chunk
/// would otherwise force an unbounded number of `Arc<dyn Fn>` trait-object
/// allocations inside one call, inconsistent with the 4 KiB `xtgettcap_buf`
/// cap already defending the sibling DCS path (rust-core-1 F1). 256 covers
/// any legitimate probe — xterm reads the entire 256-entry palette at
/// startup — and is well below the point where per-entry allocation churn
/// becomes user-visible.
///
/// # Thread-safety contract
/// Same as `CallbackCell` — single-threaded access on the BBTerm owner's
/// thread. Debug builds latch `owner` on first access and debug_assert on
/// mismatch (rust-core-1 F2/F10).
struct ColorRequestQueue {
    entries: UnsafeCell<Vec<ColorRequestEntry>>,
    /// True once `push` has refused at least one entry since the latest
    /// `drain`. Drives a one-shot log per cap-hit episode — per-drop
    /// logging would itself become the DoS amplifier we're defending
    /// against.
    cap_hit_logged: UnsafeCell<bool>,
    #[cfg(debug_assertions)]
    owner: std::sync::OnceLock<std::thread::ThreadId>,
}

/// Upper bound on queued `ColorRequestEntry`s between two drains. See
/// `ColorRequestQueue` doc for rationale.
const COLOR_REQUEST_QUEUE_CAP: usize = 256;

struct ColorRequestEntry {
    index: usize,
    formatter: Arc<dyn Fn(Rgb) -> String + Sync + Send>,
}

// SAFETY: the owning BBTerm is never shared across threads; same reasoning
// as CallbackCell.
unsafe impl Send for ColorRequestQueue {}
unsafe impl Sync for ColorRequestQueue {}

impl ColorRequestQueue {
    fn new() -> Self {
        ColorRequestQueue {
            entries: UnsafeCell::new(Vec::new()),
            cap_hit_logged: UnsafeCell::new(false),
            #[cfg(debug_assertions)]
            owner: std::sync::OnceLock::new(),
        }
    }

    #[cfg(debug_assertions)]
    fn debug_check_thread(&self) {
        let current = std::thread::current().id();
        let owner = *self.owner.get_or_init(|| current);
        debug_assert_eq!(
            owner, current,
            "blackbird_core: BBTerm handle used from multiple threads \
             (ColorRequestQueue) — single-thread-per-handle contract violated",
        );
    }

    #[cfg(not(debug_assertions))]
    #[inline(always)]
    fn debug_check_thread(&self) {}

    /// Append an entry, dropping silently when the queue is already at
    /// `COLOR_REQUEST_QUEUE_CAP`. Returns `true` when the entry was
    /// accepted.
    ///
    /// # Safety
    /// Caller must ensure no concurrent access.
    unsafe fn push(&self, entry: ColorRequestEntry) -> bool {
        self.debug_check_thread();
        let vec = &mut *self.entries.get();
        if vec.len() >= COLOR_REQUEST_QUEUE_CAP {
            let logged = &mut *self.cap_hit_logged.get();
            if !*logged {
                *logged = true;
                eprintln!(
                    "blackbird_core: ColorRequestQueue hit cap ({COLOR_REQUEST_QUEUE_CAP}); \
                     further OSC 4/10/11/12 queries in this batch dropped"
                );
            }
            return false;
        }
        vec.push(entry);
        true
    }

    /// Take and clear the queue. Resets the cap-hit latch so the next
    /// hit episode logs again.
    ///
    /// # Safety
    /// Caller must ensure no concurrent access.
    unsafe fn drain(&self) -> Vec<ColorRequestEntry> {
        self.debug_check_thread();
        *self.cap_hit_logged.get() = false;
        std::mem::take(&mut *self.entries.get())
    }

    /// Number of currently-queued entries. Test-only introspection.
    ///
    /// # Safety
    /// Caller must ensure no concurrent access.
    #[cfg(test)]
    unsafe fn len(&self) -> usize {
        (*self.entries.get()).len()
    }
}

// ---------------------------------------------------------------------------
// RoutingListener — bridges alacritty_terminal events to C callbacks
// ---------------------------------------------------------------------------

/// Event listener that forwards terminal events to a registered C callback.
///
/// Shares ownership of the `CallbackCell` and `ColorRequestQueue` with the
/// parent `BBTerm` via `Arc`. The previous implementation used raw pointers
/// and relied on field drop order (`Term` dropped before `Box<CallbackCell>`)
/// to keep them valid — a structural invariant enforced only by comments.
/// `Arc` shares the allocation, so even in a future refactor where the
/// listener outlives the owning `BBTerm` or an event fires mid-teardown,
/// every access lands on live memory (rust-core-1 F3).
///
/// # Thread-safety contract
/// Must be constructed and used exclusively on the thread that owns the
/// `BBTerm`. The Arcs are `Send + Sync` (the inner cells unsafe-impl `Sync`
/// under single-thread discipline), but BBTerm's own single-thread rule
/// still forbids concurrent `bb_term_input` calls — that is the real
/// invariant. Arc merely removes the drop-order footgun that otherwise
/// turned a future refactor into silent use-after-free.
struct RoutingListener {
    cell: Arc<CallbackCell>,
    color_queue: Arc<ColorRequestQueue>,
    /// Sliding-window rate-limiter for `Event::PtyWrite` (DSR / DA1 /
    /// DA2 / DECXCPR replies). Per audit M1 — pre-fix a hostile shell
    /// streaming `ESC[6n` in a tight loop unboundedly fanned PtyWrite
    /// replies into the writeQueue, blocking keystrokes. Wrapped in
    /// `PtyWriteRateCell` (mirrors `ColorRequestQueue`'s pattern) so
    /// the Arc is `Send + Sync` under the single-thread-per-BBTerm
    /// discipline.
    pty_write_rate: Arc<PtyWriteRateCell>,
}

/// Rate-limiter state for PtyWrite reply events. Mutated only on the
/// BBTerm-owning thread; the Send/Sync impls below upgrade the
/// `Arc<…>` to thread-safe under that discipline (same pattern as
/// `ColorRequestQueue`).
#[derive(Debug)]
struct PtyWriteRateState {
    window_start: std::time::Instant,
    window_count: u32,
}

/// Send+Sync wrapper around `UnsafeCell<PtyWriteRateState>` so it can
/// live behind an `Arc` shared with `RoutingListener`. The wrapper is
/// the same shape `ColorRequestQueue` uses; both rely on the
/// single-thread-per-BBTerm contract documented in `RoutingListener`.
struct PtyWriteRateCell {
    state: UnsafeCell<PtyWriteRateState>,
}

// SAFETY: BBTerm's single-thread-per-handle contract (see
// `RoutingListener` doc) forbids concurrent access to the listener,
// and PtyWriteRateCell is reachable only via that listener.
unsafe impl Send for PtyWriteRateCell {}
unsafe impl Sync for PtyWriteRateCell {}

impl PtyWriteRateCell {
    fn new() -> Self {
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
    unsafe fn allow(&self) -> bool {
        (*self.state.get()).allow()
    }
}

const PTY_WRITE_REPLY_PER_SECOND: u32 = 32;
const PTY_WRITE_REPLY_WINDOW: std::time::Duration = std::time::Duration::from_secs(1);

impl PtyWriteRateState {
    fn new() -> Self {
        Self {
            window_start: std::time::Instant::now(),
            window_count: 0,
        }
    }

    /// Returns true if the dispatch is allowed; false if the cap has
    /// been hit and the caller should drop the event silently.
    fn allow(&mut self) -> bool {
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

/// Strip C0 controls (U+0000..=U+001F), DEL (U+007F), and C1 controls
/// (U+0080..=U+009F) from an OSC 0/1/2 window-title payload. Bug #18: a
/// hostile stream sets the title to `before\x1b[31mafter`; downstream
/// loggers / accessibility consumers misinterpret the embedded controls
/// even though NSWindow sanitizes for display.
///
/// Codepoint-wise filter so C1 (UTF-8 `0xC2 0x80..=0xC2 0x9F`) drops by
/// a single `c <= '\u{9F}'` check rather than a fragile byte sweep that
/// would corrupt multi-byte UTF-8.
///
/// Allocation note: alacritty hands us a `&String`; a clean (no-control)
/// title is the common case. We could short-circuit when no control char
/// is present, but the title path fires once per OSC 0/2 dispatch — at
/// most a few times per second even for animated TUIs — so a single
/// always-allocate keeps the code obvious.
fn scrub_title_controls(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        let cp = c as u32;
        let is_c0 = cp <= 0x1F;
        let is_del = cp == 0x7F;
        let is_c1 = (0x80..=0x9F).contains(&cp);
        if is_c0 || is_del || is_c1 {
            continue;
        }
        out.push(c);
    }
    out
}

impl EventListener for RoutingListener {
    fn send_event(&self, event: Event) {
        // SAFETY: `cell` and `color_queue` remain live for as long as any
        // Arc clone exists; single-thread discipline (see RoutingListener
        // doc) means no concurrent access.
        unsafe {
            match event {
                Event::Bell => {
                    self.cell.fire(BBEvent {
                        kind: BBEventKind::Bell,
                        payload: std::ptr::null(),
                        len: 0,
                        i32_arg: 0,
                    });
                }
                Event::Title(ref s) => {
                    // Bug #18: strip C0 (0x00..=0x1F), DEL (0x7F), and C1
                    // (U+0080..=U+009F) controls from the title before
                    // firing. A malicious shell or remote SSH session may
                    // emit `\x1b]2;before\x1b[31mafter\x07`; alacritty hands
                    // us the raw payload and downstream consumers (Swift
                    // NSWindow.title, telemetry, accessibility) treat the
                    // String literally. Display sanitizes, but stored /
                    // logged copies misinterpret embedded controls.
                    //
                    // Filter codepoint-wise so the C1 case (encoded as
                    // 0xC2 0x80..=0xC2 0x9F in UTF-8) is handled by char
                    // semantics rather than a fragile byte filter.
                    let scrubbed = scrub_title_controls(s);
                    let bytes = scrubbed.as_bytes();
                    self.cell.fire(BBEvent {
                        kind: BBEventKind::Title,
                        payload: bytes.as_ptr(),
                        len: bytes.len(),
                        i32_arg: 0,
                    });
                }
                Event::ClipboardStore(_, ref s) => {
                    self.cell.fire(BBEvent {
                        kind: BBEventKind::Osc52Clipboard,
                        payload: s.as_ptr(),
                        len: s.len(),
                        i32_arg: 0,
                    });
                }
                Event::PtyWrite(ref s) => {
                    // Sliding-window cap on cursor-position / DA / DSR /
                    // DECXCPR replies. A hostile shell streaming
                    // `ESC[6n` in a tight loop would otherwise pin
                    // coreQueue + writeQueue at 100% CPU and prevent
                    // user keystrokes from making forward progress.
                    // 32/sec is generous for legitimate query traffic
                    // (typically a handful at session start, plus
                    // rare reactive queries during e.g. nvim auto-
                    // detection). Audit M1.
                    //
                    // SAFETY: `pty_write_rate` is wrapped in
                    // `PtyWriteRateCell` shared via Arc; the
                    // single-thread-per-BBTerm discipline (see
                    // RoutingListener doc) means no concurrent
                    // mutation. We're already inside an `unsafe {}`
                    // block at the top of `send_event`.
                    let allowed = self.pty_write_rate.allow();
                    if !allowed {
                        return;
                    }
                    let bytes = s.as_bytes();
                    self.cell.fire(BBEvent {
                        kind: BBEventKind::PtyWrite,
                        payload: bytes.as_ptr(),
                        len: bytes.len(),
                        i32_arg: 0,
                    });
                }
                Event::ColorRequest(index, formatter) => {
                    // Defer — we're inside alacritty's &mut Term borrow via
                    // dynamic_color_sequence, so the palette isn't readable
                    // from here. `bb_term_input` drains this queue right
                    // after processor.advance returns, reads the palette,
                    // calls the formatter, and emits PtyWrite.
                    // push() is `bool`-returning for DoS capping; we ignore
                    // the drop signal here — the listener can't replywrite
                    // anyway, and the one-shot log inside push() surfaces
                    // the hostile case for diagnostics.
                    let _ = self
                        .color_queue
                        .push(ColorRequestEntry { index, formatter });
                }
                // All other variants (MouseCursorDirty, ResetTitle, ClipboardLoad,
                // TextAreaSizeRequest, CursorBlinkingChange, Wakeup, Exit,
                // ChildExit) are intentionally ignored.
                _ => {}
            }
        }
    }
}

// ---------------------------------------------------------------------------
// OscScanner — parallel vte::Parser tap for OSC sequences we handle outside
// of alacritty: OSC 7 (cwd) and OSC 133 (prompt marks).
// ---------------------------------------------------------------------------

/// Minimal `vte::Perform` impl that fires on OSC 7, OSC 133, and
/// XTGETTCAP (DCS `+ q` ... ST) payloads.
///
/// `alacritty_terminal` 0.26 / `vte` 0.15 do not handle these themselves —
/// they fall through vte's `osc_dispatch` to the unhandled branch. Rather
/// than wrap alacritty's `Handler` (which has a ~90-method surface we'd
/// have to forward perfectly), we run a second, stateful `vte::Parser`
/// owned by `BBTerm` and driven from `bb_term_input` with the same byte
/// stream. That parser drives this scanner, which dispatches by the first
/// OSC param and no-ops every other Perform method — except `hook`/`put`/
/// `unhook`, which implement Kitty's XTGETTCAP capability query protocol.
///
/// Consolidated from two separate parsers (one per OSC number) into one —
/// the earlier split cost ~15% of throughput because every byte was run
/// through three parsers total (alacritty's main + two parallels). One
/// scanner with an inexpensive first-param check is strictly cheaper.
///
/// XTGETTCAP state lives on `BBTerm` rather than this scanner because DCS
/// sequences can fragment across multiple `bb_term_input` calls; the
/// scanner is re-created per call and borrows the state via `&mut`.
struct OscScanner<'a> {
    cell: &'a CallbackCell,
    in_xtgettcap: &'a mut bool,
    xtgettcap_buf: &'a mut Vec<u8>,
    /// xterm `modifyOtherKeys` level bucket. `csi_dispatch` updates this
    /// when it sees `CSI > 4 ; N m`. 0 = off, 1 / 2 = level. Writer
    /// into `BBTerm.modify_other_keys`; downstream code reads the same
    /// field and maps non-zero to `bb_mode::MODIFY_OTHER_KEYS`.
    modify_other_keys: &'a mut u8,
    /// Sliding-window state for OSC 133 A/B/C rate limiting (audit
    /// synthesis #10 — prompt-mark forgery DoS / phishing). Persisted
    /// on `BBTerm` and threaded in via `&mut` because the scanner is
    /// rebuilt per `bb_term_input` call.
    prompt_mark_rate: &'a mut PromptMarkRateState,
}

/// Per-terminal sliding-window rate limiter for OSC 133 prompt marks.
///
/// Mitigates audit synthesis bug #10: an attacker emitting `OSC 133;A`
/// thousands of times per second floods Swift's `recordPromptStart` ring
/// (cap 200) and rotates legitimate prompt marks out, so ⌘↑/⌘↓ navigation
/// lands on attacker-authored "fake prompts" — a phishing primitive.
///
/// Policy: at most `PROMPT_MARK_PER_SECOND` A/B/C dispatches per rolling
/// 1-second window; D (command-end with exit code) is exempt because it
/// is paired 1:1 with a real C dispatch the user already accepted.
///
/// The window resets when `Instant::now()` is more than 1 second past
/// `window_start`. Excess fires within an active window are dropped
/// silently.
#[derive(Clone, Copy)]
struct PromptMarkRateState {
    window_start: std::time::Instant,
    window_count: u32,
}

const PROMPT_MARK_PER_SECOND: u32 = 16;
const PROMPT_MARK_WINDOW: std::time::Duration = std::time::Duration::from_secs(1);

/// OSC 10/11/12 color-query reply rate limit (audit synthesis bug #17).
/// `ColorRequestQueue::push` already caps at 256 entries per `bb_term_input`
/// chunk, but a hostile shell can split queries across many tight chunks to
/// bypass that per-call cap and amplify replies through the PTY. This
/// sliding-window cap covers the cross-chunk case using the same pattern as
/// `PromptMarkRateState`. 32/sec is generous (legitimate apps probe at most
/// a handful per second); excess replies are dropped silently.
const COLOR_QUERY_REPLY_PER_SECOND: u32 = 32;
const COLOR_QUERY_REPLY_WINDOW: std::time::Duration = std::time::Duration::from_secs(1);

impl PromptMarkRateState {
    fn new() -> Self {
        Self {
            window_start: std::time::Instant::now(),
            window_count: 0,
        }
    }

    /// Returns true if the dispatch is allowed; false if the window cap
    /// has been hit and the caller should drop the event.
    fn allow(&mut self) -> bool {
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

impl Perform for OscScanner<'_> {
    fn osc_dispatch(&mut self, params: &[&[u8]], bell_terminated: bool) {
        // Dispatch by OSC number. The first param is always the
        // semicolon-separated numeric prefix (e.g. `7`, `133`).
        match params.first().copied() {
            Some(b"7") => self.handle_osc7(params),
            Some(b"133") => self.handle_osc133(params),
            _ => {}
        }
        // bell_terminated is irrelevant to downstream semantics; included
        // here only to satisfy the Perform signature.
        let _ = bell_terminated;
    }

    fn csi_dispatch(&mut self, params: &Params, intermediates: &[u8], _ignore: bool, action: char) {
        // xterm `modifyOtherKeys`: `CSI > 4 ; N m`. `>` is the only
        // intermediate; first param == 4; second param == 0 (off), 1
        // (level 1), or 2 (level 2). We also accept `CSI > 4 m` (no
        // second param) as the reset form, matching xterm's manpage.
        // alacritty_terminal 0.26.0 does not handle this sequence —
        // we own the entire parse path for it.
        if action == 'm' && intermediates == [b'>'] {
            let mut it = params.iter();
            let first = it.next().and_then(|p| p.first().copied());
            if first == Some(4) {
                let level = it.next().and_then(|p| p.first().copied()).unwrap_or(0);
                let clamped: u8 = match level {
                    0 => 0,
                    1 | 2 => level as u8,
                    _ => return, // unknown level — ignore, don't poison state
                };
                *self.modify_other_keys = clamped;
            }
        }
    }

    fn hook(&mut self, _params: &Params, intermediates: &[u8], _ignore: bool, action: char) {
        // XTGETTCAP opens as `ESC P + q` — intermediates == [b'+'],
        // final byte == 'q'. Any other DCS (sixel, sync output, iTerm2
        // conductor, etc.) stays inert: `dcs_rejection` tests pin that.
        if intermediates == b"+" && action == 'q' {
            *self.in_xtgettcap = true;
            self.xtgettcap_buf.clear();
        }
    }

    fn put(&mut self, byte: u8) {
        // Only collect while inside a recognized XTGETTCAP sequence. Cap
        // at 4 KiB as a DoS backstop: a legitimate query is at most a
        // few hundred bytes; truncation of an oversized query produces
        // a short reply rather than a crash or unbounded allocation.
        if *self.in_xtgettcap && self.xtgettcap_buf.len() < 4096 {
            self.xtgettcap_buf.push(byte);
        }
    }

    fn unhook(&mut self) {
        if !*self.in_xtgettcap {
            return;
        }
        *self.in_xtgettcap = false;
        // `std::mem::take` moves the buffer's bytes+allocation out into
        // `buf` for the reply-building step; the field becomes
        // `Vec::new()` (capacity 0). The next DCS will re-alloc on its
        // first `put()`. XTGETTCAP is human-rate so this churn is
        // invisible; simpler code wins over a micro-optimization.
        let buf = std::mem::take(self.xtgettcap_buf);
        // SAFETY: our parallel `vte::Parser` is driven from
        // `bb_term_input` OUTSIDE alacritty's `&mut Term` borrow, so
        // firing synchronously here is safe — we are not re-entering
        // alacritty. No deferred queue needed (unlike OSC 10/11/12,
        // which must defer because they hit the palette mid-borrow).
        unsafe { dispatch_xtgettcap(self.cell, &buf) };
    }
}

/// Fire one `PtyWrite` reply per `;`-delimited cap. Unknown caps reply
/// with status 0 and no `=value`. Match replies echo the request's cap
/// hex verbatim (preserving casing) so TUIs can correlate requests and
/// replies without canonicalizing.
///
/// # Safety
/// Caller must ensure single-threaded access to `cell` (standard BBTerm
/// thread discipline).
unsafe fn dispatch_xtgettcap(cell: &CallbackCell, payload: &[u8]) {
    for cap_hex in payload.split(|&b| b == b';') {
        if cap_hex.is_empty() {
            // `;;` or leading/trailing `;` — skip silently.
            continue;
        }
        let reply = build_xtgettcap_reply(cap_hex);
        cell.fire(BBEvent {
            kind: BBEventKind::PtyWrite,
            payload: reply.as_ptr(),
            len: reply.len(),
            i32_arg: 0,
        });
        // `reply` drops here; `fire` is synchronous so the C callback
        // has already consumed the bytes by the time we release.
    }
}

fn build_xtgettcap_reply(cap_hex: &[u8]) -> Vec<u8> {
    // Reject anything that isn't pure hex. XTGETTCAP specifies the payload
    // as hex-encoded cap name bytes, but nothing upstream enforced it —
    // an ssh'd attacker could smuggle `\x1b\\` (ST) or other control
    // bytes inside the cap_hex echo of the DCS-0-r "unknown" response,
    // terminating the DCS early and landing the tail bytes as top-level
    // input (shell-injection primitive on the remote). Audit
    // rust-core-1 F8. Unknown non-hex cap → reply with an empty cap
    // name so the reply stays well-formed and the echo channel closes.
    let is_valid_hex = !cap_hex.is_empty() && cap_hex.iter().all(|b| b.is_ascii_hexdigit());
    match (is_valid_hex, find_cap_value(cap_hex)) {
        (true, Some(value_hex)) => {
            // DCS 1 + r <cap>=<value> ST
            let mut v = Vec::with_capacity(cap_hex.len() + value_hex.len() + 8);
            v.extend_from_slice(b"\x1bP1+r");
            v.extend_from_slice(cap_hex);
            v.push(b'=');
            v.extend_from_slice(value_hex);
            v.extend_from_slice(b"\x1b\\");
            v
        }
        (true, None) => {
            // DCS 0 + r <cap> ST — hex echo is safe.
            let mut v = Vec::with_capacity(cap_hex.len() + 7);
            v.extend_from_slice(b"\x1bP0+r");
            v.extend_from_slice(cap_hex);
            v.extend_from_slice(b"\x1b\\");
            v
        }
        (false, _) => {
            // DCS 0 + r ST — no echo; hostile bytes dropped.
            b"\x1bP0+r\x1b\\".to_vec()
        }
    }
}

/// ASCII-case-insensitive lookup against `XTGETTCAP_TABLE`. Cap hex is
/// canonically uppercase, but tolerate lowercase defensively — some
/// ncurses builds lowercase hex when emitting `tput`-style queries.
fn find_cap_value(cap_hex: &[u8]) -> Option<&'static [u8]> {
    for (key, value) in XTGETTCAP_TABLE {
        if cap_hex.eq_ignore_ascii_case(key) {
            return Some(value);
        }
    }
    None
}

/// Kitty XTGETTCAP capabilities Blackbird claims. Each row is
/// (hex-encoded cap name, hex-encoded terminfo-compiled value).
///
/// Values are the bytes of the terminfo string, hex-encoded upper-case.
/// `\E` in terminfo source is ESC (0x1B), not a literal `\`+`E`, so the
/// hex is `1B` in those positions.
///
/// Claimed caps (why each matters):
/// - TN     = "xterm-kitty"  — the terminal identity string some TUIs
///   key on to enable advanced protocols.
/// - Co     = "16777216"     — color count. Pre-LOW-sweep this was
///   "256" (legacy default), which made `tput colors` report 256 even
///   though Blackbird decodes truecolor SGR 38;2;R;G;Bm — TUIs that
///   gate truecolor branches on the terminfo Co value (mc, less +F,
///   ranger, some neovim plugins) fell back to 256-color paths.
///   Audit NEW-DF-004.
/// - RGB    = "8"             — truecolor bits per channel.
/// - Smulx  = "\E[4:%p1%dm"   — styled underline select (SGR 4:n).
/// - Setulc = "\E[58:2::%p1%{65536}%/%d:%p2%{256}%/%d:%p3%d%;m"
///   — RGB underline color (SGR 58:2:R:G:B).
///
/// Smulx/Setulc together are what nvim probes before emitting colored
/// undercurl (`spellbad`, LSP diagnostics). Getting both right is the
/// whole point of claiming xterm-kitty.
///
/// Test `core/tests/xtgettcap.rs::xtgettcap_smulx_returns_expected_hex`
/// and `..._setulc_returns_expected_hex` pin these exact hex strings.
static XTGETTCAP_TABLE: &[(&[u8], &[u8])] = &[
    // TN     = "TN"     → 544E        value "xterm-kitty"  → 787465726D2D6B69747479
    (b"544E", b"787465726D2D6B69747479"),
    // Co     = "Co"     → 436F        value "16777216"     → 3136373737323136
    (b"436F", b"3136373737323136"),
    // RGB    = "RGB"    → 524742      value "8"            → 38
    (b"524742", b"38"),
    // Smulx  = "Smulx"  → 536D756C78  value "\x1B[4:%p1%dm"
    //                                 → 1B5B343A25703125646D
    (b"536D756C78", b"1B5B343A25703125646D"),
    // Setulc = "Setulc" → 536574756C63
    //                                 value "\x1B[58:2::%p1%{65536}%/%d:%p2%{256}%/%d:%p3%d%;m"
    //                                 → see test for byte-by-byte derivation
    (
        b"536574756C63",
        b"1B5B35383A323A3A257031257B36353533367D252F25643A257032257B3235367D252F25643A2570332564253B6D",
    ),
];

impl OscScanner<'_> {
    fn handle_osc7(&mut self, params: &[&[u8]]) {
        let Some(url) = params.get(1) else { return };

        // Accept only `file://` with an empty or `localhost` authority.
        let Some(rest) = url.strip_prefix(b"file://") else {
            return;
        };
        let path_bytes: &[u8] = if rest.starts_with(b"/") {
            rest // "file:///path" → "/path"
        } else if let Some(r) = rest.strip_prefix(b"localhost") {
            if !r.starts_with(b"/") {
                return;
            }
            r // "file://localhost/path" → "/path"
        } else {
            return; // non-local host
        };

        let Some(decoded) = percent_decode(path_bytes) else {
            return;
        };
        // Spec (2026-04-17-blackbird-gaps-design.md §4.1): "Malformed UTF-8
        // in the path is ignored." Percent-decoding can produce arbitrary
        // byte sequences (e.g. `file:///%ff`), so validate before firing.
        // The event's payload contract in `BBEventKind::CwdChanged` is
        // UTF-8 bytes — Swift wraps the pointer in a Swift String which
        // assumes UTF-8 validity.
        let Ok(decoded_str) = std::str::from_utf8(&decoded) else {
            return;
        };
        // Reject embedded NUL bytes. `%00` is valid UTF-8 and slips past
        // the str::from_utf8 gate, but a pathname containing NUL is
        // nonsense at the OS level (C string terminator) and lets a
        // hostile payload truncate what downstream consumers see when
        // they cast through a C API. TST-S1-014.
        if decoded.contains(&0) {
            return;
        }
        // Reject every other ASCII control byte (0x01..=0x1F, 0x7F) too.
        // Same shape as OSC title control-char scrub (c9304c2): control
        // bytes in a chrome-displayed string can fool screen readers,
        // log shippers, or any downstream parser that doesn't pre-scrub.
        // Symmetric defense with the title path. Audit M13.
        if decoded.iter().any(|&b| b < 0x20 || b == 0x7F) {
            return;
        }
        // Reject Unicode bidi-control / zero-width / invisible-payload
        // codepoints in the path. Without this gate a hostile shell can
        // emit `OSC 7;file:///Users/foo/%E2%80%AE.bashrc` and the
        // titlebar proxy icon / "Open in Finder" affordance displays
        // the path RTL-flipped (visual `cqahsab.<rtl>oof/sresU/` while
        // the actual filesystem target is what Finder will open). Same
        // codepoint list the Swift paste sanitizer strips. Audit M2.
        if contains_bidi_or_invisible(decoded.as_slice()) {
            return;
        }
        // Audit synthesis #13 — path-traversal via percent-encoded `..`.
        // An attacker can emit `OSC 7;file:///%2e%2e/%2e%2e/etc/`. After
        // percent-decode the path is `../../../../etc/`; downstream
        // consumers (titlebar proxy icon, "Open in Finder", new-tab cwd
        // inheritance) all use the raw value via NSWorkspace. Drop the
        // event silently on any `..` segment OR any non-absolute path.
        // OSC 7 specifies an absolute path; relative paths are illegal
        // by spec.
        if !decoded_str.starts_with('/') {
            return;
        }
        for component in std::path::Path::new(decoded_str).components() {
            match component {
                // The standard parent-dir component.
                std::path::Component::ParentDir => return,
                // Defensive paranoia for the `\..` shape on
                // case-insensitive HFS+ / APFS — a literal `Normal`
                // component whose bytes equal `..` would mean some
                // higher layer mis-parsed components, but we'd still
                // refuse it.
                std::path::Component::Normal(s) if s.as_encoded_bytes() == b".." => {
                    return;
                }
                _ => {}
            }
        }
        // Audit synthesis #4 (SSH-trust gap): when the user is SSH'd to a
        // remote host, the remote shell can emit OSC 7 and Blackbird's
        // titlebar proxy icon will then point at the LOCAL filesystem
        // path with the same name. Click → Finder opens the local path.
        // The terminal core can't see the foreground process tree, so a
        // proper fix is a Swift-side `CwdResolver` check that walks the
        // PTY foreground process for an `ssh`/`mosh-client` child and
        // distrusts OSC 7 while one is alive. Tracked as deferred work in
        // KNOWN_ISSUES.md ("OSC 7 trust over SSH").
        // TODO(audit synthesis #4): wire CwdResolver SSH-trust gate.

        let ev = BBEvent {
            kind: BBEventKind::CwdChanged,
            payload: decoded.as_ptr(),
            len: decoded.len(),
            i32_arg: 0,
        };
        // SAFETY: `cell` is a live reference for the duration of this call;
        // `fire` invokes the C callback synchronously, so `decoded` (owned
        // by this stack frame) outlives the borrow the callback receives.
        // `decoded` drops at the end of this scope, after `fire` returns.
        unsafe { self.cell.fire(ev) };
    }

    fn handle_osc133(&mut self, params: &[&[u8]]) {
        let Some(kind_param) = params.get(1) else {
            return;
        };
        let kind_param = *kind_param;
        // The common split: some shells emit `OSC 133 ; D ; <code> ST` →
        // params = [b"133", b"D", b"0"]. Others combine: `OSC 133 ; D;0` →
        // params = [b"133", b"D;0"]. Handle both so snippets from iTerm2,
        // kitty, fish, starship, etc. all work.
        let (kind_byte, exit_code_bytes): (u8, &[u8]) = if kind_param.len() == 1 {
            (kind_param[0], params.get(2).copied().unwrap_or(b""))
        } else if let Some(idx) = kind_param.iter().position(|&b| b == b';') {
            // `D;<code>` — split on the first ';'.
            (kind_param[0], &kind_param[idx + 1..])
        } else {
            // Longer than 1 byte without a ';' — unknown extension.
            return;
        };

        let kind: u8 = match kind_byte {
            b'A' => BBPromptMarkKind::A as u8,
            b'B' => BBPromptMarkKind::B as u8,
            b'C' => BBPromptMarkKind::C as u8,
            b'D' => BBPromptMarkKind::D as u8,
            _ => return, // unknown sub-kind — silently ignore rather than crash.
        };

        // Audit synthesis #10 — OSC 133 prompt-mark forgery DoS / phishing.
        // Rate-limit the *navigable* mark kinds (A = prompt start, B =
        // command start, C = command output) at PROMPT_MARK_PER_SECOND
        // per rolling 1-second window. D (command end with exit code)
        // is exempt: it's tied 1:1 to a real C the user already accepted,
        // and dropping D would leave Swift's prompt-ring with dangling
        // half-open commands. Excess fires within an active window are
        // dropped silently.
        if matches!(kind_byte, b'A' | b'B' | b'C') && !self.prompt_mark_rate.allow() {
            return;
        }

        // Cap exit-code payload at 16 bytes. A well-behaved shell emits
        // at most 3–4 digits; anything longer is either malicious spam or
        // a bug and the hosting TUI wouldn't know what to do with it
        // either.
        let cap = exit_code_bytes.len().min(16);
        let payload = &exit_code_bytes[..cap];

        let ev = BBEvent {
            kind: BBEventKind::PromptMark,
            payload: payload.as_ptr(),
            len: payload.len(),
            // Pack kind (A/B/C/D as 1..=4) into i32_arg so Swift can
            // branch without parsing the payload.
            i32_arg: kind as i32,
        };
        // SAFETY: `payload` borrows `params` which the caller (vte parser)
        // owns for the duration of this callback. `fire` delivers
        // synchronously, so the borrow is alive for the full dispatch.
        unsafe { self.cell.fire(ev) };
    }
}

/// Shape of the OSC 133 prompt/command mark the shell emitted.
///
/// Values match the C enum layout — Swift casts these integers directly.
/// A / B / C / D are the four standard kinds in the de-facto prompt-marks
/// spec (Apple Terminal, iTerm2, kitty, Ghostty):
///   A = prompt start     — "I'm about to draw my prompt"
///   B = command start    — "prompt done, user is typing the command"
///   C = command output   — "user pressed enter, command is running"
///   D = command end      — "command finished, exit code follows"
/// Numeric values start at 1 so 0 stays reserved for "no mark".
#[repr(u8)]
#[derive(Clone, Copy)]
pub enum BBPromptMarkKind {
    A = 1,
    B = 2,
    C = 3,
    D = 4,
}

/// True when `bytes` contains any UTF-8 sequence for a Unicode bidi-
/// control / zero-width / invisible-payload codepoint. Symmetric with
/// the Swift paste sanitizer's `stripBidiOverrides` byte map.
///
/// Used by `handle_osc7` to refuse cwd paths that would visually
/// spoof the titlebar / "Open in Finder" target. A path like
/// `/Users/foo/%E2%80%AE.bashrc` decodes to RLO + `.bashrc`; any
/// renderer that honours bidi (NSTextField, AppKit titlebar) flips
/// the visible suffix while the filesystem target stays whatever the
/// shell actually said. The defense lives at the parse boundary so
/// EVERY downstream consumer of the path benefits.
///
/// Codepoints rejected (UTF-8 byte ranges):
///
///   2-byte:
///     C2 AD               U+00AD soft hyphen
///     D8 9C               U+061C ALM
///   3-byte:
///     E1 A0 8E            U+180E MVS
///     E2 80 8B..8F        U+200B-F ZWSP/ZWNJ/ZWJ/LRM/RLM
///     E2 80 A8..AE        U+2028/9 LS/PS, U+202A-E embed/override
///     E2 81 A0            U+2060 word joiner
///     E2 81 A6..A9        U+2066-9 isolates
///     EF B8 80..8F        U+FE00-F variation selectors 1-16
///     EF BB BF            U+FEFF BOM (ZWNBSP)
///   4-byte:
///     F3 A0 80..81 ?      U+E0000-E007F tag block
///     F3 A0 84..87 ? (≤AF on 87) U+E0100-E01EF VS17-256
///
/// Audit M2.
fn contains_bidi_or_invisible(bytes: &[u8]) -> bool {
    let mut i = 0;
    while i < bytes.len() {
        let remaining = bytes.len() - i;
        let b0 = bytes[i];
        // 2-byte
        if remaining >= 2 {
            let b1 = bytes[i + 1];
            if (b0 == 0xC2 && b1 == 0xAD) || (b0 == 0xD8 && b1 == 0x9C) {
                return true;
            }
        }
        // 3-byte
        if remaining >= 3 {
            let b1 = bytes[i + 1];
            let b2 = bytes[i + 2];
            if b0 == 0xE1 && b1 == 0xA0 && b2 == 0x8E {
                return true;
            }
            if b0 == 0xE2 {
                if b1 == 0x80 && (0x8B..=0x8F).contains(&b2) {
                    return true;
                }
                if b1 == 0x80 && (0xA8..=0xAE).contains(&b2) {
                    return true;
                }
                if b1 == 0x81 && (b2 == 0xA0 || (0xA6..=0xA9).contains(&b2)) {
                    return true;
                }
            }
            if b0 == 0xEF {
                if b1 == 0xB8 && (0x80..=0x8F).contains(&b2) {
                    return true;
                }
                if b1 == 0xBB && b2 == 0xBF {
                    return true;
                }
            }
        }
        // 4-byte
        if remaining >= 4 && b0 == 0xF3 {
            let b1 = bytes[i + 1];
            let b2 = bytes[i + 2];
            let b3 = bytes[i + 3];
            if b1 == 0xA0 {
                if b2 == 0x80 || b2 == 0x81 {
                    return true;
                }
                if (0x84..=0x87).contains(&b2) && (b2 < 0x87 || b3 <= 0xAF) {
                    return true;
                }
            }
        }
        i += 1;
    }
    false
}

/// RFC 3986 percent-decode. Returns `None` only on truncated escapes
/// (`%` with fewer than two hex digits remaining) or non-hex digits.
/// Raw bytes pass through unchanged.
fn percent_decode(bytes: &[u8]) -> Option<Vec<u8>> {
    fn hex(c: u8) -> Option<u8> {
        match c {
            b'0'..=b'9' => Some(c - b'0'),
            b'a'..=b'f' => Some(c - b'a' + 10),
            b'A'..=b'F' => Some(c - b'A' + 10),
            _ => None,
        }
    }
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' {
            if i + 2 >= bytes.len() {
                return None;
            }
            out.push((hex(bytes[i + 1])? << 4) | hex(bytes[i + 2])?);
            i += 3;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    Some(out)
}

// ---------------------------------------------------------------------------
// BBTerm
// ---------------------------------------------------------------------------

/// Opaque handle exposed to Swift.
///
/// `callback` and `color_queue` are shared with the owned `Term`'s
/// `RoutingListener` via `Arc`. Field drop order between `term` and the
/// cells is no longer load-bearing for memory safety (rust-core-1 F3):
/// each Arc keeps its inner cell alive as long as any clone exists, so an
/// event firing during `Term`'s destruction still lands on live memory.
pub struct BBTerm {
    term: Term<RoutingListener>,
    processor: Processor,
    /// Parallel `vte::Parser` that drives `OscScanner` for OSC 7 (cwd) and
    /// OSC 133 (prompt marks). Stateful across `bb_term_input` calls so
    /// fragmented sequences resolve to a single event. Kept separate from
    /// alacritty's internal parser so we never perturb the grid-mutation
    /// path. Consolidated from two parsers into one on 2026-04-19 —
    /// throughput tests showed running bytes through three parsers
    /// (alacritty + 2 parallels) cost ~15 % versus two parsers.
    osc_parser: Parser,
    /// Deferred queue of OSC 10/11/12 color-query responses — see
    /// ColorRequestQueue. Drained after every `processor.advance` call in
    /// `bb_term_input` so the response writes land in the same input
    /// batch that emitted the query. Responses are actually emitted only
    /// when `color_query_enabled` is true.
    color_queue: Arc<ColorRequestQueue>,
    /// Whether OSC 10 / 11 / 12 `?` queries produce a reply. Off by
    /// default: historically, replying leaked the palette back into the
    /// PTY, which zsh-vi-mode could interpret as commands (CVE class on
    /// older shells). Users who want nvim / tmux auto-theming on a
    /// modern shell can opt in via Preferences. See
    /// `core/tests/terminal_replies.rs::osc_10_11_color_queries_are_silent`
    /// for the default-off pinning.
    color_query_enabled: bool,
    /// Latch: "the prior `bb_term_input` chunk contained an ESC byte and
    /// may have left the OSC parser mid-sequence." When this is set, we
    /// advance the OSC parser regardless of whether the current chunk has
    /// ESC/BEL, so a split sequence (`\x1b]7;file://pa` + `th\x1b\\`)
    /// resolves correctly. Cleared when we advance on a chunk with NO
    /// ESC — which means either the prior sequence terminated in-chunk
    /// (BEL seen, or ESC\ fully present) or we had a false latch. For
    /// pure-text streams (no ESC anywhere), both bits stay false and we
    /// skip the osc_parser entirely — the dominant case for `yes(1)`,
    /// `cat` on logs, and pipe output. Saves ~10-15 % on plain_text.
    osc_possibly_pending: bool,
    /// XTGETTCAP (Kitty capability query) parser state. `in_xtgettcap`
    /// latches true between `hook` (header `DCS + q` seen) and `unhook`
    /// (ST terminator seen); `xtgettcap_buf` accumulates the payload
    /// bytes. Persists across `bb_term_input` calls so a DCS fragmented
    /// across PTY reads resolves to a single reply. See `OscScanner`'s
    /// `hook`/`put`/`unhook` and `core/tests/xtgettcap.rs`.
    in_xtgettcap: bool,
    xtgettcap_buf: Vec<u8>,
    /// xterm `modifyOtherKeys` current level. `0` = off, `1` = level 1
    /// (encode colliders + "unmapped" Ctrl combos), `2` = level 2
    /// (encode every modified printable, overriding legacy byte
    /// mappings). Driven by parser observations of `CSI > 4 ; N m`.
    /// Swift-side KeyEncoder reads this indirectly via
    /// `bb_mode::MODIFY_OTHER_KEYS` (any non-zero level → bit set).
    modify_other_keys: u8,
    /// OSC 133 A/B/C rate-limit window (audit synthesis #10). See
    /// `PromptMarkRateState`. Persisted across `bb_term_input` calls so
    /// the sliding window covers prompt marks that arrive in different
    /// PTY chunks.
    prompt_mark_rate: PromptMarkRateState,
    /// OSC 10/11/12 color-query reply sliding-window state (bug #17). The
    /// per-call `ColorRequestQueue` cap stops a single chunk from forcing
    /// 256+ allocations, but a hostile stream can fan replies across many
    /// chunks. Gating each `PtyWrite` reply in `drain_color_requests` by
    /// this 1-second window with `COLOR_QUERY_REPLY_PER_SECOND` cap makes
    /// the rate limit total, not per-call. Persisted across
    /// `bb_term_input` calls for the same reason as `prompt_mark_rate`.
    color_query_reply_window_start: std::time::Instant,
    color_query_reply_window_count: u32,
    callback: Arc<CallbackCell>,
    /// Persistent OSC 8 URI intern store (rust-core-3 F1). Maps URI string →
    /// shared `Arc<CStr>`; entries survive across snapshots so the same URI
    /// appearing frame after frame is interned exactly once (not per-snapshot).
    /// A new snapshot pushes `Arc::clone(&cstr)` into its local `links` Vec —
    /// cheap (one atomic increment) vs. the old `CString::new(uri.to_owned())`
    /// per appearance.
    ///
    /// Bounded globally by `uri_cache_bytes` against
    /// `OSC8_TOTAL_INTERN_BYTES_CAP` (1 MiB) so a hostile TUI writing
    /// distinct 4 KiB URIs cannot retain arbitrary megabytes of CStrings.
    /// When the budget would be exceeded, new URIs silently drop to
    /// `link_id = 0` (no link) rather than evicting older entries —
    /// eviction would invalidate the `*const c_char` returned by
    /// `bb_snap_link_url` on still-live snapshots that reference those
    /// Arcs.
    uri_cstr_cache: std::collections::HashMap<String, Arc<std::ffi::CStr>>,
    /// Total bytes currently retained by `uri_cstr_cache` (sum of URI byte
    /// lengths, excluding the terminating NUL). Drives the
    /// `OSC8_TOTAL_INTERN_BYTES_CAP` gate in `bb_term_take_snapshot`.
    uri_cache_bytes: usize,
}

// ---------------------------------------------------------------------------
// Panic-catching guard helpers
// ---------------------------------------------------------------------------

fn payload_to_string(payload: &(dyn std::any::Any + Send)) -> String {
    if let Some(s) = payload.downcast_ref::<&'static str>() {
        (*s).to_string()
    } else if let Some(s) = payload.downcast_ref::<String>() {
        s.clone()
    } else {
        "unknown panic".to_string()
    }
}

/// Wrap any FFI body that has a valid `BBTerm*` available. On panic:
/// 1. Extract a human-readable message
/// 2. Deliver a `BBEventKind::Fatal` event via the `BBTerm`'s callback (if set)
/// 3. Return the fallback value
///
/// # Safety
/// `term` must be either null (no event delivery) or a valid `&*term` target.
///
/// # Nested-delivery contract
/// If a panic occurs while a Fatal event is already being dispatched on this
/// thread (i.e. the user callback called back into a `bb_term_*` function
/// and that call panicked), the nested Fatal is SWALLOWED rather than
/// re-dispatched. Re-dispatching would invoke the same user callback while
/// it is still on the stack — a recipe for deadlock (the callback may hold
/// the lock it took on first entry) or unbounded recursion (if the callback
/// immediately re-panics). The Swift side cannot assume every panic within
/// a re-entered FFI call surfaces as a Fatal event; the first panic will,
/// subsequent nested ones won't. See rust-core-5 F3.
unsafe fn guard_with_term<T>(term: *mut BBTerm, fallback: T, f: impl FnOnce() -> T) -> T {
    match catch_unwind(AssertUnwindSafe(f)) {
        Ok(v) => v,
        Err(payload) => {
            // Re-entry guard: the dispatch below calls the user callback
            // with a Fatal event. If that dispatch is already in flight on
            // this thread (callback → bb_term_* → panic → we're here
            // again), swallow the payload to break the cycle.
            if FFI_FATAL_IN_FLIGHT.with(|c| c.get()) {
                return fallback;
            }
            let _guard = FatalInFlightGuard::enter();
            if !term.is_null() {
                let bb = &*term;
                let msg = payload_to_string(&*payload);
                let (cb, ctx) = *bb.callback.slot.get();
                if let Some(cb) = cb {
                    let bytes = msg.as_bytes();
                    let ev = BBEvent {
                        kind: BBEventKind::Fatal,
                        payload: bytes.as_ptr(),
                        len: bytes.len(),
                        i32_arg: 0,
                    };
                    // Double-panic safety: if the callback itself panics,
                    // catch and discard. Better to drop the Fatal notification
                    // than to unwind across extern "C" (UB).
                    // AssertUnwindSafe is sound here: state after a double-panic
                    // is considered poisoned; callers won't reuse this BBTerm.
                    let _ = catch_unwind(AssertUnwindSafe(|| cb(ev, ctx)));
                }
            }
            fallback
        }
    }
}

thread_local! {
    /// True while `guard_with_term` is dispatching a Fatal event to the user
    /// callback on this thread. Re-entering (callback → bb_term_* → panic)
    /// drops the nested Fatal instead of recursing. See rust-core-5 F3.
    static FFI_FATAL_IN_FLIGHT: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
}

/// RAII guard: flips `FFI_FATAL_IN_FLIGHT` to `true` on entry and back to
/// `false` on drop. The Drop impl also fires if an unexpected panic escapes
/// the inner `catch_unwind`, ensuring the latch never sticks.
struct FatalInFlightGuard;
impl FatalInFlightGuard {
    fn enter() -> Self {
        FFI_FATAL_IN_FLIGHT.with(|c| c.set(true));
        FatalInFlightGuard
    }
}
impl Drop for FatalInFlightGuard {
    fn drop(&mut self) {
        FFI_FATAL_IN_FLIGHT.with(|c| c.set(false));
    }
}

/// Panic-swallowing guard for contexts where no `BBTerm` exists yet
/// (`bb_term_new`'s allocation path, `bb_term_free`'s destructor).
fn guard_no_term<T>(fallback: T, f: impl FnOnce() -> T) -> T {
    match catch_unwind(AssertUnwindSafe(f)) {
        Ok(v) => v,
        Err(_payload) => fallback,
    }
}

// ---------------------------------------------------------------------------
// FFI entry points
// ---------------------------------------------------------------------------

/// Create a new terminal. Returns null on invalid input or internal error.
///
/// # Thread safety
/// The returned handle is NOT Sync / Sendable. Once created, every subsequent
/// `bb_term_*` call on this handle MUST happen on the same thread; the handle
/// may never be accessed concurrently from two threads, even with external
/// locking. Crossing threads is undefined behavior. In Swift, restrict the
/// handle to the @MainActor or confine it to a single dedicated serial queue.
/// Debug builds latch the first accessor's ThreadId and debug_assert on
/// mismatch (rust-core-1 F2/F10).
///
/// # Safety
/// The returned pointer must be freed exactly once via `bb_term_free`.
///
/// Panics inside this function are caught by `catch_unwind` and swallowed
/// silently (no `BBTerm` context is available yet to deliver a Fatal event).
/// The function returns null as the fallback value.
#[no_mangle]
pub unsafe extern "C" fn bb_term_new(cols: u16, rows: u16, scrollback: u32) -> *mut BBTerm {
    guard_no_term(std::ptr::null_mut(), || {
        if cols == 0 || rows == 0 {
            return std::ptr::null_mut();
        }
        // Same bounds as bb_term_resize — a caller passing UInt16.max
        // would try to allocate cols×rows×cell_size + scrollback ×
        // cols × cell_size, tens or hundreds of GB. Clamp up front so
        // bb_term_new is safe to call with any input.
        const MAX_DIM: u16 = 1000;
        let size = TermSize {
            cols: cols.min(MAX_DIM) as usize,
            rows: rows.min(MAX_DIM) as usize,
        };
        // Cap scrollback. Alacritty allocates a Cell (~16 B) per (col,
        // line) in scrollback lazily; paired with the 1000-col
        // theoretical ceiling above, worst-case allocation is cols ×
        // scrollback × ~16 B. At a realistic 120-col session × 200 000
        // lines × 16 B = ~384 MB worst-case, which fits comfortably on
        // modern Macs and gives Claude Code / dense-log workloads
        // iTerm2-class headroom. Allocation is lazy so a fresh session
        // costs almost nothing; memory grows only as output actually
        // scrolls off screen.
        const SCROLLBACK_MAX: u32 = 200_000;
        let scrollback = scrollback.min(SCROLLBACK_MAX);
        let config = Config {
            scrolling_history: scrollback as usize,
            // Opt into alacritty's kitty keyboard protocol dispatch. Without
            // this, push_keyboard_mode / pop_keyboard_modes / set_keyboard_mode
            // handlers early-return and the TermMode bits never light, even
            // when the TUI asks for disambiguated escape codes via ESC[>1u.
            // Claude Code, nvim 0.10+, WezTerm shells all expect this.
            kitty_keyboard: true,
            // Disable alacritty's in-term OSC 52 clipboard handling. The
            // alacritty default is `Osc52::OnlyCopy`, which lets any PTY
            // program silently stuff the macOS clipboard on write. Blackbird
            // owns the Swift-side clipboard gate (see `Osc52Clipboard` event
            // in `MainWindowController.swift`); disabling the alacritty
            // handler entirely gives defence-in-depth: even if the Swift
            // gate regresses, a hostile remote can't fall through to the
            // built-in `ClipboardStore` event. `Event::ClipboardStore` is
            // only emitted when alacritty accepts the OSC 52 write, so
            // `Osc52::Disabled` also stops the forwarding path at the
            // source. Users who want the historical behaviour must re-enable
            // via a future Preferences toggle.
            osc52: alacritty_terminal::term::Osc52::Disabled,
            ..Default::default()
        };

        let callback = Arc::new(CallbackCell::new());
        let color_queue = Arc::new(ColorRequestQueue::new());
        let pty_write_rate = Arc::new(PtyWriteRateCell::new());
        let listener = RoutingListener {
            cell: Arc::clone(&callback),
            color_queue: Arc::clone(&color_queue),
            pty_write_rate: Arc::clone(&pty_write_rate),
        };
        let term = Term::new(config, &size, listener);
        let bb = Box::new(BBTerm {
            term,
            processor: Processor::new(),
            osc_parser: Parser::new(),
            color_queue,
            color_query_enabled: false,
            osc_possibly_pending: false,
            in_xtgettcap: false,
            xtgettcap_buf: Vec::with_capacity(64),
            callback,
            uri_cstr_cache: std::collections::HashMap::new(),
            uri_cache_bytes: 0,
            modify_other_keys: 0,
            prompt_mark_rate: PromptMarkRateState::new(),
            color_query_reply_window_start: std::time::Instant::now(),
            color_query_reply_window_count: 0,
        });
        Box::into_raw(bb)
    })
}

/// Free a terminal handle created by `bb_term_new`.
///
/// # Safety
/// `term` must have been returned by `bb_term_new` and not previously freed.
/// Passing null is a no-op.
///
/// Panics inside this function are caught by `catch_unwind` and swallowed
/// silently (no safe `BBTerm` context is available during teardown to deliver
/// a Fatal event). The function returns unit as the fallback value.
#[no_mangle]
pub unsafe extern "C" fn bb_term_free(term: *mut BBTerm) {
    guard_no_term((), || {
        if term.is_null() {
            return;
        }
        drop(Box::from_raw(term));
    })
}

/// Feed `len` bytes from `bytes` into the terminal's VT parser.
///
/// # Safety
/// - `term` must be non-null, properly aligned (obtained from `bb_term_new`),
///   and not freed for the duration of this call.
/// - `bytes` must be non-null when `len > 0` and point to a readable region of
///   at least `len` bytes. Passing `bytes = null, len = 0` is safe (no-op).
/// - No two threads may call any `bb_term_*` function concurrently on the same
///   `term`; interior state is mutated and `Term`/`Processor` are not `Sync`.
///
/// Panics inside this function are caught by `catch_unwind` and delivered as a
/// `BBEventKind::Fatal` event to the registered callback. The function returns
/// unit as the fallback value.
#[no_mangle]
pub unsafe extern "C" fn bb_term_input(term: *mut BBTerm, bytes: *const u8, len: usize) {
    guard_with_term(term, (), || {
        if term.is_null() || len == 0 || bytes.is_null() {
            return;
        }
        let bb = &mut *term;
        let slice = std::slice::from_raw_parts(bytes, len);
        // `CSI 2 J` (ED All — erase visible viewport) is NOT augmented with
        // `CSI 3 J` (erase scrollback). A previous revision auto-injected 3J
        // on every top-level 2J so `clear(1)` would also wipe scrollback,
        // matching `clear -x` / iTerm2's optional behavior. That heuristic
        // misfired in the field: TUIs (Claude Code's Ink renderer, ratatui
        // spinners, fzf full-screen redraws) emit 2J on every redraw cycle,
        // and the injected 3J wiped the user's scrollback on each frame.
        // Users now have ⌘K (`bb_term_clear_all`) for the explicit
        // viewport+scrollback wipe; `clear(1)` is viewport-only, matching
        // xterm / Alacritty / Terminal.app.
        //
        // Fast path: if the chunk contains no ESC byte at all, we can't have
        // any CSI sequence, so the OSC-parser is only needed when a prior
        // chunk left one pending.
        if memchr::memchr(0x1B, slice).is_none() {
            bb.processor.advance(&mut bb.term, slice);
            // OSC parser skip: pure-text chunks don't need the parallel
            // state machine UNLESS (a) a prior chunk opened an OSC that
            // may still be open, or (b) this chunk contains a BEL that
            // could be an OSC terminator. For streams with zero ESC / BEL
            // (the plain_text / `yes(1)` / `cat log` case), we skip
            // vte::Parser entirely after the first ESC-free chunk.
            //
            // Clearing the latch: after an ESC-free advance, any
            // ST-terminated (ESC \) OSC is still pending by definition
            // (ST requires an ESC, which we didn't see). Only a BEL in
            // this chunk can have terminated the pending sequence, so we
            // clear the latch only then. Unterminated sequences stay
            // pending forever — pathological but harmless.
            let has_bel = memchr::memchr(0x07, slice).is_some();
            // Also drive the parallel parser while we are mid-XTGETTCAP:
            // a `put`-heavy hex payload can be pure ASCII with no ESC/BEL,
            // so the `hook` latch is what keeps us here.
            //
            // `|| bb.in_xtgettcap`: defensive. If a future code path ever
            // clears `osc_possibly_pending` while a DCS is still open
            // (e.g. a ST-only terminator path we haven't needed yet),
            // this keeps the osc_parser alive so our hook/put/unhook
            // state advances. No current fragmentation scenario reaches
            // this branch because `osc_possibly_pending` stays true from
            // the DCS's opening ESC; kept as a safety belt.
            if bb.osc_possibly_pending || has_bel || bb.in_xtgettcap {
                let mut osc = OscScanner {
                    cell: &bb.callback,
                    in_xtgettcap: &mut bb.in_xtgettcap,
                    xtgettcap_buf: &mut bb.xtgettcap_buf,
                    modify_other_keys: &mut bb.modify_other_keys,
                    prompt_mark_rate: &mut bb.prompt_mark_rate,
                };
                bb.osc_parser.advance(&mut osc, slice);
                if has_bel {
                    bb.osc_possibly_pending = false;
                }
            }
            drain_color_requests(bb);
            return;
        }
        // Chunk contains ESC — may open a new OSC that terminates in a
        // later chunk. Set the latch so subsequent ESC-free chunks still
        // reach the parser.
        bb.osc_possibly_pending = true;
        // Drive the parallel OSC parser whole-chunk: it watches for OSC 7,
        // OSC 133, and the modify-other-keys CSI. None of those need byte-
        // precise dispatch positions, so a single `advance` is enough.
        let mut osc = OscScanner {
            cell: &bb.callback,
            in_xtgettcap: &mut bb.in_xtgettcap,
            xtgettcap_buf: &mut bb.xtgettcap_buf,
            modify_other_keys: &mut bb.modify_other_keys,
            prompt_mark_rate: &mut bb.prompt_mark_rate,
        };
        bb.osc_parser.advance(&mut osc, slice);
        bb.processor.advance(&mut bb.term, slice);
        drain_color_requests(bb);
    })
}

/// Resolve every pending OSC 10/11/12 response and emit it as a PtyWrite
/// event. Called after every `processor.advance` in `bb_term_input`
/// returns — at that point we're no longer inside alacritty's `&mut Term`
/// borrow, so the palette is readable.
///
/// # Safety
/// Caller must ensure single-threaded access to `bb.color_queue` and
/// `bb.callback` (the usual BBTerm thread discipline).
unsafe fn drain_color_requests(bb: &mut BBTerm) {
    let entries = (*bb.color_queue).drain();
    if entries.is_empty() {
        return;
    }
    // Security default: drop the queue silently unless the user has
    // explicitly enabled replies. Ignoring here rather than blocking the
    // push keeps the wire path identical in both modes — a future
    // always-enable would only need to flip this flag.
    if !bb.color_query_enabled {
        return;
    }
    let palette = bb.term.colors();
    // `palette` is alacritty's fixed-width `Colors` table. Its length is a
    // public `COUNT` constant (269 today — 256 indexed + 13 named). The
    // `Index` impl panics on out-of-bounds, so bound-check first. A
    // direct index was sound for every value the current alacritty/vte
    // surface can emit, but future widenings must not panic into
    // `BBEventKind::Fatal` (rust-core-2 F2).
    for entry in entries {
        // Bug #17 sliding-window gate: cap PtyWrite replies at
        // COLOR_QUERY_REPLY_PER_SECOND across the rolling
        // COLOR_QUERY_REPLY_WINDOW. The per-chunk
        // ColorRequestQueue cap stops in-call amplification; this
        // covers the cross-chunk case.
        let now = std::time::Instant::now();
        if now.duration_since(bb.color_query_reply_window_start) >= COLOR_QUERY_REPLY_WINDOW {
            bb.color_query_reply_window_start = now;
            bb.color_query_reply_window_count = 0;
        }
        if bb.color_query_reply_window_count >= COLOR_QUERY_REPLY_PER_SECOND {
            // Drop silently — matching the PromptMarkRateState pattern.
            continue;
        }
        bb.color_query_reply_window_count += 1;

        let slot: Option<alacritty_terminal::vte::ansi::Rgb> =
            if entry.index < alacritty_terminal::term::color::COUNT {
                palette[entry.index]
            } else {
                None
            };
        // palette[idx] is Option<Rgb>. None means the theme hasn't set
        // this slot; fall back to a sensible default so we still reply
        // rather than leaving the TUI timing out.
        let rgb = slot.unwrap_or_else(|| palette_default_rgb(entry.index));
        let reply = (entry.formatter)(rgb);
        // The `reply` String owns its bytes for the duration of this
        // scope; `fire` is synchronous (calls the registered C callback
        // which must copy bytes if it wants to outlive the call).
        let bytes = reply.as_bytes();
        bb.callback.fire(BBEvent {
            kind: BBEventKind::PtyWrite,
            payload: bytes.as_ptr(),
            len: bytes.len(),
            i32_arg: 0,
        });
    }
}

/// Fallback Rgb for palette slots the theme hasn't filled in. OSC 10 / 11 /
/// 12 queries target indices 256 (Foreground), 257 (Background), 258
/// (Cursor). The 16 base colors use the xterm default table; the 240-entry
/// 256-color cube is computed. Anything outside that falls back to a
/// visible-on-any-background grey so silence is never the TUI's response.
fn palette_default_rgb(index: usize) -> Rgb {
    let packed: u32 = if index < 256 {
        indexed_color_rgb(index as u8)
    } else {
        match index {
            256 => named_color_rgb(&NamedColor::Foreground),
            257 => named_color_rgb(&NamedColor::Background),
            258 => 0xFFFFFF, // cursor default: solid white
            _ => 0xEEEEEE,
        }
    };
    Rgb {
        r: ((packed >> 16) & 0xFF) as u8,
        g: ((packed >> 8) & 0xFF) as u8,
        b: (packed & 0xFF) as u8,
    }
}

/// Flat cell layout for cross-language consumption. Swift reads these directly.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct BBCell {
    pub ch: u32, // Unicode scalar; 0 means empty
    pub fg: u32, // 0xRRGGBB
    pub bg: u32,
    pub flags: u16, // See cell_flags
    /// Index into `BBSnap::links` (0 means no OSC 8 attribution on this cell).
    /// Resolve via `bb_snap_link_url(snap, link_id)`.
    pub link_id: u16,
    /// CSI 58 colored-underline — the user may explicitly set the underline's
    /// colour independent of the glyph fg. alacritty 0.26 stores this as
    /// `Option<Color>` on the cell's extra; we flatten to a u32 with a magic
    /// sentinel: `UNDERLINE_COLOR_UNSET` (0xFFFF_FFFF) means "follow fg".
    /// Any other value is `0x00RRGGBB`.
    ///
    /// Ignored unless at least one underline-style bit is set in `flags`.
    /// Widens BBCell from 16 to 20 bytes — still 4-aligned, still fast to
    /// iterate over 16k cells.
    pub underline_color: u32,
}

/// Sentinel for `BBCell::underline_color` meaning "no explicit underline
/// colour set; use the cell's fg". Chosen as u32::MAX because alacritty's
/// RGB representation tops out at 0x00FF_FFFF and 0xFF000000 bits are
/// otherwise unused — picking a sentinel outside the valid RGB range avoids
/// a flag bit.
pub const UNDERLINE_COLOR_UNSET: u32 = 0xFFFF_FFFF;

pub mod cell_flags {
    pub const BOLD: u16 = 1 << 0;
    pub const ITALIC: u16 = 1 << 1;
    pub const UNDERLINE: u16 = 1 << 2;
    pub const REVERSE: u16 = 1 << 3;
    pub const DIM: u16 = 1 << 4;
    pub const STRIKE: u16 = 1 << 5;
    /// Cell holds the left half of a wide (double-width) glyph — CJK, some
    /// emoji, and private-use ranges like Nerd Font glyphs tagged wide. The
    /// renderer draws the glyph from this cell occupying two cell widths.
    pub const WIDE_CHAR: u16 = 1 << 6;
    /// Cell is the right half of a wide glyph — the renderer must not draw
    /// a glyph here (the wide one in the preceding cell already covers it).
    /// Filling this cell with a space overpaints the CJK/emoji character.
    pub const WIDE_CHAR_SPACER: u16 = 1 << 7;
    /// Cell is the unused column to the LEFT of a wide glyph that wrapped
    /// because only one column remained on the prior row. Same rule as
    /// WIDE_CHAR_SPACER — don't draw.
    pub const LEADING_WIDE_CHAR_SPACER: u16 = 1 << 8;
    /// CSI 21 m — double underline. Mutually exclusive with the other four
    /// underline style bits at the alacritty level (`ALL_UNDERLINES` mask).
    pub const UNDERLINE_DOUBLE: u16 = 1 << 9;
    /// CSI 4:3 m — wavy / undercurl. Neovim/Helix LSP diagnostics emit this
    /// for warnings/errors; having it rendered correctly matters for the
    /// agentic-CLI correctness wedge.
    pub const UNDERCURL: u16 = 1 << 10;
    /// CSI 4:4 m — dotted underline.
    pub const UNDERLINE_DOTTED: u16 = 1 << 11;
    /// CSI 4:5 m — dashed underline.
    pub const UNDERLINE_DASHED: u16 = 1 << 12;
}

/// Terminal mode bitflags mirrored from `alacritty_terminal::term::TermMode`.
/// These are stable across Blackbird versions; the underlying alacritty bits
/// are intentionally not exposed directly so we can version them independently.
pub mod bb_mode {
    pub const ALT_SCREEN: u32 = 1 << 0;
    pub const APP_CURSOR: u32 = 1 << 1;
    pub const APP_KEYPAD: u32 = 1 << 2;
    pub const BRACKETED_PASTE: u32 = 1 << 3;
    pub const MOUSE_REPORT_CLICK: u32 = 1 << 4;
    pub const MOUSE_MOTION: u32 = 1 << 5;
    pub const MOUSE_DRAG: u32 = 1 << 6;
    pub const SGR_MOUSE: u32 = 1 << 7;
    pub const FOCUS_IN_OUT: u32 = 1 << 8;
    pub const SHOW_CURSOR: u32 = 1 << 9;
    pub const LINE_WRAP: u32 = 1 << 10;
    // Kitty keyboard protocol bits. The TUI enables these via ESC[>{flags}u
    // progressive-enhancement pushes; once `DISAMBIGUATE_ESC_CODES` is set the
    // input encoder must emit CSI u sequences for modified keys so apps can
    // distinguish Shift+Enter from Enter, Ctrl+i from Tab, etc.
    pub const DISAMBIGUATE_ESC_CODES: u32 = 1 << 11;
    pub const REPORT_EVENT_TYPES: u32 = 1 << 12;
    pub const REPORT_ALTERNATE_KEYS: u32 = 1 << 13;
    pub const REPORT_ALL_KEYS_AS_ESC: u32 = 1 << 14;
    pub const REPORT_ASSOCIATED_TEXT: u32 = 1 << 15;
    /// xterm `modifyOtherKeys` level ≥ 1 is active. Enabled by
    /// `CSI > 4 ; 1 m` or `CSI > 4 ; 2 m`; cleared by `CSI > 4 ; 0 m`.
    /// Blackbird treats both non-zero levels as "on" — Emacs asks for
    /// level 2; level 1's gating table is historical and rarely requested
    /// in practice. When on, the KeyEncoder emits
    /// `CSI 27 ; <mod> ; <cp> ~` for modified printables + control-code
    /// colliders (Tab/Enter/Esc/Backspace) instead of raw bytes. See
    /// <https://invisible-island.net/xterm/modified-keys.html>.
    ///
    /// Precedence: Kitty flags (if any set) take priority over
    /// modifyOtherKeys. A TUI that pushes Kitty gets Kitty output;
    /// Emacs without Kitty gets modifyOtherKeys output.
    pub const MODIFY_OTHER_KEYS: u32 = 1 << 16;
}

/// Immutable snapshot of terminal grid state. Ref-counted via `bb_snap_retain` /
/// `bb_snap_release`. The `cells` pointer is stable for the lifetime of the snapshot.
///
/// `cells` is non-null and points to exactly `cells_len` consecutive `BBCell` elements for the
/// lifetime of this snapshot. It is never null for any snapshot returned by
/// `bb_term_take_snapshot`, because `bb_term_new` rejects zero dimensions and `display_iter()`
/// always yields `cols * rows` cells.
///
/// The actual heap allocation is `BBSnapOwned`; the raw pointer exposed to C points to the
/// `snap` field at offset 0 of that struct. Do not construct or free `BBSnap` directly.
#[repr(C)]
pub struct BBSnap {
    pub cols: u16,
    pub rows: u16,
    pub cursor_col: u16,
    pub cursor_row: u16,
    pub cursor_visible: u8,
    /// Pads `display_offset` (u32) to a 4-byte boundary. Without this
    /// the field would land at offset 9 and Rust's repr(C) would
    /// inject 3 bytes of implicit padding that cbindgen wouldn't
    /// reflect in the header — Swift would then read a mis-offset
    /// field. Explicit padding keeps the C and Rust layouts in lock-
    /// step. (Pre-M5 this was 1 byte aligning the previous u16.)
    pub _pad: [u8; 3],
    /// Number of lines the viewport is scrolled above the live grid. 0 means
    /// we're pinned to the bottom (live content). When > 0 the renderer must
    /// offset the cursor by this amount or hide it if the live cursor row is
    /// no longer visible.
    ///
    /// Width: `u32` — scrollback cap is 200 000 lines, well past
    /// `u16::MAX` (65 535). The previous u16 saturated silently, so a
    /// user scrolled past line 65 535 saw the offset frozen at 65 535
    /// while alacritty's real offset kept growing. The renderer's
    /// `FrameKey.displayOffset` was widened to UInt32 in b3edd7e to
    /// defend against narrow-key wraparound, but the data was already
    /// flat at the FFI boundary — that fix is only complete now that
    /// the source field matches. Audit M5.
    pub display_offset: u32,
    pub mode: u32, // terminal mode bitflags — see bb_mode constants
    pub cells_len: usize,
    pub cells: *const BBCell,
    /// Total lines currently retained in scrollback (grows as output flows
    /// off-screen, capped at the scrollback limit). Used by the scroll
    /// indicator to size its thumb proportional to total-buffer vs viewport.
    /// Appended here to preserve the existing offsets of cells_len/cells.
    pub history_size: u32,
    /// DECSCUSR cursor shape: 0 = block, 1 = bar/beam, 2 = underline, 3 = hidden.
    /// Sourced from `Term::cursor_style().shape` at snapshot time. Callers
    /// render according to this; a value of 3 means the renderer should skip
    /// drawing the cursor entirely.
    pub cursor_shape: u8,
    pub _pad2b: [u8; 3],
}

unsafe impl Send for BBSnap {}
// SAFETY: all fields are read-only after BBSnapOwned::new returns; cells aliases
// cells_owned's heap buffer which is never reallocated after construction.
unsafe impl Sync for BBSnap {}

/// Private heap owner for a snapshot. `snap` is the first field so that a
/// `*const BBSnap` == `*const BBSnapOwned` via a simple cast, enabling the
/// public C API to hand out `*const BBSnap` while retaining full ownership here.
#[repr(C)]
struct BBSnapOwned {
    snap: BBSnap,
    rc: AtomicUsize,
    cells_owned: Vec<BBCell>,
    /// OSC 8 URI table. Empty when the grid had no OSC 8 cells (rust-core-3 F9
    /// short-circuit — no sentinel push, no HashMap, no allocation); otherwise
    /// index 0 is a reserved empty-string sentinel and index N matches
    /// `BBCell.link_id`. Stored as `Arc<CStr>` so the same interned URI is
    /// shared across snapshots via `BBTerm::uri_cstr_cache` (rust-core-3 F1),
    /// avoiding a `CString::new(uri.to_owned())` per appearance. The pointer
    /// handed out by `bb_snap_link_url` is stable for the snapshot's lifetime
    /// because the Arc's pointee never moves.
    links: Vec<Arc<std::ffi::CStr>>,
    /// Rows whose content changed between this snapshot and the previous.
    /// Extracted from alacritty's `Term::damage()` before the grid read, then
    /// the term's damage is reset so each snapshot reports deltas.
    /// Empty when `damage_full == true` OR when nothing changed; readers
    /// disambiguate via `damage_full`.
    damaged_rows: Vec<u16>,
    /// True when alacritty reports full damage (scroll, insert-mode, or a
    /// similar wholesale change). A `true` value means the renderer must
    /// redraw everything and `damaged_rows` is irrelevant.
    damage_full: bool,
}

// SAFETY: see BBSnap's unsafe impl Send above; same reasoning applies.
unsafe impl Send for BBSnapOwned {}
// SAFETY: rc is AtomicUsize (Sync); snap and cells_owned are read-only after construction.
unsafe impl Sync for BBSnapOwned {}

impl BBSnapOwned {
    // Passing 10 args is deliberate — collapsing into a struct just to appease
    // the lint would obscure the call site, which is a single private caller
    // inside `bb_term_take_snapshot`.
    #[allow(clippy::too_many_arguments)]
    fn new(
        cols: u16,
        rows: u16,
        cursor: (u16, u16, bool),
        display_offset: u32,
        history_size: u32,
        mode: u32,
        cursor_shape: u8,
        cells: Vec<BBCell>,
        links: Vec<Arc<std::ffi::CStr>>,
        damaged_rows: Vec<u16>,
        damage_full: bool,
    ) -> Box<BBSnapOwned> {
        let mut owned = Box::new(BBSnapOwned {
            snap: BBSnap {
                cols,
                rows,
                cursor_col: cursor.0,
                cursor_row: cursor.1,
                cursor_visible: cursor.2 as u8,
                _pad: [0; 3],
                display_offset,
                mode,
                cells_len: cells.len(),
                cells: std::ptr::null(),
                history_size,
                cursor_shape,
                _pad2b: [0; 3],
            },
            rc: AtomicUsize::new(1),
            cells_owned: cells,
            links,
            damaged_rows,
            damage_full,
        });
        // Capture the stable heap pointer into the public field.
        owned.snap.cells = owned.cells_owned.as_ptr();
        owned
    }

    /// Recover a mutable `BBSnapOwned` reference from a `*const BBSnap`.
    ///
    /// # Safety
    /// `snap` must point to the `snap` field of a live `BBSnapOwned` allocated
    /// by `BBSnapOwned::new`. Because `snap` is the first field and both types
    /// are `#[repr(C)]`, the pointer values are identical.
    unsafe fn from_snap_ptr(snap: *const BBSnap) -> *mut BBSnapOwned {
        snap as *mut BBSnapOwned
    }
}

/// Resize the terminal grid. Out-of-range (zero) dimensions are ignored.
///
/// # Safety
/// `term` must be a valid non-null pointer from `bb_term_new`, properly
/// aligned, not freed for the duration of the call. No concurrent calls on
/// the same term.
///
/// Panics inside this function are caught by `catch_unwind` and delivered as a
/// `BBEventKind::Fatal` event to the registered callback. The function returns
/// unit as the fallback value.
///
/// Callers that need to know whether the requested dimensions were clamped
/// should prefer `bb_term_resize2`, which returns the actually-applied dims
/// and a `clamped` flag. The void-returning form here is retained for ABI
/// stability; it internally delegates to the same clamp logic.
#[no_mangle]
pub unsafe extern "C" fn bb_term_resize(term: *mut BBTerm, cols: u16, rows: u16) {
    let _ = bb_term_resize2(term, cols, rows);
}

/// Result of `bb_term_resize2`. `applied_cols` / `applied_rows` report the
/// dimensions the grid was actually resized to after clamping (floor = 2,
/// ceiling = 1000 on each axis); `clamped` is non-zero when either requested
/// dim differed from the applied value. On a no-op call (null term, or zero
/// in either dim) all three fields are `0`.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct BBResizeResult {
    pub applied_cols: u16,
    pub applied_rows: u16,
    /// Non-zero when the request was rewritten by the clamp; zero when the
    /// grid now holds exactly the requested dims (or on no-op).
    pub clamped: u8,
    pub _pad: [u8; 3],
}

/// Resize the terminal grid and report the actually-applied dimensions.
///
/// Dimensions are clamped to `[2, 1000]` on each axis to avoid the reflow
/// explosion on tiny grids and the 100+ GB allocation on huge grids
/// (documented in the floor/ceiling comment inside this function and in
/// `MEMORY`). Zero on either axis is a no-op and returns
/// `BBResizeResult { 0, 0, 0 }`.
///
/// `clamped` is the signal to Swift that `TIOCSWINSZ` should be told the
/// APPLIED size, not the requested one — otherwise the shell and the grid
/// disagree about the viewport (rust-core-3 F4).
///
/// # Safety
/// Same as `bb_term_resize`.
#[no_mangle]
pub unsafe extern "C" fn bb_term_resize2(
    term: *mut BBTerm,
    cols: u16,
    rows: u16,
) -> BBResizeResult {
    let fallback = BBResizeResult {
        applied_cols: 0,
        applied_rows: 0,
        clamped: 0,
        _pad: [0; 3],
    };
    guard_with_term(term, fallback, || {
        if term.is_null() || cols == 0 || rows == 0 {
            return fallback;
        }
        // Floor + ceiling on dimensions. The floor (2) prevents reflow
        // explosion on shrink (1-col scrollback = millions of 1-cell
        // rows). The ceiling (1000) prevents a caller passing a huge
        // value (UInt16.max = 65535) from allocating
        // rows × (cols + scrollback) × cell_size bytes — at 65535 ×
        // (65535 + 200000) × 32B that's ~520 GB, enough to freeze any
        // machine. 1000 × 1000 × 32B ≈ 32 MB grid, comfortable.
        const MIN_DIM: u16 = 2;
        const MAX_DIM: u16 = 1000;
        let bb = &mut *term;
        let applied_cols = cols.clamp(MIN_DIM, MAX_DIM);
        let applied_rows = rows.clamp(MIN_DIM, MAX_DIM);
        let size = TermSize {
            cols: applied_cols as usize,
            rows: applied_rows as usize,
        };
        bb.term.resize(size);
        BBResizeResult {
            applied_cols,
            applied_rows,
            clamped: u8::from(applied_cols != cols || applied_rows != rows),
            _pad: [0; 3],
        }
    })
}

/// Register (or clear) the event callback for a terminal.
///
/// Pass `cb = None` to disable event delivery.  `ctx` is an opaque pointer
/// forwarded verbatim to every callback invocation; pass `null` if unused.
///
/// # Safety
/// - `term` must be non-null, valid, and not freed while the callback is
///   registered.
/// - `ctx` must remain valid for all subsequent `bb_term_input` calls until
///   the callback is cleared or the terminal is freed.
/// - The callback may be invoked synchronously from within `bb_term_input`;
///   it must not call any `bb_term_*` function on the same `term` handle
///   (no re-entrant use).
/// - All access must occur on the same thread (no concurrent calls on the
///   same term).
/// - Passing `term = null` is a no-op.
///
/// Panics inside this function are caught by `catch_unwind` and delivered as a
/// `BBEventKind::Fatal` event to the registered callback. The function returns
/// unit as the fallback value.
#[no_mangle]
pub unsafe extern "C" fn bb_term_set_event_cb(
    term: *mut BBTerm,
    cb: Option<unsafe extern "C" fn(BBEvent, *mut c_void)>,
    ctx: *mut c_void,
) {
    guard_with_term(term, (), || {
        if term.is_null() {
            return;
        }
        (*term).callback.set(cb, ctx);
    })
}

/// Convert an alacritty `Color` to a 0xRRGGBB u32, consulting the terminal's
/// palette first (so OSC 4/10/11/12 and `bb_term_set_named_color` overrides
/// route through). Falls back to built-in xterm defaults when a slot is unset.
fn color_to_rgb(color: &Color, palette: &alacritty_terminal::term::color::Colors) -> u32 {
    match color {
        Color::Spec(rgb) => ((rgb.r as u32) << 16) | ((rgb.g as u32) << 8) | (rgb.b as u32),
        Color::Named(name) => {
            let idx = *name as usize;
            if let Some(rgb) = palette[idx] {
                ((rgb.r as u32) << 16) | ((rgb.g as u32) << 8) | (rgb.b as u32)
            } else {
                named_color_rgb(name)
            }
        }
        Color::Indexed(idx) => {
            if let Some(rgb) = palette[*idx as usize] {
                ((rgb.r as u32) << 16) | ((rgb.g as u32) << 8) | (rgb.b as u32)
            } else {
                indexed_color_rgb(*idx)
            }
        }
    }
}

/// Map the 16 ANSI named colors (and semantic aliases) to xterm defaults.
fn named_color_rgb(name: &NamedColor) -> u32 {
    match name {
        NamedColor::Black => 0x000000,
        NamedColor::Red => 0xCC0000,
        NamedColor::Green => 0x4E9A06,
        NamedColor::Yellow => 0xC4A000,
        NamedColor::Blue => 0x3465A4,
        NamedColor::Magenta => 0x75507B,
        NamedColor::Cyan => 0x06989A,
        NamedColor::White => 0xD3D7CF,
        NamedColor::BrightBlack => 0x555753,
        NamedColor::BrightRed => 0xEF2929,
        NamedColor::BrightGreen => 0x8AE234,
        NamedColor::BrightYellow => 0xFCE94F,
        NamedColor::BrightBlue => 0x729FCF,
        NamedColor::BrightMagenta => 0xAD7FA8,
        NamedColor::BrightCyan => 0x34E2E2,
        NamedColor::BrightWhite => 0xEEEEEC,
        // Semantic aliases — Foreground defaults to light grey, Background to black
        NamedColor::Foreground | NamedColor::BrightForeground => 0xEEEEEE,
        NamedColor::Background => 0x000000,
        // Dim variants: map to the base color (terminal dims it visually)
        NamedColor::DimBlack => 0x000000,
        NamedColor::DimRed => 0xCC0000,
        NamedColor::DimGreen => 0x4E9A06,
        NamedColor::DimYellow => 0xC4A000,
        NamedColor::DimBlue => 0x3465A4,
        NamedColor::DimMagenta => 0x75507B,
        NamedColor::DimCyan => 0x06989A,
        NamedColor::DimWhite => 0xD3D7CF,
        NamedColor::DimForeground => 0xEEEEEE,
        // Cursor and any future variants
        _ => 0xEEEEEE,
    }
}

/// Map xterm 256-color palette index to 0xRRGGBB.
fn indexed_color_rgb(idx: u8) -> u32 {
    match idx {
        0..=15 => {
            // Standard 16 colors — same mapping as named_color_rgb
            const TABLE: [u32; 16] = [
                0x000000, 0xCC0000, 0x4E9A06, 0xC4A000, 0x3465A4, 0x75507B, 0x06989A, 0xD3D7CF,
                0x555753, 0xEF2929, 0x8AE234, 0xFCE94F, 0x729FCF, 0xAD7FA8, 0x34E2E2, 0xEEEEEC,
            ];
            TABLE[idx as usize]
        }
        16..=231 => {
            // 6×6×6 color cube
            let i = (idx - 16) as u32;
            let r = (i / 36) % 6;
            let g = (i / 6) % 6;
            let b = i % 6;
            let to_byte = |v: u32| -> u32 {
                if v == 0 {
                    0
                } else {
                    55 + 40 * v
                }
            };
            (to_byte(r) << 16) | (to_byte(g) << 8) | to_byte(b)
        }
        232..=255 => {
            // 24-step grayscale ramp
            let v = 8 + 10 * (idx - 232) as u32;
            (v << 16) | (v << 8) | v
        }
    }
}

/// Extract our stable `cell_flags` bitset from alacritty's `Flags`.
fn extract_cell_flags(f: CellFlags) -> u16 {
    let mut out: u16 = 0;
    if f.contains(CellFlags::BOLD) {
        out |= cell_flags::BOLD;
    }
    if f.contains(CellFlags::ITALIC) {
        out |= cell_flags::ITALIC;
    }
    if f.contains(CellFlags::UNDERLINE) {
        out |= cell_flags::UNDERLINE;
    }
    if f.contains(CellFlags::INVERSE) {
        out |= cell_flags::REVERSE;
    }
    if f.contains(CellFlags::DIM) {
        out |= cell_flags::DIM;
    }
    if f.contains(CellFlags::STRIKEOUT) {
        out |= cell_flags::STRIKE;
    }
    if f.contains(CellFlags::WIDE_CHAR) {
        out |= cell_flags::WIDE_CHAR;
    }
    if f.contains(CellFlags::WIDE_CHAR_SPACER) {
        out |= cell_flags::WIDE_CHAR_SPACER;
    }
    if f.contains(CellFlags::LEADING_WIDE_CHAR_SPACER) {
        out |= cell_flags::LEADING_WIDE_CHAR_SPACER;
    }
    // Underline-style dimension (mutually exclusive at the alacritty level):
    // double / curly / dotted / dashed. The plain UNDERLINE bit above covers
    // CSI 4 m; these four are CSI 21 m and CSI 4:3/4:4/4:5 m respectively.
    if f.contains(CellFlags::DOUBLE_UNDERLINE) {
        out |= cell_flags::UNDERLINE_DOUBLE;
    }
    if f.contains(CellFlags::UNDERCURL) {
        out |= cell_flags::UNDERCURL;
    }
    if f.contains(CellFlags::DOTTED_UNDERLINE) {
        out |= cell_flags::UNDERLINE_DOTTED;
    }
    if f.contains(CellFlags::DASHED_UNDERLINE) {
        out |= cell_flags::UNDERLINE_DASHED;
    }
    out
}

/// Map `alacritty_terminal::term::TermMode` to our stable `bb_mode` bitflags.
fn extract_mode(term_mode: &TermMode) -> u32 {
    let mut m: u32 = 0;
    if term_mode.contains(TermMode::ALT_SCREEN) {
        m |= bb_mode::ALT_SCREEN;
    }
    if term_mode.contains(TermMode::APP_CURSOR) {
        m |= bb_mode::APP_CURSOR;
    }
    if term_mode.contains(TermMode::APP_KEYPAD) {
        m |= bb_mode::APP_KEYPAD;
    }
    if term_mode.contains(TermMode::BRACKETED_PASTE) {
        m |= bb_mode::BRACKETED_PASTE;
    }
    if term_mode.contains(TermMode::MOUSE_REPORT_CLICK) {
        m |= bb_mode::MOUSE_REPORT_CLICK;
    }
    if term_mode.contains(TermMode::MOUSE_MOTION) {
        m |= bb_mode::MOUSE_MOTION;
    }
    if term_mode.contains(TermMode::MOUSE_DRAG) {
        m |= bb_mode::MOUSE_DRAG;
    }
    if term_mode.contains(TermMode::SGR_MOUSE) {
        m |= bb_mode::SGR_MOUSE;
    }
    if term_mode.contains(TermMode::FOCUS_IN_OUT) {
        m |= bb_mode::FOCUS_IN_OUT;
    }
    if term_mode.contains(TermMode::SHOW_CURSOR) {
        m |= bb_mode::SHOW_CURSOR;
    }
    if term_mode.contains(TermMode::LINE_WRAP) {
        m |= bb_mode::LINE_WRAP;
    }
    // Kitty keyboard protocol sub-flags. Tested against each bit individually
    // because TermMode::KITTY_KEYBOARD_PROTOCOL is a *composite* mask (all five
    // bits); using `.contains()` on the composite would require every bit to be
    // set before we expose any, which loses fidelity when the TUI enables just
    // DISAMBIGUATE_ESC_CODES (the common case for Claude Code / vim / tmux).
    if term_mode.contains(TermMode::DISAMBIGUATE_ESC_CODES) {
        m |= bb_mode::DISAMBIGUATE_ESC_CODES;
    }
    if term_mode.contains(TermMode::REPORT_EVENT_TYPES) {
        m |= bb_mode::REPORT_EVENT_TYPES;
    }
    if term_mode.contains(TermMode::REPORT_ALTERNATE_KEYS) {
        m |= bb_mode::REPORT_ALTERNATE_KEYS;
    }
    if term_mode.contains(TermMode::REPORT_ALL_KEYS_AS_ESC) {
        m |= bb_mode::REPORT_ALL_KEYS_AS_ESC;
    }
    if term_mode.contains(TermMode::REPORT_ASSOCIATED_TEXT) {
        m |= bb_mode::REPORT_ASSOCIATED_TEXT;
    }
    m
}

/// Like `extract_mode` but also folds in the `modifyOtherKeys` bit
/// sourced from `BBTerm.modify_other_keys` (any non-zero level → bit
/// set). Kept separate from `extract_mode` so the pure
/// `TermMode → u32` mapping (exposed to callers that only see the
/// alacritty mode) stays argument-clean.
fn extract_mode_with_extras(bb: &BBTerm) -> u32 {
    let mut m = extract_mode(bb.term.mode());
    if bb.modify_other_keys > 0 {
        m |= bb_mode::MODIFY_OTHER_KEYS;
    }
    m
}

/// Take an immutable snapshot of the current grid state.
///
/// # Safety
/// Same preconditions as `bb_term_input`. Returns null on null input.
/// The returned pointer must be released by exactly one `bb_snap_release` per
/// successful call (plus one per `bb_snap_retain`).
///
/// Panics inside this function are caught by `catch_unwind` and delivered as a
/// `BBEventKind::Fatal` event to the registered callback. The function returns
/// null as the fallback value.
#[no_mangle]
pub unsafe extern "C" fn bb_term_take_snapshot(term: *mut BBTerm) -> *const BBSnap {
    guard_with_term(term, std::ptr::null(), || {
        if term.is_null() {
            return std::ptr::null();
        }
        let bb = &mut *term;

        // Drain the damage set BEFORE reading the grid. `Term::damage` takes
        // `&mut self`; the grid borrow below is immutable, so the two can't
        // coexist. Capturing damage first lets us hold it in a plain Vec<u16>
        // that outlives the grid borrow. After reading, reset damage so the
        // next `bb_term_input` cycle starts with a clean slate — the renderer
        // gets one set of damaged rows per snapshot, not a growing union.
        use alacritty_terminal::term::TermDamage;
        let (damaged_rows, damage_full): (Vec<u16>, bool) = match bb.term.damage() {
            TermDamage::Full => (Vec::new(), true),
            TermDamage::Partial(iter) => (iter.map(|b| b.line as u16).collect(), false),
        };
        bb.term.reset_damage();

        // Pluck the persistent URI intern cache out of `bb` so we can
        // mutate it while holding an immutable borrow on `bb.term` (for
        // `grid`). Entries survive across snapshots (rust-core-3 F1):
        // the same URI appearing frame after frame is interned exactly
        // once across the terminal's lifetime. A new snapshot
        // `Arc::clone`s the existing CStr into its local `links` — one
        // atomic increment, zero allocation. `uri_cache_bytes` tracks
        // the global byte footprint; new URIs dropped silently once
        // it crosses `OSC8_TOTAL_INTERN_BYTES_CAP` (1 MiB).
        let mut uri_cache = std::mem::take(&mut bb.uri_cstr_cache);
        let mut uri_cache_bytes = bb.uri_cache_bytes;

        let palette = bb.term.colors();
        let grid = bb.term.grid();

        let rows = grid.screen_lines() as u16;
        let cols = grid.columns() as u16;
        let mut cells: Vec<BBCell> = Vec::with_capacity(rows as usize * cols as usize);

        // OSC 8 hyperlink interning. When non-empty, `links[0]` is the
        // "no link" sentinel so cell `link_id == 0` always means "no
        // OSC 8 attribution" and subsequent URIs get 1-based indices.
        // Caps:
        //   - distinct URIs per snapshot: `u16::MAX - 1 = 65534` (local ids)
        //   - per-URI bytes: 4 KiB (covers any realistic http URL)
        //   - total interned bytes ACROSS the persistent cache:
        //     `OSC8_TOTAL_INTERN_BYTES_CAP` = 1 MiB. Without a global
        //     byte cap a hostile TUI writing distinct 4 KiB URIs can
        //     retain ~256 MiB of CStrings per live snapshot ×
        //     outstanding refcount (rust-core-3 F1). Over the ceiling,
        //     new URIs drop to no-link rather than evict — eviction
        //     would invalidate pointers held by still-live snapshots
        //     that `Arc::clone`d the existing CStr.
        //
        // rust-core-3 F9: `links` starts empty and the index-0
        // sentinel CString is pushed only when the first hyperlink
        // cell is seen. The common case — ProMotion frame re-render
        // with no OSC 8 on screen — pays zero heap allocations for
        // the intern table (and, with the persistent cache, zero
        // allocations for repeat-URI snapshots too). `bb_snap_link_url`
        // short-circuits on `link_id == 0`, and a non-zero lookup
        // against an empty `links` misses the bounds check and
        // returns null — so the empty-Vec shape is safe.
        let mut links: Vec<Arc<std::ffi::CStr>> = Vec::new();
        // Per-snapshot URI → local id map. `String` keys let us look
        // up by `&str` (via `Borrow<str>`) without cloning alacritty's
        // Hyperlink-scoped &str out of its borrow. Only one
        // `String::from` per unique URI per snapshot.
        let mut local_uri_to_id: Option<std::collections::HashMap<String, u16>> = None;

        const OSC8_URI_MAX: usize = 4096;
        const OSC8_TOTAL_INTERN_BYTES_CAP: usize = 1024 * 1024;
        for indexed in grid.display_iter() {
            let link_id: u16 = match indexed.cell.hyperlink() {
                Some(h) => {
                    let uri = h.uri();
                    // alacritty's OSC 8 parser rejects empty URIs upstream, but
                    // we defensively treat an empty uri as "no link".
                    if uri.is_empty() || uri.len() > OSC8_URI_MAX {
                        0
                    } else {
                        // Lazy init: first hyperlink of the snapshot
                        // materializes `links` (with its sentinel) and
                        // the local URI map.
                        if links.is_empty() {
                            let sentinel: Arc<std::ffi::CStr> = std::ffi::CString::default().into();
                            links.push(sentinel);
                            local_uri_to_id = Some(std::collections::HashMap::with_capacity(8));
                        }
                        let local_map = local_uri_to_id
                            .as_mut()
                            .expect("local_uri_to_id initialised above");
                        if let Some(&id) = local_map.get(uri) {
                            id
                        } else if links.len() >= u16::MAX as usize {
                            // Out of per-snapshot ids — drop
                            // attribution silently. 65 534 links per
                            // snapshot is already well past any
                            // realistic TUI.
                            0
                        } else {
                            // Persistent-cache hit? reuse the Arc (one
                            // atomic increment, zero allocation). Miss
                            // → intern subject to the global byte cap.
                            let cstr_arc: Option<Arc<std::ffi::CStr>> =
                                if let Some(existing) = uri_cache.get(uri) {
                                    Some(Arc::clone(existing))
                                } else if uri_cache_bytes.saturating_add(uri.len())
                                    > OSC8_TOTAL_INTERN_BYTES_CAP
                                {
                                    None
                                } else {
                                    match std::ffi::CString::new(uri) {
                                        Ok(cs) => {
                                            let arc: Arc<std::ffi::CStr> = cs.into();
                                            uri_cache.insert(uri.to_owned(), Arc::clone(&arc));
                                            uri_cache_bytes += uri.len();
                                            Some(arc)
                                        }
                                        Err(_) => None,
                                    }
                                };
                            match cstr_arc {
                                Some(arc) => {
                                    let id = links.len() as u16;
                                    links.push(arc);
                                    local_map.insert(uri.to_owned(), id);
                                    id
                                }
                                None => 0,
                            }
                        }
                    }
                }
                None => 0,
            };
            // Underline colour (CSI 58): alacritty stores as Option<Color>.
            // None → sentinel (shader falls back to fg). Some(c) → resolve
            // through the palette, same as fg/bg so indexed colours route
            // correctly.
            let underline_color = match indexed.cell.underline_color() {
                Some(c) => color_to_rgb(&c, palette),
                None => UNDERLINE_COLOR_UNSET,
            };
            cells.push(BBCell {
                ch: indexed.c as u32,
                fg: color_to_rgb(&indexed.fg, palette),
                bg: color_to_rgb(&indexed.bg, palette),
                flags: extract_cell_flags(indexed.flags),
                link_id,
                underline_color,
            });
        }

        let cursor_point = grid.cursor.point;
        // cursor_point.line.0 is a 0-based screen row (Line wraps i32; visible rows are 0..rows-1).
        // cursor_point.column.0 is a 0-based column (Column wraps usize).
        let cursor_row = cursor_point.line.0.max(0) as u16;
        let cursor_col = cursor_point.column.0 as u16;
        // display_offset: lines scrolled above the live grid. When > 0 the
        // `cells` above are from scrollback; the live cursor at `cursor_row`
        // is actually `cursor_row + display_offset` from the top of the
        // visible viewport — and may be below it entirely.
        let display_offset = grid.display_offset().min(u32::MAX as usize) as u32;
        let history_size = grid.history_size().min(u32::MAX as usize) as u32;
        // Drop the `grid`/`palette` borrows (and by extension the `&bb.term`
        // borrow) before we touch `bb.uri_cstr_cache` mutably below. The
        // `cursor_style()`/`mode()` reads through `bb.term` happen through a
        // fresh immutable borrow, which is compatible with handing the
        // cache back via `&mut bb`.
        let _ = grid;
        let _ = palette;
        // `local_uri_to_id` lives and dies with this snapshot.
        drop(local_uri_to_id);
        // Return the persistent intern cache to BBTerm. Entries survive
        // across snapshots (rust-core-3 F1) so repeat URIs are a hash
        // probe + Arc-clone next frame, not a full CString allocation.
        bb.uri_cstr_cache = uri_cache;
        bb.uri_cache_bytes = uri_cache_bytes;
        let term_mode = bb.term.mode();
        let mode = extract_mode_with_extras(bb);
        // DECTCEM (ESC [ ? 25 h/l) toggles SHOW_CURSOR. Previously we
        // hardcoded true, so a TUI asking for a hidden cursor (less in
        // page view, fzf, nvim during paint) would still get drawn by
        // the Metal renderer.
        let cursor_visible = term_mode.contains(TermMode::SHOW_CURSOR);
        // Read current DECSCUSR cursor shape. alacritty_terminal 0.26 exposes
        // `Term::cursor_style() -> CursorStyle` whose `.shape` is one of
        // Block/Underline/Beam/HollowBlock/Hidden. We pack to a stable u8:
        // 0 = block (default), 1 = bar/beam, 2 = underline, 3 = hidden.
        // HollowBlock renders as block in v1 (no dedicated outline shape).
        let cursor_shape: u8 = {
            use alacritty_terminal::vte::ansi::CursorShape;
            match bb.term.cursor_style().shape {
                CursorShape::Block => 0,
                CursorShape::Beam => 1,
                CursorShape::Underline => 2,
                CursorShape::Hidden => 3,
                CursorShape::HollowBlock => 0,
            }
        };
        let owned = BBSnapOwned::new(
            cols,
            rows,
            (cursor_col, cursor_row, cursor_visible),
            display_offset,
            history_size,
            mode,
            cursor_shape,
            cells,
            links,
            damaged_rows,
            damage_full,
        );
        // Expose the public `snap` field (first field at offset 0).
        let owned_ptr = Box::into_raw(owned);
        &(*owned_ptr).snap as *const BBSnap
    })
}

/// Increment refcount. Returns the input pointer for fluent usage.
///
/// # Safety
/// `snap` must be a pointer returned by `bb_term_take_snapshot` or previously
/// retained, and not yet released to zero. Null is a no-op (returns null).
/// Safe to call from any thread.
///
/// Panics inside this function are caught by `catch_unwind` and swallowed
/// silently (no `BBTerm` context is available). The function returns the input
/// `snap` pointer as the fallback value.
#[no_mangle]
pub unsafe extern "C" fn bb_snap_retain(snap: *const BBSnap) -> *const BBSnap {
    guard_no_term(snap, || {
        if snap.is_null() {
            return snap;
        }
        let owned = BBSnapOwned::from_snap_ptr(snap);
        (*owned).rc.fetch_add(1, Ordering::Relaxed);
        snap
    })
}

/// Decrement refcount; free when it reaches zero.
///
/// # Safety
/// Each `snap` must be released exactly once per acquire (new or retain).
/// Null is a no-op. Safe to call from any thread, but each concrete handle
/// follows the acquire/release discipline documented above.
///
/// Panics inside this function are caught by `catch_unwind` and swallowed
/// silently (no `BBTerm` context is available). The function returns unit as
/// the fallback value.
#[no_mangle]
pub unsafe extern "C" fn bb_snap_release(snap: *const BBSnap) {
    guard_no_term((), || {
        if snap.is_null() {
            return;
        }
        let owned = BBSnapOwned::from_snap_ptr(snap);
        let prev = (*owned).rc.fetch_sub(1, Ordering::Release);
        if prev == 1 {
            std::sync::atomic::fence(Ordering::Acquire);
            drop(Box::from_raw(owned));
        }
    })
}

/// Look up the OSC 8 link id at a snapshot cell. Returns 0 when `snap` is
/// null, `(row, col)` is outside the grid, or the cell has no OSC 8
/// attribution.
///
/// Pass the returned non-zero id to `bb_snap_link_url` to get the URL.
///
/// # Safety
/// `snap` must be non-null and returned by `bb_term_take_snapshot` /
/// `bb_snap_retain`, not yet released to zero.
#[no_mangle]
pub unsafe extern "C" fn bb_snap_link_id_at(snap: *const BBSnap, row: u16, col: u16) -> u32 {
    guard_no_term(0u32, || {
        if snap.is_null() {
            return 0;
        }
        let s = &*snap;
        if (row as usize) >= (s.rows as usize) || (col as usize) >= (s.cols as usize) {
            return 0;
        }
        let idx = (row as usize) * (s.cols as usize) + (col as usize);
        if idx >= s.cells_len {
            return 0;
        }
        let cell = &*s.cells.add(idx);
        cell.link_id as u32
    })
}

/// Resolve an OSC 8 link id to its UTF-8 URL. Returns null when `snap` is
/// null, `link_id == 0`, or the id is unknown. The returned pointer is
/// valid for the snapshot's lifetime (until the matching `bb_snap_release`
/// drops the refcount to zero).
///
/// # Safety
/// `snap` must be non-null and returned by `bb_term_take_snapshot` /
/// `bb_snap_retain`, not yet released to zero.
#[no_mangle]
pub unsafe extern "C" fn bb_snap_link_url(
    snap: *const BBSnap,
    link_id: u32,
) -> *const std::os::raw::c_char {
    guard_no_term(std::ptr::null(), || {
        if snap.is_null() || link_id == 0 {
            return std::ptr::null();
        }
        let owned = BBSnapOwned::from_snap_ptr(snap);
        let links = &(*owned).links;
        match links.get(link_id as usize) {
            // Index 0 is the empty-string sentinel, already filtered above.
            Some(cstr) => cstr.as_ptr(),
            None => std::ptr::null(),
        }
    })
}

/// Toggle OSC 10 / 11 / 12 `?` reply behaviour. Disabled by default so
/// a hostile remote can't round-trip the palette back into the PTY
/// (mitigates the zsh-vi-mode command-injection class). Pass `1` to
/// enable replies when running a known-safe shell that wants nvim /
/// tmux auto-theming.
///
/// # Safety
/// Same preconditions as `bb_term_input`. Null is a no-op.
#[no_mangle]
pub unsafe extern "C" fn bb_term_set_color_query_enabled(term: *mut BBTerm, enabled: u8) {
    guard_with_term(term, (), || {
        if term.is_null() {
            return;
        }
        (*term).color_query_enabled = enabled != 0;
    })
}

/// Read the current terminal mode bitfield as a `bb_mode::*` union.
/// O(1) — no snapshot allocation. Use when a caller needs to branch on
/// a single mode bit (e.g., focus-event emission must check
/// `FOCUS_IN_OUT` before writing `\x1b[I` / `\x1b[O` to the PTY, since
/// emitting those bytes when the TUI hasn't enabled mode 1004 would be
/// interpreted as `HPA` / a cursor move).
///
/// # Safety
/// Same preconditions as `bb_term_input`. Null returns 0 (no bits set),
/// which is the correct default for "don't emit".
///
/// Panics inside this function are caught by `catch_unwind` and delivered as a
/// `BBEventKind::Fatal` event to the registered callback. The function returns
/// 0 as the fallback value.
#[no_mangle]
pub unsafe extern "C" fn bb_term_current_mode(term: *mut BBTerm) -> u32 {
    guard_with_term(term, 0u32, || {
        if term.is_null() {
            return 0;
        }
        let bb = &*term;
        extract_mode_with_extras(bb)
    })
}

/// Report whether the snapshot's damage set is "full" (all rows need a
/// redraw — scroll, insert-mode, viewport scrollback change). When true,
/// the renderer must treat every row as damaged regardless of
/// `bb_snap_damage_rows`.
///
/// # Safety
/// `snap` must be a pointer from `bb_term_take_snapshot` or retained from
/// one. Null returns 1 (the safe default: repaint everything).
#[no_mangle]
pub unsafe extern "C" fn bb_snap_damage_is_full(snap: *const BBSnap) -> u8 {
    guard_no_term(1u8, || {
        if snap.is_null() {
            return 1;
        }
        let owned = BBSnapOwned::from_snap_ptr(snap);
        if (*owned).damage_full {
            1
        } else {
            0
        }
    })
}

/// Copy the snapshot's damaged-row indices into the caller's buffer. Returns
/// the TOTAL number of damaged rows (which may exceed `out_cap`); the
/// function writes at most `min(total, out_cap)` rows into `out`.
///
/// Truncation detection: callers compare the return value against `out_cap`.
/// If `return_value > out_cap`, the buffer was too small and the caller
/// should re-allocate at `return_value` slots and retry to avoid leaving
/// stale pixels on the undrawn rows.
///
/// Length probe: passing `out = null` with any `out_cap` returns the
/// total count without writing anything, so a caller can size a buffer
/// before allocating.
///
/// If the damage is `Full`, returns 0 — callers must check
/// `bb_snap_damage_is_full` first and treat "full" as "all rows need
/// redraw" regardless of this function's return value.
///
/// # Safety
/// - `snap` must be a pointer from `bb_term_take_snapshot` or retained
/// - `out` must either be null OR point to at least `out_cap * 2` bytes of
///   writable memory. No u16 alignment is required on `out` — the body
///   copies byte-wise (rust-core-4 F3).
/// - Safe to call from any thread.
#[no_mangle]
pub unsafe extern "C" fn bb_snap_damage_rows(
    snap: *const BBSnap,
    out: *mut u16,
    out_cap: usize,
) -> usize {
    guard_no_term(0usize, || {
        if snap.is_null() {
            return 0;
        }
        let owned = BBSnapOwned::from_snap_ptr(snap);
        if (*owned).damage_full {
            return 0;
        }
        let rows = &(*owned).damaged_rows;
        let total = rows.len();
        // Length probe: caller passed null to size a buffer without writing.
        if out.is_null() || out_cap == 0 {
            return total;
        }
        let n = total.min(out_cap);
        // Copy as raw bytes (not u16) so an unaligned `out` — e.g. a caller
        // that cast a u8 buffer via `.cast::<u16>()` at an odd address — is
        // well-defined on every target, not just those that forgive
        // unaligned stores. Each u16 is 2 bytes, so `n * 2` bytes total
        // (rust-core-4 F3).
        std::ptr::copy_nonoverlapping(
            rows.as_ptr() as *const u8,
            out as *mut u8,
            n * std::mem::size_of::<u16>(),
        );
        // Truncation signal: callers compare the returned `total` against
        // `out_cap`; `total > out_cap` means the buffer was too small and
        // the caller should re-allocate at `total` and retry. We don't
        // `debug_assert` here because truncation is a legitimate API shape
        // when the caller is size-probing — the log is routed via Swift
        // when the caller wants diagnostics.
        total
    })
}

/// Scroll the display by `delta` lines. Positive = scroll up (show older
/// content), negative = scroll down (show newer content, towards bottom).
///
/// # Safety
/// Same preconditions as `bb_term_input`. Passing null or delta == 0 is a no-op.
///
/// Panics inside this function are caught by `catch_unwind` and delivered as a
/// `BBEventKind::Fatal` event to the registered callback. The function returns
/// unit as the fallback value.
#[no_mangle]
pub unsafe extern "C" fn bb_term_scroll(term: *mut BBTerm, delta: i32) {
    guard_with_term(term, (), || {
        if term.is_null() || delta == 0 {
            return;
        }
        let bb = &mut *term;
        use alacritty_terminal::grid::Scroll;
        bb.term.scroll_display(Scroll::Delta(delta));
    })
}

/// Snap the viewport back to the live grid (display_offset = 0). Called after
/// any user keystroke so typing/Enter always brings them back from scrollback
/// history. A no-op if already at the bottom.
///
/// # Safety
/// Same preconditions as `bb_term_input`. Null is a no-op.
///
/// Panics inside this function are caught by `catch_unwind` and delivered as a
/// `BBEventKind::Fatal` event to the registered callback. The function returns
/// unit as the fallback value.
#[no_mangle]
pub unsafe extern "C" fn bb_term_scroll_to_bottom(term: *mut BBTerm) {
    guard_with_term(term, (), || {
        if term.is_null() {
            return;
        }
        let bb = &mut *term;
        use alacritty_terminal::grid::Scroll;
        bb.term.scroll_display(Scroll::Bottom);
    })
}

/// Clear the visible screen AND the scrollback, moving the cursor to the
/// top-left. Equivalent to `clear -x` (BSD) / iTerm2's "⌘K" wipe — NOT
/// what `clear(1)` emits, which is viewport-only (a plain `\x1b[H\x1b[2J`
/// that leaves scrollback intact). The rest of the terminal state
/// (palette, cursor color, etc.) is untouched.
///
/// # Safety
/// Same preconditions as `bb_term_input`. Null is a no-op.
#[no_mangle]
pub unsafe extern "C" fn bb_term_clear_all(term: *mut BBTerm) {
    guard_with_term(term, (), || {
        if term.is_null() {
            return;
        }
        let bb = &mut *term;
        // H = cursor home, 2J = erase display, 3J = erase scrollback.
        bb.processor.advance(&mut bb.term, b"\x1b[H\x1b[2J\x1b[3J");
    })
}

/// Update one slot of the terminal's color palette. Slot indices match
/// alacritty's `NamedColor` ordering: 0..=15 = 16 ANSI colors, 16..=255 =
/// extended 256-palette, 256 = Foreground, 257 = Background, 258 = Cursor,
/// 259 = BrightForeground, plus a few more (see alacritty's NamedColor enum).
/// `rgb` is packed 0xRRGGBB.
///
/// # Safety
/// Same preconditions as `bb_term_input`. Null `term` is a no-op. Slots
/// beyond alacritty's palette length are silently ignored.
#[no_mangle]
pub unsafe extern "C" fn bb_term_set_named_color(term: *mut BBTerm, slot: u16, rgb: u32) {
    guard_with_term(term, (), || {
        if term.is_null() {
            return;
        }
        let bb = &mut *term;
        // alacritty's Term::set_color indexes its Colors array directly; any
        // slot ≥ the array length panics with an index-out-of-bounds. The
        // Colors layout is `[Option<Rgb>; COUNT]` with COUNT = 269 in 0.26
        // (256 palette + 13 named). The Swift side only uses 0..=258, but
        // the FFI must survive arbitrary input (fuzzer, misbehaving API
        // user) without panicking — libFuzzer's panic hook aborts the
        // process before `guard_with_term`'s `catch_unwind` ever runs, so
        // "catch the panic" is not a substitute for "don't panic". Gate
        // against the constant COUNT from alacritty's public API.
        if (slot as usize) >= alacritty_terminal::term::color::COUNT {
            return;
        }
        let r = ((rgb >> 16) & 0xFF) as u8;
        let g = ((rgb >> 8) & 0xFF) as u8;
        let b = (rgb & 0xFF) as u8;
        use alacritty_terminal::vte::ansi::{Handler, Rgb};
        bb.term.set_color(slot as usize, Rgb { r, g, b });
    })
}

/// Owned UTF-8 byte buffer returned from text-extraction FFIs.
///
/// `bytes`/`len` describe a read-only view into the heap buffer whose raw
/// parts are stored in `_owned_ptr` / `_owned_cap`. The Rust side
/// heap-allocates a `Box<BBString>`, builds the payload as a `Vec<u8>`, then
/// decomposes the vec (ptr + capacity) and installs the pointer into
/// `bytes`. Callers must free via `bb_string_release` exactly once; nothing
/// else keeps the backing allocation alive.
///
/// The `_owned_*` fields are intentionally present in the C-visible layout
/// to keep the struct self-contained (one `Box<BBString>` + one `Vec<u8>`
/// buffer, freed together by `bb_string_release`). Consumers on the C side
/// should read only `bytes` and `len` and otherwise treat the struct as
/// opaque — never poke into the owned fields. Using raw pointer + capacity
/// instead of a literal `Vec<u8>` field lets cbindgen emit a complete,
/// FFI-safe layout that Swift can import: `Vec<u8>` is not `repr(C)`, so a
/// `Vec` field would surface as an incomplete type in the generated header.
///
/// `_magic` is a sentinel set by `bb_string_new` (to `BB_STRING_MAGIC`) and
/// zeroed by `bb_string_release` before the heap buffer is reconstructed.
/// It gives `bb_string_release` a cheap defence against double-free and
/// wild-pointer input: a mismatching `_magic` short-circuits without
/// calling `Vec::from_raw_parts` (which would be UB on stale pointers).
/// Safety belt for Swift callers — still single-free by contract.
#[repr(C)]
pub struct BBString {
    pub bytes: *const u8,
    pub len: usize,
    _owned_ptr: *mut u8,
    _owned_cap: usize,
    /// Magic sentinel: `BB_STRING_MAGIC` when live, `0` after release.
    /// Double-free and wild-pointer input are rejected cheaply.
    _magic: u64,
}

/// Magic sentinel stamped into `BBString::_magic` on construction. Any
/// 64-bit constant unlikely to appear on the heap by accident. Also
/// invariant-encodes the string "BlackbirdStr" via the low byte pattern.
pub const BB_STRING_MAGIC: u64 = 0xB1AC_5BBD_5721_57E0;

/// Extract UTF-8 text from the terminal buffer between two buffer-relative
/// points. `start_line`/`end_line` are grid lines where 0 is the top of the
/// visible viewport and negative values reach into scrollback (buffer-relative,
/// matching alacritty's `Line(i32)` convention).
///
/// `rect == 0` selects prose mode: the first line is emitted from `start_col`
/// to the end of the row, the last line from column 0 to `end_col`, and
/// middle lines are taken in full. Trailing spaces are trimmed from every
/// line except the last to avoid pulling the grid's blank fill into copied
/// output.
///
/// `rect != 0` selects rectangular mode: every line is clipped to
/// `[start_col, end_col]` with no trimming.
///
/// `\0` cells (alacritty's "unrendered" sentinel) are emitted as spaces. Real
/// spaces come through as-is. Wide-char spacer cells (alacritty's
/// `WIDE_CHAR_SPACER` / `LEADING_WIDE_CHAR_SPACER` flags) are SKIPPED entirely
/// — the preceding primary cell already held the wide glyph's character, and
/// emitting a space for the spacer would double-count columns and break paste
/// round-trip for CJK/emoji (e.g. "中文" would emit as "中 文 "). Lines outside
/// `[topmost_line, bottommost_line]` are skipped silently. Points are
/// normalized so `(start_line, start_col) <= (end_line, end_col)` before
/// iterating.
///
/// Returns a heap-allocated `BBString` the caller must free with
/// `bb_string_release`. Returns null when `term` is null.
///
/// # Safety
/// Same preconditions as `bb_term_input`. Caller owns the returned pointer.
///
/// Panics inside this function are caught by `catch_unwind` and delivered as a
/// `BBEventKind::Fatal` event to the registered callback. The function returns
/// null as the fallback value.
#[no_mangle]
pub unsafe extern "C" fn bb_term_text_range(
    term: *mut BBTerm,
    start_line: i32,
    start_col: u16,
    end_line: i32,
    end_col: u16,
    rect: u8,
) -> *mut BBString {
    guard_with_term(term, std::ptr::null_mut(), || {
        if term.is_null() {
            return std::ptr::null_mut();
        }
        use alacritty_terminal::index::{Column, Line};

        let bb = &*term;
        let grid = bb.term.grid();

        let cols = grid.columns();
        if cols == 0 {
            // No columns to read from; return an empty string for C-side
            // convenience (single allocation pair, len == 0).
            return bb_string_new(Vec::new());
        }
        let last_col = cols - 1;

        // Normalize so (start_line, start_col) <= (end_line, end_col).
        let (s_line, s_col, e_line, e_col) = {
            let a = (start_line, start_col as usize);
            let b = (end_line, end_col as usize);
            let (lo, hi) = if a <= b { (a, b) } else { (b, a) };
            (lo.0, lo.1.min(last_col), hi.0, hi.1.min(last_col))
        };

        let topmost = grid.topmost_line().0;
        let bottommost = grid.bottommost_line().0;

        // Clamp to what actually exists in the grid before iterating. A
        // caller that passes i32::MIN / i32::MAX (or the fuzzer in
        // core/fuzz) would otherwise spin ~4 billion loop iterations that
        // each do nothing but bounds-check and increment.
        let iter_start = s_line.max(topmost);
        let iter_end = e_line.min(bottommost);

        // Collect each line's emitted text, then join with '\n' at the end.
        let mut lines: Vec<String> = Vec::new();

        let rectangular = rect != 0;
        let single_line = s_line == e_line;

        if iter_start > iter_end {
            return bb_string_new(Vec::new());
        }

        let mut line_i = iter_start;
        while line_i <= iter_end {
            let (col_lo, col_hi, trim) = if rectangular {
                // Rectangular mode clips every row to the column span of
                // the bounding box. Tuple-normalisation above only orders
                // (line, col) as a pair, so a rectangle anchored at
                // top-right+bottom-left would land here with s_col > e_col
                // and the inner `while c <= col_hi` loop would skip the
                // row entirely. Sort columns independently so the box's
                // geometry is always extracted.
                (s_col.min(e_col), s_col.max(e_col), false)
            } else if single_line {
                (s_col, e_col, false)
            } else if line_i == s_line {
                (s_col, last_col, true)
            } else if line_i == e_line {
                (0usize, e_col, false)
            } else {
                (0usize, last_col, true)
            };

            let mut text = String::with_capacity(col_hi.saturating_sub(col_lo) + 1);
            let row = &grid[Line(line_i)];
            let mut c = col_lo;
            while c <= col_hi {
                let cell = &row[Column(c)];
                // Skip wide-char spacer cells entirely. alacritty stores a
                // wide char (CJK, emoji) in the primary cell and a '\0'
                // sentinel in the continuation cell to its right; naively
                // emitting ' ' for every '\0' produces "中 文 " instead of
                // "中文" and breaks paste round-trip. The leading spacer is
                // the analogous cell at the end of a line just before a wide
                // glyph wraps — same skip rule applies.
                if cell
                    .flags
                    .intersects(CellFlags::WIDE_CHAR_SPACER | CellFlags::LEADING_WIDE_CHAR_SPACER)
                {
                    c += 1;
                    continue;
                }
                let ch = cell.c;
                // alacritty uses '\0' for unrendered/empty cells; surface as
                // a plain space so callers can concatenate without seeing
                // embedded NULs in their UTF-8.
                let out = if ch == '\0' { ' ' } else { ch };
                text.push(out);
                c += 1;
            }

            if trim {
                let trimmed_len = text.trim_end_matches(' ').len();
                text.truncate(trimmed_len);
            }

            lines.push(text);
            line_i += 1;
        }

        let joined = lines.join("\n");
        bb_string_new(joined.into_bytes())
    })
}

/// Allocate a `BBString` wrapping `bytes`. The vec's heap buffer is stolen
/// (via `Vec::into_raw_parts`-style decomposition) and held in `_owned_ptr` +
/// `_owned_cap` so `bb_string_release` can rebuild and drop it.
///
/// Stamps `_magic` with `BB_STRING_MAGIC` so `bb_string_release` can detect
/// a double-free or wild-pointer input before invoking `Vec::from_raw_parts`
/// (which would be UB on stale parts).
///
/// For an empty payload (`bytes.is_empty()`), both `bytes` and `_owned_ptr`
/// are set to null so a C consumer can rely on `bytes == NULL ⇔ len == 0`.
/// `Vec::new().as_mut_ptr()` would otherwise hand back `NonNull::dangling()`
/// (a non-null sentinel equal to `align_of::<u8>()`), which (a) breaks that
/// invariant for Swift/C callers and (b) is UB if passed to `memcpy` with
/// `n == 0` under strict C11 semantics. `bb_string_release` mirrors the
/// null check and skips `Vec::from_raw_parts` for the empty case
/// (rust-core-4 F1).
///
/// # Safety
/// The returned pointer must be released exactly once via `bb_string_release`.
unsafe fn bb_string_new(bytes: Vec<u8>) -> *mut BBString {
    if bytes.is_empty() {
        // Drop the vec eagerly; we know its capacity is irrelevant once we
        // publish null. Any residual heap buffer (non-zero cap on an empty
        // vec) deallocates with the Vec's own allocator, not ours to track.
        drop(bytes);
        let boxed = Box::new(BBString {
            bytes: std::ptr::null(),
            len: 0,
            _owned_ptr: std::ptr::null_mut(),
            _owned_cap: 0,
            _magic: BB_STRING_MAGIC,
        });
        return Box::into_raw(boxed);
    }
    let mut v = bytes;
    v.shrink_to_fit();
    let len = v.len();
    let cap = v.capacity();
    // SAFETY: leaking the vec is safe; its raw parts are recorded below and
    // will be reconstituted in bb_string_release.
    let ptr = v.as_mut_ptr();
    std::mem::forget(v);
    let boxed = Box::new(BBString {
        bytes: ptr as *const u8,
        len,
        _owned_ptr: ptr,
        _owned_cap: cap,
        _magic: BB_STRING_MAGIC,
    });
    Box::into_raw(boxed)
}

/// Free a `BBString` returned by `bb_term_text_range`.
///
/// Rebuilds the owned `Vec<u8>` from `_owned_ptr`/`_owned_cap`/`len` so its
/// heap buffer is deallocated with the matching `Vec` allocator, then drops
/// the `Box<BBString>`.
///
/// Defends against double-free and wild-pointer input by checking
/// `_magic` against `BB_STRING_MAGIC` before touching the owned parts. A
/// mismatching magic returns early (with a one-line log) without calling
/// `Vec::from_raw_parts` — that would be UB on stale/invalid raw parts and
/// the null guard can't catch it. Successful releases zero the magic so a
/// subsequent double-release is detected cheaply.
///
/// # Safety
/// `s` must have been returned by `bb_term_text_range` and not previously
/// released. Passing null is a no-op.
///
/// Panics inside this function are caught by `catch_unwind` and swallowed
/// silently (no `BBTerm` context is available). The function returns unit as
/// the fallback value.
#[no_mangle]
pub unsafe extern "C" fn bb_string_release(s: *mut BBString) {
    guard_no_term((), || {
        if s.is_null() {
            return;
        }
        // Magic check BEFORE `Box::from_raw` so a wild pointer doesn't even
        // get reconstituted as a Box (whose Drop would try to call the
        // allocator on a garbage address). Read the magic byte-wise via a
        // raw pointer projection; this sidesteps creating a &BBString to
        // a potentially-invalid allocation.
        let magic_ptr = std::ptr::addr_of!((*s)._magic);
        let magic = std::ptr::read(magic_ptr);
        if magic != BB_STRING_MAGIC {
            // Zero magic => already released (double-free). Any other
            // value => wild/uninitialized pointer. Either way, don't touch
            // the owned parts. Logging through eprintln! is acceptable: this
            // is a one-shot development-side signal, not a hot path.
            eprintln!(
                "bb_string_release: magic mismatch (got {:#x}, expected {:#x}); \
                 refusing to free possibly-invalid BBString",
                magic, BB_STRING_MAGIC
            );
            return;
        }
        // Zero the magic *before* reclaiming the box so a concurrent or
        // immediate double-release reads a cleared sentinel and early-outs.
        std::ptr::write(magic_ptr as *mut u64, 0);
        let boxed = Box::from_raw(s);
        // Reconstitute the owned vec so its heap buffer is freed via the
        // matching `Vec<u8>` allocator. `bb_string_new` short-circuits
        // empty payloads to `_owned_ptr = null`, so skip `from_raw_parts`
        // there — calling it with a null pointer is UB even when cap is 0
        // (rust-core-4 F1).
        if !boxed._owned_ptr.is_null() {
            let _ = Vec::from_raw_parts(boxed._owned_ptr, boxed.len, boxed._owned_cap);
        }
        drop(boxed);
    })
}

/// Test-only: force a panic inside the FFI boundary to verify Fatal event delivery.
///
/// # Safety
/// Same as other guarded FFI functions. `term` must be a valid non-null pointer
/// from `bb_term_new`, not freed for the duration of the call.
///
/// Panics inside this function are caught by `catch_unwind` and delivered as a
/// `BBEventKind::Fatal` event to the registered callback.
#[no_mangle]
#[cfg(any(test, feature = "test-only"))]
pub unsafe extern "C" fn bb_term_test_only_panic(term: *mut BBTerm) {
    guard_with_term(term, (), || {
        panic!("intentional test panic");
    });
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

    /// Regression for rust-core-1 F1: ColorRequestQueue::push must cap at
    /// COLOR_REQUEST_QUEUE_CAP so a hostile stream spamming
    /// `ESC]4;N;?BEL` can't force unbounded Arc<dyn Fn> allocations inside
    /// a single bb_term_input call. Direct-construct the queue so the
    /// test is insensitive to alacritty's OSC 4 parser dedup / rate policy.
    #[test]
    fn color_request_queue_push_caps_entries() {
        let q = ColorRequestQueue::new();
        let fmt: Arc<dyn Fn(Rgb) -> String + Sync + Send> = Arc::new(|_rgb| String::new());
        unsafe {
            for _ in 0..COLOR_REQUEST_QUEUE_CAP {
                assert!(q.push(ColorRequestEntry {
                    index: 0,
                    formatter: Arc::clone(&fmt),
                }));
            }
            // One past the cap must be refused.
            assert!(!q.push(ColorRequestEntry {
                index: 0,
                formatter: Arc::clone(&fmt),
            }));
            let drained = q.drain();
            assert_eq!(drained.len(), COLOR_REQUEST_QUEUE_CAP);
            // After draining the latch resets and a new push goes through.
            assert!(q.push(ColorRequestEntry {
                index: 0,
                formatter: Arc::clone(&fmt),
            }));
        }
    }

    /// Regression for rust-core-1 F2/F10: CallbackCell must debug_assert on
    /// cross-thread access so accidental Swift-side @Sendable leakage (or a
    /// future alacritty release that calls send_event on a background
    /// thread) surfaces as a diagnosable panic instead of silent UB.
    /// Only meaningful in debug builds where the latch is live.
    #[test]
    #[cfg(debug_assertions)]
    fn callback_cell_catches_cross_thread_access() {
        use std::panic::{catch_unwind, AssertUnwindSafe};
        let cell = Arc::new(CallbackCell::new());
        // Latch the owner on this thread by touching the cell once.
        unsafe {
            cell.fire(BBEvent {
                kind: BBEventKind::Bell,
                payload: std::ptr::null(),
                len: 0,
                i32_arg: 0,
            });
        }
        let cell_clone = Arc::clone(&cell);
        let result = std::thread::spawn(move || {
            catch_unwind(AssertUnwindSafe(|| unsafe {
                cell_clone.fire(BBEvent {
                    kind: BBEventKind::Bell,
                    payload: std::ptr::null(),
                    len: 0,
                    i32_arg: 0,
                });
            }))
        })
        .join()
        .expect("spawned thread panicked before catch_unwind caught anything");
        assert!(
            result.is_err(),
            "cross-thread CallbackCell::fire should trip the debug_assert_eq",
        );
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
        let callback = Arc::new(CallbackCell::new());
        let color_queue = Arc::new(ColorRequestQueue::new());
        let pty_write_rate = Arc::new(PtyWriteRateCell::new());
        let listener = RoutingListener {
            cell: Arc::clone(&callback),
            color_queue: Arc::clone(&color_queue),
            pty_write_rate: Arc::clone(&pty_write_rate),
        };
        // Keep the Arcs alive past listener construction so the inner
        // cells survive for the lifetime of `term`.
        let _callback_keepalive = callback;
        let _color_queue_keepalive = color_queue;
        let mut term = Term::new(config, &size, listener);

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

    #[test]
    fn input_writes_to_grid() {
        unsafe {
            let term = bb_term_new(80, 24, 1000);
            assert!(!term.is_null());
            let bytes = b"hello";
            bb_term_input(term, bytes.as_ptr(), bytes.len());

            // Lower-level test — reads the grid directly through the Rust API
            // rather than via the FFI snapshot (covered by `snapshot_contains_input`).
            let bb = &*term;
            let text: String = bb
                .term
                .grid()
                .display_iter()
                .take(5)
                .map(|indexed| indexed.c)
                .collect();
            assert_eq!(text, "hello");

            bb_term_free(term);
        }
    }

    #[test]
    fn input_with_null_term_is_noop() {
        unsafe {
            let bytes = b"x";
            bb_term_input(std::ptr::null_mut(), bytes.as_ptr(), bytes.len());
        }
    }

    #[test]
    fn input_with_zero_len_leaves_grid_unchanged() {
        unsafe {
            let term = bb_term_new(80, 24, 100);
            bb_term_input(term, b"ignored".as_ptr(), 0);
            let bb = &*term;
            let grid = bb.term.grid();
            let first_cell = grid.display_iter().next().expect("grid has cells");
            assert_eq!(first_cell.c, ' ', "grid should be untouched");
            bb_term_free(term);
        }
    }

    #[test]
    fn input_with_null_bytes_is_noop() {
        unsafe {
            let term = bb_term_new(80, 24, 100);
            bb_term_input(term, std::ptr::null(), 5);
            bb_term_free(term);
        }
    }

    #[test]
    fn snapshot_contains_input() {
        unsafe {
            let term = bb_term_new(80, 24, 1000);
            let bytes = b"hi";
            bb_term_input(term, bytes.as_ptr(), bytes.len());

            let snap = bb_term_take_snapshot(term);
            assert!(!snap.is_null());

            let s = &*snap;
            assert_eq!(s.cols, 80);
            assert_eq!(s.rows, 24);
            // `cells` is a flat row-major array of length cols*rows.
            let cell0 = &*s.cells;
            let cell1 = &*s.cells.add(1);
            assert_eq!(char::from_u32(cell0.ch), Some('h'));
            assert_eq!(char::from_u32(cell1.ch), Some('i'));

            bb_snap_release(snap);
            bb_term_free(term);
        }
    }

    #[test]
    fn snap_two_owners_release_cleanly() {
        unsafe {
            let term = bb_term_new(10, 3, 100);
            let owner_a = bb_term_take_snapshot(term); // rc = 1
            let owner_b = bb_snap_retain(owner_a); // rc = 2, same address
            assert_eq!(owner_a, owner_b); // retain returns the input pointer
            bb_snap_release(owner_b); // rc = 1 (owner_b done)
            bb_snap_release(owner_a); // rc = 0, freed (owner_a done)
            bb_term_free(term);
        }
    }

    #[test]
    fn mode_app_cursor_set_by_decset_1() {
        unsafe {
            let term = bb_term_new(80, 24, 1000);
            assert!(!term.is_null());

            // Default mode: APP_CURSOR should be off.
            let snap = bb_term_take_snapshot(term);
            assert!(!snap.is_null());
            assert_eq!(
                (*snap).mode & bb_mode::APP_CURSOR,
                0,
                "APP_CURSOR should be clear before DECSET 1"
            );
            bb_snap_release(snap);

            // Send DECSET 1 — enables application cursor keys.
            let seq = b"\x1b[?1h";
            bb_term_input(term, seq.as_ptr(), seq.len());

            let snap2 = bb_term_take_snapshot(term);
            assert!(!snap2.is_null());
            assert_ne!(
                (*snap2).mode & bb_mode::APP_CURSOR,
                0,
                "APP_CURSOR should be set after DECSET 1"
            );
            // Default modes should also be set.
            assert_ne!(
                (*snap2).mode & bb_mode::SHOW_CURSOR,
                0,
                "SHOW_CURSOR should be set by default"
            );
            assert_ne!(
                (*snap2).mode & bb_mode::LINE_WRAP,
                0,
                "LINE_WRAP should be set by default"
            );
            bb_snap_release(snap2);
            bb_term_free(term);
        }
    }

    #[test]
    fn snap_layout_matches_expected() {
        // BBSnap is the C-visible struct. Layout was bumped on
        // 2026-04-28 (audit M5) to widen `display_offset` u16→u32 so
        // it survives scrollback past line 65 535. cbindgen
        // regenerates BBCore.h to match; the test pins the new
        // offsets so a future field insert that shifted them again
        // would catch a stale Swift binding.
        assert_eq!(
            std::mem::offset_of!(BBSnap, cells_len),
            24,
            "cells_len at offset 24 (post-M5 layout)"
        );
        assert_eq!(
            std::mem::offset_of!(BBSnap, cells),
            32,
            "cells at offset 32 (post-M5 layout)"
        );
        // Verify BBSnapOwned layout: snap is at offset 0 so pointer casts are sound.
        assert_eq!(
            std::mem::offset_of!(BBSnapOwned, snap),
            0,
            "snap must be at offset 0 in BBSnapOwned"
        );
        // BBCell ABI: 20 bytes (bumped from 16 on 2026-04-19 to add
        // underline_color for CSI 58 colored underlines). link_id stays at
        // offset 14; underline_color lives at 16. Swift and any other C
        // ABI consumer reads cells directly from BBSnap.cells via these
        // exact offsets — any further field addition needs a bump here
        // AND a corresponding stride update in CellInstance / Shaders.metal.
        assert_eq!(
            std::mem::size_of::<BBCell>(),
            20,
            "BBCell ABI size must stay synchronized with the Swift reader's struct stride"
        );
        assert_eq!(
            std::mem::offset_of!(BBCell, link_id),
            14,
            "link_id must stay at offset 14 (replacing _reserved)"
        );
        assert_eq!(
            std::mem::offset_of!(BBCell, underline_color),
            16,
            "underline_color must stay at offset 16 — packed directly after link_id"
        );
        // Also pin the tail of BBSnap: display_offset / mode /
        // history_size / cursor_shape sit past the pointer fields, so
        // a future field insertion BEFORE them would silently shift
        // their offsets in the Swift bridge. Audit rust-core-3 F15 +
        // rust-build F7. (Offsets bumped 2026-04-28 for audit M5
        // u16→u32 widen of display_offset.)
        assert_eq!(
            std::mem::offset_of!(BBSnap, display_offset),
            12,
            "display_offset at offset 12 (post-M5 u32 widen)"
        );
        assert_eq!(
            std::mem::offset_of!(BBSnap, mode),
            16,
            "mode follows display_offset (post-M5 layout)"
        );
        assert_eq!(
            std::mem::offset_of!(BBSnap, history_size),
            40,
            "history_size follows cells at offset 40 (post-M5 layout)"
        );
        assert_eq!(
            std::mem::offset_of!(BBSnap, cursor_shape),
            44,
            "cursor_shape follows history_size (post-M5 layout)"
        );
        assert_eq!(
            std::mem::size_of::<BBSnap>(),
            48,
            "BBSnap total size 48 bytes (post-M5 layout, includes tail padding)"
        );
    }

    #[test]
    fn snap_null_retain_release_are_noops() {
        unsafe {
            let _ = bb_snap_retain(std::ptr::null());
            bb_snap_release(std::ptr::null());
        }
    }

    #[test]
    fn take_snapshot_from_null_term_returns_null() {
        unsafe {
            assert!(bb_term_take_snapshot(std::ptr::null_mut()).is_null());
        }
    }

    #[test]
    fn resize_changes_dimensions() {
        unsafe {
            let term = bb_term_new(80, 24, 1000);
            bb_term_resize(term, 120, 40);
            let snap = bb_term_take_snapshot(term);
            assert_eq!((*snap).cols, 120);
            assert_eq!((*snap).rows, 40);
            bb_snap_release(snap);
            bb_term_free(term);
        }
    }

    #[test]
    fn resize_to_zero_is_noop() {
        unsafe {
            let term = bb_term_new(80, 24, 1000);
            bb_term_resize(term, 0, 40); // no-op
            bb_term_resize(term, 120, 0); // no-op
            let snap = bb_term_take_snapshot(term);
            assert_eq!((*snap).cols, 80);
            assert_eq!((*snap).rows, 24);
            bb_snap_release(snap);
            bb_term_free(term);
        }
    }

    /// Regression: fuzzing found that shrinking from 80×24 with 1 000 lines
    /// of scrollback down to 1×1 made alacritty's grid.resize allocate
    /// hundreds of megabytes while reflowing history into millions of
    /// one-cell rows. bb_term_resize now floors the target dimensions at
    /// 2×2 (without touching the zero-is-noop contract).
    #[test]
    fn resize_clamps_degenerate_dimensions() {
        unsafe {
            let term = bb_term_new(80, 24, 1000);
            // Push enough history that reflow matters.
            for _ in 0..100 {
                bb_term_input(term, b"x\r\n".as_ptr(), 3);
            }
            // Request 1×1 — clamped to 2×2. Previously OOM.
            bb_term_resize(term, 1, 1);
            let snap = bb_term_take_snapshot(term);
            assert_eq!((*snap).cols, 2, "cols should clamp to min 2");
            assert_eq!((*snap).rows, 2, "rows should clamp to min 2");
            bb_snap_release(snap);
            bb_term_free(term);
        }
    }

    /// Regression: bb_term_new/bb_term_resize must clamp oversized dims to
    /// MAX_DIM (1000). The original OOM incident was fuzz/Swift passing
    /// u16::MAX for cols/rows, triggering a 100+ GB alloc inside alacritty's
    /// grid allocator. We deliberately DO NOT pass u16::MAX here — if the
    /// clamp ever regresses, this test would itself OOM the CI runner. 10 000
    /// is 10× MAX_DIM, safely allocatable if the clamp were (catastrophically)
    /// removed, and well outside anything a legitimate caller could want.
    /// The paired Swift-side clamp at TerminalSession.swift is tested
    /// independently; this is defence-in-depth on the Rust side.
    #[test]
    fn new_clamps_oversized_dimensions() {
        unsafe {
            let term = bb_term_new(10_000, 10_000, 1000);
            assert!(!term.is_null());
            let snap = bb_term_take_snapshot(term);
            assert!(
                (*snap).cols <= 1000,
                "bb_term_new must clamp oversized cols to MAX_DIM (got {})",
                (*snap).cols
            );
            assert!(
                (*snap).rows <= 1000,
                "bb_term_new must clamp oversized rows to MAX_DIM (got {})",
                (*snap).rows
            );
            bb_snap_release(snap);
            bb_term_free(term);
        }
    }

    #[test]
    fn resize_clamps_oversized_dimensions() {
        unsafe {
            let term = bb_term_new(80, 24, 1000);
            bb_term_resize(term, 10_000, 10_000);
            let snap = bb_term_take_snapshot(term);
            assert!(
                (*snap).cols <= 1000,
                "bb_term_resize must clamp oversized cols (got {})",
                (*snap).cols
            );
            assert!(
                (*snap).rows <= 1000,
                "bb_term_resize must clamp oversized rows (got {})",
                (*snap).rows
            );
            bb_snap_release(snap);
            bb_term_free(term);
        }
    }

    /// Regression: resize_changes_dimensions covers the nominal case, but the
    /// interesting failure mode is resize + scrollback. Feeding enough lines
    /// to build history and then shrinking should preserve the scrollback
    /// count (alacritty reflows but retains history up to the configured
    /// limit). This catches any future refactor that accidentally drops the
    /// history buffer on resize.
    #[test]
    fn resize_preserves_scrollback_history() {
        unsafe {
            let term = bb_term_new(10, 3, 100);
            assert!(!term.is_null());
            // 8 line-feeds past the 3-row screen → 5 lines in history.
            let input = b"aaa\nbbb\nccc\nddd\neee\nfff\nggg\nhhh";
            bb_term_input(term, input.as_ptr(), input.len());

            let before = bb_term_take_snapshot(term);
            let before_hist = (*before).history_size;
            assert!(
                before_hist >= 5,
                "history should have built to >=5 lines, got {}",
                before_hist
            );
            bb_snap_release(before);

            // Shrink vertically. alacritty reflows but keeps history.
            bb_term_resize(term, 10, 2);
            let after = bb_term_take_snapshot(term);
            assert_eq!((*after).rows, 2);
            assert!(
                (*after).history_size >= before_hist,
                "resize shrinking rows must not evict scrollback"
            );
            bb_snap_release(after);

            bb_term_free(term);
        }
    }

    #[test]
    fn resize_null_term_is_noop() {
        unsafe {
            bb_term_resize(std::ptr::null_mut(), 80, 24);
        }
    }

    #[test]
    fn bell_event_fires_callback() {
        use std::os::raw::c_void;
        use std::sync::{Arc, Mutex};

        let fired: Arc<Mutex<Vec<u32>>> = Arc::new(Mutex::new(Vec::new()));
        let fired_ptr = Arc::into_raw(fired.clone()) as *mut c_void;

        unsafe extern "C" fn cb(ev: BBEvent, ctx: *mut c_void) {
            let fired = &*(ctx as *const std::sync::Mutex<Vec<u32>>);
            fired.lock().unwrap().push(ev.kind as u32);
        }

        unsafe {
            let term = bb_term_new(20, 5, 100);
            bb_term_set_event_cb(term, Some(cb), fired_ptr);
            let byte = b"\x07"; // BEL
            bb_term_input(term, byte.as_ptr(), 1);

            let guard = fired.lock().unwrap();
            assert!(guard.contains(&(BBEventKind::Bell as u32)));
            drop(guard);

            bb_term_free(term);
            Arc::from_raw(fired_ptr as *const Mutex<Vec<u32>>);
        }
    }

    #[test]
    fn title_event_fires_callback() {
        use std::os::raw::c_void;
        use std::sync::{Arc, Mutex};

        let received: Arc<Mutex<Vec<String>>> = Arc::new(Mutex::new(Vec::new()));
        let received_ptr = Arc::into_raw(received.clone()) as *mut c_void;

        unsafe extern "C" fn cb(ev: BBEvent, ctx: *mut c_void) {
            if matches!(ev.kind, BBEventKind::Title) {
                let received = &*(ctx as *const std::sync::Mutex<Vec<String>>);
                let bytes = std::slice::from_raw_parts(ev.payload, ev.len);
                received
                    .lock()
                    .unwrap()
                    .push(String::from_utf8_lossy(bytes).into_owned());
            }
        }

        unsafe {
            let term = bb_term_new(20, 5, 100);
            bb_term_set_event_cb(term, Some(cb), received_ptr);
            // OSC 2 ; <title> BEL
            let seq = b"\x1b]2;my-title\x07";
            bb_term_input(term, seq.as_ptr(), seq.len());

            let got = received.lock().unwrap().clone();
            assert!(got.iter().any(|s| s == "my-title"), "got: {:?}", got);

            bb_term_free(term);
            Arc::from_raw(received_ptr as *const Mutex<Vec<String>>);
        }
    }

    #[test]
    fn setting_null_cb_disables_callback() {
        use std::os::raw::c_void;
        use std::sync::{Arc, Mutex};

        let count: Arc<Mutex<u32>> = Arc::new(Mutex::new(0));
        let count_ptr = Arc::into_raw(count.clone()) as *mut c_void;

        unsafe extern "C" fn cb(_ev: BBEvent, ctx: *mut c_void) {
            let count = &*(ctx as *const Mutex<u32>);
            *count.lock().unwrap() += 1;
        }

        unsafe {
            let term = bb_term_new(20, 5, 100);

            // Register callback, fire BEL, expect 1 invocation.
            bb_term_set_event_cb(term, Some(cb), count_ptr);
            bb_term_input(term, b"\x07".as_ptr(), 1);
            assert_eq!(*count.lock().unwrap(), 1);

            // Clear callback, fire BEL again, count must NOT increase.
            bb_term_set_event_cb(term, None, std::ptr::null_mut());
            bb_term_input(term, b"\x07".as_ptr(), 1);
            assert_eq!(
                *count.lock().unwrap(),
                1,
                "cleared callback should not fire"
            );

            bb_term_free(term);
            Arc::from_raw(count_ptr as *const Mutex<u32>);
        }
    }

    #[test]
    fn set_event_cb_on_null_term_is_noop() {
        unsafe {
            bb_term_set_event_cb(std::ptr::null_mut(), None, std::ptr::null_mut());
        }
    }

    /// text_range with rect=1 but s_col == e_col (degenerate rectangle).
    /// Loop should still run; each line emits one character.
    #[test]
    fn text_range_rectangular_single_column() {
        unsafe {
            let term = bb_term_new(10, 3, 100);
            bb_term_input(term, b"abcdefghij\r\nABCDEFGHIJ\r\n1234567890".as_ptr(), 32);
            let s = bb_term_text_range(term, 0, 5, 2, 5, 1);
            let bytes = std::slice::from_raw_parts((*s).bytes, (*s).len);
            assert_eq!(std::str::from_utf8(bytes).unwrap(), "f\nF\n6");
            bb_string_release(s);
            bb_term_free(term);
        }
    }

    /// Passing out-of-range u16 cols should clip to last_col (not overflow
    /// through to a garbage row access).
    #[test]
    fn text_range_clips_huge_col_request() {
        unsafe {
            let term = bb_term_new(5, 2, 100);
            bb_term_input(term, b"abcde".as_ptr(), 5);
            // Request cols 0..=u16::MAX — should clip to last_col = 4.
            let s = bb_term_text_range(term, 0, 0, 0, u16::MAX, 0);
            let bytes = std::slice::from_raw_parts((*s).bytes, (*s).len);
            assert_eq!(std::str::from_utf8(bytes).unwrap(), "abcde");
            bb_string_release(s);
            bb_term_free(term);
        }
    }

    #[test]
    fn text_range_extracts_single_line() {
        unsafe {
            let term = bb_term_new(20, 5, 100);
            bb_term_input(term, b"hello world".as_ptr(), 11);
            let s = bb_term_text_range(term, 0, 0, 0, 10, 0);
            assert!(!s.is_null());
            let bytes = std::slice::from_raw_parts((*s).bytes, (*s).len);
            assert_eq!(std::str::from_utf8(bytes).unwrap(), "hello world");
            bb_string_release(s);
            bb_term_free(term);
        }
    }

    #[test]
    fn text_range_spans_multiple_lines() {
        unsafe {
            let term = bb_term_new(5, 3, 100);
            bb_term_input(term, b"aaa\r\nbbb\r\nccc".as_ptr(), 13);
            let s = bb_term_text_range(term, 0, 0, 2, 2, 0);
            assert!(!s.is_null());
            let bytes = std::slice::from_raw_parts((*s).bytes, (*s).len);
            assert_eq!(std::str::from_utf8(bytes).unwrap(), "aaa\nbbb\nccc");
            bb_string_release(s);
            bb_term_free(term);
        }
    }

    /// Regression: before the clamp, feeding i32::MIN / i32::MAX as the
    /// line bounds caused the inner while loop to iterate ~4 billion times
    /// doing nothing but increment. This test should return nearly-instantly
    /// now; if someone removes the clamp it'll hang the test runner (which
    /// is exactly the signal we want).
    #[test]
    fn text_range_clamps_huge_line_range() {
        unsafe {
            let term = bb_term_new(5, 3, 100);
            bb_term_input(term, b"hi".as_ptr(), 2);
            let start = std::time::Instant::now();
            let s = bb_term_text_range(term, i32::MIN, 0, i32::MAX, 4, 0);
            let elapsed = start.elapsed();
            assert!(
                elapsed.as_secs() < 1,
                "text_range with i32::MIN..i32::MAX must be clamped — took {:?}",
                elapsed
            );
            // Only the grid's real lines contribute; "hi" is on line 0.
            let bytes = std::slice::from_raw_parts((*s).bytes, (*s).len);
            let out = std::str::from_utf8(bytes).unwrap();
            assert!(out.contains("hi"), "expected 'hi' in output, got {out:?}");
            bb_string_release(s);
            bb_term_free(term);
        }
    }

    #[test]
    fn text_range_reads_scrollback() {
        unsafe {
            let term = bb_term_new(3, 2, 100);
            bb_term_input(term, b"AAA\r\nBBB\r\nCCC\r\nDDD\r\nEEE".as_ptr(), 23);
            let s = bb_term_text_range(term, -3, 0, -3, 2, 0);
            let bytes = std::slice::from_raw_parts((*s).bytes, (*s).len);
            assert_eq!(std::str::from_utf8(bytes).unwrap(), "AAA");
            bb_string_release(s);
            bb_term_free(term);
        }
    }

    /// Regression: rectangular selection anchored top-right + bottom-left
    /// arrives with s_col > e_col after tuple-normalisation. The previous
    /// rectangular branch passed those straight into the inner loop, so
    /// `while c <= col_hi` never executed and every line came back empty.
    /// Now sort columns independently.
    #[test]
    fn text_range_rectangular_independent_col_sort() {
        unsafe {
            let term = bb_term_new(10, 3, 100);
            bb_term_input(term, b"abcdefghij\r\nABCDEFGHIJ\r\n1234567890".as_ptr(), 32);
            // Anchor at (0, 4), cursor at (2, 2) — rectangular mode. The
            // bounding rect spans cols 2..=4 on rows 0..=2.
            let s = bb_term_text_range(term, 0, 4, 2, 2, 1);
            let bytes = std::slice::from_raw_parts((*s).bytes, (*s).len);
            assert_eq!(
                std::str::from_utf8(bytes).unwrap(),
                "cde\nCDE\n345",
                "rectangular mode must extract the bounding rect regardless of corner order"
            );
            bb_string_release(s);
            bb_term_free(term);
        }
    }

    #[test]
    fn text_range_rectangular_clips_columns() {
        unsafe {
            let term = bb_term_new(10, 3, 100);
            bb_term_input(term, b"abcdefghij\r\nABCDEFGHIJ\r\n1234567890".as_ptr(), 32);
            let s = bb_term_text_range(term, 0, 2, 2, 4, 1);
            let bytes = std::slice::from_raw_parts((*s).bytes, (*s).len);
            assert_eq!(std::str::from_utf8(bytes).unwrap(), "cde\nCDE\n345");
            bb_string_release(s);
            bb_term_free(term);
        }
    }

    #[test]
    fn text_range_null_term_returns_null() {
        unsafe {
            assert!(bb_term_text_range(std::ptr::null_mut(), 0, 0, 0, 0, 0).is_null());
        }
    }

    #[test]
    fn string_release_null_is_noop() {
        unsafe {
            bb_string_release(std::ptr::null_mut());
        }
    }

    #[test]
    fn fatal_event_on_panic() {
        use std::os::raw::c_void;
        use std::sync::{Arc, Mutex};

        let fired: Arc<Mutex<Vec<(u32, String)>>> = Arc::new(Mutex::new(Vec::new()));
        let fired_ptr = Arc::into_raw(fired.clone()) as *mut c_void;

        unsafe extern "C" fn cb(ev: BBEvent, ctx: *mut c_void) {
            let fired = &*(ctx as *const std::sync::Mutex<Vec<(u32, String)>>);
            let msg = if ev.payload.is_null() || ev.len == 0 {
                String::new()
            } else {
                let slice = std::slice::from_raw_parts(ev.payload, ev.len);
                String::from_utf8_lossy(slice).into_owned()
            };
            fired.lock().unwrap().push((ev.kind as u32, msg));
        }

        unsafe {
            let term = bb_term_new(20, 5, 100);
            bb_term_set_event_cb(term, Some(cb), fired_ptr);

            bb_term_test_only_panic(term); // forces a panic inside guard()

            let guard_ = fired.lock().unwrap();
            let fatal = guard_.iter().find(|(k, _)| *k == BBEventKind::Fatal as u32);
            assert!(fatal.is_some(), "expected Fatal event, got {:?}", *guard_);
            assert!(
                fatal.unwrap().1.contains("intentional test panic"),
                "fatal msg should contain panic message: {:?}",
                fatal
            );
            drop(guard_);

            bb_term_free(term);
            Arc::from_raw(fired_ptr as *const Mutex<Vec<(u32, String)>>);
        }
    }

    /// Regression for rust-core-5 F3: if a Fatal dispatch re-enters the
    /// FFI (callback panics a `bb_term_*` call), the nested Fatal must be
    /// swallowed so the same callback isn't re-invoked recursively. We
    /// arrange exactly that shape: callback, on its first Fatal, calls
    /// `bb_term_test_only_panic(term)` which panics inside guard_with_term;
    /// the FFI_FATAL_IN_FLIGHT latch must cause the second dispatch to
    /// drop instead of firing the callback a second time (or deadlocking
    /// if the callback held a re-entrant lock).
    #[test]
    fn fatal_dispatch_does_not_reenter_callback() {
        use std::os::raw::c_void;
        use std::sync::{Arc, Mutex};

        // Pair: (invocation-count, has-re-panicked-once).
        // Mutex is NOT intentionally re-entrant — the swallow path is what
        // keeps this test from deadlocking, not NSLock-style recursion.
        struct State {
            term: *mut BBTerm,
            invocations: Mutex<u32>,
            already_re_panicked: Mutex<bool>,
        }
        // *mut BBTerm is not Send/Sync; the callback runs synchronously
        // on the test's own thread so we can cross that boundary safely.
        unsafe impl Send for State {}
        unsafe impl Sync for State {}

        let state = Arc::new(State {
            term: std::ptr::null_mut(),
            invocations: Mutex::new(0),
            already_re_panicked: Mutex::new(false),
        });
        // We'll write `term` into the Arc after creation by leaking the
        // Arc into a raw ptr, creating term, patching the field, and
        // handing the ptr to the callback context.
        let state_ptr = Arc::into_raw(Arc::clone(&state)) as *mut c_void;

        unsafe extern "C" fn cb(ev: BBEvent, ctx: *mut c_void) {
            let state = &*(ctx as *const State);
            *state.invocations.lock().unwrap() += 1;
            if ev.kind == BBEventKind::Fatal {
                let mut done = state.already_re_panicked.lock().unwrap();
                if !*done {
                    *done = true;
                    drop(done);
                    // Re-enter the FFI: this call itself panics inside
                    // guard_with_term. Without the re-entry latch we
                    // would be invoked recursively here and would
                    // observe `invocations == 2` below.
                    bb_term_test_only_panic(state.term);
                }
            }
        }

        unsafe {
            let term = bb_term_new(20, 5, 100);
            // Patch the `term` field post-hoc. Arc::into_raw gave us a raw
            // const pointer; we unsafe-mutate a field it points to through
            // a *mut cast. The field is !Send/!Sync but we've declared
            // State as such above; no other thread is reading while we
            // write, so this is sound.
            let state_mut = state_ptr as *mut State;
            std::ptr::addr_of_mut!((*state_mut).term).write(term);

            bb_term_set_event_cb(term, Some(cb), state_ptr);
            bb_term_test_only_panic(term);

            let invocations = *state.invocations.lock().unwrap();
            assert_eq!(
                invocations, 1,
                "callback must be invoked exactly once; nested Fatal was \
                 re-dispatched instead of swallowed (rust-core-5 F3 regression)",
            );

            bb_term_free(term);
            Arc::from_raw(state_ptr as *const State);
        }
    }

    #[test]
    fn set_named_color_changes_background_default() {
        unsafe {
            let term = bb_term_new(5, 2, 100);
            bb_term_input(term, b"x".as_ptr(), 1);
            // Slot 257 = NamedColor::Background in alacritty 0.26.
            bb_term_set_named_color(term, 257, 0xFF00AA);
            let snap = bb_term_take_snapshot(term);
            let cells = std::slice::from_raw_parts((*snap).cells, (*snap).cells_len);
            // Second cell in row 0 wasn't written → uses default bg → now 0xFF00AA.
            assert_eq!(cells[1].bg, 0xFF00AA);
            bb_snap_release(snap);
            bb_term_free(term);
        }
    }

    /// Out-of-range slot indices shouldn't panic through the FFI guard.
    /// alacritty's `Term::set_color` indexes the `Colors` array (fixed
    /// length `COUNT` = 269 in 0.26) directly: slots ≥ `COUNT` panic with
    /// index-out-of-bounds. A fuzzer found 0x0E0E (3598) reproduces this.
    /// `catch_unwind` inside `guard_with_term` does catch the panic in
    /// normal process space, but libFuzzer installs a panic hook that
    /// aborts first — so relying on `catch_unwind` isn't enough. Clamp in
    /// the FFI instead.
    #[test]
    fn set_named_color_out_of_range_slot_is_noop() {
        unsafe {
            let term = bb_term_new(5, 2, 100);
            // Should neither crash nor panic.
            bb_term_set_named_color(term, u16::MAX, 0x123456);
            bb_term_set_named_color(term, 9999, 0x987654);
            // Specific fuzzer-discovered value — 0x0E0E from a little-endian
            // u16. Must not panic.
            bb_term_set_named_color(term, 0x0E0E, 0x0E0E0E);
            // Right on the boundary — COUNT itself is invalid, COUNT-1 is
            // valid (exact last slot).
            bb_term_set_named_color(
                term,
                alacritty_terminal::term::color::COUNT as u16,
                0x010203,
            );
            // Sanity: a legit slot still works.
            bb_term_set_named_color(term, 257, 0xAABBCC);
            let snap = bb_term_take_snapshot(term);
            let cells = std::slice::from_raw_parts((*snap).cells, (*snap).cells_len);
            assert_eq!(
                cells[0].bg, 0xAABBCC,
                "slot 257 (Background) must still take effect"
            );
            bb_snap_release(snap);
            bb_term_free(term);
        }
    }

    #[test]
    fn set_named_color_null_term_is_noop() {
        unsafe {
            bb_term_set_named_color(std::ptr::null_mut(), 0, 0xFFFFFF);
        }
    }

    /// DECTCEM: ESC [ ? 25 l hides the cursor; h shows it. Previously we
    /// hard-coded cursor_visible = 1, so TUIs (less in page view, fzf,
    /// nvim during paint) that disabled the cursor still rendered it.
    #[test]
    fn dectcem_toggles_cursor_visible() {
        unsafe {
            let term = bb_term_new(10, 3, 100);
            let snap = bb_term_take_snapshot(term);
            assert_eq!(
                (*snap).cursor_visible,
                1,
                "cursor should default to visible on a fresh term"
            );
            bb_snap_release(snap);

            bb_term_input(term, b"\x1b[?25l".as_ptr(), 6);
            let hidden = bb_term_take_snapshot(term);
            assert_eq!((*hidden).cursor_visible, 0, "DECTCEM ?25l should hide");
            bb_snap_release(hidden);

            bb_term_input(term, b"\x1b[?25h".as_ptr(), 6);
            let shown = bb_term_take_snapshot(term);
            assert_eq!((*shown).cursor_visible, 1, "DECTCEM ?25h should re-show");
            bb_snap_release(shown);
            bb_term_free(term);
        }
    }

    #[test]
    fn cursor_shape_defaults_to_block() {
        unsafe {
            let term = bb_term_new(5, 2, 100);
            let snap = bb_term_take_snapshot(term);
            assert_eq!((*snap).cursor_shape, 0);
            bb_snap_release(snap);
            bb_term_free(term);
        }
    }

    #[test]
    fn cursor_shape_set_by_decscusr() {
        unsafe {
            let term = bb_term_new(5, 2, 100);
            // DECSCUSR 5 = steady bar (beam).
            bb_term_input(term, b"\x1B[5 q".as_ptr(), 5);
            let snap = bb_term_take_snapshot(term);
            assert_eq!((*snap).cursor_shape, 1); // 1 = bar
            bb_snap_release(snap);
            bb_term_free(term);
        }
    }

    /// SGR 7 (reverse video) must surface on the cell via the REVERSE flag
    /// so the Metal renderer can draw the inverted highlight. Without this
    /// the vim/less/ncurses highlight bars come through as plain text.
    #[test]
    fn sgr_reverse_sets_cell_reverse_flag() {
        unsafe {
            let term = bb_term_new(5, 2, 100);
            // ESC [ 7 m  switches to reverse video; then "A" writes the cell.
            bb_term_input(term, b"\x1b[7mA".as_ptr(), 5);
            let snap = bb_term_take_snapshot(term);
            let cells = std::slice::from_raw_parts((*snap).cells, (*snap).cells_len);
            assert_eq!(char::from_u32(cells[0].ch), Some('A'));
            assert_ne!(
                cells[0].flags & cell_flags::REVERSE,
                0,
                "cell written under SGR 7 should report REVERSE flag"
            );
            bb_snap_release(snap);
            bb_term_free(term);
        }
    }

    /// SGR 2 (dim / faint) — plain text renders normally, dim cells are
    /// surfaced via the DIM flag so the renderer can halve their brightness.
    #[test]
    fn sgr_dim_sets_cell_dim_flag() {
        unsafe {
            let term = bb_term_new(5, 2, 100);
            bb_term_input(term, b"\x1b[2mx".as_ptr(), 5);
            let snap = bb_term_take_snapshot(term);
            let cells = std::slice::from_raw_parts((*snap).cells, (*snap).cells_len);
            assert_ne!(cells[0].flags & cell_flags::DIM, 0);
            bb_snap_release(snap);
            bb_term_free(term);
        }
    }

    /// SGR 0 (reset) must clear accumulated attribute flags so subsequent
    /// text doesn't inherit the highlight.
    #[test]
    fn sgr_reset_clears_reverse_flag() {
        unsafe {
            let term = bb_term_new(5, 2, 100);
            bb_term_input(term, b"\x1b[7mA\x1b[0mB".as_ptr(), 10);
            let snap = bb_term_take_snapshot(term);
            let cells = std::slice::from_raw_parts((*snap).cells, (*snap).cells_len);
            assert_ne!(
                cells[0].flags & cell_flags::REVERSE,
                0,
                "A should be REVERSE"
            );
            assert_eq!(
                cells[1].flags & cell_flags::REVERSE,
                0,
                "B should not be REVERSE after SGR 0"
            );
            bb_snap_release(snap);
            bb_term_free(term);
        }
    }

    #[test]
    fn clear_all_wipes_viewport_and_scrollback() {
        unsafe {
            let term = bb_term_new(3, 2, 100);
            bb_term_input(term, b"AAA\r\nBBB\r\nCCC\r\nDDD".as_ptr(), 16);
            bb_term_clear_all(term);
            let snap = bb_term_take_snapshot(term);
            // Display has 2 rows of blanks. History should be empty.
            let cells = std::slice::from_raw_parts((*snap).cells, (*snap).cells_len);
            for c in cells {
                assert!(c.ch == 0 || c.ch == b' ' as u32, "got ch={}", c.ch);
            }
            assert_eq!((*snap).history_size, 0, "history not cleared");
            bb_snap_release(snap);
            bb_term_free(term);
        }
    }

    /// clear_all must reset display_offset even when the user was scrolled
    /// back. Otherwise `⌘K` inside scrollback leaves the viewport pointing at
    /// a now-empty region and the terminal looks "blank" until the user
    /// scrolls down — confusing and wrong, since the live grid is where the
    /// fresh prompt is about to appear.
    #[test]
    fn clear_all_snaps_viewport_to_live_grid() {
        unsafe {
            let term = bb_term_new(5, 3, 1000);
            // Push enough lines to build scrollback.
            for _ in 0..50 {
                bb_term_input(term, b"line\r\n".as_ptr(), 6);
            }
            // Scroll back into history.
            bb_term_scroll(term, 20);
            let mid = bb_term_take_snapshot(term);
            assert!(
                (*mid).display_offset > 0,
                "precondition: viewport should be scrolled back before clear"
            );
            bb_snap_release(mid);

            bb_term_clear_all(term);
            let after = bb_term_take_snapshot(term);
            assert_eq!(
                (*after).display_offset,
                0,
                "clear_all must snap viewport to live grid (display_offset == 0)"
            );
            assert_eq!((*after).history_size, 0, "scrollback must be wiped too");
            bb_snap_release(after);
            bb_term_free(term);
        }
    }

    /// i32::MIN / MAX deltas must not panic the core. A misbehaving input
    /// driver (or a future Swift caller that forgets to clamp) could hand us
    /// those extremes; alacritty's scroll_display clamps internally, but the
    /// FFI boundary needs to stay a no-panic zone regardless.
    #[test]
    fn scroll_extreme_deltas_dont_panic() {
        unsafe {
            let term = bb_term_new(5, 2, 100);
            // Build some scrollback first so both extremes have something to
            // clamp against.
            for _ in 0..50 {
                bb_term_input(term, b"line\r\n".as_ptr(), 6);
            }
            bb_term_scroll(term, i32::MIN);
            bb_term_scroll(term, i32::MAX);
            bb_term_scroll(term, 0); // explicit no-op branch
                                     // Reachable through either extreme — the viewport should still
                                     // snap back to the live grid cleanly afterwards.
            bb_term_scroll_to_bottom(term);
            let snap = bb_term_take_snapshot(term);
            assert_eq!(
                (*snap).display_offset,
                0,
                "scroll_to_bottom should pin the viewport regardless of prior extreme deltas"
            );
            bb_snap_release(snap);
            bb_term_free(term);
        }
    }

    /// Regression for rust-core-4 F2: `bb_snap_damage_rows` must now return
    /// the TOTAL damaged-row count, not the bytes written. A caller that
    /// passes a buffer smaller than the damaged set detects truncation by
    /// comparing the return value against `out_cap` and retrying with a
    /// larger buffer.
    #[test]
    fn damage_rows_reports_total_for_truncation_detection() {
        unsafe {
            let term = bb_term_new(10, 6, 100);
            // Drain the initial full-damage snapshot.
            let s0 = bb_term_take_snapshot(term);
            bb_snap_release(s0);
            // Touch three distinct rows so damage is partial on multiple rows.
            bb_term_input(term, b"A\r\nB\r\nC".as_ptr(), 5);
            let s = bb_term_take_snapshot(term);
            if bb_snap_damage_is_full(s) == 0 {
                // Probe via null-out gets the full total count.
                let total = bb_snap_damage_rows(s, std::ptr::null_mut(), 0);
                assert!(
                    total >= 1,
                    "expected ≥1 damaged row after row touches, got {total}"
                );
                // Zero-cap with a non-null out also returns the total.
                let mut tiny = [0u16; 1];
                let probed_with_buf = bb_snap_damage_rows(s, tiny.as_mut_ptr(), 0);
                assert_eq!(probed_with_buf, total);
                // Retry with an exact-sized buffer; `written == total`.
                let mut full = vec![0u16; total];
                let written = bb_snap_damage_rows(s, full.as_mut_ptr(), full.len());
                assert_eq!(written, total);

                // Truncation path (only exercises when total ≥ 2 — which
                // occurs for the three-row write above in release but may
                // collapse to 1 row in debug if alacritty coalesces). When
                // total ≥ 2, passing `out_cap = 1` writes exactly one row
                // but still reports `total` so the caller detects the
                // shortfall and can re-allocate.
                if total >= 2 {
                    let mut shortfall = [u16::MAX; 1];
                    let reported = bb_snap_damage_rows(s, shortfall.as_mut_ptr(), 1);
                    assert_eq!(
                        reported, total,
                        "return value must be total even on truncation"
                    );
                    assert_ne!(
                        shortfall[0],
                        u16::MAX,
                        "first slot must be written even on truncation"
                    );
                }
            }
            bb_snap_release(s);
            bb_term_free(term);
        }
    }

    /// Regression for rust-core-4 F13: double-free of a `BBString` must
    /// short-circuit via the magic sentinel rather than call
    /// `Vec::from_raw_parts` on stale parts (UB).
    #[test]
    fn bb_string_release_double_free_detected_via_magic() {
        unsafe {
            let term = bb_term_new(10, 2, 100);
            bb_term_input(term, b"abc".as_ptr(), 3);
            let s = bb_term_text_range(term, 0, 0, 0, 9, 0);
            assert!(!s.is_null());
            // First release: frees normally, zeroes _magic.
            bb_string_release(s);
            // Second release with the SAME pointer. The magic check in
            // bb_string_release must short-circuit: the allocation has
            // been freed but the pointer is still known; the released-
            // magic sentinel is 0, which no longer matches BB_STRING_MAGIC,
            // so the function returns without touching _owned_ptr (UB).
            bb_string_release(s);
            bb_term_free(term);
        }
    }

    /// Regression for rust-core-4 F1: an empty payload must surface as
    /// `bytes == NULL` (and len == 0) so Swift/C consumers can treat
    /// `NULL ⇔ empty` as a load-bearing invariant, rather than receiving
    /// `Vec::new().as_mut_ptr()`'s dangling-alignment sentinel. Also
    /// verifies `bb_string_release` tolerates the null `_owned_ptr` without
    /// calling `Vec::from_raw_parts(null, ...)` (UB).
    #[test]
    fn bb_string_new_empty_bytes_is_null() {
        unsafe {
            let s = bb_string_new(Vec::new());
            assert!(
                !s.is_null(),
                "bb_string_new itself should still return a valid Box"
            );
            let as_ref = &*s;
            assert!(
                as_ref.bytes.is_null(),
                "empty payload must expose bytes = NULL to C consumers",
            );
            assert_eq!(as_ref.len, 0);
            assert!(as_ref._owned_ptr.is_null());
            assert_eq!(as_ref._owned_cap, 0);
            // Release must be a clean no-op on the Vec::from_raw_parts path.
            bb_string_release(s);
        }
    }

    /// Regression for rust-core-4 F13: the magic constant and struct
    /// layout are pinned so a future refactor that reshapes BBString
    /// trips this assertion rather than silently drifting away from the
    /// Swift binding.
    #[test]
    fn bb_string_magic_layout_pinned() {
        assert_eq!(BB_STRING_MAGIC, 0xB1AC_5BBD_5721_57E0);
        // Field offsets — Swift reads bytes/len by name through the
        // cbindgen-generated header, but pinning size matters so an
        // accidental field-type change can't silently corrupt the
        // import on a 64-bit Darwin host (the only target today).
        assert_eq!(std::mem::offset_of!(BBString, bytes), 0);
        assert_eq!(std::mem::offset_of!(BBString, len), 8);
        assert_eq!(std::mem::size_of::<BBString>(), 40);
    }

    /// Regression for rust-core-4 F5: wide-char (CJK, emoji) text must
    /// round-trip through `bb_term_text_range` without inserting a space
    /// for every continuation cell. "中文" used to copy out as "中 文 ".
    ///
    /// Uses a two-row selection so the first row's `trim` path strips
    /// the grid-fill blanks; the wide-char skip is the load-bearing
    /// change here (without it the output would be "中 文 " with extra
    /// interior spaces that trim would NOT remove).
    #[test]
    fn text_range_skips_wide_char_spacer_cells() {
        unsafe {
            let term = bb_term_new(10, 2, 100);
            let bytes = "中文\r\nabc".as_bytes();
            bb_term_input(term, bytes.as_ptr(), bytes.len());
            let s = bb_term_text_range(term, 0, 0, 1, 2, 0);
            let bytes = std::slice::from_raw_parts((*s).bytes, (*s).len);
            let out = std::str::from_utf8(bytes).unwrap();
            assert_eq!(
                out, "中文\nabc",
                "CJK wide chars must emit without a space for each spacer cell"
            );
            bb_string_release(s);
            bb_term_free(term);
        }
    }

    /// `CSI 2 J` (ED All — erase visible viewport) MUST NOT touch the
    /// scrollback buffer. A previous revision auto-injected `CSI 3 J`
    /// after every top-level 2J so `clear(1)` would also wipe scrollback,
    /// but that wiped users' scrollback on every TUI redraw (Claude Code's
    /// Ink renderer, ratatui spinners, fzf full-screen redraws all emit
    /// 2J on each frame). Scrollback wipe is now reserved for the
    /// explicit `bb_term_clear_all` (⌘K) entry point.
    #[test]
    fn esc_2j_split_across_chunks_preserves_scrollback() {
        unsafe {
            let term = bb_term_new(10, 2, 100);
            for _ in 0..20 {
                bb_term_input(term, b"xx\r\n".as_ptr(), 4);
            }
            let before = bb_term_take_snapshot(term);
            let before_hist = (*before).history_size;
            bb_snap_release(before);
            assert!(before_hist > 0, "precondition: scrollback populated");

            // Split `\x1b[H\x1b[2J` across two tiny chunks so the
            // dispatching `J` arrives separately from the introducer.
            bb_term_input(term, b"\x1b[H\x1b[2".as_ptr(), 6);
            bb_term_input(term, b"J".as_ptr(), 1);

            // 2J erases the visible viewport; alacritty may archive the
            // soon-to-be-cleared row as it scrolls, so history can grow
            // by a small constant. The contract we care about is "2J
            // does not WIPE scrollback", not exact count preservation.
            let after = bb_term_take_snapshot(term);
            let after_hist = (*after).history_size;
            bb_snap_release(after);
            assert!(
                after_hist >= before_hist,
                "split-chunk ESC[2J must NOT shrink scrollback; \
                 before={before_hist} after={after_hist}"
            );
            bb_term_free(term);
        }
    }

    /// Top-level `ESC[2J` (the `clear(1)` case) erases the visible
    /// viewport but leaves scrollback intact. Users wanting both wiped
    /// invoke `bb_term_clear_all` directly (⌘K).
    #[test]
    fn top_level_esc_2j_preserves_scrollback() {
        unsafe {
            let term = bb_term_new(10, 2, 100);
            for _ in 0..20 {
                bb_term_input(term, b"yy\r\n".as_ptr(), 4);
            }
            let before = bb_term_take_snapshot(term);
            let before_hist = (*before).history_size;
            assert!(before_hist > 0);
            bb_snap_release(before);

            let clear_seq = b"\x1b[H\x1b[2J";
            bb_term_input(term, clear_seq.as_ptr(), clear_seq.len());

            let after = bb_term_take_snapshot(term);
            let after_hist = (*after).history_size;
            bb_snap_release(after);
            assert!(
                after_hist >= before_hist,
                "top-level ESC[2J must NOT shrink scrollback; \
                 before={before_hist} after={after_hist}"
            );
            bb_term_free(term);
        }
    }

    /// Repeated 2J frames (the actual TUI redraw pattern that surfaced
    /// the original bug) must leave scrollback monotonically non-
    /// decreasing. A naive re-introduction of the augmentation is
    /// already caught by the single-frame tests; this test catches the
    /// subtler case of a *conditional* injection (e.g. "inject after
    /// every Nth 2J") that would slip past single-frame coverage.
    #[test]
    fn repeated_esc_2j_frames_never_shrink_scrollback() {
        unsafe {
            let term = bb_term_new(80, 24, 1000);
            // Build up real scrollback content.
            for i in 0..200 {
                let line = format!("scrollback-line-{i}\n");
                bb_term_input(term, line.as_ptr(), line.len());
            }
            let pre = bb_term_take_snapshot(term);
            let pre_hist = (*pre).history_size;
            bb_snap_release(pre);
            assert!(pre_hist > 0, "precondition: scrollback populated");

            // Simulate 50 frames of TUI redraw spam — exactly the
            // pattern that wiped the user's scrollback continuously.
            let frame = b"\x1b[H\x1b[2J\x1b[1;1HSPINNER";
            let mut min_hist = pre_hist;
            for _ in 0..50 {
                bb_term_input(term, frame.as_ptr(), frame.len());
                let snap = bb_term_take_snapshot(term);
                let h = (*snap).history_size;
                bb_snap_release(snap);
                min_hist = min_hist.min(h);
            }
            assert!(
                min_hist >= pre_hist,
                "TUI redraw loop must not shrink scrollback; \
                 pre={pre_hist} min_during_loop={min_hist}"
            );
            bb_term_free(term);
        }
    }

    /// `bb_term_clear_all` (⌘K) is the explicit "wipe everything"
    /// entry point and DOES erase scrollback.
    #[test]
    fn bb_term_clear_all_erases_scrollback() {
        unsafe {
            let term = bb_term_new(10, 2, 100);
            for _ in 0..20 {
                bb_term_input(term, b"zz\r\n".as_ptr(), 4);
            }
            let before = bb_term_take_snapshot(term);
            assert!((*before).history_size > 0);
            bb_snap_release(before);

            bb_term_clear_all(term);

            let after = bb_term_take_snapshot(term);
            assert_eq!(
                (*after).history_size,
                0,
                "bb_term_clear_all must erase scrollback"
            );
            bb_snap_release(after);
            bb_term_free(term);
        }
    }

    /// Regression for rust-core-2 F10: OSC 52 clipboard-store no longer
    /// fires an `Osc52Clipboard` event by default. alacritty's `Osc52`
    /// config is `Disabled`, so the `Event::ClipboardStore` path is gated
    /// at the source and the user's clipboard can't be written by a
    /// remote PTY without an explicit opt-in FFI toggle.
    #[test]
    fn osc52_store_event_is_inert_by_default() {
        use std::os::raw::c_void;
        use std::sync::{Arc, Mutex};

        let fired: Arc<Mutex<Vec<u32>>> = Arc::new(Mutex::new(Vec::new()));
        let fired_ptr = Arc::into_raw(fired.clone()) as *mut c_void;

        unsafe extern "C" fn cb(ev: BBEvent, ctx: *mut c_void) {
            let fired = &*(ctx as *const std::sync::Mutex<Vec<u32>>);
            fired.lock().unwrap().push(ev.kind as u32);
        }

        unsafe {
            let term = bb_term_new(20, 5, 100);
            bb_term_set_event_cb(term, Some(cb), fired_ptr);
            // base64("hello") = "aGVsbG8=", the minimal valid payload.
            let seq = b"\x1b]52;c;aGVsbG8=\x07";
            bb_term_input(term, seq.as_ptr(), seq.len());
            let guard = fired.lock().unwrap();
            assert!(
                !guard.contains(&(BBEventKind::Osc52Clipboard as u32)),
                "Osc52Clipboard must be gated off by default; got {:?}",
                *guard
            );
            drop(guard);
            bb_term_free(term);
            let _ = Arc::from_raw(fired_ptr as *const Mutex<Vec<u32>>);
        }
    }

    /// Regression for rust-core-3 F4: `bb_term_resize2` must report the
    /// APPLIED dims + a `clamped` flag so Swift can reconcile
    /// TIOCSWINSZ with what alacritty actually did.
    #[test]
    fn resize2_reports_clamped_dims() {
        unsafe {
            let term = bb_term_new(80, 24, 100);
            // In-range request: no clamp, dims applied as-is.
            let r1 = bb_term_resize2(term, 120, 40);
            assert_eq!(r1.applied_cols, 120);
            assert_eq!(r1.applied_rows, 40);
            assert_eq!(r1.clamped, 0);
            // Oversized request: clamped to MAX_DIM = 1000.
            let r2 = bb_term_resize2(term, 10_000, 10_000);
            assert_eq!(r2.applied_cols, 1000);
            assert_eq!(r2.applied_rows, 1000);
            assert_ne!(r2.clamped, 0);
            // Undersized request: clamped to MIN_DIM = 2.
            let r3 = bb_term_resize2(term, 1, 1);
            assert_eq!(r3.applied_cols, 2);
            assert_eq!(r3.applied_rows, 2);
            assert_ne!(r3.clamped, 0);
            // Zero dim: no-op with all-zero result.
            let r4 = bb_term_resize2(term, 0, 5);
            assert_eq!(r4.applied_cols, 0);
            assert_eq!(r4.applied_rows, 0);
            assert_eq!(r4.clamped, 0);
            // Null term: same all-zero fallback.
            let r5 = bb_term_resize2(std::ptr::null_mut(), 10, 10);
            assert_eq!(r5.applied_cols, 0);
            assert_eq!(r5.applied_rows, 0);
            assert_eq!(r5.clamped, 0);
            bb_term_free(term);
        }
    }

    /// Regression for rust-core-3 F1: a hostile TUI writing many distinct
    /// 4 KiB URIs must NOT retain megabytes of CStrings per snapshot. The
    /// total-bytes cap (1 MiB) hits first and further URIs drop to
    /// link_id = 0.
    ///
    /// Memory discipline: 10×10 = 100 cells; we emit ~30 distinct URIs
    /// and at ~4 KiB each that's ~120 KiB total — well under the cap.
    /// The cap path is exercised by the integration test's 300×4 KiB
    /// pattern; the in-crate test pins the bookkeeping primitive
    /// (total-bytes stays under the declared maximum).
    #[test]
    fn osc8_total_bytes_cap_bookkeeping() {
        unsafe {
            let term = bb_term_new(10, 10, 100);
            // Emit 30 distinct URIs, ~4 KiB each.
            let long_a = "a".repeat(4000);
            for i in 0..30u32 {
                let uri = format!("https://example.com/{i}-{long_a}");
                let seq = format!("\x1b]8;;{uri}\x1b\\X\x1b]8;;\x1b\\");
                bb_term_input(term, seq.as_bytes().as_ptr(), seq.len());
            }
            let snap = bb_term_take_snapshot(term);
            assert!(!snap.is_null());
            let mut any_live_link = false;
            let cells = std::slice::from_raw_parts((*snap).cells, (*snap).cells_len);
            for c in cells {
                if c.link_id != 0 {
                    any_live_link = true;
                    break;
                }
            }
            assert!(
                any_live_link,
                "under-cap URIs must still produce attributions"
            );
            bb_snap_release(snap);
            bb_term_free(term);
        }
    }

    /// Regression for rust-core-3 F1: the URI intern store is truly
    /// persistent across snapshots — the same URI seen again in a later
    /// snapshot is NOT reallocated. We verify by taking two snapshots
    /// with the same URI and confirming:
    ///   1. `uri_cstr_cache` has the entry after the first snapshot.
    ///   2. The interned `Arc<CStr>` pointer is the SAME across
    ///      snapshots — proving reuse, not reallocation.
    ///   3. `uri_cache_bytes` does not grow on the second snapshot.
    #[test]
    fn osc8_intern_cache_is_retained_on_bbterm() {
        unsafe {
            let term = bb_term_new(10, 2, 100);
            // Emit an OSC 8 so the cache gets an entry.
            let seq = b"\x1b]8;;https://x.test/\x1b\\Y\x1b]8;;\x1b\\";
            bb_term_input(term, seq.as_ptr(), seq.len());

            let s1 = bb_term_take_snapshot(term);
            assert!(!s1.is_null());

            let bb = &*term;
            assert!(
                !bb.uri_cstr_cache.is_empty(),
                "uri_cstr_cache must retain entries across snapshots"
            );
            assert!(
                bb.uri_cache_bytes > 0,
                "uri_cache_bytes must track bytes of retained URIs"
            );
            let bytes_before = bb.uri_cache_bytes;
            // Capture a raw pointer to the cached Arc's pointee — used
            // below to confirm the second snapshot reuses this exact
            // allocation (not a fresh one).
            let cached_arc = bb
                .uri_cstr_cache
                .get("https://x.test/")
                .expect("URI must be interned after first snapshot");
            let cached_ptr = cached_arc.as_ptr();

            // Second snapshot — same URI still in the grid. Must reuse.
            let s2 = bb_term_take_snapshot(term);
            assert!(!s2.is_null());
            let bb = &*term;
            assert_eq!(
                bb.uri_cache_bytes, bytes_before,
                "uri_cache_bytes must not grow on a repeat URI — the \
                 intern store should have reused the existing entry"
            );
            let cached_arc_2 = bb
                .uri_cstr_cache
                .get("https://x.test/")
                .expect("URI must still be interned on second snapshot");
            assert_eq!(
                cached_arc_2.as_ptr(),
                cached_ptr,
                "repeated URI across snapshots must share the same Arc<CStr> \
                 allocation, not re-intern"
            );

            bb_snap_release(s1);
            bb_snap_release(s2);
            bb_term_free(term);
        }
    }

    /// Regression for rust-core-3 F1 — TOTAL-BYTES CAP. A hostile TUI
    /// writing distinct ~4 KiB URIs into many cells must not retain
    /// arbitrary megabytes of CStrings per snapshot: once the 1 MiB
    /// ceiling is crossed, subsequent distinct URIs drop to `link_id =
    /// 0` (no link) instead of polluting `BBSnapOwned::links`.
    ///
    /// Memory discipline: 40 × 30 = 1200 cells; we emit 300 distinct
    /// URIs at ~4 KiB each → ~1.2 MiB of raw URI bytes, ~2-3 MiB peak
    /// including HashMap/String overhead. Well below any OOM threshold
    /// (the snapshot-cells array itself is ~40 KiB).
    ///
    /// Expectations:
    ///   - at least one early cell retains a live link (cache fills
    ///     up to ~1 MiB before it saturates)
    ///   - at least one late cell has `link_id == 0` (cap fired)
    ///   - the live-link count is strictly less than 300 — proving the
    ///     cap dropped something. A regression that removed the cap
    ///     would let all 300 intern.
    #[test]
    fn osc8_intern_cap_drops_links_past_1mib() {
        unsafe {
            let term = bb_term_new(40, 30, 100);
            // 300 distinct ~4 KiB URIs. Each `X` lands on its own cell;
            // 300 cells fit in the top 8 rows of a 40×30 grid, so none
            // scroll off the screen before the snapshot.
            //
            // `bulk` is shared across URIs (one 4 KiB allocation) to
            // keep test peak RAM near the raw-URI total rather than
            // 300× that figure.
            let bulk = "a".repeat(4000);
            for i in 0..300u32 {
                let uri = format!("https://example.com/{i:03}-{bulk}");
                let seq = format!("\x1b]8;;{uri}\x1b\\X\x1b]8;;\x1b\\");
                bb_term_input(term, seq.as_bytes().as_ptr(), seq.len());
            }
            let snap = bb_term_take_snapshot(term);
            assert!(!snap.is_null());
            let cells = std::slice::from_raw_parts((*snap).cells, (*snap).cells_len);

            // A prefix of cells must have live links (cap not yet hit).
            let live_prefix = cells.iter().take(10).any(|c| c.link_id != 0);
            assert!(
                live_prefix,
                "early URIs must intern successfully before the 1 MiB cap fires"
            );

            // A suffix of cells must have been dropped to link_id = 0.
            // The 256th distinct URI alone pushes past 1 MiB; anything
            // after that falls into the "budget exhausted" branch.
            let dropped = cells.iter().take(300).filter(|c| c.link_id == 0).count();
            assert!(
                dropped > 0,
                "at least one URI past the 1 MiB cap must drop to link_id = 0"
            );

            // Cross-check: the live-link count is bounded. With 4 KiB
            // URIs and a 1 MiB cap, we expect at most ~260 live links
            // (`1_048_576 / 4032 ≈ 260`). Pin a loose upper bound that
            // would catch a regression where the cap is gone (all 300
            // would intern).
            let live_link_count = cells.iter().take(300).filter(|c| c.link_id != 0).count();
            assert!(
                live_link_count < 300,
                "cap must drop some URIs; saw {live_link_count}/300 live"
            );

            bb_snap_release(snap);
            bb_term_free(term);
        }
    }

    /// Regression for rust-core-3 F9 — ZERO-LINK FAST PATH. A snapshot
    /// of a grid with zero OSC 8 cells must not build the `links` Vec
    /// (no sentinel CString, no HashMap insert). We can't observe the
    /// allocation count directly, but the observable contract is:
    ///   - `bb_snap_link_url(snap, 0)` returns null (every snapshot,
    ///     per API — sanity)
    ///   - `bb_snap_link_url(snap, N)` for any `N > 0` also returns
    ///     null, because `links` is empty and the bounds check misses
    ///   - no panic, no UB reading past an empty Vec
    #[test]
    fn osc8_zero_link_snapshot_skips_intern_alloc() {
        unsafe {
            let term = bb_term_new(20, 5, 100);
            // Write plain text — no OSC 8 anywhere.
            let seq = b"hello world";
            bb_term_input(term, seq.as_ptr(), seq.len());
            let snap = bb_term_take_snapshot(term);
            assert!(!snap.is_null());

            // Every cell must have link_id == 0.
            let cells = std::slice::from_raw_parts((*snap).cells, (*snap).cells_len);
            for (i, c) in cells.iter().enumerate() {
                assert_eq!(
                    c.link_id, 0,
                    "cell {i} in a zero-OSC-8 grid must have link_id == 0"
                );
            }

            // link_id = 0 short-circuit.
            assert!(bb_snap_link_url(snap, 0).is_null());
            // Any non-zero id against an empty `links` Vec must resolve
            // to null — not panic, not dereference past the end.
            assert!(bb_snap_link_url(snap, 1).is_null());
            assert!(bb_snap_link_url(snap, 42).is_null());
            assert!(bb_snap_link_url(snap, u32::MAX).is_null());

            bb_snap_release(snap);
            bb_term_free(term);
        }
    }

    /// Regression for rust-core-1 F3: `RoutingListener` holds `Arc<...>`
    /// instead of raw pointers, so the `CallbackCell` and
    /// `ColorRequestQueue` remain live even if the listener outlives the
    /// owning `BBTerm` or an event fires during teardown. The previous
    /// implementation's invariant ("Term always dropped before BBTerm")
    /// was only documented; a future refactor could quietly violate it
    /// and turn it into use-after-free.
    ///
    /// The test pins the observable contract:
    ///   1. A listener cloned out of a `BBTerm` still refers to the same
    ///      `CallbackCell` (Arc refcount ≥ 2 after clone).
    ///   2. Dropping the BBTerm while the listener still holds its Arc
    ///      leaves the callback storage valid — we can still call `fire`
    ///      through the listener's Arc without UB (no segfault, no
    ///      Miri stacked-borrows complaint).
    ///   3. `push` into a ColorRequestQueue whose BBTerm has dropped
    ///      still succeeds and doesn't touch freed memory.
    #[test]
    fn routing_listener_arc_survives_bbterm_drop() {
        unsafe {
            let term_ptr = bb_term_new(10, 3, 100);
            assert!(!term_ptr.is_null());
            // Clone out the Arcs. The BBTerm still holds its own clones
            // via `callback` + `color_queue`, and the Term's listener
            // holds a third pair internally.
            let cell_arc: Arc<CallbackCell> = Arc::clone(&(*term_ptr).callback);
            let queue_arc: Arc<ColorRequestQueue> = Arc::clone(&(*term_ptr).color_queue);
            assert!(
                Arc::strong_count(&cell_arc) >= 2,
                "cloning the callback Arc must increment the refcount"
            );
            assert!(
                Arc::strong_count(&queue_arc) >= 2,
                "cloning the color_queue Arc must increment the refcount"
            );

            // Drop the BBTerm — this drops the Term (which drops its
            // listener, which drops its Arc pair) AND the BBTerm's own
            // Arc pair. Our out-of-BBTerm clone is the only reference
            // left to each cell.
            bb_term_free(term_ptr);

            // After free, the cells are still live (our Arcs hold them).
            // fire() with no callback registered is a no-op but must
            // not UAF. This is the regression — previously the raw
            // pointer in the listener could dangle if drop order
            // changed; with Arc, the cell is alive as long as an Arc
            // clone exists.
            cell_arc.fire(BBEvent {
                kind: BBEventKind::Bell,
                payload: std::ptr::null(),
                len: 0,
                i32_arg: 0,
            });

            // Same for the color queue: push must not touch freed
            // memory. No callback is registered inside the cell so
            // the entry just sits in the vec until our Arc drops.
            let fmt: Arc<dyn Fn(Rgb) -> String + Sync + Send> = Arc::new(|_rgb| String::new());
            assert!(queue_arc.push(ColorRequestEntry {
                index: 0,
                formatter: fmt,
            }));
            assert_eq!(queue_arc.len(), 1);

            // Our clones are the last holders. Drop them explicitly —
            // this runs the real destructors for `CallbackCell` and
            // `ColorRequestQueue` after the `BBTerm` has been gone
            // for several lines. Under the old raw-pointer regime,
            // every access above would have dereferenced freed
            // memory.
            drop(cell_arc);
            drop(queue_arc);
        }
    }

    // -------------------------------------------------------------------
    // Audit synthesis #13 — OSC 7 path traversal via percent-encoded `..`
    // -------------------------------------------------------------------

    /// Helper: run a single byte slice through a fresh BBTerm and return
    /// the captured (kind, payload) events. Mirrors the integration-test
    /// `drive` helper but stays inside `mod tests` so unit-only `cargo
    /// test --lib` runs cover these cases.
    fn drive_events(bytes: &[u8]) -> Vec<(u32, Vec<u8>)> {
        use std::os::raw::c_void;
        use std::sync::Mutex;

        struct Sink {
            events: Mutex<Vec<(u32, Vec<u8>)>>,
        }
        unsafe extern "C" fn cb(ev: BBEvent, ctx: *mut c_void) {
            let sink = &*(ctx as *const Sink);
            let bytes = if ev.len == 0 {
                Vec::new()
            } else {
                std::slice::from_raw_parts(ev.payload, ev.len).to_vec()
            };
            sink.events.lock().unwrap().push((ev.kind as u32, bytes));
        }

        let sink = Sink {
            events: Mutex::new(Vec::new()),
        };
        unsafe {
            let term = bb_term_new(80, 24, 1000);
            bb_term_set_event_cb(term, Some(cb), &sink as *const _ as *mut c_void);
            bb_term_input(term, bytes.as_ptr(), bytes.len());
            bb_term_free(term);
        }
        sink.events.into_inner().unwrap()
    }

    /// Audit synthesis #13: percent-encoded `..` segments must be rejected
    /// before the CwdChanged fires. Without this gate, an attacker emits
    /// `\x1b]7;file:///%2e%2e/etc\x07` and Blackbird's titlebar / Open in
    /// Finder / new-tab cwd inheritance lands at `../etc` (i.e. anywhere
    /// reachable from the prior cwd via `..`).
    #[test]
    fn osc7_rejects_percent_encoded_parent_dir() {
        let seq = b"\x1b]7;file:///%2e%2e/etc\x07";
        let events = drive_events(seq);
        assert!(
            events
                .iter()
                .all(|(k, _)| *k != BBEventKind::CwdChanged as u32),
            "%2e%2e (../) must drop the OSC 7 silently — got events: {events:?}"
        );
    }

    /// Audit synthesis #13: OSC 7 specifies an absolute path; the URI
    /// `file://hostname/relative/path` decodes to a host-authority + path
    /// where the path bytes don't start with `/`. Reject without firing.
    #[test]
    fn osc7_rejects_relative_path() {
        // `file://hostname/relative` — `hostname` is a non-localhost
        // authority; the OSC 7 handler already drops non-local hosts,
        // but a pure `relative/path` (no scheme structure with leading
        // `/`) must also be rejected. Easiest reproduction of the
        // "no leading slash after percent-decode" path: a bare
        // `file://relative` (rest = `relative`) is neither slash-prefix
        // nor `localhost`-prefix → returns at the strip stage.
        let seq = b"\x1b]7;file://relative/path\x07";
        let events = drive_events(seq);
        assert!(
            events
                .iter()
                .all(|(k, _)| *k != BBEventKind::CwdChanged as u32),
            "relative path must drop the OSC 7 silently — got events: {events:?}"
        );
    }

    /// Audit synthesis #13: legitimate absolute path still fires. Pin
    /// the happy path so the new traversal guard doesn't over-block.
    #[test]
    fn osc7_accepts_legitimate_path() {
        let seq = b"\x1b]7;file:///Users/foo/proj\x07";
        let events = drive_events(seq);
        let cwd = events
            .iter()
            .find(|(k, _)| *k == BBEventKind::CwdChanged as u32)
            .expect("expected CwdChanged event for a clean absolute path");
        assert_eq!(&cwd.1, b"/Users/foo/proj");
    }

    // -------------------------------------------------------------------
    // Audit synthesis #10 — OSC 133 prompt-mark rate limiting
    // -------------------------------------------------------------------

    /// Audit synthesis #10: an attacker spamming `OSC 133;A` must not
    /// flood the prompt-mark stream. Within a single 1-second window the
    /// Rust core dispatches at most PROMPT_MARK_PER_SECOND (16) of the
    /// navigable kinds (A/B/C); the rest are dropped silently.
    #[test]
    fn osc133_rate_limit_drops_excess_marks() {
        let mut buf = Vec::with_capacity(7 * 100);
        for _ in 0..100 {
            buf.extend_from_slice(b"\x1b]133;A\x07");
        }
        let events = drive_events(&buf);
        let prompt_marks = events
            .iter()
            .filter(|(k, _)| *k == BBEventKind::PromptMark as u32)
            .count();
        assert!(
            prompt_marks <= PROMPT_MARK_PER_SECOND as usize,
            "expected at most {} prompt marks within one window, got {}",
            PROMPT_MARK_PER_SECOND,
            prompt_marks
        );
    }

    /// Audit synthesis #10: after the 1-second window expires the
    /// counter resets. Sleeping just past the window boundary and
    /// firing one more A must dispatch — so total events from
    /// (16 spam + sleep + 1 spam) is 17, not stuck at 16.
    #[test]
    fn osc133_rate_limit_window_resets_after_one_second() {
        use std::os::raw::c_void;
        use std::sync::Mutex;

        struct Sink {
            count: Mutex<usize>,
        }
        unsafe extern "C" fn cb(ev: BBEvent, ctx: *mut c_void) {
            if matches!(ev.kind, BBEventKind::PromptMark) {
                let sink = &*(ctx as *const Sink);
                *sink.count.lock().unwrap() += 1;
            }
        }

        let sink = Sink {
            count: Mutex::new(0),
        };
        unsafe {
            let term = bb_term_new(80, 24, 1000);
            bb_term_set_event_cb(term, Some(cb), &sink as *const _ as *mut c_void);

            // Fire exactly the cap (16) inside the first window.
            let mut buf = Vec::with_capacity(7 * PROMPT_MARK_PER_SECOND as usize);
            for _ in 0..PROMPT_MARK_PER_SECOND {
                buf.extend_from_slice(b"\x1b]133;A\x07");
            }
            bb_term_input(term, buf.as_ptr(), buf.len());
            assert_eq!(
                *sink.count.lock().unwrap(),
                PROMPT_MARK_PER_SECOND as usize,
                "first window must accept exactly the cap"
            );

            // Sleep past the 1-second window boundary so the counter
            // resets. Total test wall-clock stays under 2 s.
            std::thread::sleep(std::time::Duration::from_millis(1100));

            let one_more = b"\x1b]133;A\x07";
            bb_term_input(term, one_more.as_ptr(), one_more.len());

            assert_eq!(
                *sink.count.lock().unwrap(),
                PROMPT_MARK_PER_SECOND as usize + 1,
                "post-sleep mark must dispatch once the window resets"
            );

            bb_term_free(term);
        }
    }

    // -------------------------------------------------------------------
    // Bug #17 — OSC 10/11/12 color-query reply rate limit (cross-call)
    // -------------------------------------------------------------------

    /// Bug #17: a hostile shell spamming OSC 10 color queries must not
    /// amplify replies through the PTY. Within one rolling 1-second
    /// window the core dispatches at most COLOR_QUERY_REPLY_PER_SECOND
    /// (32) PtyWrite events; the rest drop silently.
    ///
    /// Drives the full path (alacritty's OSC 10 dispatch → ColorRequest
    /// → ColorRequestQueue → drain_color_requests) with replies enabled
    /// so the gate inside drain is actually exercised.
    #[test]
    fn osc_color_query_rate_limit_drops_excess() {
        use std::os::raw::c_void;
        use std::sync::Mutex;

        struct Sink {
            count: Mutex<usize>,
        }
        unsafe extern "C" fn cb(ev: BBEvent, ctx: *mut c_void) {
            if matches!(ev.kind, BBEventKind::PtyWrite) {
                let sink = &*(ctx as *const Sink);
                *sink.count.lock().unwrap() += 1;
            }
        }

        let sink = Sink {
            count: Mutex::new(0),
        };
        unsafe {
            let term = bb_term_new(80, 24, 1000);
            bb_term_set_event_cb(term, Some(cb), &sink as *const _ as *mut c_void);
            bb_term_set_color_query_enabled(term, 1);

            // 200 separate OSC 10 queries, fed across 200 distinct
            // bb_term_input chunks so the per-call ColorRequestQueue cap
            // (256) does NOT come into play — this isolates the new
            // sliding-window gate as the only line of defense.
            let one_query = b"\x1b]10;?\x1b\\";
            for _ in 0..200 {
                bb_term_input(term, one_query.as_ptr(), one_query.len());
            }

            let writes = *sink.count.lock().unwrap();
            assert!(
                writes <= COLOR_QUERY_REPLY_PER_SECOND as usize,
                "expected at most {} color-query replies within one window, got {}",
                COLOR_QUERY_REPLY_PER_SECOND,
                writes
            );

            bb_term_free(term);
        }
    }

    /// Bug #17: after the 1-second window expires the counter resets.
    /// Fire the cap (32), sleep just past the boundary, fire one more —
    /// total replies must be 33.
    #[test]
    fn osc_color_query_rate_limit_window_resets() {
        use std::os::raw::c_void;
        use std::sync::Mutex;

        struct Sink {
            count: Mutex<usize>,
        }
        unsafe extern "C" fn cb(ev: BBEvent, ctx: *mut c_void) {
            if matches!(ev.kind, BBEventKind::PtyWrite) {
                let sink = &*(ctx as *const Sink);
                *sink.count.lock().unwrap() += 1;
            }
        }

        let sink = Sink {
            count: Mutex::new(0),
        };
        unsafe {
            let term = bb_term_new(80, 24, 1000);
            bb_term_set_event_cb(term, Some(cb), &sink as *const _ as *mut c_void);
            bb_term_set_color_query_enabled(term, 1);

            let one_query = b"\x1b]10;?\x1b\\";
            for _ in 0..COLOR_QUERY_REPLY_PER_SECOND {
                bb_term_input(term, one_query.as_ptr(), one_query.len());
            }
            assert_eq!(
                *sink.count.lock().unwrap(),
                COLOR_QUERY_REPLY_PER_SECOND as usize,
                "first window must accept exactly the cap"
            );

            std::thread::sleep(std::time::Duration::from_millis(1100));

            bb_term_input(term, one_query.as_ptr(), one_query.len());
            assert_eq!(
                *sink.count.lock().unwrap(),
                COLOR_QUERY_REPLY_PER_SECOND as usize + 1,
                "post-sleep query must dispatch once the window resets"
            );

            bb_term_free(term);
        }
    }

    // -------------------------------------------------------------------
    // Bug #18 — OSC 0/1/2 window-title control-character scrubbing
    // -------------------------------------------------------------------

    /// Bug #18 (unit): direct test of `scrub_title_controls`. Pins the
    /// strip behaviour for every C0 byte (0x00..=0x1F), DEL (0x7F), and
    /// every C1 codepoint (U+0080..=U+009F). Printable ASCII and
    /// non-control multi-byte UTF-8 must pass through untouched.
    #[test]
    fn scrub_title_controls_strips_c0_del_c1() {
        // C0: NUL, BEL, ESC, plus a CSI-like sequence.
        let c0 = "a\x00b\x07c\x1bd\x1b[31me";
        assert_eq!(scrub_title_controls(c0), "abcd[31me");

        // DEL.
        assert_eq!(scrub_title_controls("a\x7fb"), "ab");

        // C1: U+0085 (NEL), U+009B (CSI).
        assert_eq!(scrub_title_controls("a\u{0085}b\u{009b}c"), "abc");

        // Non-control multi-byte UTF-8 unchanged.
        assert_eq!(scrub_title_controls("café 日本語"), "café 日本語");

        // Empty string.
        assert_eq!(scrub_title_controls(""), "");
    }

    /// Bug #18 (integration): feed the canonical attack payload
    /// `\x1b]2;before\x1b[31mafter\x07` through the full input path. The
    /// emitted Title event must contain no ESC (0x1B) and no `[` byte
    /// from a CSI tail; `scrub_title_controls` plus vte's own
    /// OSC-string state machine together guarantee the C0 bytes are
    /// gone before the listener sees them.
    #[test]
    fn osc_title_strips_c0_controls() {
        let seq = b"\x1b]2;before\x1b[31mafter\x07";
        let events = drive_events(seq);
        let titles: Vec<&Vec<u8>> = events
            .iter()
            .filter(|(k, _)| *k == BBEventKind::Title as u32)
            .map(|(_, p)| p)
            .collect();
        assert!(
            !titles.is_empty(),
            "expected at least one Title event, got: {events:?}"
        );
        for title in &titles {
            assert!(
                !title.contains(&0x1B),
                "Title payload must not contain ESC (0x1B); got {:?}",
                String::from_utf8_lossy(title)
            );
            // Defense in depth: every byte must be non-C0 / non-DEL /
            // non-C1 (single-byte form). Multi-byte UTF-8 leading bytes
            // are >= 0xC2 so this filter does not snag them.
            for &b in title.iter() {
                assert!(
                    !(b <= 0x1F || b == 0x7F),
                    "Title payload contains C0/DEL byte 0x{b:02X}: {:?}",
                    String::from_utf8_lossy(title)
                );
            }
        }
    }

    /// Bug #18 (integration): C1 controls in UTF-8 (U+0085 → 0xC2 0x85)
    /// survive vte's OSC-string filter (which only drops single-byte
    /// C0). Our `scrub_title_controls` codepoint filter must catch them.
    #[test]
    fn osc_title_strips_c1_controls() {
        // U+0085 (NEL) between 'a' and 'b'.
        let seq = b"\x1b]2;a\xc2\x85b\x07";
        let events = drive_events(seq);
        let title = events
            .iter()
            .find(|(k, _)| *k == BBEventKind::Title as u32)
            .expect("expected Title event");
        assert_eq!(
            title.1.as_slice(),
            b"ab",
            "C1 control U+0085 must be stripped from title; got {:?}",
            String::from_utf8_lossy(&title.1)
        );
    }
}
