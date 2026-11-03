import AppKit

/// How a composition sits on the grid: split into lines that wrap at the right
/// edge exactly where the committed text will, so the overlay never runs past
/// the window. The first line starts at the cursor column, every later line at
/// column 0. A wide grapheme that does not fit in the cells left on a line moves
/// to the next one, as in the grid, which can leave the first line empty.
///
/// Pure value type: the overlay frame, the drawing, the IME candidate anchor
/// (`firstRect`) and click hit-testing (`characterIndex`) all derive from this
/// one layout, so they cannot disagree about where a character is.
struct PreeditLayout {
    struct Line {
        /// UTF-16 range of the composition shown on this line.
        let range: NSRange
        /// Grid column of the line's first cell.
        let startCol: Int
        /// Terminal cells the line's text occupies.
        let cells: Int
    }

    /// Never empty.
    let lines: [Line]
    /// Grid width the text was wrapped to.
    let cols: Int
    private let plain: NSString

    /// `maxLines` caps the height so a pathologically long preedit stays inside
    /// the view; whatever does not fit is dropped from the display.
    init(text: String, startCol: Int, cols: Int, maxLines: Int) {
        let cols = max(1, cols)
        let maxLines = max(1, maxLines)
        var lines: [Line] = []
        var lineStart = 0, utf16 = 0, lineCol = min(max(0, startCol), cols - 1), used = 0
        for cluster in text {
            let w = CellWidth.terminalCellWidth(of: String(cluster))
            // Wrap unless the line is still at column 0, where wrapping can
            // make no progress (a wide grapheme in a one-column grid).
            if lineCol + used > 0 && lineCol + used + w > cols {
                lines.append(Line(range: NSRange(location: lineStart, length: utf16 - lineStart),
                                  startCol: lineCol, cells: used))
                if lines.count == maxLines {
                    self.init(lines: lines, cols: cols, plain: text as NSString)
                    return
                }
                lineStart = utf16
                lineCol = 0
                used = 0
            }
            used += w
            utf16 += cluster.utf16.count
        }
        lines.append(Line(range: NSRange(location: lineStart, length: utf16 - lineStart),
                          startCol: lineCol, cells: used))
        self.init(lines: lines, cols: cols, plain: text as NSString)
    }

    private init(lines: [Line], cols: Int, plain: NSString) {
        self.lines = lines
        self.cols = cols
        self.plain = plain
    }

    /// Column of the overlay view's left edge. Wrapped text spans the full grid
    /// width; a single line is exactly as wide as its text.
    var leftCol: Int { lines.count > 1 ? 0 : lines[0].startCol }

    /// Width of the overlay view in cells (at least one, so an empty-width
    /// composition still paints).
    var widthCells: Int { lines.count > 1 ? cols : max(1, lines[0].cells) }

    /// Line and grid column where the character at UTF-16 `offset` is drawn.
    /// An offset on a wrap boundary belongs to the later line; one past the end
    /// sits just after the last cell.
    func cell(atUTF16 offset: Int) -> (line: Int, col: Int) {
        let index = lines.firstIndex(where: { (l: Line) -> Bool in offset < NSMaxRange(l.range) })
            ?? lines.count - 1
        let line = lines[index]
        let leading = max(0, min(offset, NSMaxRange(line.range)) - line.range.location)
        let leadingText = plain.substring(with: NSRange(location: line.range.location, length: leading))
        return (index, line.startCol + CellWidth.terminalCellWidth(of: leadingText))
    }

    /// Cells of `range` that sit on `lineIndex` (the rest of a range that
    /// wraps is on later lines).
    func cells(of range: NSRange, onLine lineIndex: Int) -> Int {
        let part = NSIntersectionRange(range, lines[lineIndex].range)
        guard part.length > 0 else { return 0 }
        return CellWidth.terminalCellWidth(of: plain.substring(with: part))
    }

    /// UTF-16 index of the grapheme covering `cellOffset` cells into `lineIndex`;
    /// the line's end when the offset is past its text.
    func utf16Index(onLine lineIndex: Int, atCellOffset cellOffset: Int) -> Int {
        let line = lines[lineIndex]
        var consumed = 0
        var index = line.range.location
        for cluster in plain.substring(with: line.range) {
            let w = CellWidth.terminalCellWidth(of: String(cluster))
            if consumed + w > cellOffset { return index }
            consumed += w
            index += cluster.utf16.count
        }
        return NSMaxRange(line.range)
    }
}

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
    /// Wrapped lines of `preeditString`, positioned relative to `leftCol`.
    private var lines: [PreeditLayout.Line] = []
    private var leftCol: Int = 0
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
                layout: PreeditLayout,
                cellSize: NSSize,
                font: NSFont,
                foreground: NSColor,
                background: NSColor,
                underline: NSColor) {
        preeditString = text
        lines = layout.lines
        leftCol = layout.leftCol
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
        // Hoist `font` to a local so we don't round-trip through the
        // attributes dict just to read back its pointSize.
        let glyphFont = font
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: fgColor,
            .font: glyphFont
        ]
        let mutable = NSMutableAttributedString(attributedString: preeditString)
        mutable.addAttributes(attrs, range: NSRange(location: 0, length: mutable.length))
        for (i, line) in lines.enumerated() {
            // An empty line (a wide grapheme wrapped off the last column)
            // paints nothing, leaving the grid cells under it visible.
            guard line.range.length > 0, NSMaxRange(line.range) <= mutable.length else { continue }
            let rect = NSRect(
                x: CGFloat(line.startCol - leftCol) * cellWidth,
                y: CGFloat(i) * cellHeight,
                width: max(cellWidth, CGFloat(line.cells) * cellWidth),
                height: cellHeight
            )
            // Fill the entire preedit span with the theme background so the
            // underlying terminal cells don't bleed through the composition. The
            // colour tracks the user's active Blackbird theme — not AppKit's
            // system `textBackgroundColor`, which would flip with the OS
            // appearance even when the theme is pinned to light or dark.
            ctx.setFillColor(bgColor.cgColor)
            ctx.fill(rect)
            // Text: left-aligned, vertically centered in the cell.
            mutable.attributedSubstring(from: line.range).draw(
                at: NSPoint(x: rect.minX, y: rect.minY + (cellHeight - glyphFont.pointSize) / 2)
            )
            // Dotted underline across the full line width. Matches macOS's
            // conventional "uncommitted composition" affordance.
            ctx.saveGState()
            ctx.setStrokeColor(underlineColor.cgColor)
            ctx.setLineWidth(1.0)
            let pattern: [CGFloat] = [2.0, 2.0]
            ctx.setLineDash(phase: 0, lengths: pattern)
            let y = rect.maxY - 1.5
            ctx.move(to: CGPoint(x: rect.minX, y: y))
            ctx.addLine(to: CGPoint(x: rect.maxX, y: y))
            ctx.strokePath()
            ctx.restoreGState()
        }
    }
}
