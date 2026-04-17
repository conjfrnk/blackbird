import AppKit

/// In-flight IME composition. While non-nil the view is in preedit mode:
/// `hasMarkedText()` is true, `keyDown` hands every event to the input
/// context, and nothing reaches the PTY until `insertText(_:)` commits.
struct Composition {
    var attributedText: NSAttributedString
    /// Caret offset *inside the preedit string* as reported by the IME. We
    /// surface it via `selectedRange()` so the input method can position
    /// its candidate window correctly mid-composition.
    var selectedRange: NSRange
}

#if DEBUG
/// Records bytes that would have been written to a real PTY. Swapped in via
/// `TerminalView.ptyRecorderForTests` so the IME tests can assert exactly
/// which commits reach the shell without spinning up a forkpty. Declared
/// in the production target (gated on DEBUG) so `TerminalView`'s stored
/// property type is resolvable from the test bundle without forcing the
/// test module to inject it — matches the `urlOpenerForTests` pattern.
public final class RecordingPTY {
    public var sent = Data()
    public init() {}
}
#endif

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
    private var fgColor: NSColor = .labelColor
    private var underlineColor: NSColor = .controlAccentColor

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(text: NSAttributedString,
                cellSize: NSSize,
                foreground: NSColor,
                underline: NSColor) {
        preeditString = text
        cellWidth = max(1, cellSize.width)
        cellHeight = max(1, cellSize.height)
        fgColor = foreground
        underlineColor = underline
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard preeditString.length > 0 else { return }
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // Fill the entire preedit span with a solid bg so the underlying
        // terminal cells don't bleed through the composition. Uses the
        // view's textBackgroundColor — in practice this matches what the
        // theme paints for default-bg cells.
        ctx.setFillColor(NSColor.textBackgroundColor.cgColor)
        ctx.fill(bounds)
        // Text: left-aligned, top-of-cell baseline matching the grid.
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: fgColor,
            .font: NSFont.monospacedSystemFont(ofSize: cellHeight * 0.7, weight: .regular)
        ]
        let mutable = NSMutableAttributedString(attributedString: preeditString)
        mutable.addAttributes(attrs, range: NSRange(location: 0, length: mutable.length))
        mutable.draw(at: NSPoint(x: 0, y: (cellHeight - (attrs[.font] as! NSFont).pointSize) / 2))
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

extension TerminalView: NSTextInputClient {

    // MARK: - NSTextInputClient

    public func hasMarkedText() -> Bool { composition != nil }

    public func markedRange() -> NSRange {
        guard let c = composition else {
            return NSRange(location: NSNotFound, length: 0)
        }
        return NSRange(location: 0, length: c.attributedText.length)
    }

    public func selectedRange() -> NSRange {
        composition?.selectedRange ?? NSRange(location: NSNotFound, length: 0)
    }

    public func setMarkedText(_ string: Any,
                              selectedRange: NSRange,
                              replacementRange: NSRange) {
        let attrs: NSAttributedString
        if let s = string as? NSAttributedString {
            attrs = s
        } else if let s = string as? String {
            attrs = NSAttributedString(string: s)
        } else {
            attrs = NSAttributedString(string: "")
        }
        if attrs.length == 0 {
            composition = nil
        } else {
            composition = Composition(attributedText: attrs, selectedRange: selectedRange)
        }
        refreshPreeditOverlay()
    }

    public func unmarkText() {
        composition = nil
        refreshPreeditOverlay()
    }

    public func insertText(_ string: Any, replacementRange: NSRange) {
        let committed: String
        if let a = string as? NSAttributedString {
            committed = a.string
        } else if let str = string as? String {
            committed = str
        } else {
            committed = ""
        }
        composition = nil
        refreshPreeditOverlay()
        // Set the flag even for empty commits — keyDown treats "IME said
        // something" as "don't double-encode", and an empty commit (e.g.
        // the IME cancelled composition without producing output) still
        // means the event was consumed.
        didInsertTextViaIME = true
        guard !committed.isEmpty else { return }
        // Commit path: route through the same encoder keyDown uses so
        // termMode-aware quirks (e.g. paste-like batching) stay consistent.
        // Modifiers are empty — the IME has already resolved the user's
        // intent into a final grapheme cluster.
        let mode = currentSnapshot?.termMode ?? []
        let bytes = encoder.encode(chars: committed, modifiers: [], mode: mode)
        if !bytes.isEmpty { sendToSession(bytes) }
    }

