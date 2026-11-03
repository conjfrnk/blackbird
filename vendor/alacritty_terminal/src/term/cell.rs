use std::hash::{Hash, Hasher};
use std::sync::Arc;
use std::sync::atomic::{AtomicU32, AtomicUsize, Ordering};

use bitflags::bitflags;
#[cfg(feature = "serde")]
use serde::{Deserialize, Serialize};

use crate::grid::{self, GridCell};
use crate::index::Column;
use crate::vte::ansi::{Color, Hyperlink as VteHyperlink, NamedColor};

bitflags! {
    #[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
    #[cfg_attr(feature = "serde", derive(Serialize, Deserialize))]
    pub struct Flags: u16 {
        const INVERSE                   = 0b0000_0000_0000_0001;
        const BOLD                      = 0b0000_0000_0000_0010;
        const ITALIC                    = 0b0000_0000_0000_0100;
        const BOLD_ITALIC               = 0b0000_0000_0000_0110;
        const UNDERLINE                 = 0b0000_0000_0000_1000;
        const WRAPLINE                  = 0b0000_0000_0001_0000;
        const WIDE_CHAR                 = 0b0000_0000_0010_0000;
        const WIDE_CHAR_SPACER          = 0b0000_0000_0100_0000;
        const DIM                       = 0b0000_0000_1000_0000;
        const DIM_BOLD                  = 0b0000_0000_1000_0010;
        const HIDDEN                    = 0b0000_0001_0000_0000;
        const STRIKEOUT                 = 0b0000_0010_0000_0000;
        const LEADING_WIDE_CHAR_SPACER  = 0b0000_0100_0000_0000;
        const DOUBLE_UNDERLINE          = 0b0000_1000_0000_0000;
        const UNDERCURL                 = 0b0001_0000_0000_0000;
        const DOTTED_UNDERLINE          = 0b0010_0000_0000_0000;
        const DASHED_UNDERLINE          = 0b0100_0000_0000_0000;
        const ALL_UNDERLINES            = Self::UNDERLINE.bits() | Self::DOUBLE_UNDERLINE.bits()
                                        | Self::UNDERCURL.bits() | Self::DOTTED_UNDERLINE.bits()
                                        | Self::DASHED_UNDERLINE.bits();
    }
}

/// Counter for hyperlinks without explicit ID.
static HYPERLINK_ID_SUFFIX: AtomicU32 = AtomicU32::new(0);

/// Max zero-width scalars kept on one cell.
///
/// Blackbird fix (re-apply on bump): see `Cell::push_zerowidth`, which enforces it.
pub(crate) const ZEROWIDTH_MAX: usize = 32;

/// Max bytes of URI kept for one hyperlink. Matches `OSC8_URI_MAX` in blackbird_core's
/// snapshot, which never surfaces a longer one as a link.
const HYPERLINK_URI_MAX: usize = 4096;

/// Max bytes of `id=` kept for one hyperlink; a longer id is cut to this, not refused.
const HYPERLINK_ID_MAX: usize = 256;

/// Max bytes of hyperlink data one terminal keeps alive across grid and scrollback.
///
/// Blackbird fix (re-apply on bump): see `Hyperlink::bounded`, which enforces it.
pub(crate) const HYPERLINK_LIVE_MAX: usize = 32 * 1024 * 1024;

/// Bookkeeping charged per hyperlink on top of its strings (Arc header, two `String` headers,
/// allocator rounding), so links with tiny URIs cannot slip under `HYPERLINK_LIVE_MAX`.
const HYPERLINK_FIXED_COST: usize = 128;

/// Why `Hyperlink::bounded` refused a link. The two are told apart because only `OverBudget`
/// persists: one over-long URI is a single bad sequence, but past the budget every later link
/// is refused too, which is the "links stopped working" report the caller leaves a breadcrumb for.
pub(crate) enum HyperlinkRefused {
    TooLong,
    OverBudget,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
#[cfg_attr(feature = "serde", derive(Serialize, Deserialize))]
pub struct Hyperlink {
    inner: Arc<HyperlinkInner>,
}

impl Hyperlink {
    pub fn new<T: ToString>(id: Option<T>, uri: String) -> Self {
        let inner = Arc::new(HyperlinkInner::new(id, uri));
        Self { inner }
    }

