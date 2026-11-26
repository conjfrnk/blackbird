import AppKit

extension TerminalView: NSTextInputClient {

    struct Composition {
        var attributedText: NSAttributedString
        /// Caret offset inside the preedit string, as reported by the IME.
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

    /// Guards against a malformed IME range, including the `(0, NSIntegerMax)` whole-string idiom.
    static func clampedRange(_ range: NSRange, total: Int) -> NSRange {
        let loc = max(0, min(range.location, total))
        let len = max(0, min(range.length, total - loc))
        return NSRange(location: loc, length: len)
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
            let clampedSel = Self.clampedRange(selectedRange, total: attrs.length)
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
        let hadComposition = composition != nil
        composition = nil
        refreshPreeditOverlay()
        // Set even for an empty commit: the IME consumed the event, so keyDown must not encode it again.
        didInsertTextViaIME = true
        guard !committed.isEmpty else { return }
        // AppKit delivers every plain printable through here without modifiers. Under kitty flags 4/8
        // Shift must come from the routing keyDown, which this commit is when no composition was in flight.
        let mode = currentSnapshot?.termMode ?? []
        let wantsShiftBits = mode.contains(.reportAllKeysAsEsc) || mode.contains(.reportAlternateKeys)
        let mods: KeyEncoder.Modifiers = (wantsShiftBits && !hadComposition)
            ? (pendingInsertTextModifiers ?? []).intersection(.shift)
            : []
        // A held plain key reaches here too; an IME commit is never a repeat.
        let eventType = hadComposition
            ? KeyEncoder.EventType.press
            : Self.keyDownEventType(isRepeat: pendingInsertTextIsRepeat, mode: mode)
        // A keypad key's `keyUp` must release this text, not the US-table character (see `keypadCommittedText`).
        if !hadComposition, let keypadKeyCode = pendingInsertTextKeypadKeyCode {
            keypadCommittedText[keypadKeyCode] = committed
        }
        let bytes = encoder.encode(chars: committed, modifiers: mods, mode: mode, eventType: eventType)
        if !bytes.isEmpty { sendToSession(bytes) }
    }

    public func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        [.underlineStyle, .underlineColor, .markedClauseSegment]
    }

    public func attributedSubstring(
        forProposedRange range: NSRange,
        actualRange: NSRangePointer?
    ) -> NSAttributedString? {
        guard let c = composition else { return nil }
        let clamped = Self.clampedRange(range, total: c.attributedText.length)
        actualRange?.pointee = clamped
        return c.attributedText.attributedSubstring(from: clamped)
    }

    public func firstRect(
        forCharacterRange range: NSRange,
        actualRange: NSRangePointer?
    ) -> NSRect {
        let cellRect = cursorCellRectInView()
        let cellWidth = metrics.cellWidth

        func toScreen(_ local: NSRect) -> NSRect {
            guard let window else { return local }
            return window.convertToScreen(convert(local, to: nil))
        }

        // NSTextInputClient convention: when no sub-range is honoured, report NSNotFound
        // in `actualRange` and return the cursor rect.
        guard let c = composition else {
            actualRange?.pointee = NSRange(location: NSNotFound, length: 0)
            return toScreen(cellRect)
        }

        let total = c.attributedText.length
        if range.location == NSNotFound || range.length < 0 || total == 0 {
            actualRange?.pointee = NSRange(location: NSNotFound, length: 0)
            return toScreen(cellRect)
        }

        let clamped = Self.clampedRange(range, total: total)
        actualRange?.pointee = clamped

        // Offsets are in cells, not UTF-16 units: an astral emoji is 2 units but 1 or 2 cells.
        let placement = preeditPlacement(of: c.attributedText.string)
        let at = placement.layout.cell(atUTF16: clamped.location)
        let spanCells = max(1, placement.layout.cells(of: clamped, onLine: at.line))
        let anchor = cellRectInView(row: placement.firstRow + at.line, col: at.col)
        let offsetRect = NSRect(
            x: anchor.minX,
            y: anchor.minY,
            width: CGFloat(spanCells) * cellWidth,
            height: anchor.height
        )
        return toScreen(offsetRect)
    }

    public func characterIndex(for point: NSPoint) -> Int {
        guard let composition else { return NSNotFound }
        guard let localWindow = window?.convertPoint(fromScreen: point) else {
            return NSNotFound
        }
        let local = convert(localWindow, from: nil)
        let cw = max(metrics.cellWidth, 1)
        let placement = preeditPlacement(of: composition.attributedText.string)
        let layout = placement.layout
        let yFromTop = (bounds.height - local.y).sanitizedPixel - titlebarOnlyTopInset
        let hitRow = Int(max(0, yFromTop) / max(metrics.cellHeight, 1))
        let lineIndex = max(0, min(layout.lines.count - 1, hitRow - placement.firstRow))
        let line = layout.lines[lineIndex]
        let dx = local.x - cellOriginPx(row: 0, col: line.startCol).x
        guard dx >= 0 else { return line.range.location }   // rejects negatives and NaN
        // `point` comes from an external caller: clamp before the `Int(Double)` cast, because
        // +Infinity passes the guard above and an out-of-range value traps.
        let safeDx = dx.sanitizedPixel
        let cellOffset = Int((safeDx / cw).rounded(.down))
        return layout.utf16Index(onLine: lineIndex, atCellOffset: cellOffset)
    }

