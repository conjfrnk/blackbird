import Foundation

/// Pure derivation of the find bar's chrome colors from a `ThemePalette`.
///
/// The find bar used to be the one piece of chrome styled with generic
/// system colors (`windowBackgroundColor` + bezeled fields) while the
/// terminal body, titlebar, and window background all paint the exact
/// theme RGB — so it read as a foreign macOS gray panel floating over
/// every non-default theme. Deriving its surfaces from the palette the
/// same way the rest of the chrome does makes it part of the themed
/// surface.
///
/// Surfaces are blends from the theme background *toward* the foreground:
/// a small step reads as "elevated panel on the terminal background" in
/// both light and dark palettes without hardcoding a lighten/darken
/// direction. Kept as a value type with the blend math public + pure so
/// the exact colors are unit-testable without AppKit.
public struct FindBarColorScheme: Equatable {
    /// Bar surface — `blend(bg → fg, 0.07)`, one visible step off the
    /// terminal background.
    public let barBackground: UInt32
    /// Text-field fill — `blend(bg → fg, 0.13)`, a second step so the
    /// editable wells read against the bar.
    public let fieldBackground: UInt32
    /// Field text, button glyphs — the palette foreground verbatim.
    /// Muted uses (match counter, placeholder) apply an alpha at the
    /// consumption site rather than storing a third RGB here.
    public let text: UInt32
    /// Bottom hairline separating the bar from the terminal content —
    /// `blend(bg → fg, 0.15)`.
    public let separator: UInt32

    public init(palette: ThemePalette) {
        barBackground   = Self.blend(palette.background, palette.foreground, by: 0.07)
        fieldBackground = Self.blend(palette.background, palette.foreground, by: 0.13)
        text            = palette.foreground
        separator       = Self.blend(palette.background, palette.foreground, by: 0.15)
    }

    /// Linear per-8-bit-channel blend from `from` toward `to` by
    /// `t ∈ [0, 1]`: `round(from_c + (to_c - from_c) * t)` for each of the
    /// R, G, B channels of a 0xRRGGBB value. `t` outside [0, 1] is clamped
    /// so a bad call site can't produce out-of-range channels.
    public static func blend(_ from: UInt32, _ to: UInt32, by t: Double) -> UInt32 {
        let t = min(max(t, 0), 1)
        func channel(_ shift: UInt32) -> UInt32 {
            let f = Double((from >> shift) & 0xFF)
            let g = Double((to   >> shift) & 0xFF)
            return UInt32((f + (g - f) * t).rounded()) & 0xFF
        }
        return channel(16) << 16 | channel(8) << 8 | channel(0)
    }
}
