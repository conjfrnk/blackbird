import AppKit

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

    /// Clamp `range` into `[0, total]` — location clamped first, then length to
    /// the remaining span. The ONE defensive marked-text clamp (was copy-pasted
    /// across `setMarkedText` / `attributedSubstring(forProposedRange:)` /
    /// `firstRect(forCharacterRange:)`): a malformed IME handing us a location
    /// or length that overruns the marked text — including the `(0, NSIntegerMax)`
    /// "the whole thing" idiom — can't index past it.
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
            // Defensive clamp on the caret range: a malformed IME could
            // hand us a location or length that overruns `attrs`, and
            // `selectedRange()` would then return a range the candidate
            // window can't interpret. Use the same pattern
            // `attributedSubstring` uses so behaviour is consistent.
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
        // Set the flag even for empty commits — keyDown treats "IME said
        // something" as "don't double-encode", and an empty commit (e.g.
        // the IME cancelled composition without producing output) still
        // means the event was consumed.
        didInsertTextViaIME = true
        guard !committed.isEmpty else { return }
        // Commit path: route through the same encoder keyDown uses so
        // termMode-aware quirks (e.g. paste-like batching) stay consistent.
        // Modifiers are empty for a real IME commit — the IME has resolved
        // the user's intent into a final grapheme cluster. But AppKit also
        // delivers EVERY plain printable through here with no modifier
        // information, so under kitty flags 4/8 (which encode the key as
        // its unshifted codepoint plus modifier bits) Shift was lost:
        // Shift+A became `CSI 97u` and the TUI typed `a`. Use the routing
        // keyDown's modifiers when this commit is that key, i.e. when no
        // composition was in flight.
        let mode = currentSnapshot?.termMode ?? []
        let wantsShiftBits = mode.contains(.reportAllKeysAsEsc) || mode.contains(.reportAlternateKeys)
        let mods: KeyEncoder.Modifiers = (wantsShiftBits && !hadComposition)
            ? (pendingInsertTextModifiers ?? []).intersection(.shift)
            : []
        // A held plain key reaches here too (flag 8 makes it a CSI u escape
        // code); an IME commit is never a repeat.
        let eventType = hadComposition
            ? KeyEncoder.EventType.press
            : Self.keyDownEventType(isRepeat: pendingInsertTextIsRepeat, mode: mode)
        // A keypad key's `keyUp` must release this text, not the US-table
        // character (see `keypadCommittedText`).
        if !hadComposition, let keypadKeyCode = pendingInsertTextKeypadKeyCode {
            keypadCommittedText[keypadKeyCode] = committed
        }
        let bytes = encoder.encode(chars: committed, modifiers: mods, mode: mode, eventType: eventType)
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
        let clamped = Self.clampedRange(range, total: c.attributedText.length)
        actualRange?.pointee = clamped
        return c.attributedText.attributedSubstring(from: clamped)
    }

    public func firstRect(
        forCharacterRange range: NSRange,
        actualRange: NSRangePointer?
    ) -> NSRect {
        // Base anchor: the cursor cell in local view coords. Used directly
        // for the empty / no-composition / out-of-range cases; a sub-range
        // is anchored on the preedit's own (possibly wrapped) layout below.
        let cellRect = cursorCellRectInView()
        let cellWidth = metrics.cellWidth

        // Convert a local-view rect to screen coords. Falls back to the
        // local rect when we're not yet in a window (can happen during
        // headless tests or between `viewWillMove`/`viewDidMoveToWindow`).
        func toScreen(_ local: NSRect) -> NSRect {
            guard let window else { return local }
            return window.convertToScreen(convert(local, to: nil))
        }

        // No active composition → defer to the cursor cell, same as the
        // prior behaviour. Signal to the caller that we didn't honour a
        // sub-range by writing NSNotFound into `actualRange`.
        guard let c = composition else {
            actualRange?.pointee = NSRange(location: NSNotFound, length: 0)
            return toScreen(cellRect)
        }

        let total = c.attributedText.length
        // Sentinel / empty / degenerate requests: the IME doesn't know what
        // sub-range to anchor under. Per the NSTextInputClient convention,
        // report NSNotFound in `actualRange` and hand back the cursor rect
        // so the candidate popover still has a sensible place to sit.
        if range.location == NSNotFound || range.length < 0 || total == 0 {
            actualRange?.pointee = NSRange(location: NSNotFound, length: 0)
            return toScreen(cellRect)
        }

        // Clamp against the marked-text extent, mirroring the clamping
        // `attributedSubstring(forProposedRange:…)` already applies. An
        // IME that hands us `(0, NSIntegerMax)` to mean "the whole thing"
        // lands here with `clamped == (0, total)`.
        let clamped = Self.clampedRange(range, total: total)
        actualRange?.pointee = clamped

        // Cell-count offset from the composition's left edge. UTF-16
        // length is wrong — an astral-plane emoji (😀 = 2 UTF-16 units,
        // 1 or 2 cells depending on wide-glyph status) would otherwise
        // place the candidate popover two cells to the right of where
        // the emoji renders (F-S5-012). The layout converts both the
        // leading offset AND the span width through `terminalCellWidth`
        // so the mapping stays grapheme-aware, and follows the preedit
        // where it wraps at the right edge so the popover tracks the
        // visible text. `characterIndex(for:)` walks cells the same way.
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
        // During a composition, map the screen point back to an offset
        // inside the marked text so the input method can reposition
        // candidates / navigate within the preedit on click. Without
        // this, clicking on a candidate word during Chinese/Japanese
        // input misses and VoiceOver's read-at-point always reads the
        // composition's first grapheme. Audit terminal-ime F5.
        guard let composition else { return NSNotFound }
        // Convert screen to local using the same inverse transform
        // firstRect(forCharacterRange:) uses forward.
        guard let localWindow = window?.convertPoint(fromScreen: point) else {
            return NSNotFound
        }
        let local = convert(localWindow, from: nil)
        let cw = max(metrics.cellWidth, 1)
        // A wrapped preedit spans several lines: pick the one under `point`
        // (a single-line composition always resolves to line 0). Clamped
        // before the `Int(Double)` cast like `dx` below.
        let placement = preeditPlacement(of: composition.attributedText.string)
        let layout = placement.layout
        let yFromTop = (bounds.height - local.y).sanitizedPixel - titlebarOnlyTopInset
        let hitRow = Int(max(0, yFromTop) / max(metrics.cellHeight, 1))
        let lineIndex = max(0, min(layout.lines.count - 1, hitRow - placement.firstRow))
        let line = layout.lines[lineIndex]
        // Offset relative to the line's leading edge in CELLS,
        // then map to a UTF-16 index by accumulating cellWidth per
        // grapheme from the composition string.
        let dx = local.x - cellOriginPx(row: 0, col: line.startCol).x
        guard dx >= 0 else { return line.range.location }   // rejects negatives and NaN
        // Clamp a finite-but-absurd (or +Infinity) dx before the
        // `Int(Double)` cast. `point` arrives straight from an external
        // NSTextInputClient caller (an input method, an assistive tool
        // synthesising read-at-point, or fault injection); a magnitude
        // like 1e300 — or +Inf, which slips past the `dx >= 0` guard —
        // would otherwise trap ("Double value cannot be converted to
        // Int because it is outside the representable range") and crash
        // the app. `dx >= 0` is guaranteed by the guard above, so
        // `max(0, dx) == dx` and `sanitizedPixel` matches the original
        // `min(dx, sanePx)` exactly. Mirrors the `CGFloat.sanePx` clamp
        // applied in Selection.swift and TerminalView+Mouse.swift before
        // their point-derived Int() casts.
        let safeDx = dx.sanitizedPixel
        let cellOffset = Int((safeDx / cw).rounded(.down))
        // Walk graphemes summing width until we reach cellOffset. Per-grapheme
        // width comes from `terminalCellWidth(of:)` — the SAME grapheme-aware
        // model the grid and `firstRect(forCharacterRange:)` use — so a ZWJ
        // family counts as one wide cell AND an emoji-presentation sequence
        // (base + VS16 / keycap, e.g. ⚠️) counts as 2 cells, matching where the
        // grid actually draws it. (A previous per-scalar `.max()` here counted
        // ⚠️ as 1 cell, anchoring the caret a cell off — KNOWN_ISSUES "IME caret
        // width model divergence".) Past the line's end → clamp to the LAST VALID
        // INSERTION POINT (= length on the last line, AppKit convention), not
        // length-1 which would place the caret one UTF-16 unit before the end
        // of an astral grapheme.
        return layout.utf16Index(onLine: lineIndex, atCellOffset: cellOffset)
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
    /// Leaving this empty WAS the fix for the printable-key selectors, but
    /// one exception needs real handling (audit terminal-ime F3):
    /// - `cancelOperation:` fires on Esc during an active composition; the
    ///   IME expects "abort the preedit" not "encode Esc". Clear the
    ///   composition so the user can re-start input without the stale
    ///   marked text showing through. `keyDown` also drops the Esc itself
    ///   (`routeKeyDownThroughIME` owns any key that arrives mid-composition).
    /// - `deleteBackward:` during a composition is how a dead-key preedit
    ///   (Option+E → ´) hears Backspace; it must delete the pending preedit
    ///   grapheme, not be absorbed and leave the accent stuck on screen.
    ///
    /// `noop:` (Ctrl+C/Z/U/W/S/G, F1-F20) and `complete:` (F5, Opt+Esc) are
    /// absorbed too. Nothing in the responder chain implements either, so
    /// forwarding them makes `NSResponder` run off the end of the chain and
    /// play the system alert on those very common terminal keys.
    public override func doCommand(by selector: Selector) {
        if selector == #selector(NSResponder.cancelOperation(_:)),
           composition != nil {
            inputContext?.discardMarkedText()
            unmarkText()
            return
        }
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
            // Emptied: tell the system input context too, or it keeps the
            // dead key armed and the next letter still gets the accent.
            if composition == nil { inputContext?.discardMarkedText() }
            return
        }
        // Everything else: absorb silently. keyDown has already routed
        // the raw NSEvent through the encoder.
    }

    // MARK: - Helpers

    /// Pixel rectangle of the cursor cell in this view's local coordinate
    /// space (top-left origin, matching what the Metal renderer uses when
    /// placing the cursor). Feeds `firstRect(forCharacterRange:…)` so the
    /// IME candidate window anchors under the composition.
    func cursorCellRectInView() -> NSRect {
        let cursor = cursorCellInView()
        return cellRectInView(row: cursor.row, col: cursor.col)
    }

    /// The cursor's (row, col) as the IME anchors it — the snapshot's, or the
    /// test override.
    func cursorCellInView() -> (row: Int, col: Int) {
        #if DEBUG
        if let test = cursorOverrideForTests {
            return (row: test.row, col: test.col)
        }
        #endif
        return (row: cursorRowInView(), col: cursorColInView())
    }

    /// View-local rectangle of grid cell `(row, col)`, in the same coordinate
    /// space as `cursorCellRectInView()`.
    func cellRectInView(row: Int, col: Int) -> NSRect {
        let cw = metrics.cellWidth
        let ch = metrics.cellHeight
        // Route through the cell↔view single-source-of-truth helper so
        // the inset (horizontal + titlebar) can never drift between this
        // anchor and the renderer's drawn cursor.
        let origin = cellOriginPx(row: row, col: col)
        // Renderer renders row 0 at the top. In AppKit (flipped = false)
        // Y=0 sits at the *bottom*, so mirror: the cell's top-left in view
        // coords is (bounds.height - origin.y - ch).
        let yPointsFromBottom = max(0, bounds.height - origin.y - ch)
        return NSRect(x: origin.x, y: yPointsFromBottom, width: cw, height: ch)
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

    /// `text` laid out from the cursor cell, wrapped to the visible grid
    /// (derived from the view's bounds, the area that is actually shown, so
    /// it also holds mid-resize before the snapshot catches up), and the grid
    /// row its first line sits on. A preedit taller than the rows below the
    /// cursor slides up so its last line stays on screen.
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

    /// Reposition the preedit overlay subview against the current composition.
    /// Creates it lazily on first use; removes it entirely when composition
    /// ends so idle sessions keep a clean view hierarchy.
    ///
    /// Called from five places:
    ///   - `setMarkedText` / `unmarkText` / `insertText` (composition state
    ///     changed),
    ///   - `layout()` in `TerminalView` (bounds changed — keeps the overlay
    ///     anchored to the cursor cell while the user resizes the window
    ///     mid-composition),
    ///   - `render(snapshot:)` (the cursor cell moved under a pending
    ///     preedit — output, paste echo, or a resize's reflow snapshot,
    ///     which arrives after `layout()` has already run),
    ///   - `applyTheme(_:)` (palette swap — repaints the overlay in the new
    ///     theme fg/bg without waiting for the next IME callback).
    func refreshPreeditOverlay() {
        guard let composition else {
            preeditOverlay?.removeFromSuperview()
            preeditOverlay = nil
            needsDisplay = true
            return
        }
        // Width in cells, not graphemes. `String.count` counts grapheme
        // clusters, but CJK + wide emoji occupy TWO terminal cells per
        // grapheme — under-sizing by 50% leaves the theme-bg fill
        // bleeding through the right half of every wide glyph. Audit
        // terminal-ime F4. The layout weighs each grapheme by its East
        // Asian Width so the overlay matches what the grid will paint,
        // and wraps it at the right edge so it can't run out of the view.
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

    /// Unpack a packed 0x00RRGGBB integer into an `NSColor`. Extension-local
    /// because the existing SIMD converter in the renderer wants `SIMD4<Float>`,
    /// and the preedit overlay draws via Core Graphics which wants NSColor.
    fileprivate static func nsColor(fromRgb rgb: UInt32) -> NSColor {
        let r = CGFloat((rgb >> 16) & 0xFF) / 255.0
        let g = CGFloat((rgb >> 8)  & 0xFF) / 255.0
        let b = CGFloat(rgb & 0xFF) / 255.0
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1.0)
    }

    /// Discard any in-flight preedit composition when the hosting window
    /// resigns key. Without this, a partially-composed Pinyin/Romaji buffer
    /// survives Cmd-Tab — AppKit may tear down our `NSTextInputContext`
    /// state on deactivation, so the next Space / Enter / arrow the user
    /// types no longer routes through `insertText` and the preedit becomes
    /// a ghost overlay layered above the shell. Worse, in a multi-tab
    /// setup the stale preedit can bleed into the next-focused terminal.
    ///
    /// Wired from `TerminalView.viewDidMoveToWindow` alongside the existing
    /// `didBecomeKey` / `didResignKey` focus-event observers so there's a
    /// single owner of window-notification lifetimes. Called on the main
    /// queue by the notification observer; `[weak self]` in the caller
    /// guards against late-fire after the view is gone.
    func discardCompositionOnResignKey() {
        // Early-out when there's nothing to tear down. Avoids churning the
        // preedit overlay subview hierarchy for every Cmd-Tab on a window
        // the user isn't actively composing in.
        guard composition != nil else { return }
        // `discardMarkedText()` is the AppKit-side counterpart to
        // `unmarkText()` — it tells the system input context to drop its
        // cached state so the next keystroke starts a fresh composition.
        // Pair with `unmarkText()` so our own `composition` + overlay
        // state is cleared too.
        inputContext?.discardMarkedText()
        unmarkText()
    }

    #if DEBUG
    /// Test hook that exercises the same teardown path the window-resign
    /// observer runs. The real notification requires a live `NSWindow`
    /// transitioning out of key state, which the headless test harness
    /// can't synthesise reliably; this lets `IMETests` assert that a
    /// preedit buffer is cleared without booting a full windowed host.
    func _testOnly_simulateWindowResignKey() {
        discardKeyboardStateOnResignKey()
    }
    #endif

    /// IME-commit wrapper around `session.send(bytes)` — used ONLY by the
    /// NSTextInputClient commit path, the main `keyDown` encoder
    /// fall-through, and (since the issue-#30 batch) every xterm mouse report,
    /// so the mouse-reporting layer is observable in tests. Does NOT intercept
    /// paste, focus events, or the Ctrl-letter fast path: those remain on
    /// `session.send` / `session.sendImmediate` directly. Gated on DEBUG so the IME tests
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
