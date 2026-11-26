import Foundation
import BBCore

/// Cell width of strings not yet in the grid (IME preedit). Per-scalar widths come from the core.
enum CellWidth {

    /// Each grapheme is the sum of its scalars' widths (a spacing vowel sign gets its own cell), except an
    /// emoji ZWJ sequence, which is one wide glyph and takes its widest scalar's width, as the grid does.
    static func terminalCellWidth(of string: String) -> Int {
        var total = 0
        for grapheme in string {
            var sum = 0
            var widest = 0
            var promotesToWide = false
            var isFirstScalar = true
            for scalar in grapheme.unicodeScalars {
                // An Emoji_Modifier after its base has grid width 0; one that starts the grapheme is a wide swatch.
                let isModifierOnBase = !isFirstScalar && Self.isEmojiModifier(scalar)
                let scalarWidth = isModifierOnBase ? 0 : width(for: scalar)
                isFirstScalar = false
                sum += scalarWidth
                widest = max(widest, scalarWidth)
                // VS-16 (U+FE0F), U+20E3 keycaps and a skin-tone modifier widen a narrow base to two cells.
                if scalar.value == 0xFE0F || scalar.value == 0x20E3 || isModifierOnBase {
                    promotesToWide = true
                }
            }
            var cells = isEmojiZWJSequence(grapheme) ? widest : sum
            if promotesToWide && cells < 2 {
                cells = 2
            }
            total += cells
        }
        return total
    }

    private static func isEmojiModifier(_ scalar: UnicodeScalar) -> Bool {
        (0x1F3FB...0x1F3FF).contains(scalar.value)
    }

    /// ASCII is skipped: `#`, `*` and the digits carry the Emoji property only as keycap bases.
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

    static func width(for scalar: UnicodeScalar) -> Int {
        Int(bb_scalar_cell_width(scalar.value))
    }
}
