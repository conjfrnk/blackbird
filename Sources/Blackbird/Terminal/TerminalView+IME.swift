import AppKit

#if DEBUG
/// Records bytes that would have been written to a real PTY. Swapped in via
/// `TerminalView.ptyRecorderForTests` so the IME tests can assert exactly
/// which commits reach the shell without spinning up a forkpty. Declared
/// in the production target (gated on DEBUG) so `TerminalView`'s stored
/// property type is resolvable from the test bundle via `@testable import
/// Blackbird`. Internal access is sufficient — the test module pulls it
/// in through `@testable`, and nothing ships this symbol in release.
final class RecordingPTY {
    var sent = Data()
    init() {}
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

extension TerminalView: NSTextInputClient {

    /// In-flight IME composition. While non-nil the view is in preedit mode:
    /// `hasMarkedText()` is true, `keyDown` hands every event to the input
    /// context, and nothing reaches the PTY until `insertText(_:)` commits.
    ///
    /// Nested inside `TerminalView` to keep the generic-sounding
    /// "Composition" name from taking up a module-wide identifier.
    struct Composition {
        var attributedText: NSAttributedString
        /// Caret offset *inside the preedit string* as reported by the IME.
        /// Surfaced via `selectedRange()` so the input method can position
        /// its candidate window correctly mid-composition.
        var selectedRange: NSRange
    }

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
            // Defensive clamp on the caret range: a malformed IME could
            // hand us a location or length that overruns `attrs`, and
            // `selectedRange()` would then return a range the candidate
            // window can't interpret. Use the same pattern
            // `attributedSubstring` uses so behaviour is consistent.
            let total = attrs.length
            let loc = max(0, min(selectedRange.location, total))
            let len = max(0, min(selectedRange.length, total - loc))
            let clampedSel = NSRange(location: loc, length: len)
            composition = TerminalView.Composition(
                attributedText: attrs,
                selectedRange: clampedSel
            )
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

    /// NSTextInputClient routes editing keys that aren't printable through
    /// `doCommand(by:)`: Backspace → `deleteBackward:`, Enter → `insertNewline:`,
    /// arrows → `moveUp:` / `moveDown:` / `moveLeft:` / `moveRight:`, etc.
    /// `inputContext?.handleEvent(event)` in `keyDown` calls this BEFORE
    /// keyDown's encoder fall-through runs, so by the time the encoder sends
    /// the correct byte to the PTY, the default `NSResponder` implementation
    /// of (e.g.) `deleteBackward(_:)` has already walked up the chain and
    /// rung the system bell — a beep on every Backspace/Enter/arrow while
    /// typing.
    ///
    /// Absorb the selector here. We don't need to re-do the encoding — the
    /// keyDown → encoder path handles it a few lines later with the actual
    /// event (correct modifiers, kitty disambiguation, Option-as-Meta, etc.).
    /// Leaving this empty IS the fix: the selector is "handled" (no further
    /// routing), so `NSResponder`'s default doesn't fire its bell.
    public override func doCommand(by selector: Selector) {
        // Intentionally empty — see docstring above.
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
    ///
    /// Called from four places:
    ///   - `setMarkedText` / `unmarkText` / `insertText` (composition state
    ///     changed),
    ///   - `layout()` in `TerminalView` (bounds changed — keeps the overlay
    ///     anchored to the cursor cell while the user resizes the window
    ///     mid-composition),
    ///   - `applyTheme(_:)` (palette swap — repaints the overlay in the new
    ///     theme fg/bg without waiting for the next IME callback).
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
            font: metrics.font,
            foreground: Self.nsColor(fromRgb: themeDefaultFgRgb),
            background: Self.nsColor(fromRgb: themeDefaultBgRgb),
            underline: .controlAccentColor
        )
        needsDisplay = true
    }

    /// Unpack a packed 0x00RRGGBB integer into an `NSColor`. Extension-local
    /// because the existing SIMD converter in the renderer wants `SIMD4<Float>`,
    /// and the preedit overlay draws via Core Graphics which wants NSColor.
    fileprivate static func nsColor(fromRgb rgb: UInt32) -> NSColor {
        let r = CGFloat((rgb >> 16) & 0xFF) / 255.0
        let g = CGFloat((rgb >> 8)  & 0xFF) / 255.0
        let b = CGFloat(rgb & 0xFF) / 255.0
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1.0)
    }

    /// IME-commit wrapper around `session.send(bytes)` — used ONLY by the
    /// NSTextInputClient commit path and the main `keyDown` encoder
    /// fall-through. Does NOT intercept paste, mouse reporting, focus
    /// events, or the Ctrl-letter fast path: those remain on `session.send`
    /// / `session.sendImmediate` directly. Gated on DEBUG so the IME tests
    /// can capture commit bytes via `ptyRecorderForTests` without a real
    /// forkpty; release builds collapse to a plain `session?.send`.
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