    public func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        // macOS IMEs consult this list before attaching clause segmentation
        // or underline colour hints to the preedit attributed string. Keeping
        // the set small matches what Terminal.app advertises.
        [.underlineStyle, .underlineColor, .markedClauseSegment]
    }

    public func attributedSubstring(
        forProposedRange range: NSRange,
        actualRange: NSRangePointer?
    ) -> NSAttributedString? {
        guard let c = composition else { return nil }
        let total = c.attributedText.length
        let loc = max(0, min(range.location, total))
        let len = max(0, min(range.length, total - loc))
        let clamped = NSRange(location: loc, length: len)
        actualRange?.pointee = clamped
        return c.attributedText.attributedSubstring(from: clamped)
    }

    public func firstRect(
        forCharacterRange range: NSRange,
        actualRange: NSRangePointer?
    ) -> NSRect {
        actualRange?.pointee = range
        let cellRect = cursorCellRectInView()
        guard let window else { return cellRect }
        let windowRect = convert(cellRect, to: nil)
        return window.convertToScreen(windowRect)
    }

    public func characterIndex(for point: NSPoint) -> Int {
        // Terminals don't expose a richer character index because every
        // cell is independently addressable. 0 is the documented default
        // for "point doesn't fall on a character".
        0
    }

    // MARK: - Helpers

    /// Pixel rectangle of the cursor cell in this view's local coordinate
    /// space (top-left origin, matching what the Metal renderer uses when
    /// placing the cursor). Feeds `firstRect(forCharacterRange:…)` so the
    /// IME candidate window anchors under the composition.
    func cursorCellRectInView() -> NSRect {
        let cw = metrics.cellWidth
        let ch = metrics.cellHeight
        // Renderer adds `topInsetPoints` to every cell. Mirror that so the
        // preedit anchor lines up with where the cursor is actually drawn.
        let topInset = CGFloat(titlebarOnlyTopInset)
        let row: Int
        let col: Int
        #if DEBUG
        if let test = cursorOverrideForTests {
            row = test.row
            col = test.col
        } else {
            row = cursorRowInView()
            col = cursorColInView()
        }
        #else
        row = cursorRowInView()
        col = cursorColInView()
        #endif
        let xPoints = CGFloat(col) * cw
        // Renderer renders row 0 at the top. In AppKit (flipped = false)
        // Y=0 sits at the *bottom*, so mirror: the cell's top-left in view
        // coords is (bounds.height - topInset - (row+1)*ch).
        let yPointsFromTop = topInset + CGFloat(row) * ch
        let yPointsFromBottom = max(0, bounds.height - yPointsFromTop - ch)
        return NSRect(x: xPoints, y: yPointsFromBottom, width: cw, height: ch)
    }

    /// Live cursor row in the visible grid. When scrolled-back into history
    /// the live cursor may be off-screen; clamp to the last row so the IME
    /// anchor stays reasonable instead of leaving the view.
    func cursorRowInView() -> Int {
        guard let snap = currentSnapshot else { return 0 }
        let screenRow = snap.cursorRow + snap.displayOffset
        return max(0, min(snap.rows - 1, screenRow))
    }

    func cursorColInView() -> Int {
        guard let snap = currentSnapshot else { return 0 }
        return max(0, min(snap.cols - 1, snap.cursorCol))
    }

    /// Reposition the preedit overlay subview against the current composition.
    /// Creates it lazily on first use; removes it entirely when composition
    /// ends so idle sessions keep a clean view hierarchy.
    func refreshPreeditOverlay() {
        guard let composition else {
            preeditOverlay?.removeFromSuperview()
            preeditOverlay = nil
            needsDisplay = true
            return
        }
        let cellRect = cursorCellRectInView()
        let charCount = composition.attributedText.string.count
        // One cell per grapheme is close enough for CJK composition. We
        // don't need exact glyph metrics for the dotted underline — a dashed
        // rule across the preedit span is the affordance users track.
        let width = max(metrics.cellWidth, metrics.cellWidth * CGFloat(charCount))
        let frame = NSRect(
            x: cellRect.origin.x,
            y: cellRect.origin.y,
            width: width,
            height: cellRect.height
        )
        let overlay: PreeditOverlayView
        if let existing = preeditOverlay {
            overlay = existing
        } else {
            overlay = PreeditOverlayView(frame: frame)
            overlay.wantsLayer = true
            addSubview(overlay)
            preeditOverlay = overlay
        }
        overlay.frame = frame
        overlay.update(
            text: composition.attributedText,
            cellSize: NSSize(width: metrics.cellWidth, height: metrics.cellHeight),
            foreground: .labelColor,
            underline: .controlAccentColor
        )
        needsDisplay = true
    }

    /// Wrapper around `session.send(bytes)` that routes through an injected
    /// recorder in DEBUG builds so tests can assert exactly which bytes the
    /// IME commit path would have emitted without forkpty'ing a real shell.
    /// Production always calls `session?.send` directly.
    func sendToSession(_ bytes: Data) {
        #if DEBUG
        if let recorder = ptyRecorderForTests {
            recorder.sent.append(bytes)
            return
        }
        #endif
        session?.send(bytes)
    }
}
