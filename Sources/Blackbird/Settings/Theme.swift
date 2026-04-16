import Foundation

/// A full theme palette. Values are 0xRRGGBB; alpha is always opaque —
/// terminals don't composite window transparency beyond the solid bg.
public struct ThemePalette: Equatable, Sendable {
    public var background: UInt32
    public var foreground: UInt32
    public var cursor: UInt32
    /// 16 ANSI colors — 0..7 = normal, 8..15 = bright.
    public var ansi: [UInt32]

    public init(background: UInt32, foreground: UInt32, cursor: UInt32, ansi: [UInt32]) {
        precondition(ansi.count == 16, "ansi must have 16 entries")
        self.background = background
        self.foreground = foreground
        self.cursor = cursor
        self.ansi = ansi
    }
}

public enum Theme: String, CaseIterable, Identifiable, Sendable {
    case defaultTheme = "Default"
    case gruvbox      = "Gruvbox"
    case solarized    = "Solarized"
    case catppuccin   = "Catppuccin"

    public var id: String { rawValue }
    public var displayName: String { rawValue }

    public func palette(dark: Bool) -> ThemePalette {
        switch self {
        case .defaultTheme: return dark ? Self.defaultDark   : Self.defaultLight
        case .gruvbox:      return dark ? Self.gruvboxDark   : Self.gruvboxLight
        case .solarized:    return dark ? Self.solarizedDark : Self.solarizedLight
        case .catppuccin:   return dark ? Self.catppuccinDark: Self.catppuccinLight
        }
    }

    // DEFAULT — neutral high-contrast, tuned for general use.
    static let defaultDark = ThemePalette(
        background: 0x0E0E11, foreground: 0xE5E5EA, cursor: 0xFFFFFF,
        ansi: [
            0x1E1E22, 0xFF5555, 0x50FA7B, 0xF1FA8C,
            0xBD93F9, 0xFF79C6, 0x8BE9FD, 0xC7C7C7,
            0x595959, 0xFF6E6E, 0x69FF94, 0xFFFFA5,
            0xD6ACFF, 0xFF92DF, 0xA4FFFF, 0xFFFFFF
        ])
    static let defaultLight = ThemePalette(
        background: 0xFCFCFD, foreground: 0x24292E, cursor: 0x24292E,
        ansi: [
            0x24292E, 0xD73A49, 0x22863A, 0xB08800,
            0x005CC5, 0x6F42C1, 0x032F62, 0x6A737D,
            0x959DA5, 0xCB2431, 0x28A745, 0xDBAB09,
            0x2188FF, 0x8A63D2, 0x0A3069, 0x24292E
        ])

    // GRUVBOX — morhetz/gruvbox canonical.
    static let gruvboxDark = ThemePalette(
        background: 0x282828, foreground: 0xEBDBB2, cursor: 0xEBDBB2,
        ansi: [
            0x282828, 0xCC241D, 0x98971A, 0xD79921,
            0x458588, 0xB16286, 0x689D6A, 0xA89984,
            0x928374, 0xFB4934, 0xB8BB26, 0xFABD2F,
            0x83A598, 0xD3869B, 0x8EC07C, 0xEBDBB2
        ])
    static let gruvboxLight = ThemePalette(
        background: 0xFBF1C7, foreground: 0x3C3836, cursor: 0x3C3836,
        ansi: [
            0xFBF1C7, 0xCC241D, 0x98971A, 0xD79921,
            0x458588, 0xB16286, 0x689D6A, 0x7C6F64,
            0x928374, 0x9D0006, 0x79740E, 0xB57614,
            0x076678, 0x8F3F71, 0x427B58, 0x3C3836
        ])

    // SOLARIZED — Ethan Schoonover canonical.
    static let solarizedDark = ThemePalette(
        background: 0x002B36, foreground: 0x839496, cursor: 0x93A1A1,
        ansi: [
            0x073642, 0xDC322F, 0x859900, 0xB58900,
            0x268BD2, 0xD33682, 0x2AA198, 0xEEE8D5,
            0x002B36, 0xCB4B16, 0x586E75, 0x657B83,
            0x839496, 0x6C71C4, 0x93A1A1, 0xFDF6E3
        ])
    static let solarizedLight = ThemePalette(
        background: 0xFDF6E3, foreground: 0x657B83, cursor: 0x586E75,
        ansi: [
            0xEEE8D5, 0xDC322F, 0x859900, 0xB58900,
            0x268BD2, 0xD33682, 0x2AA198, 0x073642,
            0xFDF6E3, 0xCB4B16, 0x93A1A1, 0x839496,
            0x657B83, 0x6C71C4, 0x586E75, 0x002B36
        ])

    // CATPPUCCIN — Mocha (dark) and Latte (light).
    static let catppuccinDark = ThemePalette(
        background: 0x1E1E2E, foreground: 0xCDD6F4, cursor: 0xF5E0DC,
        ansi: [
            0x45475A, 0xF38BA8, 0xA6E3A1, 0xF9E2AF,
            0x89B4FA, 0xF5C2E7, 0x94E2D5, 0xBAC2DE,
            0x585B70, 0xF38BA8, 0xA6E3A1, 0xF9E2AF,
            0x89B4FA, 0xF5C2E7, 0x94E2D5, 0xA6ADC8
        ])
    static let catppuccinLight = ThemePalette(
        background: 0xEFF1F5, foreground: 0x4C4F69, cursor: 0xDC8A78,
        ansi: [
            0x5C5F77, 0xD20F39, 0x40A02B, 0xDF8E1D,
            0x1E66F5, 0xEA76CB, 0x179299, 0xACB0BE,
            0x6C6F85, 0xD20F39, 0x40A02B, 0xDF8E1D,
            0x1E66F5, 0xEA76CB, 0x179299, 0xBCC0CC
        ])
}
