use std::os::raw::c_void;

#[repr(u32)]
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum BBEventKind {
    Title = 1,
    Bell = 2,
    /// Reserved; not emitted. Read cursor state from snapshots.
    CursorShape = 3,
    Osc52Clipboard = 4,
    /// Bytes to write BACK to the PTY: replies to DSR (ESC[6n), DA1/DA2, DECRPM and similar.
    PtyWrite = 5,
    /// Payload: UTF-8 local filesystem path decoded from an OSC 7 `file://` URL for this machine.
    CwdChanged = 6,
    /// OSC 133 mark. `i32_arg`: 1 = A (prompt start), 2 = B (command start), 3 = C (output
    /// start), 4 = D (command end). `payload`: ASCII decimal exit code for D, empty otherwise.
    PromptMark = 7,
    /// OSC 9, OSC 777 `;notify;title;body`, or kitty OSC 99. Payload: UTF-8 `title U+001F body`.
    Notification = 8,
    Fatal = 99,
}

/// `payload` is valid **only for the duration of the callback**; copy the bytes to keep them.
#[repr(C)]
pub struct BBEvent {
    pub kind: BBEventKind,
    /// Borrowed pointer into Rust-owned memory; `payload == NULL ⇔ len == 0`.
    pub payload: *const u8,
    pub len: usize,
    /// `PromptMark`: the mark kind (see `BBPromptMarkKind`). 0 for every other event kind.
    pub i32_arg: i32,
    /// `PromptMark` kind A: the cursor's grid row (0 = top of the live grid) when parsed; else 0.
    pub cursor_row: u16,
    /// `PromptMark` kind A: the primary screen's lines-scrolled counter when parsed; else 0.
    pub lines_scrolled: u64,
}

pub type BBEventCb = unsafe extern "C" fn(BBEvent, *mut c_void);
