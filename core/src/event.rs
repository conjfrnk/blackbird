//! Public event-callback types forwarded across the C ABI.
//!
//! Leaf types with no in-crate dependencies; re-exported from the crate root
//! so `blackbird_core::BBEvent` and the cbindgen header are unchanged.

use std::os::raw::c_void;

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
    /// `CallbackCell::fire` normalizes this invariant at dispatch
    /// (audit S6-001): producers may hand `fire` an empty slice's
    /// `as_ptr()` (non-null) or even a fresh `String`'s
    /// `NonNull::dangling()` — the callback always observes
    /// `payload == NULL ⇔ len == 0`, so a C consumer branching on
    /// non-null per this contract never sees a dangling pointer.
    pub payload: *const u8,
    pub len: usize,
    /// Event-specific integer argument (audit S6-002):
    /// - `PromptMark`: the mark kind, 1 = A (prompt start), 2 = B
    ///   (command start), 3 = C (command output), 4 = D (command end) —
    ///   see `BBPromptMarkKind`.
    /// - `CursorShape` (reserved; not currently emitted): 0 = block,
    ///   1 = bar, 2 = underline.
    /// - 0 for every other event kind.
    pub i32_arg: i32,
}

/// C callback signature for terminal events.
pub type BBEventCb = unsafe extern "C" fn(BBEvent, *mut c_void);
