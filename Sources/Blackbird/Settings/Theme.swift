import Foundation
import os

/// A full theme palette. Values are 0xRRGGBB; alpha is always opaque —
/// terminals don't composite window transparency beyond the solid bg.
public struct ThemePalette: Equatable, Sendable {
    public var background: UInt32
    public var foreground: UInt32
    public var cursor: UInt32
    /// 16 ANSI colors — 0..7 = normal, 8..15 = bright.
    public var ansi: [UInt32]

    private static let themeLogger = Logger(subsystem: "dev.conjfrnk.blackbird", category: "theme")

    public init(background: UInt32, foreground: UInt32, cursor: UInt32, ansi: [UInt32]) {
        // fix-#14 philosophy: don't abort the process on a malformed theme.
        // A non-16-entry `ansi` array previously hit a `precondition` that
        // aborts in BOTH debug AND release (reachable the moment a non-literal
        // theme source — e.g. a user-theme importer — hands in the wrong
        // length). Normalise to exactly 16 entries instead — truncate extras,
        // pad missing slots with `foreground` so text stays visible — and log
        // a warning, mirroring the cursor snap-to-foreground recovery below.
        // Downstream (renderer, color_to_rgb) indexes ansi[0..<16] and relies
        // on this invariant. Audit S6-003.
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
        // Audit fix-#14 (2026-05-11): the original DEBUG-only asserts ship
        // an invisible-cursor palette in release. The author explicitly
        // didn't want to crash on a user-supplied theme with poor contrast
        // (see comment block below), so the release path now snaps the
        // cursor to the foreground color when its contrast against bg
        // falls below 1.25 — that floor is much looser than the WCAG
        // text threshold and only catches the degenerate "cursor RGB ==
        // background RGB" case. A warning is emitted via os.Logger so
        // the regression is visible in the unified log without breaking
        // the user's session.
        let cursorBg = Self.contrastRatio(fg: cursor, bg: background)
        if cursorBg < 1.25 {
            Self.themeLogger.warning(
                "Theme palette cursor/background contrast \(cursorBg, format: .fixed(precision: 2)) < 1.25 — snapping cursor to foreground (was 0x\(String(cursor, radix: 16), privacy: .public), now 0x\(String(foreground, radix: 16), privacy: .public))"
            )
            self.cursor = foreground
        } else {
            self.cursor = cursor
        }
        self.ansi = normalizedAnsi
        #if DEBUG
        // Check the three "first-class" colors for glaring misconfiguration
        // so a future palette edit can't ship a theme with an invisible
        // cursor or unreadable prompt. WCAG AA requires a 4.5:1 contrast
        // ratio for normal text; we use a looser 3:1 threshold here because
        // the curated palettes trip the 4.5 bar at the margins (Solarized
        // Dark's foreground 0x839496 on 0x002B36 is ~7.0, but user-supplied
        // themes may dip to ~3-4 and still be legible for UI-chrome text).
        // The cursor check requires any contrast at all against the bg so
        // a cursor that blends into the background ships a visible warning
        // during test runs. Release builds rely on the snap-to-foreground
        // fallback above instead of crashing — ThemePalette is value-type
        // and re-validated on every swap. (settings F6 + fix-#14)
        let fgBg = Self.contrastRatio(fg: foreground, bg: background)
        assert(fgBg >= 3.0,
               "Theme palette foreground/background contrast \(fgBg) < 3:1")
        assert(cursorBg >= 1.25,
               "Theme palette cursor/background contrast \(cursorBg) < 1.25:1 — cursor is invisible")
        #endif
    }

    // MARK: - Contrast helpers (settings F6)
    //
    // Relative luminance per WCAG 2.x: sRGB → linear-light → weighted sum.
    // Matches what `TerminalView.setWindowAppearance` used to compute
    // inline for the titlebar light/dark decision; lifting the math onto
    // the palette itself lets any consumer (future user-theme importer,
    // contrast-sanity unit test) query the same numbers without
    // duplicating the formula.

    /// Rec. 709 / sRGB relative luminance of a 0xRRGGBB color. Returns a
    /// value in `[0, 1]` where 0 is pure black and 1 is pure white.
    public static func relativeLuminance(_ rgb: UInt32) -> Double {
        let r = Double((rgb >> 16) & 0xFF) / 255.0
        let g = Double((rgb >>  8) & 0xFF) / 255.0
        let b = Double( rgb        & 0xFF) / 255.0
        func lin(_ c: Double) -> Double {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    /// WCAG contrast ratio `(L1 + 0.05) / (L2 + 0.05)` where L1 is the
    /// lighter of the two luminances. Always ≥ 1; 21 is maximum
    /// (black-on-white or white-on-black).
    public static func contrastRatio(fg: UInt32, bg: UInt32) -> Double {
        let a = relativeLuminance(fg)
        let b = relativeLuminance(bg)
        let lighter = max(a, b)
        let darker  = min(a, b)
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// True when the palette's background reads as "dark" — used by
    /// window-chrome decisions (titlebar appearance) and by the Settings
    /// UI to pick a light/dark variant of the glass materials. Threshold
    /// is the WCAG 2.x midpoint for "dark": any bg with linear luminance
    /// ≤ 0.18 is classified dark. Matches what TerminalView was computing
    /// inline.
    public var isDark: Bool {
        Self.relativeLuminance(background) <= 0.18
    }

    /// Foreground-to-background contrast ratio of this palette. Call site
    /// for future user-supplied-theme validation (WCAG AA requires 4.5:1
    /// for normal-weight text; our curated palettes all exceed that).
    public var foregroundBackgroundContrast: Double {
        Self.contrastRatio(fg: foreground, bg: background)
    }

    /// Cursor-to-background contrast ratio. Any value at or near 1.0
    /// means the cursor is invisible; validator should reject < 1.25.
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