    pub fn id(&self) -> &str {
        &self.inner.id
    }

    pub fn uri(&self) -> &str {
        &self.inner.uri
    }

    /// Build a link charged against `live`, or say why it must not be kept (no link).
    ///
    /// Blackbird fix (re-apply on bump): upstream stores whatever OSC 8 delivers (vte allows
    /// 8 MiB for the URI and for `id=`), and every cell written under the link shares that one
    /// allocation, so each row pinned its own full-size copy until it left the scrollback and
    /// retention tracked the bytes sent, 1:1. A URI past its cap is refused, and so is any
    /// link that would take `live` (the terminal's running total, released as links drop) past
    /// `limit`, `HYPERLINK_LIVE_MAX` unless the terminal was configured otherwise; the latter
    /// also covers many distinct links just under the caps. An id past its cap is cut instead:
    /// nothing in this crate reads it, so dropping the link for it would lose a usable link.
    pub(crate) fn bounded(
        link: VteHyperlink,
        live: &Arc<AtomicUsize>,
        limit: usize,
    ) -> Result<Self, HyperlinkRefused> {
        let VteHyperlink { id, uri } = link;
        if uri.len() > HYPERLINK_URI_MAX {
            return Err(HyperlinkRefused::TooLong);
        }
        // Cut in place: `HyperlinkInner::new` copies the id (`to_string`), and the cost charged
        // below is that copy's capacity, so the oversized original is neither kept nor billed.
        let id = id.map(|mut id| {
            if id.len() > HYPERLINK_ID_MAX {
                let mut cut = HYPERLINK_ID_MAX;
                while !id.is_char_boundary(cut) {
                    cut -= 1;
                }
                id.truncate(cut);
            }
            id
        });

        let mut inner = HyperlinkInner::new(id, uri);
        let cost = inner.cost();
        if live.load(Ordering::Relaxed) + cost > limit {
            return Err(HyperlinkRefused::OverBudget);
        }
        live.fetch_add(cost, Ordering::Relaxed);
        inner.live = Some((Arc::clone(live), cost));

        Ok(Self { inner: Arc::new(inner) })
    }
}

impl From<VteHyperlink> for Hyperlink {
    fn from(value: VteHyperlink) -> Self {
        Self::new(value.id, value.uri)
    }
}

impl From<Hyperlink> for VteHyperlink {
    fn from(val: Hyperlink) -> Self {
        VteHyperlink { id: Some(val.id().to_owned()), uri: val.uri().to_owned() }
    }
}

/// Blackbird fix (re-apply on bump): `live` charges the link to the terminal's hyperlink byte
/// budget (see `Hyperlink::bounded`), so `PartialEq`/`Eq`/`Hash` are written by hand over
/// `(id, uri)` instead of derived, and `Drop` credits the budget back.
#[derive(Debug)]
#[cfg_attr(feature = "serde", derive(Serialize, Deserialize))]
struct HyperlinkInner {
    /// Identifier for the given hyperlink.
    id: String,

    /// Resource identifier of the hyperlink.
    uri: String,

    /// Terminal-wide byte total this link is charged to, and the bytes charged, credited back
    /// on drop.
    #[cfg_attr(feature = "serde", serde(skip))]
    live: Option<(Arc<AtomicUsize>, usize)>,
}

// Identity is `(id, uri)`; the accounting handle is not part of it.
impl PartialEq for HyperlinkInner {
    fn eq(&self, other: &Self) -> bool {
        self.id == other.id && self.uri == other.uri
    }
}

impl Eq for HyperlinkInner {}

impl Hash for HyperlinkInner {
    fn hash<H: Hasher>(&self, state: &mut H) {
        self.id.hash(state);
        self.uri.hash(state);
    }
}

impl Drop for HyperlinkInner {
    fn drop(&mut self) {
        if let Some((live, charged)) = &self.live {
            live.fetch_sub(*charged, Ordering::Relaxed);
        }
    }
}

impl HyperlinkInner {
    pub fn new<T: ToString>(id: Option<T>, uri: String) -> Self {
        let id = match id {
            Some(id) => id.to_string(),
            None => {
                let mut id = HYPERLINK_ID_SUFFIX.fetch_add(1, Ordering::Relaxed).to_string();
                id.push_str("_alacritty");
                id
            },
        };

        Self { id, uri, live: None }
    }

