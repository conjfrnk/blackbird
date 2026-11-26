import AppKit
import Foundation
import BBCore

extension TerminalView {

    // MARK: - Mouse reporting

    func mouseReportingEnabled() -> Bool {
        guard let mode = currentSnapshot?.termMode else { return false }
        return mode.contains(.mouseReportClick) || mode.contains(.mouseMotion) || mode.contains(.mouseDrag)
    }

    func sgrMouseEnabled() -> Bool {
        currentSnapshot?.termMode.contains(.sgrMouse) ?? false
    }

    func utf8MouseEnabled() -> Bool {
        currentSnapshot?.termMode.contains(.utf8Mouse) ?? false
    }

    /// `NSEvent.clickCount` counts the system's click sequence, including the activation click
    /// AppKit never delivers to this view, so clicks are renumbered against the mousedowns received here.
    struct ClickSequenceMark: Equatable {
        let systemClickCount: Int
        let effectiveClickCount: Int
        let timestamp: TimeInterval
    }

    /// Keyed on count and time only, not the clicked cell: the window server already enforces
    /// slop, and a double-click straddling a cell boundary must stay a double-click.
    static func effectiveClickCount(previous: ClickSequenceMark?,
                                    clickCount: Int,
                                    timestamp: TimeInterval,
                                    doubleClickInterval: TimeInterval) -> Int {
        guard clickCount > 1 else { return clickCount }
        guard let previous, previous.systemClickCount == clickCount - 1 else { return 1 }
        let elapsed = timestamp - previous.timestamp
        guard elapsed >= 0, elapsed <= doubleClickInterval else { return 1 }
        return previous.effectiveClickCount + 1
    }

    public override func mouseDown(with event: NSEvent) {
        wakeRenderLoop()
        // Renumber before any early return: a click consumed by URL-open, window-drag or reporting still counts.
        let clicks = Self.effectiveClickCount(previous: lastMouseDownMark,
                                              clickCount: event.clickCount,
                                              timestamp: event.timestamp,
                                              doubleClickInterval: NSEvent.doubleClickInterval)
        lastMouseDownMark = ClickSequenceMark(systemClickCount: event.clickCount,
                                             effectiveClickCount: clicks,
                                             timestamp: event.timestamp)

        pendingLinkClick = nil
        didReportMouseDown = false
        lastReportedDragCell = nil

        // Not gated on mouse reporting: ⌘ has no bit in the xterm mouse protocol (shift=4, meta=8, ctrl=16),
        // so a TUI cannot act on it. The URL opens on mouseUp, so a ⌘-drag starting on a link still moves the window.
        if event.modifierFlags.contains(.command) {
            // Skip the titlebar inset: `bufferPointFromEvent` clamps those clicks to row 0, which may carry a link.
            let local = convert(event.locationInWindow, from: nil)
            let textAreaTop = bounds.height - titlebarOnlyTopInset
            let inTextArea = local.y < textAreaTop
            if inTextArea {
                let p = bufferPointFromEvent(event)
                let screenRow = Int(p.line) + (currentSnapshot?.displayOffset ?? 0)
                if let url = resolveClickURL(screenRow: screenRow, col: p.col) {
                    pendingLinkClick = PendingLinkClick(
                        url: url,
                        downEvent: event,
                        clickCount: clicks
                    )
                    return
                }
            }
        }
        let windowDragMask = Preferences.shared.windowDragModifier.modifierMask
        if !windowDragMask.isEmpty, event.modifierFlags.contains(windowDragMask) {
            window?.performDrag(with: event)
            return
        }
        let optionHeld = event.modifierFlags.contains(.option)
        if mouseReportingEnabled() && !optionHeld, session != nil {
            // Record what was emitted, not what was intended: the X10 encoder refuses coordinates
            // past 223, and a release must never reach the TUI without its press.
            didReportMouseDown = sendMouseEvent(event, button: 0, press: true)
            return
        }
        selectionController.beginSelection(with: event, clickCount: clicks)
    }

    public override func mouseUp(with event: NSEvent) {
        if let pending = pendingLinkClick {
            pendingLinkClick = nil
            if !pending.cancelled, pending.isStillAClick(at: event.locationInWindow) {
                urlOpener.open(pending.url)
            }
            _ = selectionController.endDrag()
            // The press was never reported, so the release must not be either.
            return
        }
        if selectionController.endDrag() {
            didReportMouseDown = false
            if Preferences.shared.copyOnSelect, selection != nil {
                copy(nil)
            }
            return
        }
        // Mirror what mousedown did. Re-deriving `mouseReportingEnabled()` emits an orphan release when
        // the press was consumed locally or the TUI flipped mouse mode between the two events.
        guard didReportMouseDown else { return }
        didReportMouseDown = false
        sendMouseEvent(event, button: 0, press: false)
    }

