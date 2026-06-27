//! The snapshot data types crossing the C ABI — `BBCell`, `BBSnap`, the
//! `cell_flags`/`bb_mode` bit tables — and `BBSnapOwned`, the private heap
//! owner whose `snap` field sits at offset 0 so a `*const BBSnap` cast
//! recovers the whole allocation (Part I §3). The repr(C) layouts are
//! append-only with explicit padding (Part I §4/§5); see the offset asserts
//! in the test module. Moved out of the monolith verbatim (REFACTOR.md
//! Wave 1); behavior unchanged.

use std::sync::atomic::AtomicUsize;
use std::sync::Arc;

use alacritty_terminal::grid::Dimensions;
use alacritty_terminal::term::cell::Flags as CellFlags;
use alacritty_terminal::term::TermMode;

use crate::color::color_to_rgb;
use crate::scrub::contains_bidi_or_invisible;
use crate::{BBTerm, UNDERLINE_COLOR_UNSET};

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
    /// The cell's base glyph starts an emoji-presentation sequence — a
    /// text-default symbol carrying a VS16 (U+FE0F) zero-width mark (⚠️ ‼️ ❤️,
    /// keycaps) — so the renderer must rasterise the COLOUR emoji from the
    /// base + VS16 grapheme, not the bare base scalar (which CoreText resolves
    /// to the monochrome text glyph). Width is carried separately by
    /// WIDE_CHAR; this bit only governs colour / glyph selection. Set by the
    /// snapshot FFI when a cell's zerowidth list contains U+FE0F.
    pub const EMOJI_PRESENTATION: u16 = 1 << 13;
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
    /// Monotonic count of lines the PRIMARY screen has pushed toward
    /// scrollback history — including lines recycled once the ring
    /// saturated. Unlike `history_size`, which plateaus at the
    /// scrollback cap, this never saturates, so callers can anchor
    /// content positions across eviction: content at grid row R in a
    /// snapshot whose counter read P sits `(counter_now − P)` rows
    /// further up in any later snapshot.
    ///
    /// Scope of the algebra (review-tightened): it is reliable for
    /// content that scrolls toward history via ordinary full-width
    /// output flow. Content still in the VIEWPORT can additionally be
    /// moved by operations this counter does not see — reverse index /
    /// CSI T at the top of the screen (`scroll_down`), IL/DL, and
    /// DECSTBM scroll-region rotations — so anchors to viewport rows
    /// drift under full-screen TUI redraws (shell prompt flows don't
    /// use these). Invalidation rules for consumers:
    /// - ANY resize (either axis) invalidates all anchors.
    /// - Clears are PTY-initiated and not separately signalled; detect
    ///   them by `history_size` shrinking between snapshots (ED 3 /
    ///   RIS reset history while this counter holds still) and drop
    ///   anchors then.
    /// - The counter never moves backward for a live handle.
    ///
    /// Appended at the struct tail to preserve existing field offsets
    /// (same rule as `history_size`). Audit S5-004/S5-005.
    pub lines_scrolled: u64,
    /// 1 when the cursor is parked ON the last written cell with
    /// alacritty's `input_needs_wrap` set — the input line exactly
    /// filled the row, so the shell's LOGICAL cursor position is one
    /// character PAST `cursor_col` even though the grid cursor hasn't
    /// wrapped yet. Grid state alone cannot distinguish this from a
    /// cursor legitimately sitting on a character (e.g. after
    /// arrow-left); consumers doing character-position math (the
    /// find-replace splice) need this bit. Audit S5-003 review
    /// follow-up. Appended at the tail per the ABI-evolution rule.
    pub cursor_pending_wrap: u8,
    pub _pad3: [u8; 7],
}

unsafe impl Send for BBSnap {}
// SAFETY: all fields are read-only after BBSnapOwned::new returns; cells aliases
// cells_owned's heap buffer which is never reallocated after construction.
unsafe impl Sync for BBSnap {}

