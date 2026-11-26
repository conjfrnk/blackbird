//! Snapshot types crossing the C ABI. The repr(C) layouts are append-only with explicit padding.

use std::sync::atomic::AtomicUsize;
use std::sync::Arc;

use alacritty_terminal::grid::Dimensions;
use alacritty_terminal::term::cell::{Flags as CellFlags, Hyperlink};
use alacritty_terminal::term::TermMode;

use crate::color::color_to_rgb;
use crate::diag::breadcrumb;
use crate::scrub::contains_bidi_or_invisible;
use crate::{BBTerm, UriKey, UNDERLINE_COLOR_UNSET};

/// Flat cell layout; Swift reads these directly.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct BBCell {
    pub ch: u32, // Unicode scalar; 0 means empty
    pub fg: u32, // 0xRRGGBB
    pub bg: u32,
    pub flags: u16,
    /// Index into the snapshot's link table (0 = no OSC 8 link); resolve via `bb_snap_link_url`.
    pub link_id: u16,
    /// CSI 58 underline colour as `0x00RRGGBB`; `UNDERLINE_COLOR_UNSET` (0xFFFF_FFFF) means
    /// "follow fg". Ignored unless an underline-style bit is set in `flags`.
    pub underline_color: u32,
}

pub mod cell_flags {
    pub const BOLD: u16 = 1 << 0;
    pub const ITALIC: u16 = 1 << 1;
    pub const UNDERLINE: u16 = 1 << 2;
    pub const REVERSE: u16 = 1 << 3;
    pub const DIM: u16 = 1 << 4;
    pub const STRIKE: u16 = 1 << 5;
    /// Left half of a double-width glyph; the renderer draws it across two cell widths.
    pub const WIDE_CHAR: u16 = 1 << 6;
    /// Right half of a wide glyph — the renderer must not draw a glyph here.
    pub const WIDE_CHAR_SPACER: u16 = 1 << 7;
    /// Unused column left of a wide glyph that wrapped to the next row — don't draw.
    pub const LEADING_WIDE_CHAR_SPACER: u16 = 1 << 8;
    /// CSI 21 m. The underline style bits are mutually exclusive.
    pub const UNDERLINE_DOUBLE: u16 = 1 << 9;
    /// CSI 4:3 m.
    pub const UNDERCURL: u16 = 1 << 10;
    /// CSI 4:4 m.
    pub const UNDERLINE_DOTTED: u16 = 1 << 11;
    /// CSI 4:5 m.
    pub const UNDERLINE_DASHED: u16 = 1 << 12;
    /// The base glyph carries VS16 (U+FE0F): rasterise the colour emoji. Width is in WIDE_CHAR.
    pub const EMOJI_PRESENTATION: u16 = 1 << 13;
    /// The row ending in this cell soft-wrapped. Only ever set on a row's last cell; apps that
    /// lay rows out with cursor motion (tmux, TUIs) never set it.
    pub const WRAPLINE: u16 = 1 << 14;
    /// CSI 8 m. The cell keeps its real `ch` but the renderer must not draw the glyph. Not
    /// expressible as fg == bg: translucency, the selection tint and the block cursor reveal it.
    pub const HIDDEN: u16 = 1 << 15;
}

/// Stable mirror of alacritty's `TermMode`; the alacritty bits are not exposed directly.
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
    pub const DISAMBIGUATE_ESC_CODES: u32 = 1 << 11;
    pub const REPORT_EVENT_TYPES: u32 = 1 << 12;
    pub const REPORT_ALTERNATE_KEYS: u32 = 1 << 13;
    pub const REPORT_ALL_KEYS_AS_ESC: u32 = 1 << 14;
    pub const REPORT_ASSOCIATED_TEXT: u32 = 1 << 15;
    /// xterm `modifyOtherKeys` level ≥ 1 (`CSI > 4 ; 1 m` or `CSI > 4 ; 2 m`; cleared by
    /// `CSI > 4 ; 0 m`). Kitty flags, if any are set, take priority over it.
    pub const MODIFY_OTHER_KEYS: u32 = 1 << 16;
    /// DEC private mode 1007, set by default. While set on the alt screen with mouse reporting
    /// off, the wheel is translated into cursor-key presses.
    pub const ALTERNATE_SCROLL: u32 = 1 << 17;
    /// DEC private mode 1005 (UTF-8 mouse coordinates); SGR (1006) takes precedence.
    pub const UTF8_MOUSE: u32 = 1 << 18;
}

