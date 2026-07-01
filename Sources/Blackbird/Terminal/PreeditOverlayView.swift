import AppKit

/// Preedit overlay rendered as a thin `CALayer`-backed `NSView` docked at the
/// cursor's pixel position.
///
/// Why a CALayer view instead of a Metal shader pass? Preedit is a rare,
/// one-off overlay (most users never trigger it) and keeping it out of the
/// `buildInstances` hot path preserves the zero-allocation invariant when
/// nothing's being composed. The trade-off is that the preedit glyphs float
/// in a separate layer rather than participating in the atlas — acceptable
/// because CoreText on the composing font produces pixel-identical output
/// at the small sizes we use, and the dotted underline (drawn with a dash
/// pattern in `draw(_:)`) is the real affordance users look for.
final class PreeditOverlayView: NSView {
    private var preeditString: NSAttributedString = NSAttributedString(string: "")
    private var cellWidth: CGFloat = 1
    private var cellHeight: CGFloat = 1
    /// Resolved theme foreground — kept in sync with `TerminalView`'s cached
    /// `themeDefaultFgRgb` so the composing text reads in the same colour
    /// committed output will take.
    private var fgColor: NSColor = .labelColor
    /// Resolved theme background — kept in sync with `themeDefaultBgRgb` so
    /// the overlay paints against the same tint a default-bg cell would.
    private var bgColor: NSColor = .textBackgroundColor
    private var underlineColor: NSColor = .controlAccentColor
    /// Font used to render the composing text. Matches the terminal's
    /// configured font so a user on "Hack Nerd Font Mono" sees `´` in Hack,
    /// not SF Mono, and doesn't get a font flip at commit. Defaults to
    /// system mono until `update(...)` is called with the real one.
    private var font: NSFont = .monospacedSystemFont(ofSize: 12, weight: .regular)

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(text: NSAttributedString,
                cellSize: NSSize,
                font: NSFont,
                foreground: NSColor,
                background: NSColor,
                underline: NSColor) {
        preeditString = text
        cellWidth = max(1, cellSize.width)
        cellHeight = max(1, cellSize.height)
        self.font = font
        fgColor = foreground
        bgColor = background
        underlineColor = underline
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard preeditString.length > 0 else { return }
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // Fill the entire preedit span with the theme background so the
        // underlying terminal cells don't bleed through the composition. The
        // colour tracks the user's active Blackbird theme — not AppKit's
        // system `textBackgroundColor`, which would flip with the OS
        // appearance even when the theme is pinned to light or dark.
        ctx.setFillColor(bgColor.cgColor)
        ctx.fill(bounds)
        // Text: left-aligned, vertically centered in the cell. Hoist `font`
        // to a local so we don't round-trip through the attributes dict
        // just to read back its pointSize.
        let glyphFont = font
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: fgColor,
            .font: glyphFont
        ]
        let mutable = NSMutableAttributedString(attributedString: preeditString)
        mutable.addAttributes(attrs, range: NSRange(location: 0, length: mutable.length))
        mutable.draw(at: NSPoint(x: 0, y: (cellHeight - glyphFont.pointSize) / 2))
        // Dotted underline across the full preedit width. Matches macOS's
        // conventional "uncommitted composition" affordance.
        ctx.saveGState()
        ctx.setStrokeColor(underlineColor.cgColor)
        ctx.setLineWidth(1.0)
        let pattern: [CGFloat] = [2.0, 2.0]
        ctx.setLineDash(phase: 0, lengths: pattern)
        let y = bounds.height - 1.5
        ctx.move(to: CGPoint(x: 0, y: y))
        ctx.addLine(to: CGPoint(x: bounds.width, y: y))
        ctx.strokePath()
        ctx.restoreGState()
    }
}
