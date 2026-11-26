import AppKit

/// Wraps a composition at the right edge exactly where the committed text will: the first line starts at the
/// cursor column, later lines at column 0. Overlay frame, drawing, `firstRect` and `characterIndex` all derive from it.
struct PreeditLayout {
    struct Line {
        /// UTF-16 range of the composition shown on this line.
        let range: NSRange
        let startCol: Int
        let cells: Int
    }

    /// Never empty.
    let lines: [Line]
    let cols: Int
    private let plain: NSString

    init(text: String, startCol: Int, cols: Int, maxLines: Int) {
        let cols = max(1, cols)
        let maxLines = max(1, maxLines)
        var lines: [Line] = []
        var lineStart = 0, utf16 = 0, lineCol = min(max(0, startCol), cols - 1), used = 0
        for cluster in text {
            let w = CellWidth.terminalCellWidth(of: String(cluster))
            // No wrap at column 0: it can make no progress (a wide grapheme in a one-column grid).
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

    var leftCol: Int { lines.count > 1 ? 0 : lines[0].startCol }

    var widthCells: Int { lines.count > 1 ? cols : max(1, lines[0].cells) }

    /// An offset on a wrap boundary belongs to the later line; one past the end sits just after the last cell.
    func cell(atUTF16 offset: Int) -> (line: Int, col: Int) {
        let index = lines.firstIndex(where: { (l: Line) -> Bool in offset < NSMaxRange(l.range) })
            ?? lines.count - 1
        let line = lines[index]
        let leading = max(0, min(offset, NSMaxRange(line.range)) - line.range.location)
        let leadingText = plain.substring(with: NSRange(location: line.range.location, length: leading))
        return (index, line.startCol + CellWidth.terminalCellWidth(of: leadingText))
    }

    func cells(of range: NSRange, onLine lineIndex: Int) -> Int {
        let part = NSIntersectionRange(range, lines[lineIndex].range)
        guard part.length > 0 else { return 0 }
        return CellWidth.terminalCellWidth(of: plain.substring(with: part))
    }

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

/// A `CALayer`-backed view, not a Metal pass: preedit stays out of the `buildInstances` hot path.
final class PreeditOverlayView: NSView {
    private var preeditString: NSAttributedString = NSAttributedString(string: "")
    private var lines: [PreeditLayout.Line] = []
    private var leftCol: Int = 0
    private var cellWidth: CGFloat = 1
    private var cellHeight: CGFloat = 1
    private var fgColor: NSColor = .labelColor
    private var bgColor: NSColor = .textBackgroundColor
    private var underlineColor: NSColor = .controlAccentColor
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
        let glyphFont = font
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: fgColor,
            .font: glyphFont
        ]
        let mutable = NSMutableAttributedString(attributedString: preeditString)
        mutable.addAttributes(attrs, range: NSRange(location: 0, length: mutable.length))
        for (i, line) in lines.enumerated() {
            guard line.range.length > 0, NSMaxRange(line.range) <= mutable.length else { continue }
            let rect = NSRect(
                x: CGFloat(line.startCol - leftCol) * cellWidth,
                y: CGFloat(i) * cellHeight,
                width: max(cellWidth, CGFloat(line.cells) * cellWidth),
                height: cellHeight
            )
            // The theme background, not `textBackgroundColor`, which flips with the OS appearance.
            ctx.setFillColor(bgColor.cgColor)
            ctx.fill(rect)
            mutable.attributedSubstring(from: line.range).draw(
                at: NSPoint(x: rect.minX, y: rect.minY + (cellHeight - glyphFont.pointSize) / 2)
            )
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
