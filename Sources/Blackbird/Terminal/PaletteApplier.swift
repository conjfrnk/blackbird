import Foundation

/// Pushes a resolved theme palette into the Rust core and re-publishes so
/// cells recolor on the next draw.
///
/// Pure extraction from `TerminalSession` (REFACTOR.md Part IV — Finding 1,
/// the "palette as collaborator" peel): the color-math + OSC-slot mapping is a
/// self-contained concern that doesn't belong in the session god-object. It
/// touches neither `publishLock` nor the coalescer's internal state — it only
/// uses the coalescer's public producer API (`publishPendingSnapshot`), exactly
/// as every other snapshot producer (resize, scroll) does.
///
/// Holds an `unowned let session`; the only deferred block captures
/// `[weak session]` so a palette apply that races teardown is a clean no-op.
final class PaletteApplier {

    private unowned let session: TerminalSession

    init(session: TerminalSession) {
        self.session = session
    }

    /// Push a full palette into the Rust term + publish a fresh snapshot so
    /// cells re-color on the next draw. Serialized through `coreQueue` as
    /// `async` — the previous `sync` flavour blocked main waiting for any
    /// pending `feed(_:)` items to drain, which on a chatty shell
    /// (`xcodebuild test`, tailing logs, Claude streaming) turns every Settings
    /// click that changes the palette / cursor / translucency into a visible
    /// beachball. Async preserves ordering against feeds because `coreQueue` is
    /// serial, and the resulting snapshot is routed through the same single-slot
    /// coalescer that `feed(_:)` publishes through, so a palette change
    /// mid-burst can't jump ahead of or duplicate the snapshot stream.
    func apply(_ palette: ThemePalette) {
        session.coreQueue.async { [weak session = self.session] in
            guard let session else { return }
            // L-1: same termination gate as `feed` (F11). All other
            // coreQueue.async paths bail when isTerminated is set; without the
            // check here a theme apply that races terminate() can publish a
            // snapshot through the coalescer for a session whose consumer is
            // tearing down.
            if session.isTerminatedLocked() { return }
            for (i, c) in palette.ansi.enumerated() {
                session.bbterm.setColor(slot: i, rgb: c)
            }
            // NamedColor layout in alacritty 0.26 (per vte-0.15.0/src/ansi.rs):
            //   256 = Foreground, 257 = Background, 258 = Cursor
            //   259..=266 = DimBlack..DimWhite
            //   267 = BrightForeground, 268 = DimForeground
            session.bbterm.setColor(slot: 256, rgb: palette.foreground)
            session.bbterm.setColor(slot: 257, rgb: palette.background)
            session.bbterm.setColor(slot: 258, rgb: palette.cursor)
            // Audit fix-#24 (2026-05-11): without explicit writes for slots
            // 267/268 the renderer falls through to named_color_rgb's
            // hardcoded 0xEEEEEE for both BrightForeground and DimForeground
            // (lib.rs:2513,2524). A TUI that emits bold default-fg (xterm
            // bold-color path) or SGR 2 dim default-fg would render the xterm
            // default regardless of theme — wrong under Solarized Dark /
            // Catppuccin / Light variants where 0xEEEEEE clashes with the
            // chosen palette. Derive from the theme's foreground: lighten 20%
            // toward white for Bright, darken 30% toward black for Dim. Matches
            // alacritty's own SGR-1 / SGR-2 expected behaviour reasonably well;
            // users with explicit OSC 4/10 overrides for these slots still win
            // because OSC writes land via the same setColor path.
            let brightFg = Self.lightenRGB(palette.foreground, by: 0.20)
            let dimFg = Self.darkenRGB(palette.foreground, by: 0.30)
            session.bbterm.setColor(slot: 267, rgb: brightFg)
            session.bbterm.setColor(slot: 268, rgb: dimFg)
            guard let snap = session.bbterm.snapshot() else { return }
            session.snapshotCoalescer.publishPendingSnapshot(snap)
        }
    }

    /// Audit fix-#24 helper: blend a 0xRRGGBB color toward white by `factor`
    /// in [0, 1]. factor=0 returns the input unchanged; factor=1 returns
    /// 0xFFFFFF. Saturating at 255 per channel.
    private static func lightenRGB(_ rgb: UInt32, by factor: Double) -> UInt32 {
        let r = Double((rgb >> 16) & 0xFF)
        let g = Double((rgb >> 8) & 0xFF)
        let b = Double(rgb & 0xFF)
        let nr = UInt32(min(255.0, r + (255.0 - r) * factor).rounded())
        let ng = UInt32(min(255.0, g + (255.0 - g) * factor).rounded())
        let nb = UInt32(min(255.0, b + (255.0 - b) * factor).rounded())
        return (nr << 16) | (ng << 8) | nb
    }

    /// Audit fix-#24 helper: blend a 0xRRGGBB color toward black by `factor`
    /// in [0, 1]. factor=0 returns the input unchanged; factor=1 returns
    /// 0x000000.
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