    /// macOS 26+ can end a left-button gesture without a `mouseUp`; treat it as a release with no click semantics.
    #if compiler(>=6.2)  // macOS 26 SDK
    @available(macOS 26.0, *)
    public override func mouseCancelled(with event: NSEvent) {
        pendingLinkClick = nil
        if selectionController.endDrag() {
            didReportMouseDown = false
            return
        }
        guard didReportMouseDown else { return }
        didReportMouseDown = false
        sendMouseEvent(event, button: 0, press: false)
    }
    #endif

    func bufferPointFromLocalPoint(_ local: CGPoint) -> BufferPoint {
        guard let snap = currentSnapshot else {
            TerminalView.logEarlyClickOnce()
            return BufferPoint(line: 0, col: 0)
        }
        // With `.fullSizeContentView`, `bounds.height` includes the titlebar region: pre-clamp y to the text area.
        let textAreaHeight = bounds.height - titlebarOnlyTopInset
        let clampedY = min(max(0, local.y), max(0, textAreaHeight))
        let clampedLocal = CGPoint(x: local.x, y: clampedY)
        return bufferPoint(
            forView: clampedLocal,
            cellWidth: metrics.cellWidth,
            cellHeight: metrics.cellHeight,
            viewportHeight: textAreaHeight,
            displayOffset: snap.displayOffset,
            cols: snap.cols,
            rows: snap.rows,
            historySize: snap.historySize,
            leftInsetPoints: TerminalView.horizontalContentInsetPoints
        )
    }

    public override func rightMouseDown(with event: NSEvent) {
        didReportRightMouseDown = false
        lastReportedDragCell = nil
        // Drop a resize context whose `rightMouseUp` never arrived (there is no rightMouseCancelled);
        // left in place it swallows this gesture's drag in `rightMouseDragged`.
        if windowResizeController.end() {
            endSynchronousResizePresentation()
        }
        let windowResizeMask = Preferences.shared.windowResizeModifier.modifierMask
        if !windowResizeMask.isEmpty, event.modifierFlags.contains(windowResizeMask), let win = window {
            windowResizeControllerStartFrame = win.frame
            windowResizeController.begin(
                localPoint: convert(event.locationInWindow, from: nil),
                in: bounds,
                startMouseGlobal: NSEvent.mouseLocation,
                windowFrame: win.frame
            )
            // This gesture drives `setFrame` itself, so AppKit never enters live-resize.
            beginSynchronousResizePresentation()
            return
        }
        let optionHeld = event.modifierFlags.contains(.option)
        guard mouseReportingEnabled() && !optionHeld, session != nil else {
            super.rightMouseDown(with: event)
            return
        }
        didReportRightMouseDown = sendMouseEvent(event, button: 2, press: true)
    }

    public override func rightMouseDragged(with event: NSEvent) {
        // There is no rightMouseCancelled: end the gesture once the right button is no longer down.
        if windowResizeController.isResizing, NSEvent.pressedMouseButtons & 0b10 == 0 {
            _ = windowResizeController.end()
            endSynchronousResizePresentation()
            return
        }
        if windowResizeController.isResizing, let win = window {
            let minContent = win.contentMinSize
            let chrome = win.frame.height - (win.contentView?.bounds.height ?? win.frame.height)
            let minWidth  = max(minContent.width, 200)
            let minHeight = max(minContent.height + chrome, 120)
            let mouse = NSEvent.mouseLocation
            // The screen the mouse is on, so the window can grow onto the next display.
            let bound = (NSScreen.screens.first { NSPointInRect(mouse, $0.frame) }
                         ?? win.screen)?.visibleFrame
            if let frame = windowResizeController.frameForCurrentDrag(
                currentMouseGlobal: mouse,
                minWidth: minWidth,
                minHeight: minHeight,
                boundingFrame: bound
            ) {
                win.setFrame(frame, display: true)
            }
            return
        }
        // AppKit delivers a right-button (and Ctrl+left) drag as `rightMouseDragged`, never as
        // `mouseMoved`, so this is the only motion source for a DEC 1002 / 1003 TUI.
        if didReportRightMouseDown {
            reportDragMotionIfNeeded(for: event, button: 2)
            return
        }
        super.rightMouseDragged(with: event)
    }

