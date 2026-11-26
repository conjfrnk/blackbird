import Foundation
import os

/// Values are 0xRRGGBB, always opaque.
public struct ThemePalette: Equatable, Sendable {
    public var background: UInt32
    public var foreground: UInt32
    public var cursor: UInt32
    /// 16 ANSI colors: 0..7 normal, 8..15 bright.
    public var ansi: [UInt32]

    private static let themeLogger = Logger(subsystem: "dev.conjfrnk.blackbird", category: "theme")

    private static let minCursorContrast: Double = 1.25
    private static let minForegroundContrast: Double = 3.0
    private static let darkLuminanceThreshold: Double = 0.18

    public var selection: UInt32 {
        let blue = ansi.count > 12 ? ansi[12] : 0x4080FF
        let candidate = Self.mix(blue, background, towardSecond: 0.45)
        if Self.contrastRatio(fg: candidate, bg: background) < 1.3 {
            return Self.mix(foreground, background, towardSecond: 0.6)
        }
        return candidate
    }

    public var selectionForeground: UInt32 { background }

    static func mix(_ a: UInt32, _ b: UInt32, towardSecond t: Double) -> UInt32 {
        let t = min(1, max(0, t))
        func ch(_ shift: UInt32) -> UInt32 {
            let ca = Double((a >> shift) & 0xFF)
            let cb = Double((b >> shift) & 0xFF)
            return UInt32((ca + (cb - ca) * t).rounded()) & 0xFF
        }
        return (ch(16) << 16) | (ch(8) << 8) | ch(0)
    }

    public init(background: UInt32, foreground: UInt32, cursor: UInt32, ansi: [UInt32]) {
        // Downstream (renderer, color_to_rgb) indexes ansi[0..<16]: normalise to exactly 16 entries rather
        // than abort on a malformed theme.
        let normalizedAnsi: [UInt32]
        if ansi.count == 16 {
            normalizedAnsi = ansi
        } else {
            Self.themeLogger.warning(
                "Theme palette ANSI array has \(ansi.count, privacy: .public) entries, expected 16 — normalising to 16 (was a process-aborting precondition before audit S6-003)"
            )
            if ansi.count > 16 {
                normalizedAnsi = Array(ansi.prefix(16))
            } else {
                normalizedAnsi = ansi + Array(repeating: foreground, count: 16 - ansi.count)
            }
        }
        self.background = background
        self.foreground = foreground
        let cursorBg = Self.contrastRatio(fg: cursor, bg: background)
        if cursorBg < Self.minCursorContrast {
            Self.themeLogger.warning(
                "Theme palette cursor/background contrast \(cursorBg, format: .fixed(precision: 2)) < 1.25 — snapping cursor to foreground (was 0x\(String(cursor, radix: 16), privacy: .public), now 0x\(String(foreground, radix: 16), privacy: .public))"
            )
            self.cursor = foreground
        } else {
            self.cursor = cursor
        }
        self.ansi = normalizedAnsi
        #if DEBUG
        let fgBg = Self.contrastRatio(fg: foreground, bg: background)
        assert(fgBg >= Self.minForegroundContrast,
               "Theme palette foreground/background contrast \(fgBg) < 3:1")
        assert(cursorBg >= Self.minCursorContrast,
               "Theme palette cursor/background contrast \(cursorBg) < 1.25:1 — cursor is invisible")
        #endif
    }

    // MARK: - Contrast helpers

    /// WCAG 2.x relative luminance of a 0xRRGGBB color, in `[0, 1]`.
    public static func relativeLuminance(_ rgb: UInt32) -> Double {
        let r = Double((rgb >> 16) & 0xFF) / 255.0
        let g = Double((rgb >>  8) & 0xFF) / 255.0
        let b = Double( rgb        & 0xFF) / 255.0
        func lin(_ c: Double) -> Double {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    /// WCAG contrast ratio `(L1 + 0.05) / (L2 + 0.05)`, L1 the lighter; in `[1, 21]`.
    public static func contrastRatio(fg: UInt32, bg: UInt32) -> Double {
        let a = relativeLuminance(fg)
        let b = relativeLuminance(bg)
        let lighter = max(a, b)
        let darker  = min(a, b)
        return (lighter + 0.05) / (darker + 0.05)
    }

    public var isDark: Bool {
        Self.relativeLuminance(background) <= Self.darkLuminanceThreshold
    }

    public var foregroundBackgroundContrast: Double {
        Self.contrastRatio(fg: foreground, bg: background)
    }

    public var cursorBackgroundContrast: Double {
        Self.contrastRatio(fg: cursor, bg: background)
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

    // Catppuccin Mocha (dark) and Latte (light).
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