    /// Bytes charged against the terminal's hyperlink budget.
    ///
    /// Capacity, not length: vte rebuilds a URI containing `;` with `push`/`push_str`, which
    /// leaves the `String` holding up to twice the bytes it uses, and the allocation is what
    /// stays resident.
    fn cost(&self) -> usize {
        HYPERLINK_FIXED_COST + self.id.capacity() + self.uri.capacity()
    }
}

/// Trait for determining if a reset should be performed.
pub trait ResetDiscriminant<T> {
    /// Value based on which equality for the reset will be determined.
    fn discriminant(&self) -> T;
}

impl<T: Copy> ResetDiscriminant<T> for T {
    fn discriminant(&self) -> T {
        *self
    }
}

impl ResetDiscriminant<Color> for Cell {
    fn discriminant(&self) -> Color {
        self.bg
    }
}

/// Dynamically allocated cell content.
///
/// This storage is reserved for cell attributes which are rarely set. This allows reducing the
/// allocation required ahead of time for every cell, with some additional overhead when the extra
/// storage is actually required.
#[derive(Default, Debug, Clone, Eq, PartialEq)]
#[cfg_attr(feature = "serde", derive(Serialize, Deserialize))]
pub struct CellExtra {
    zerowidth: Vec<char>,
    underline_color: Option<Color>,
    hyperlink: Option<Hyperlink>,
}

/// Content and attributes of a single cell in the terminal grid.
#[derive(Clone, Debug, Eq, PartialEq)]
#[cfg_attr(feature = "serde", derive(Serialize, Deserialize))]
pub struct Cell {
    pub c: char,
    pub fg: Color,
    pub bg: Color,
    pub flags: Flags,
    pub extra: Option<Arc<CellExtra>>,
}

impl Default for Cell {
    #[inline]
    fn default() -> Cell {
        Cell {
            c: ' ',
            bg: Color::Named(NamedColor::Background),
            fg: Color::Named(NamedColor::Foreground),
            flags: Flags::empty(),
            extra: None,
        }
    }
}

impl Cell {
    /// Zerowidth characters stored in this cell.
    #[inline]
    pub fn zerowidth(&self) -> Option<&[char]> {
        self.extra.as_ref().map(|extra| extra.zerowidth.as_slice())
    }

    /// Write a new zerowidth character to this cell.
    ///
    /// Blackbird fix (re-apply on bump): upstream appends without limit, and a zero-width
    /// scalar never advances the cursor, so `CSI 65535 b` (REP) after one combining mark
    /// piled 65,535 scalars (~256 KiB) onto a single cell per 8 input bytes. Scalars past
    /// `ZEROWIDTH_MAX` are dropped; real grapheme clusters (ZWJ families, stacked marks) use
    /// a handful, so only hostile input is truncated.
    #[inline]
    pub fn push_zerowidth(&mut self, character: char) {
        if self.extra.as_ref().is_some_and(|extra| extra.zerowidth.len() >= ZEROWIDTH_MAX) {
            return;
        }
        let extra = self.extra.get_or_insert(Default::default());
        Arc::make_mut(extra).zerowidth.push(character);
    }

    /// Remove all wide char data from a cell.
    #[inline(never)]
    pub fn clear_wide(&mut self) {
        self.flags.remove(Flags::WIDE_CHAR);
        if let Some(extra) = self.extra.as_mut() {
            Arc::make_mut(extra).zerowidth = Vec::new();
        }
        self.c = ' ';
    }

