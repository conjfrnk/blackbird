import Foundation

/// Swift-side terminal-cell width model for *strings that aren't in the grid yet*.
///
/// This is a deliberate, isolated parallel to the Rust core's width logic — not
/// an accidental duplicate. The core resolves width during VT parsing and only
/// ever exposes it as an already-applied, per-cell `WIDE_CHAR` flag on cells
/// that are physically in the grid; there is no `string -> width` entry point on
/// the FFI surface (`Sources/BBCore`). The IME preedit overlay needs to size and
/// anchor composing text BEFORE any of it has been committed to the PTY or laid
/// into the grid, so it can't ask the core. Hence a self-contained string→width
/// model lives here on the Swift side.
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

    /// Approximate terminal-cell width of a string. Each grapheme cluster
    /// contributes 1 cell for ASCII/Latin/Cyrillic, 2 cells for CJK
    /// ideographs and wide emoji, 0 cells for combining marks or
    /// zero-width joiners. Good enough for preedit overlay sizing;
    /// exact glyph metrics would require a CoreText pass per composition
    /// update which is too slow for per-keystroke refreshes.
    ///
    /// Walks `Character` (grapheme clusters), not `UnicodeScalar` — a ZWJ
    /// sequence like 👨‍👩‍👧 is one grapheme that renders as one wide
    /// glyph, so it must count as 2 cells, not 2+0+2+0+2=6. Per-grapheme
    /// we take the max scalar width (ignoring ZWJ / VS / combiners which
    /// would otherwise mask the real width-contributing scalar).
    static func terminalCellWidth(of string: String) -> Int {
        var total = 0
        for grapheme in string {
            var widest = 0
            var promotesToWide = false
            for scalar in grapheme.unicodeScalars {
                widest = max(widest, width(for: scalar))
                // VS-16 (U+FE0F) forces the preceding base into emoji
                // presentation, and U+20E3 builds keycap sequences
                // (`#️⃣`, `1️⃣`). Neither base scalar is in our wide
                // ranges (U+2764, U+0023, …) but the rendered grapheme
                // occupies two cells. Don't let the per-scalar table
                // miss them.
                if scalar.value == 0xFE0F || scalar.value == 0x20E3 {
                    promotesToWide = true
                }
            }
            if promotesToWide && widest < 2 {
                widest = 2
            }
            // A grapheme that's purely zero-width (e.g. an isolated
            // combining mark) still occupies no cells.
            total += widest
        }
        return total
    }

    /// Rough cell-width classification for a single scalar. Based on
    /// Unicode's East Asian Width property plus the emoji / symbol
    /// ranges that terminal emulators conventionally treat as wide.
    static func width(for scalar: UnicodeScalar) -> Int {
        let v = scalar.value
        // Combining marks / zero-width joiners / VS16 etc. → 0 cells.
        if (0x0300...0x036F).contains(v)   // Combining Diacriticals
            || (0x200B...0x200F).contains(v) // ZW* + bidi marks
            || (0xFE00...0xFE0F).contains(v) // Variation Selectors 1-16
            || v == 0x200D                   // ZWJ
            || (0xFE20...0xFE2F).contains(v) // Combining Half Marks
        {
            return 0
        }
        // Common wide ranges. Covers the cases users actually hit at
        // Blackbird's prompt: CJK ideographs, Hangul syllables,
        // fullwidth forms, wide emoji.
        if (0x1100...0x115F).contains(v)    // Hangul Jamo
            || (0x2E80...0x303E).contains(v) // CJK Radicals + Kangxi
            || (0x3041...0x33FF).contains(v) // Hiragana + Katakana + CJK Symbols
            || (0x3400...0x4DBF).contains(v) // CJK Ext A
            || (0x4E00...0x9FFF).contains(v) // CJK Unified Ideographs
            || (0xA000...0xA4CF).contains(v) // Yi
            || (0xAC00...0xD7A3).contains(v) // Hangul Syllables
            || (0xF900...0xFAFF).contains(v) // CJK Compatibility Ideographs
            || (0xFE30...0xFE4F).contains(v) // CJK Compatibility Forms
            || (0xFF00...0xFF60).contains(v) // Fullwidth Forms
            || (0xFFE0...0xFFE6).contains(v) // Fullwidth signs
            || (0x1F300...0x1F9FF).contains(v) // Misc symbols + emoji
            || (0x20000...0x2FFFD).contains(v) // CJK Ext B/C/D/E
            || (0x30000...0x3FFFD).contains(v) // CJK Ext G
        {
            return 2
        }
        return 1
    }
}