    /// The input context calls this before keyDown's encoder runs. Selectors are absorbed: NSResponder's
    /// defaults (and unimplemented `noop:` / `complete:`) walk the chain and beep on every editing key.
    public override func doCommand(by selector: Selector) {
        if selector == #selector(NSResponder.cancelOperation(_:)),
           composition != nil {
            inputContext?.discardMarkedText()
            unmarkText()
            return
        }
        // `deleteBackward:` is how a dead-key preedit (Option+E) hears Backspace.
        if selector == #selector(NSResponder.deleteBackward(_:)),
           let c = composition {
            let text = c.attributedText.string as NSString
            let lastGrapheme = text.rangeOfComposedCharacterSequence(at: text.length - 1)
            let kept = c.attributedText.attributedSubstring(
                from: NSRange(location: 0, length: lastGrapheme.location)
            )
            setMarkedText(kept,
                          selectedRange: NSRange(location: kept.length, length: 0),
                          replacementRange: NSRange(location: NSNotFound, length: 0))
            // Emptied: tell the system input context too, or it keeps the dead key armed
            // and the next letter still gets the accent.
            if composition == nil { inputContext?.discardMarkedText() }
            return
        }
    }

    // MARK: - Helpers

    func cursorCellRectInView() -> NSRect {
        let cursor = cursorCellInView()
        return cellRectInView(row: cursor.row, col: cursor.col)
    }

    func cursorCellInView() -> (row: Int, col: Int) {
        #if DEBUG
        if let test = cursorOverrideForTests {
            return (row: test.row, col: test.col)
        }
        #endif
        return (row: cursorRowInView(), col: cursorColInView())
    }

    func cellRectInView(row: Int, col: Int) -> NSRect {
        let cw = metrics.cellWidth
        let ch = metrics.cellHeight
        let origin = cellOriginPx(row: row, col: col)
        // The renderer puts row 0 at the top; this unflipped view has y=0 at the bottom.
        let yPointsFromBottom = max(0, bounds.height - origin.y - ch)
        return NSRect(x: origin.x, y: yPointsFromBottom, width: cw, height: ch)
    }

    /// Clamped to the visible grid: when scrolled back the live cursor may be off-screen.
    func cursorRowInView() -> Int {
        guard let snap = currentSnapshot else { return 0 }
        let screenRow = snap.cursorRow + snap.displayOffset
        return max(0, min(snap.rows - 1, screenRow))
    }

    func cursorColInView() -> Int {
        guard let snap = currentSnapshot else { return 0 }
        return max(0, min(snap.cols - 1, snap.cursorCol))
    }

    /// The grid is derived from the view's bounds, not the snapshot, so this also holds mid-resize.
    /// A preedit taller than the rows below the cursor slides up so its last line stays on screen.
    func preeditPlacement(of text: String) -> (layout: PreeditLayout, firstRow: Int) {
        let usable = Self.usableViewSize(
            forBounds: bounds.size,
            titlebarTopInset: titlebarOnlyTopInset,
            metrics: metrics
        )
        let grid = metrics.grid(forPixelSize: usable)
        let cursor = cursorCellInView()
        let layout = PreeditLayout(text: text, startCol: cursor.col, cols: grid.cols, maxLines: grid.rows)
        return (layout, max(0, min(cursor.row, grid.rows - layout.lines.count)))
    }

    func refreshPreeditOverlay() {
        guard let composition else {
            preeditOverlay?.removeFromSuperview()
            preeditOverlay = nil
            needsDisplay = true
            return
        }
        // Sized in cells, not graphemes: CJK and wide emoji occupy two cells each.
        let placement = preeditPlacement(of: composition.attributedText.string)
        let layout = placement.layout
        let height = metrics.cellHeight * CGFloat(layout.lines.count)
        let origin = cellOriginPx(row: placement.firstRow, col: layout.leftCol)
        let frame = NSRect(
            x: origin.x,
            y: max(0, bounds.height - origin.y - height),
            width: metrics.cellWidth * CGFloat(layout.widthCells),
            height: height
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
            layout: layout,
            cellSize: NSSize(width: metrics.cellWidth, height: metrics.cellHeight),
            font: metrics.font,
            foreground: Self.nsColor(fromRgb: themeDefaultFgRgb),
            background: Self.nsColor(fromRgb: themeDefaultBgRgb),
            underline: .controlAccentColor
        )
        needsDisplay = true
    }

    /// `rgb` is packed 0x00RRGGBB.
    fileprivate static func nsColor(fromRgb rgb: UInt32) -> NSColor {
        let r = CGFloat((rgb >> 16) & 0xFF) / 255.0
        let g = CGFloat((rgb >> 8)  & 0xFF) / 255.0
        let b = CGFloat(rgb & 0xFF) / 255.0
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1.0)
    }

    /// AppKit may tear down the input context's state on deactivation, leaving a preedit that never
    /// commits. `discardMarkedText()` clears the system context; `unmarkText()` clears ours.
    func discardCompositionOnResignKey() {
        guard composition != nil else { return }
        inputContext?.discardMarkedText()
        unmarkText()
    }

    #if DEBUG
    func _testOnly_simulateWindowResignKey() {
        discardKeyboardStateOnResignKey()
    }
    #endif

    /// Used by the IME commit path, the `keyDown` encoder fall-through and mouse reports. Paste, focus
    /// events and the Ctrl-letter fast path call `session.send` / `session.sendImmediate` directly.
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