/// Immutable grid snapshot, ref-counted via `bb_snap_retain` / `bb_snap_release`; do not construct
/// or free it directly. `cells` is non-null and holds exactly `cells_len` cells for its lifetime.
#[repr(C)]
pub struct BBSnap {
    pub cols: u16,
    pub rows: u16,
    pub cursor_col: u16,
    pub cursor_row: u16,
    pub cursor_visible: u8,
    /// Explicit padding: cbindgen would not reflect implicit repr(C) padding in the header.
    pub _pad: [u8; 3],
    /// Lines the viewport is scrolled above the live grid; 0 means pinned to the bottom.
    pub display_offset: u32,
    pub mode: u32,
    pub cells_len: usize,
    pub cells: *const BBCell,
    /// Lines currently retained in scrollback; plateaus at the scrollback limit.
    pub history_size: u32,
    /// DECSCUSR cursor shape: 0 = block, 1 = bar/beam, 2 = underline, 3 = hidden.
    pub cursor_shape: u8,
    pub _pad2b: [u8; 3],
    /// Monotonic count of lines the primary screen pushed toward scrollback; never saturates, so
    /// content at counter P sits `(counter_now − P)` rows further up later. Any resize, or
    /// `history_size` shrinking (a clear), invalidates such anchors; viewport rows can drift.
    pub lines_scrolled: u64,
    /// 1 when the cursor is parked on the last written cell with a wrap pending: the logical
    /// cursor position is one character past `cursor_col`.
    pub cursor_pending_wrap: u8,
    pub _pad3: [u8; 7],
}

unsafe impl Send for BBSnap {}
// SAFETY: all fields are read-only after BBSnapOwned::new returns; cells aliases
// cells_owned's heap buffer which is never reallocated after construction.
unsafe impl Sync for BBSnap {}

#[derive(Default)]
pub(crate) struct ZeroWidthTable {
    /// `(cell index, range into scalars)`, ascending by cell index: `at` binary-searches it.
    runs: Vec<(usize, std::ops::Range<usize>)>,
    scalars: Vec<u32>,
}

impl ZeroWidthTable {
    pub(crate) fn push(&mut self, cell: usize, marks: &[char]) {
        if marks.is_empty() {
            return;
        }
        let start = self.scalars.len();
        self.scalars.extend(marks.iter().map(|&m| m as u32));
        self.runs.push((cell, start..self.scalars.len()));
    }

    pub(crate) fn at(&self, cell: usize) -> &[u32] {
        match self.runs.binary_search_by_key(&cell, |(c, _)| *c) {
            Ok(i) => &self.scalars[self.runs[i].1.clone()],
            Err(_) => &[],
        }
    }
}

/// `snap` must stay the first field: a `*const BBSnap` is cast back to `*const BBSnapOwned`.
#[repr(C)]
pub(crate) struct BBSnapOwned {
    pub(crate) snap: BBSnap,
    pub(crate) rc: AtomicUsize,
    pub(crate) cells_owned: Vec<BBCell>,
    /// Empty when the grid had no OSC 8 cells; else index 0 is a sentinel, N is `BBCell.link_id`.
    pub(crate) links: Vec<Arc<std::ffi::CStr>>,
    pub(crate) zerowidth: ZeroWidthTable,
    /// Empty when `damage_full == true` or when nothing changed.
    pub(crate) damaged_rows: Vec<u16>,
    pub(crate) damage_full: bool,
}

// SAFETY: see BBSnap's unsafe impl Send above; same reasoning applies.
unsafe impl Send for BBSnapOwned {}
// SAFETY: rc is AtomicUsize (Sync); snap and cells_owned are read-only after construction.
unsafe impl Sync for BBSnapOwned {}

impl BBSnapOwned {
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
        zerowidth: ZeroWidthTable,
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
            zerowidth,
            damaged_rows,
            damage_full,
        });
        owned.snap.cells = owned.cells_owned.as_ptr();
        owned
    }

    /// # Safety
    /// `snap` must point to the `snap` field of a live `BBSnapOwned` from `BBSnapOwned::new`.
    pub(crate) unsafe fn from_snap_ptr(snap: *const BBSnap) -> *mut BBSnapOwned {
        snap as *mut BBSnapOwned
    }
}