/// Private heap owner for a snapshot. `snap` is the first field so that a
/// `*const BBSnap` == `*const BBSnapOwned` via a simple cast, enabling the
/// public C API to hand out `*const BBSnap` while retaining full ownership here.
#[repr(C)]
pub(crate) struct BBSnapOwned {
    pub(crate) snap: BBSnap,
    pub(crate) rc: AtomicUsize,
    pub(crate) cells_owned: Vec<BBCell>,
    /// OSC 8 URI table. Empty when the grid had no OSC 8 cells (rust-core-3 F9
    /// short-circuit — no sentinel push, no HashMap, no allocation); otherwise
    /// index 0 is a reserved empty-string sentinel and index N matches
    /// `BBCell.link_id`. Stored as `Arc<CStr>` so the same interned URI is
    /// shared across snapshots via `BBTerm::uri_cstr_cache` (rust-core-3 F1),
    /// avoiding a `CString::new(uri.to_owned())` per appearance. The pointer
    /// handed out by `bb_snap_link_url` is stable for the snapshot's lifetime
    /// because the Arc's pointee never moves.
    pub(crate) links: Vec<Arc<std::ffi::CStr>>,
    /// Rows whose content changed between this snapshot and the previous.
    /// Extracted from alacritty's `Term::damage()` before the grid read, then
    /// the term's damage is reset so each snapshot reports deltas.
    /// Empty when `damage_full == true` OR when nothing changed; readers
    /// disambiguate via `damage_full`.
    pub(crate) damaged_rows: Vec<u16>,
    /// True when alacritty reports full damage (scroll, insert-mode, or a
    /// similar wholesale change). A `true` value means the renderer must
    /// redraw everything and `damaged_rows` is irrelevant.
    pub(crate) damage_full: bool,
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
    pub(crate) fn new(
        cols: u16,
        rows: u16,
        cursor: (u16, u16, bool),
        cursor_pending_wrap: bool,
        display_offset: u32,
        history_size: u32,
        lines_scrolled: u64,
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
                lines_scrolled,
                cursor_pending_wrap: cursor_pending_wrap as u8,
                _pad3: [0; 7],
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
    pub(crate) unsafe fn from_snap_ptr(snap: *const BBSnap) -> *mut BBSnapOwned {
        snap as *mut BBSnapOwned
    }
}

// Compile-time ABI layout guards (Part I §3-5). A field reorder, insertion, or
// size change that would desync the cbindgen-generated BBCore.h or the Swift
// bridge is a BUILD error here — not merely a runtime test failure. These pin
// exactly the offsets the runtime `snap_layout_matches_expected` test asserts;
// keeping both means a layout drift is caught whether or not tests are run.
const _: () = {
    use std::mem::{offset_of, size_of};
    // BBSnapOwned: `snap` at offset 0 so `*const BBSnap` recovers the whole
    // allocation via a plain cast (from_snap_ptr). Part I §3 — the load-bearing
    // miri-H5 invariant.
    assert!(offset_of!(BBSnapOwned, snap) == 0);
    // BBSnap head + appended fields are append-only (Part I §4); offsets frozen.
    assert!(offset_of!(BBSnap, cols) == 0);
    assert!(offset_of!(BBSnap, rows) == 2);
    assert!(offset_of!(BBSnap, cursor_col) == 4);
    assert!(offset_of!(BBSnap, cursor_row) == 6);
    assert!(offset_of!(BBSnap, cursor_visible) == 8);
    assert!(offset_of!(BBSnap, display_offset) == 12);
    assert!(offset_of!(BBSnap, mode) == 16);
    assert!(offset_of!(BBSnap, cells_len) == 24);
    assert!(offset_of!(BBSnap, cells) == 32);
    assert!(offset_of!(BBSnap, history_size) == 40);
    assert!(offset_of!(BBSnap, cursor_shape) == 44);
    assert!(offset_of!(BBSnap, lines_scrolled) == 48);
    assert!(offset_of!(BBSnap, cursor_pending_wrap) == 56);
    assert!(size_of::<BBSnap>() == 64);
    // BBCell: 20-byte ABI (Part I §5). Any further field needs a stride bump in
    // CellInstance / Shaders.metal too.
    assert!(size_of::<BBCell>() == 20);
    assert!(offset_of!(BBCell, link_id) == 14);
    assert!(offset_of!(BBCell, underline_color) == 16);
};

/// Extract our stable `cell_flags` bitset from alacritty's `Flags`.
pub(crate) fn extract_cell_flags(f: CellFlags) -> u16 {
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
pub(crate) fn extract_mode(term_mode: &TermMode) -> u32 {
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
pub(crate) fn extract_mode_with_extras(bb: &BBTerm) -> u32 {
    let mut m = extract_mode(bb.term.mode());
    if bb.modify_other_keys > 0 {
        m |= bb_mode::MODIFY_OTHER_KEYS;
    }
    m
}

/// Build an immutable `BBSnapOwned` from the current grid state and return a
/// `*const BBSnap` aliasing its offset-0 `snap` field. The returned pointer is
/// caller-owned (one `bb_snap_release` per call). Pure logic over `&mut BBTerm`
/// — no FFI handle — so it is directly unit-testable. (Extracted verbatim from
/// the body of `bb_term_take_snapshot`; REFACTOR.md Part IV.)
pub(crate) fn snapshot(bb: &mut BBTerm) -> *const BBSnap {
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

    let palette = bb.term.colors();
    let grid = bb.term.grid();

    let rows = grid.screen_lines() as u16;
    let cols = grid.columns() as u16;
    let mut cells: Vec<BBCell> = Vec::with_capacity(rows as usize * cols as usize);

    // OSC 8 hyperlink interning is split into two phases to keep the
    // term borrow disjoint from the persistent cache mutation
    // (audit RC-01). Phase 1 (here, under `&bb.term`) collects each
    // unique URI as an owned `String` and records each cell's
    // local-id (1..=N). Phase 2 (after the term borrow ends)
    // resolves those local ids against `bb.uri_cstr_cache` and
    // builds the final `links: Vec<Arc<CStr>>`. Translating cells
    // from local id → final id then walks `cells` once.
    //
    // The earlier shape used `mem::take` to pluck the cache out of
    // `bb` for the duration of the grid loop, then wrote it back at
    // the end. Any panic between the take and the write-back left
    // `bb.uri_cstr_cache` empty while `bb.uri_cache_bytes` retained
    // its non-zero value — every future snapshot would then fail
    // the byte-cap check against an empty cache, permanently
    // dropping all OSC 8 attribution. The two-phase shape removes
    // the take entirely.
    //
    // Caps preserved:
    //   - distinct URIs per snapshot: `u16::MAX - 1 = 65534` (local ids)
    //   - per-URI bytes: 4 KiB (covers any realistic http URL)
    //   - total interned bytes ACROSS the persistent cache:
    //     `OSC8_TOTAL_INTERN_BYTES_CAP` = 1 MiB. Over the ceiling,
    //     new URIs drop to no-link rather than evict — eviction
    //     would invalidate pointers held by still-live snapshots
    //     that `Arc::clone`d the existing CStr.
    //
    // rust-core-3 F9: `links` stays empty until phase 2 sees that
    // phase 1 actually collected URIs. The common case — ProMotion
    // frame re-render with no OSC 8 on screen — pays zero heap
    // allocations for the intern table.
    const OSC8_URI_MAX: usize = 4096;
    const OSC8_TOTAL_INTERN_BYTES_CAP: usize = 1024 * 1024;
    // Phase 1 state: dedup'd URIs in insertion order, plus a parallel
    // dedup map sharing the same allocation. Audit L-7 (2026-05-03):
    // wrap each unique URI in `Arc<str>` once and clone the Arc into
    // both the vec and the dedup map — cloning an Arc is one atomic
    // increment, much cheaper than the prior shape that allocated a
    // fresh `String` per side (one `to_owned`, one `clone`).
    let mut phase1_uris: Vec<Arc<str>> = Vec::new();
    let mut local_uri_to_id: std::collections::HashMap<Arc<str>, u16> =
        std::collections::HashMap::new();
    // Track whether this snapshot ran out of u16 link ids so we can
    // emit a one-shot diagnostic AFTER the grid borrow ends (the
    // `bb.osc8_id_exhaustion_logged` field can't be touched while
    // `grid` borrows `bb.term`). Audit S2-014.
    let mut osc8_id_exhausted_this_snapshot = false;
    for indexed in grid.display_iter() {
        let link_id: u16 = match indexed.cell.hyperlink() {
            Some(h) => {
                let uri = h.uri();
                // alacritty's OSC 8 parser rejects empty URIs upstream, but
                // we defensively treat an empty uri as "no link".
                if uri.is_empty() || uri.len() > OSC8_URI_MAX {
                    0
                } else if contains_bidi_or_invisible(uri.as_bytes()) {
                    // Audit S4-001 / fix-#03. Parity with the OSC 7 path
                    // (lib.rs:1146) and the OSC 0/2 title scrubber
                    // (scrub_title_controls): drop attribution for URIs
                    // carrying raw bidi-override / invisible scalars.
                    // Foundation's URL(string:) percent-encodes them on
                    // the Swift side, slipping the URI past the
                    // containsPercentEncodedControlBytes regex (which
                    // matches %00-%1F and %7F only); QuickLook / future
                    // chrome surfaces that render the raw stored bytes
                    // would honour U+202E (RIGHT-TO-LEFT OVERRIDE) and
                    // visually flip the URL the user reads. Rejecting
                    // here matches the OSC 7 posture rather than relying
                    // on every display-side consumer to scrub.
                    0
                } else if let Some(&id) = local_uri_to_id.get(uri) {
                    id
                } else if phase1_uris.len() + 1 >= u16::MAX as usize {
                    // Out of per-snapshot ids — drop attribution.
                    // 65 534 links per snapshot is already well past
                    // any realistic TUI; reaching the cap implies a
                    // hostile remote emitting unique per-cell URIs.
                    // Latch a one-shot breadcrumb (deferred until
                    // after the grid borrow ends) so support
                    // engineers triaging "my OSC 8 links stopped
                    // working" have a signal. Audit S2-014.
                    osc8_id_exhausted_this_snapshot = true;
                    0
                } else {
                    let id = (phase1_uris.len() + 1) as u16; // 1-based; 0 = no link
                    let owned: Arc<str> = Arc::from(uri);
                    local_uri_to_id.insert(Arc::clone(&owned), id);
                    phase1_uris.push(owned);
                    id
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
        // Emoji-presentation: a text-default base carrying a VS16 (U+FE0F)
        // renders as the colour emoji (base + VS16 grapheme), not the
        // monochrome base scalar. Width parity is already handled by the
        // alacritty Term::input promotion (WIDE_CHAR); this flag only
        // drives the renderer's colour / glyph selection.
        let mut flags = extract_cell_flags(indexed.flags);
        if let Some(zw) = indexed.cell.zerowidth() {
            if zw.contains(&'\u{FE0F}') {
                flags |= cell_flags::EMOJI_PRESENTATION;
            }
        }
        cells.push(BBCell {
            ch: indexed.c as u32,
            fg: color_to_rgb(&indexed.fg, palette),
            bg: color_to_rgb(&indexed.bg, palette),
            flags,
            link_id,
            underline_color,
        });
    }

    let cursor_point = grid.cursor.point;
    let cursor_pending_wrap = grid.cursor.input_needs_wrap;
    // cursor_point.line.0 is a 0-based screen row (Line wraps i32; visible rows are 0..rows-1).
    // cursor_point.column.0 is a 0-based column (Column wraps usize).
    let cursor_row = cursor_point.line.0.max(0) as u16;
    // column.0 is a usize; saturate at u16::MAX rather than truncating, so
    // the cast can never silently wrap to a small column. Symmetric with
    // the row's `.max(0)` clamp above and the display_offset/history_size
    // `.min(u32::MAX as usize)` clamps below. Bounded by MAX_DIM today, but
    // a defensive clamp keeps the snapshot's cursor honest unconditionally.
    // Audit S6-002.
    let cursor_col = cursor_point.column.0.min(u16::MAX as usize) as u16;
    // display_offset: lines scrolled above the live grid. When > 0 the
    // `cells` above are from scrollback; the live cursor at `cursor_row`
    // is actually `cursor_row + display_offset` from the top of the
    // visible viewport — and may be below it entirely.
    let display_offset = grid.display_offset().min(u32::MAX as usize) as u32;
    let history_size = grid.history_size().min(u32::MAX as usize) as u32;
    let lines_scrolled = bb.term.primary_lines_scrolled();
    // Drop the `grid`/`palette` borrows (and by extension the `&bb.term`
    // borrow) before we touch `bb.uri_cstr_cache` mutably below.
    let _ = grid;
    let _ = palette;
    // `local_uri_to_id` lives and dies with this snapshot.
    drop(local_uri_to_id);

    // Deferred S2-014 breadcrumb: if any cell hit the u16 link-id
    // ceiling during phase 1, log exactly once per BBTerm session.
    // Mutating bb here is sound because the grid borrow ended above.
    if osc8_id_exhausted_this_snapshot && !bb.osc8_id_exhaustion_logged {
        bb.osc8_id_exhaustion_logged = true;
        eprintln!(
            "[blackbird_core] OSC 8 link-id cap (u16) saturated for this snapshot — \
                 attribution silently dropped on cells past 65 534 distinct URIs. \
                 Symptom: 'links stopped working'. One-shot per session."
        );
    }

    // Phase 2: intern the URIs collected in phase 1 against the
    // persistent cache. Entries survive across snapshots
    // (rust-core-3 F1): the same URI appearing frame after frame is
    // an `Arc::clone` (one atomic increment, zero allocation) on
    // the second sighting. New URIs dropped silently once the
    // global byte footprint crosses `OSC8_TOTAL_INTERN_BYTES_CAP`
    // (1 MiB).
    //
    // `links` is empty when phase 1 collected zero URIs (the common
    // case). When non-empty, `links[0]` is the "no link" sentinel
    // so cell `link_id == 0` always means "no OSC 8 attribution"
    // and subsequent URIs get 1-based final indices (matching the
    // C ABI documented in `bb_snap_link_url`).
    let mut links: Vec<Arc<std::ffi::CStr>> = Vec::new();
    // `local_to_final[local_id]` = final id (or 0 if interning
    // failed for this URI). Built in lockstep with `phase1_uris`,
    // so `local_to_final[0]` is unused (local id 0 = no link).
    let mut local_to_final: Vec<u16> = Vec::new();
    if !phase1_uris.is_empty() {
        let sentinel: Arc<std::ffi::CStr> = std::ffi::CString::default().into();
        links.push(sentinel);
        local_to_final.push(0); // local 0 reserved for "no link"
        for uri in &phase1_uris {
            let uri_str: &str = uri.as_ref();
            let cstr_arc: Option<Arc<std::ffi::CStr>> = if let Some(existing) =
                bb.uri_cstr_cache.get(uri_str).cloned()
            {
                Some(existing)
            } else if bb.uri_cache_bytes.saturating_add(uri_str.len()) > OSC8_TOTAL_INTERN_BYTES_CAP
            {
                None
            } else {
                match std::ffi::CString::new(uri_str) {
                    Ok(cs) => {
                        let arc: Arc<std::ffi::CStr> = cs.into();
                        bb.uri_cstr_cache
                            .insert(uri_str.to_owned(), Arc::clone(&arc));
                        bb.uri_cache_bytes += uri_str.len();
                        Some(arc)
                    }
                    Err(_) => None,
                }
            };
            match cstr_arc {
                Some(arc) => {
                    let final_id = links.len() as u16;
                    links.push(arc);
                    local_to_final.push(final_id);
                }
                None => local_to_final.push(0),
            }
        }
        // Translate every cell's local id to its final id. Cells
        // with local id 0 stay 0 (no link). Cells whose URI failed
        // to intern (byte-cap exceeded, NUL in URI) get 0 too —
        // matching the previous shape's "drop attribution silently"
        // semantics.
        for cell in cells.iter_mut() {
            let local = cell.link_id as usize;
            if local != 0 && local < local_to_final.len() {
                cell.link_id = local_to_final[local];
            }
        }
    }
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
        cursor_pending_wrap,
        display_offset,
        history_size,
        lines_scrolled,
        mode,
        cursor_shape,
        cells,
        links,
        damaged_rows,
        damage_full,
    );
    // Expose the public `snap` field (first field at offset 0). Cast the
    // BBSnapOwned pointer rather than forming `&(*owned_ptr).snap`: snap is
    // the first `#[repr(C)]` field (identical address), but a `&BBSnap`
    // reference would narrow the Stacked/Tree Borrows tag to snap's extent
    // [0x0..size_of::<BBSnap>()), making the later `rc` access in
    // bb_snap_retain / bb_snap_release (a field PAST snap) an out-of-range
    // retag → UB. The pointer cast preserves provenance over the whole
    // allocation, so the rc field is legally reachable. (miri H-5 surface.)
    let owned_ptr = Box::into_raw(owned);
    owned_ptr as *const BBSnap
}
