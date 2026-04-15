import AppKit
import CoreText
import Combine

/// Fixed-cell metrics derived from a monospaced font.
public struct CellMetrics {
    public let font: NSFont
    public let cellWidth: CGFloat
    public let cellHeight: CGFloat
    public let ascent: CGFloat
    public let descent: CGFloat
    public let leading: CGFloat

    public init(font: NSFont) {
        self.font = font
        let ct = font as CTFont
        self.ascent = CTFontGetAscent(ct)
        self.descent = CTFontGetDescent(ct)
        self.leading = CTFontGetLeading(ct)
        self.cellHeight = (ascent + descent + leading).rounded()
        // Measure the advance of 'M' — a reliable monospace cell width.
        var glyph = CGGlyph(0)
        var chars: [UniChar] = [UInt16(("M" as Character).asciiValue ?? 77)]
        CTFontGetGlyphsForCharacters(ct, &chars, &glyph, 1)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(ct, .horizontal, &glyph, &advance, 1)
        self.cellWidth = advance.width.rounded()
    }

    public func grid(forPixelSize size: CGSize) -> (cols: Int, rows: Int) {
        let cols = max(1, Int(size.width / cellWidth))
        let rows = max(1, Int(size.height / cellHeight))
        return (cols, rows)
    }
}

/// NSView that draws a BBSnapshot via CoreText and forwards keyboard input
/// through a KeyEncoder to a TerminalSession.
///
/// Plan 2 scope: CoreText-per-character drawing (slow but correct). Plan 3
/// replaces with a Metal glyph atlas for 120Hz performance.
public final class TerminalView: NSView {

    public weak var session: TerminalSession? {
        didSet { subscribeToSession() }
    }

    public let metrics: CellMetrics
    public let encoder = KeyEncoder()

    private var currentSnapshot: BBSnapshot?
    private var cancellables: [AnyCancellable] = []

    public override init(frame frameRect: NSRect) {
        self.metrics = CellMetrics(font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        super.init(frame: frameRect)
        self.wantsLayer = true
        self.layer?.backgroundColor = NSColor.black.cgColor
    }

    public required init?(coder: NSCoder) { fatalError("not supported") }

    public override var acceptsFirstResponder: Bool { true }

    // MARK: - Rendering

    public func render(snapshot: BBSnapshot) {
        self.currentSnapshot = snapshot
        self.needsDisplay = true
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard let snap = currentSnapshot, let ctx = NSGraphicsContext.current?.cgContext else {
            return
        }

        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(dirtyRect)

        ctx.setAllowsFontSmoothing(true)
        ctx.setAllowsFontSubpixelQuantization(true)
        ctx.setAllowsAntialiasing(true)
        ctx.textMatrix = CGAffineTransform(scaleX: 1.0, y: 1.0)

        let rows = min(snap.rows, Int(bounds.height / metrics.cellHeight))
        let cols = min(snap.cols, Int(bounds.width  / metrics.cellWidth))

        for row in 0..<rows {
            let baselineFromTop = CGFloat(row) * metrics.cellHeight + metrics.ascent
            let y = bounds.height - baselineFromTop
            for col in 0..<cols {
                guard let ch = snap.character(at: col, row: row), ch != " " else { continue }
                let x = CGFloat(col) * metrics.cellWidth
                drawCharacter(ch, at: CGPoint(x: x, y: y), in: ctx)
            }
        }

        // Cursor.
        if snap.cursorVisible, snap.cursorRow < rows, snap.cursorCol < cols {
            let cx = CGFloat(snap.cursorCol) * metrics.cellWidth
            let cy = bounds.height - (CGFloat(snap.cursorRow + 1) * metrics.cellHeight)
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(1.0)
            ctx.stroke(CGRect(x: cx, y: cy, width: metrics.cellWidth, height: metrics.cellHeight))
        }
    }

    private func drawCharacter(_ ch: Character, at point: CGPoint, in ctx: CGContext) {
        let attr = NSAttributedString(
            string: String(ch),
            attributes: [.font: metrics.font, .foregroundColor: NSColor.white]
        )
        let line = CTLineCreateWithAttributedString(attr)
        ctx.textPosition = point
        CTLineDraw(line, ctx)
    }

    // MARK: - Session observation

    private func subscribeToSession() {
        cancellables.removeAll()
        guard let session else { return }

        session.$snapshot.sink { [weak self] snap in
            guard let self, let snap else { return }
            DispatchQueue.main.async {
                self.render(snapshot: snap)
            }
        }.store(in: &cancellables)

        session.$title.sink { [weak self] title in
            guard let self else { return }
            DispatchQueue.main.async {
                self.window?.title = title ?? "Blackbird"
            }
        }.store(in: &cancellables)
    }

    // MARK: - Input

    public override func keyDown(with event: NSEvent) {
        guard let session else { super.keyDown(with: event); return }
        let mods = KeyEncoder.Modifiers(event: event)

        if let special = Self.specialKey(for: event) {
            let bytes = encoder.encodeSpecial(special, modifiers: mods)
            if !bytes.isEmpty { session.send(bytes) }
            return
        }

        let chars = event.charactersIgnoringModifiers ?? event.characters ?? ""
        let bytes = encoder.encode(chars: chars, modifiers: mods)
        if !bytes.isEmpty { session.send(bytes) }
    }

    private static func specialKey(for event: NSEvent) -> KeyEncoder.SpecialKey? {
        let key = event.specialKey
        switch key {
        case NSEvent.SpecialKey.upArrow:    return .up
        case NSEvent.SpecialKey.downArrow:  return .down
        case NSEvent.SpecialKey.leftArrow:  return .left
        case NSEvent.SpecialKey.rightArrow: return .right
        case NSEvent.SpecialKey.home:       return .home
        case NSEvent.SpecialKey.end:        return .end
        case NSEvent.SpecialKey.pageUp:     return .pageUp
        case NSEvent.SpecialKey.pageDown:   return .pageDown
        case NSEvent.SpecialKey.delete:     return .delete
        case NSEvent.SpecialKey.deleteForward: return .delete
        default: return nil
        }
    }
}

// MARK: - Modifier mapping

extension KeyEncoder.Modifiers {
    init(event: NSEvent) {
        var mods: KeyEncoder.Modifiers = []
        let flags = event.modifierFlags
        if flags.contains(.shift)   { mods.insert(.shift) }
        if flags.contains(.control) { mods.insert(.control) }
        if flags.contains(.option)  { mods.insert(.option) }
        if flags.contains(.command) { mods.insert(.command) }
        self = mods
    }
}