    public override func rightMouseUp(with event: NSEvent) {
        // Capture before `end()` clears the gesture state.
        let resizeMovedTheFrame = windowResizeController.isResizing
            && window?.frame != windowResizeControllerStartFrame
        if windowResizeController.end() {
            endSynchronousResizePresentation()
            // AppKit never posts `windowDidEndLiveResize` for this gesture, so settle explicitly. Only when
            // the frame moved: a ⌘-right-click without a drag also opens and ends a resize context.
            if resizeMovedTheFrame {
                (window?.windowController as? MainWindowController)?.settleAfterResizeGesture()
            }
            return
        }
        guard didReportRightMouseDown else {
            super.rightMouseUp(with: event)
            return
        }
        didReportRightMouseDown = false
        sendMouseEvent(event, button: 2, press: false)
    }

    // MARK: - Middle-mouse button reporting
    // xterm button 1 is middle. AppKit delivers every non-left/right button as `otherMouse*`;
    // only `buttonNumber` 2 is the middle button, and the others fall through to `super`.

    public override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 {
            didReportMiddleMouseDown = false
            lastReportedDragCell = nil
        }
        let optionHeld = event.modifierFlags.contains(.option)
        guard event.buttonNumber == 2, mouseReportingEnabled() && !optionHeld, session != nil else {
            super.otherMouseDown(with: event)
            return
        }
        didReportMiddleMouseDown = sendMouseEvent(event, button: 1, press: true)
    }

    public override func otherMouseDragged(with event: NSEvent) {
        if event.buttonNumber == 2, didReportMiddleMouseDown {
            reportDragMotionIfNeeded(for: event, button: 1)
            return
        }
        super.otherMouseDragged(with: event)
    }

    public override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2, didReportMiddleMouseDown else {
            super.otherMouseUp(with: event)
            return
        }
        didReportMiddleMouseDown = false
        sendMouseEvent(event, button: 1, press: false)
    }

    func anyEventMouseEnabled() -> Bool {
        guard let mode = currentSnapshot?.termMode else { return false }
        return mode.contains(.mouseMotion)
    }

    /// DEC 1003 no-button motion is xterm button 35 (32 + 3, "no button pressed").
    func reportPointerMotionIfNeeded(for event: NSEvent, screenRow: Int, col: Int) {
        guard session != nil, mouseReportingEnabled(), anyEventMouseEnabled(),
              !event.modifierFlags.contains(.option),
              lastReportedMotionCell != BBXYPoint(col: col, row: screenRow) else {
            return
        }
        lastReportedMotionCell = BBXYPoint(col: col, row: screenRow)
        sendMouseEvent(event, button: 35, press: true)
    }

    public override func scrollWheel(with event: NSEvent) {
        wakeRenderLoop()
        // Not the pointer position: AppKit delivers no `mouseMoved` for a scroll.
        hoverCoordinator.clearHoverDerivedState()
        guard let session else { super.scrollWheel(with: event); return }
        let optionHeld = event.modifierFlags.contains(.option)
        let mode = currentSnapshot?.termMode ?? []
        if mouseReportingEnabled() && !optionHeld {
            // macOS has already applied Natural scrolling: `scrollingDeltaY > 0` always means older
            // content, so deltaY > 0 is xterm wheel-up (button 64) and deltaY < 0 is button 65.
            // Shift turns a classic-wheel notch into a horizontal one (`scrollingDeltaX`, deltaY 0).
            var wheelDelta = event.scrollingDeltaY
            if wheelDelta == 0, event.modifierFlags.contains(.shift) {
                wheelDelta = event.scrollingDeltaX
            }
            let n = wheelAccumulator.lines(
                deltaY: wheelDelta,
                precise: event.hasPreciseScrollingDeltas,
                pointsPerLine: Double(metrics.cellHeight),
                linesPerNotch: 1
            )
            let button = n > 0 ? 64 : 65
            for _ in 0..<min(abs(n), Self.maxWheelUnitsPerEvent) {
                _ = sendMouseEvent(event, button: button, press: true)
            }
        } else if mode.contains(.altScreen), mode.contains(.alternateScroll), !optionHeld {
            // DEC 1007 alternate scroll: the alt screen has no history, so the wheel becomes cursor keys.
            let n = wheelAccumulator.lines(
                deltaY: event.scrollingDeltaY,
                precise: event.hasPreciseScrollingDeltas,
                pointsPerLine: Double(metrics.cellHeight),
                linesPerNotch: 3
            )
            if n != 0 {
                let key: KeyEncoder.SpecialKey = n > 0 ? .up : .down
                let one = encoder.encodeSpecial(
                    key,
                    modifiers: [],
                    applicationCursorKeys: mode.contains(.appCursor),
                    applicationKeypad: mode.contains(.appKeypad),
                    mode: mode
                )
                var bytes = Data()
                for _ in 0..<min(abs(n), Self.maxWheelUnitsPerEvent) { bytes.append(one) }
                if !bytes.isEmpty { sendToSession(bytes) }
            }
        } else {
            // Precise deltas are in points; `pointsPerLine = cellHeight / 2` doubles trackpad travel.
            let lines = wheelAccumulator.lines(
                deltaY: event.scrollingDeltaY,
                precise: event.hasPreciseScrollingDeltas,
                pointsPerLine: Double(metrics.cellHeight) / 2.0,
                linesPerNotch: 3
            )
            if lines != 0 {
                session.scroll(delta: Int32(clamping: lines))
            }
        }
    }

    public override func mouseDragged(with event: NSEvent) {
        wakeRenderLoop()
        if var pending = pendingLinkClick {
            if !pending.cancelled {
                guard !pending.isStillAClick(at: event.locationInWindow) else { return }
                pending.cancelled = true
                pendingLinkClick = pending
                let windowDragMask = Preferences.shared.windowDragModifier.modifierMask
                if !windowDragMask.isEmpty, event.modifierFlags.contains(windowDragMask) {
                    // `-[NSWindow performDrag:]` requires the original mouseDown event.
                    window?.performDrag(with: pending.downEvent)
                    return
                }
                selectionController.beginSelection(with: pending.downEvent,
                                                   clickCount: pending.clickCount)
            }
            // The press was never reported, so no drag report may follow it.
            _ = selectionController.handleDrag(with: event)
            return
        }
        if selectionController.handleDrag(with: event) { return }
        guard didReportMouseDown else { return }
        reportDragMotionIfNeeded(for: event, button: 0)
    }

    /// Button-held motion (xterm `Cb = button + 32`) for DEC 1002 / 1003. The caller has established the press was reported.
    private func reportDragMotionIfNeeded(for event: NSEvent, button: Int) {
        guard !event.modifierFlags.contains(.option),
              let mode = currentSnapshot?.termMode,
              mode.contains(.mouseMotion) || mode.contains(.mouseDrag),
              session != nil
        else { return }
        let p = bufferPointFromEvent(event)
        let screenRow = Int(p.line) + (currentSnapshot?.displayOffset ?? 0)
        let cell = BBXYPoint(col: p.col, row: screenRow)
        // Past the grid edge keep reporting although the clamped cell stops changing:
        // a TUI in copy/visual mode relies on the continuing stream to autoscroll.
        let local = convert(event.locationInWindow, from: nil)
        let insideGrid = bounds.contains(local)
            && local.y < bounds.height - titlebarOnlyTopInset
        if insideGrid {
            // Separate from `lastReportedMotionCell`: a TUI tracks drag motion and hover motion independently.
            guard lastReportedDragCell != cell else { return }
        }
        lastReportedDragCell = cell
        sendMouseEvent(event, button: button + 32, press: true)
    }

    func bufferPointFromEvent(_ event: NSEvent) -> BufferPoint {
        bufferPointFromLocalPoint(convert(event.locationInWindow, from: nil))
    }

    // MARK: - Mouse reporting helpers

    static let maxWheelUnitsPerEvent = 64

    @discardableResult
    func sendMouseEvent(_ event: NSEvent, button: Int, press: Bool) -> Bool {
        let loc = convert(event.locationInWindow, from: nil)
        // `Int(Double)` traps on NaN, infinity and out-of-range magnitudes: guard and clamp before the casts.
        guard loc.x.isFinite, loc.y.isFinite else { return false }
        let safeY = loc.y.sanitizedPixel
        let safeX = loc.x.sanitizedPixel
        let rowY = (bounds.height - titlebarOnlyTopInset - safeY) / metrics.cellHeight
        let colX = (safeX - TerminalView.horizontalContentInsetPoints) / metrics.cellWidth
        // Clamp to the live grid: a TUI must never be told about a cell that is not on its screen.
        let snap = currentSnapshot
        let maxCol: Int = snap.map { max(0, $0.cols - 1) } ?? 10_000
        let maxRow: Int = snap.map { max(0, $0.rows - 1) } ?? 10_000
        let col = max(0, min(maxCol, Int(colX)))
        let row = max(0, min(maxRow, Int(rowY)))
        // xterm folds Shift (4) and Ctrl (16) into the button code of every report. Meta (8) never
        // appears: ⌥ is the reporting bypass at every call site, and ⌘ has no bit.
        var modifiers = 0
        if event.modifierFlags.contains(.shift) { modifiers |= 4 }
        if event.modifierFlags.contains(.control) { modifiers |= 16 }
        guard let bytes = MouseReportEncoder.encode(
            sgr: sgrMouseEnabled(),
            button: button,
            press: press,
            col: col,
            row: row,
            modifiers: modifiers,
            utf8: utf8MouseEnabled()
        ) else { return false }
        sendToSession(bytes)
        return true
    }

}
