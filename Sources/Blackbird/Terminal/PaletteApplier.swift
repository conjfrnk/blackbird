import Foundation

final class PaletteApplier {

    private unowned let session: TerminalSession

    init(session: TerminalSession) {
        self.session = session
    }

    /// `async`, not `sync`: a sync hop blocks main until every pending `feed(_:)` drains.
    /// Ordering against feeds holds because `coreQueue` is serial.
    func apply(_ palette: ThemePalette) {
        session.coreQueue.async { [weak session = self.session] in
            guard let session else { return }
            if session.isTerminatedLocked() { return }
            for (i, c) in palette.ansi.enumerated() {
                session.bbterm.setColor(slot: i, rgb: c)
            }
            // alacritty NamedColor slots: 256 Foreground, 257 Background, 258 Cursor,
            // 259..=266 DimBlack..DimWhite, 267 BrightForeground, 268 DimForeground.
            session.bbterm.setColor(slot: 256, rgb: palette.foreground)
            session.bbterm.setColor(slot: 257, rgb: palette.background)
            session.bbterm.setColor(slot: 258, rgb: palette.cursor)
            // Without explicit writes the core falls back to a hardcoded 0xEEEEEE for 267 and 268, whatever the theme.
            let brightFg = Self.lightenRGB(palette.foreground, by: 0.20)
            let dimFg = Self.darkenRGB(palette.foreground, by: 0.30)
            session.bbterm.setColor(slot: 267, rgb: brightFg)
            session.bbterm.setColor(slot: 268, rgb: dimFg)
            guard let snap = session.bbterm.snapshot() else { return }
            session.snapshotCoalescer.publishPendingSnapshot(snap)
        }
    }

    private static func lightenRGB(_ rgb: UInt32, by factor: Double) -> UInt32 {
        let r = Double((rgb >> 16) & 0xFF)
        let g = Double((rgb >> 8) & 0xFF)
        let b = Double(rgb & 0xFF)
        let nr = UInt32(min(255.0, r + (255.0 - r) * factor).rounded())
        let ng = UInt32(min(255.0, g + (255.0 - g) * factor).rounded())
        let nb = UInt32(min(255.0, b + (255.0 - b) * factor).rounded())
        return (nr << 16) | (ng << 8) | nb
    }

    private static func darkenRGB(_ rgb: UInt32, by factor: Double) -> UInt32 {
        let r = Double((rgb >> 16) & 0xFF)
        let g = Double((rgb >> 8) & 0xFF)
        let b = Double(rgb & 0xFF)
        let nr = UInt32(max(0.0, r * (1.0 - factor)).rounded())
        let ng = UInt32(max(0.0, g * (1.0 - factor)).rounded())
        let nb = UInt32(max(0.0, b * (1.0 - factor)).rounded())
        return (nr << 16) | (ng << 8) | nb
    }
}