    /// Set underline color on the cell.
    pub fn set_underline_color(&mut self, color: Option<Color>) {
        // If we reset color and we don't have zerowidth we should drop extra storage.
        if color.is_none()
            && self
                .extra
                .as_ref()
                .is_none_or(|extra| extra.zerowidth.is_empty() && extra.hyperlink.is_none())
        {
            self.extra = None;
        } else {
            let extra = self.extra.get_or_insert(Default::default());
            Arc::make_mut(extra).underline_color = color;
        }
    }

    /// Underline color stored in this cell.
    #[inline]
    pub fn underline_color(&self) -> Option<Color> {
        self.extra.as_ref()?.underline_color
    }

    /// Set hyperlink.
    pub fn set_hyperlink(&mut self, hyperlink: Option<Hyperlink>) {
        let should_drop = hyperlink.is_none()
            && self
                .extra
                .as_ref()
                .is_none_or(|extra| extra.zerowidth.is_empty() && extra.underline_color.is_none());

        if should_drop {
            self.extra = None;
        } else {
            let extra = self.extra.get_or_insert(Default::default());
            Arc::make_mut(extra).hyperlink = hyperlink;
        }
    }

    /// Hyperlink stored in this cell.
    #[inline]
    pub fn hyperlink(&self) -> Option<Hyperlink> {
        self.extra.as_ref()?.hyperlink.clone()
    }
}

impl GridCell for Cell {
    #[inline]
    fn is_empty(&self) -> bool {
        (self.c == ' ' || self.c == '\t')
            && self.bg == Color::Named(NamedColor::Background)
            && self.fg == Color::Named(NamedColor::Foreground)
            && !self.flags.intersects(
                Flags::INVERSE
                    | Flags::ALL_UNDERLINES
                    | Flags::STRIKEOUT
                    | Flags::WRAPLINE
                    | Flags::WIDE_CHAR_SPACER
                    | Flags::LEADING_WIDE_CHAR_SPACER,
            )
            && self.extra.as_ref().map(|extra| extra.zerowidth.is_empty()) != Some(false)
    }

    #[inline]
    fn flags(&self) -> &Flags {
        &self.flags
    }

    #[inline]
    fn flags_mut(&mut self) -> &mut Flags {
        &mut self.flags
    }

    #[inline]
    fn reset(&mut self, template: &Self) {
        *self = Cell { bg: template.bg, ..Cell::default() };
    }
}

impl From<Color> for Cell {
    #[inline]
    fn from(color: Color) -> Self {
        Self { bg: color, ..Cell::default() }
    }
}

/// Get the length of occupied cells in a line.
pub trait LineLength {
    /// Calculate the occupied line length.
    fn line_length(&self) -> Column;
}

impl LineLength for grid::Row<Cell> {
    fn line_length(&self) -> Column {
        let mut length = Column(0);

        if self[Column(self.len() - 1)].flags.contains(Flags::WRAPLINE) {
            return Column(self.len());
        }

        for (index, cell) in self[..].iter().rev().enumerate() {
            if cell.c != ' '
                || cell.extra.as_ref().map(|extra| extra.zerowidth.is_empty()) == Some(false)
            {
                length = Column(self.len() - index);
                break;
            }
        }

        length
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    use std::mem;

    use crate::grid::Row;
    use crate::index::Column;

    #[test]
    fn cell_size_is_below_cap() {
        // Expected cell size on 64-bit architectures.
        const EXPECTED_CELL_SIZE: usize = 24;

        // Ensure that cell size isn't growing by accident.
        assert!(mem::size_of::<Cell>() <= EXPECTED_CELL_SIZE);
    }

    #[test]
    fn line_length_works() {
        let mut row = Row::<Cell>::new(10);
        row[Column(5)].c = 'a';

        assert_eq!(row.line_length(), Column(6));
    }

    #[test]
    fn line_length_works_with_wrapline() {
        let mut row = Row::<Cell>::new(10);
        row[Column(9)].flags.insert(super::Flags::WRAPLINE);

        assert_eq!(row.line_length(), Column(10));
    }
}
