import Foundation

/// Surfaces are 0xRRGGBB blends from the theme background toward the foreground, so no lighten/darken
/// direction is hardcoded.
public struct FindBarColorScheme: Equatable {
    public let barBackground: UInt32
    public let fieldBackground: UInt32
    public let text: UInt32
    public let separator: UInt32

    public init(palette: ThemePalette) {
        barBackground   = Self.blend(palette.background, palette.foreground, by: 0.07)
        fieldBackground = Self.blend(palette.background, palette.foreground, by: 0.13)
        text            = palette.foreground
        separator       = Self.blend(palette.background, palette.foreground, by: 0.15)
    }

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
