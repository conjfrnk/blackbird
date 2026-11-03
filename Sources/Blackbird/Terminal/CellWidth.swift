import Foundation
import BBCore

/// Swift-side terminal-cell width model for *strings that aren't in the grid yet*.
///
/// The IME preedit overlay needs to size and anchor composing text BEFORE any of
/// it has been committed to the PTY or laid into the grid, so it can't ask the
/// grid; this walks the string itself. What a single scalar occupies is NOT
/// decided here: `width(for:)` reads the core's own per-scalar width
/// (`bb_scalar_cell_width`, the lookup `Term::input` sizes each printed char
/// with), so the preedit and the committed text cannot disagree about a symbol,
/// emoji or mark. (A hand-written Swift range list once did, for ~15k scalars:
/// `⭐` `✅` `✨` counted 1 cell where the grid gives 2, text-default pictographs
/// like `🌡` counted 2 where the grid gives 1.) The string-level policy below is
/// all that lives on the Swift side.
///
/// Keeping it in its own named, unit-tested namespace (rather than inlined inside
/// the `+IME` extension, where it was graded a parallel-width-model smell) means
/// the contract is pinned by `CellWidthTests` and the divergence is documented
/// instead of hidden. The model is intentionally approximate — exact glyph
/// metrics would need a CoreText pass per composition update, which is too slow
/// for per-keystroke preedit refreshes — and is only ever used to place the IME
/// candidate popover, never to decide what the grid actually draws.
///
/// History: an earlier per-scalar `.max()` form of this model counted an
/// emoji-presentation grapheme such as `⚠️` (base + VS16) as 1 cell, anchoring
/// the IME caret one cell off where the grid renders it (the "IME caret width
/// model divergence" called out in the `+IME` call-site comments). The
/// grapheme-walking form below — with the VS16 / U+20E3 keycap promotion — is
/// what keeps the overlay aligned with the grid.
enum CellWidth {

    /// Approximate terminal-cell width of a string, as the grid will lay it out
    /// once committed: each grapheme cluster is the sum of its scalars' cell
    /// widths (a combining mark or variation selector contributes 0; a spacing
    /// vowel sign such as Devanagari `ि` or Thai `ำ` gets its own cell, which
    /// is why a `Character` is not one cell). Good enough for preedit overlay
    /// sizing; exact glyph metrics would require a CoreText pass per
    /// composition update which is too slow for per-keystroke refreshes.
    ///
    /// Walks `Character` (grapheme clusters) rather than the flat scalar stream
    /// so it can keep one deliberate deviation from the grid, and only for
    /// EMOJI ZWJ sequences: 👨‍👩‍👧 (or 👩🏽‍💻, with a skin-tone modifier the grid
    /// also gives 2 cells) is one grapheme that renders as one wide glyph, so it
    /// counts 2 cells, the widest scalar's width, not the 2+0+2+0+2=6 the grid
    /// lays out. A ZWJ in any other script (a Devanagari `क्‍ष` conjunct) is not
    /// a one-glyph emoji sequence, so those graphemes keep the plain per-scalar
    /// sum the grid uses.
    static func terminalCellWidth(of string: String) -> Int {
        var total = 0
        for grapheme in string {
            var sum = 0
            var widest = 0
            var promotesToWide = false
            for scalar in grapheme.unicodeScalars {
                let scalarWidth = width(for: scalar)
                sum += scalarWidth
                widest = max(widest, scalarWidth)
                // VS-16 (U+FE0F) forces the preceding base into emoji
                // presentation, and U+20E3 builds keycap sequences
                // (`#️⃣`, `1️⃣`). Neither base scalar is wide on its own
                // (U+2764, U+0023, …) but the rendered grapheme occupies
                // two cells. Don't let the per-scalar widths miss them.
                if scalar.value == 0xFE0F || scalar.value == 0x20E3 {
                    promotesToWide = true
                }
            }
            var cells = isEmojiZWJSequence(grapheme) ? widest : sum
            if promotesToWide && cells < 2 {
                cells = 2
            }
            // A grapheme that's purely zero-width (e.g. an isolated
            // combining mark) still occupies no cells.
            total += cells
        }
        return total
    }

    /// True when `grapheme` joins an emoji with a ZWJ (U+200D): such a sequence
    /// is drawn as ONE glyph. The emoji check is what keeps ZWJ conjuncts in
    /// other scripts (Devanagari `क्‍ष`), which the grid lays out scalar by
    /// scalar, out of the collapse. ASCII is skipped because `#`, `*` and the
    /// digits carry the Emoji property only as keycap bases.
    private static func isEmojiZWJSequence(_ grapheme: Character) -> Bool {
        var hasZWJ = false
        var hasEmoji = false
        for scalar in grapheme.unicodeScalars {
            if scalar.value == 0x200D {
                hasZWJ = true
            } else if scalar.value > 0x7F && scalar.properties.isEmoji {
                hasEmoji = true
            }
        }
        return hasZWJ && hasEmoji
    }

    /// Cells the core's grid gives a single printed scalar: 0 (combining marks,
    /// ZWJ, variation selectors, controls), 1, or 2 (East Asian Wide /
    /// Emoji_Presentation).
    static func width(for scalar: UnicodeScalar) -> Int {
        Int(bb_scalar_cell_width(scalar.value))
    }
}