// Compile-time ABI layout guards for the cbindgen-generated header and the Swift bridge.
const _: () = {
    use std::mem::{offset_of, size_of};
    assert!(offset_of!(BBSnapOwned, snap) == 0);
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
    // Any further BBCell field needs a stride bump in CellInstance / Shaders.metal too.
    assert!(size_of::<BBCell>() == 20);
    assert!(offset_of!(BBCell, link_id) == 14);
    assert!(offset_of!(BBCell, underline_color) == 16);
};

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
    if f.contains(CellFlags::HIDDEN) {
        out |= cell_flags::HIDDEN;
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
    if f.contains(CellFlags::WRAPLINE) {
        out |= cell_flags::WRAPLINE;
    }
    out
}

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
    // Test each Kitty bit individually: `TermMode::KITTY_KEYBOARD_PROTOCOL` is a composite mask,
    // and `.contains()` on it would require all five bits to be set.
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
    if term_mode.contains(TermMode::ALTERNATE_SCROLL) {
        m |= bb_mode::ALTERNATE_SCROLL;
    }
    if term_mode.contains(TermMode::UTF8_MOUSE) {
        m |= bb_mode::UTF8_MOUSE;
    }
    m
}

pub(crate) fn extract_mode_with_extras(bb: &BBTerm) -> u32 {
    let mut m = extract_mode(bb.term.mode());
    if bb.osc_tap.modify_other_keys > 0 {
        m |= bb_mode::MODIFY_OTHER_KEYS;
    }
    m
}

/// Live-grid frame facts, read in O(1) without draining damage; fields match `BBSnap`'s. All-zero
/// (`cols == 0`) is the fallback for a null handle, a re-entrant call or a caught panic.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct BBGridState {
    pub lines_scrolled: u64,
    pub mode: u32,
    pub history_size: u32,
    pub cols: u16,
    pub rows: u16,
    pub _pad: [u8; 4],
}

pub(crate) fn grid_state(bb: &BBTerm) -> BBGridState {
    let grid = bb.term.grid();
    BBGridState {
        lines_scrolled: bb.term.primary_lines_scrolled(),
        mode: extract_mode_with_extras(bb),
        history_size: grid.history_size().min(u32::MAX as usize) as u32,
        cols: grid.columns() as u16,
        rows: grid.screen_lines() as u16,
        _pad: [0; 4],
    }
}

// Over the total cap new URIs drop to no-link: eviction would invalidate live snapshots' pointers.
const OSC8_URI_MAX: usize = 4096;
const OSC8_TOTAL_INTERN_BYTES_CAP: usize = 1024 * 1024;

/// Returns a per-snapshot local link id (1-based; 0 = no link).
fn resolve_link_id(
    uri: &str,
    phase1_uris: &mut Vec<Arc<str>>,
    local_uri_to_id: &mut std::collections::HashMap<Arc<str>, u16>,
    exhausted: &mut bool,
) -> u16 {
    if uri.is_empty() || uri.len() > OSC8_URI_MAX {
        return 0;
    }
    if let Some(&id) = local_uri_to_id.get(uri) {
        return id;
    }
    if contains_bidi_or_invisible(uri.as_bytes()) {
        return 0;
    }
    if phase1_uris.len() + 1 >= u16::MAX as usize {
        *exhausted = true;
        return 0;
    }
    let id = (phase1_uris.len() + 1) as u16;
    let owned: Arc<str> = Arc::from(uri);
    local_uri_to_id.insert(Arc::clone(&owned), id);
    phase1_uris.push(owned);
    id
}

fn intern_osc8_links(
    bb: &mut BBTerm,
    phase1_uris: &[Arc<str>],
    cells: &mut [BBCell],
) -> Vec<Arc<std::ffi::CStr>> {
    let mut links: Vec<Arc<std::ffi::CStr>> = Vec::new();
    let mut local_to_final: Vec<u16> = Vec::new();
    if phase1_uris.is_empty() {
        return links;
    }
    let sentinel: Arc<std::ffi::CStr> = std::ffi::CString::default().into();
    links.push(sentinel);
    local_to_final.push(0);
    for uri in phase1_uris {
        let uri_str: &str = uri.as_ref();
        let cstr_arc: Option<Arc<std::ffi::CStr>> = if let Some(existing) = bb
            .uri_cstr_cache
            .get(uri_str.as_bytes())
            .map(|k| Arc::clone(k.arc()))
        {
            Some(existing)
        } else if bb.uri_cache_bytes.saturating_add(uri_str.len()) > OSC8_TOTAL_INTERN_BYTES_CAP {
            if crate::osc::once(&mut bb.osc8_intern_cap_logged) {
                breadcrumb!(
                    "[blackbird_core] OSC 8 URI intern budget ({} bytes) exhausted — \
                     attribution silently dropped for every NEW hyperlink from now on. \
                     Symptom: 'links stopped working'. Cleared by ⌘K (bb_term_clear_all). \
                     One-shot per session.",
                    OSC8_TOTAL_INTERN_BYTES_CAP
                );
            }
            None
        } else {
            match std::ffi::CString::new(uri_str) {
                Ok(cs) => {
                    let arc: Arc<std::ffi::CStr> = cs.into();
                    bb.uri_cstr_cache.insert(UriKey::new(Arc::clone(&arc)));
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
    for cell in cells.iter_mut() {
        let local = cell.link_id as usize;
        if local != 0 && local < local_to_final.len() {
            cell.link_id = local_to_final[local];
        }
    }
    links
}

pub(crate) fn snapshot(bb: &mut BBTerm) -> *const BBSnap {
    // Drain damage before the grid read, then reset it so each snapshot reports deltas.
    use alacritty_terminal::term::TermDamage;
    let (damaged_rows, damage_full): (Vec<u16>, bool) = match bb.term.damage() {
        TermDamage::Full => (Vec::new(), true),
        TermDamage::Partial(iter) => (iter.map(|b| b.line as u16).collect(), false),
    };
    bb.term.reset_damage();

    let palette = bb.term.colors();
    let theme = &bb.theme_colors;
    let grid = bb.term.grid();

    let rows = grid.screen_lines() as u16;
    let cols = grid.columns() as u16;
    let mut cells: Vec<BBCell> = Vec::with_capacity(rows as usize * cols as usize);

    // OSC 8 interning is two-phase: local ids under the grid borrow, then the cache mutation.
    // Never `mem::take` the cache across the loop: a panic would leave it empty for good.
    let mut phase1_uris: Vec<Arc<str>> = Vec::new();
    let mut local_uri_to_id: std::collections::HashMap<Arc<str>, u16> =
        std::collections::HashMap::new();
    let mut osc8_id_exhausted_this_snapshot = false;
    // Adjacent cells of one OSC 8 run share an `Arc`, so the `==` below is a pointer compare.
    let mut last_link: Option<(Hyperlink, u16)> = None;
    let mut zerowidth = ZeroWidthTable::default();
    for indexed in grid.display_iter() {
        let link_id = match indexed.cell.hyperlink() {
            None => 0,
            Some(h) => match &last_link {
                Some((lh, id)) if *lh == h => *id,
                _ => {
                    let id = resolve_link_id(
                        h.uri(),
                        &mut phase1_uris,
                        &mut local_uri_to_id,
                        &mut osc8_id_exhausted_this_snapshot,
                    );
                    last_link = Some((h, id));
                    id
                }
            },
        };
        let underline_color = match indexed.cell.underline_color() {
            Some(c) => color_to_rgb(&c, palette, theme),
            None => UNDERLINE_COLOR_UNSET,
        };
        let mut flags = extract_cell_flags(indexed.flags);
        if let Some(zw) = indexed.cell.zerowidth() {
            if zw.contains(&'\u{FE0F}') {
                flags |= cell_flags::EMOJI_PRESENTATION;
            }
            zerowidth.push(cells.len(), zw);
        }
        cells.push(BBCell {
            ch: indexed.c as u32,
            fg: color_to_rgb(&indexed.fg, palette, theme),
            bg: color_to_rgb(&indexed.bg, palette, theme),
            flags,
            link_id,
            underline_color,
        });
    }

    let cursor_point = grid.cursor.point;
    let cursor_pending_wrap = grid.cursor.input_needs_wrap;
    let cursor_row = cursor_point.line.0.max(0) as u16;
    let cursor_col = cursor_point.column.0.min(u16::MAX as usize) as u16;
    let display_offset = grid.display_offset().min(u32::MAX as usize) as u32;
    let history_size = grid.history_size().min(u32::MAX as usize) as u32;
    let lines_scrolled = bb.term.primary_lines_scrolled();
    let _ = grid;
    let _ = palette;
    drop(local_uri_to_id);

    if osc8_id_exhausted_this_snapshot && crate::osc::once(&mut bb.osc8_id_exhaustion_logged) {
        breadcrumb!(
            "[blackbird_core] OSC 8 link-id cap (u16) saturated for this snapshot — \
                 attribution silently dropped on cells past 65 534 distinct URIs. \
                 Symptom: 'links stopped working'. One-shot per session."
        );
    }

    let links = intern_osc8_links(bb, &phase1_uris, &mut cells);
    let term_mode = bb.term.mode();
    let mode = extract_mode_with_extras(bb);
    let cursor_visible = term_mode.contains(TermMode::SHOW_CURSOR);
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
        zerowidth,
        damaged_rows,
        damage_full,
    );
    // Cast the owner pointer rather than forming `&(*owned_ptr).snap`: a `&BBSnap` narrows
    // provenance to `snap`, making the later `rc` access in bb_snap_retain / release UB.
    let owned_ptr = Box::into_raw(owned);
    owned_ptr as *const BBSnap
}
