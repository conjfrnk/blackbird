import AppKit
import Foundation
import BBCore

/// Mouse event handling for `TerminalView`:
///
///   - **Selection gestures** — click / drag / shift-click, rectangular
///     (option-drag) mode, word-expand on double-click, line-expand on
///     triple-click, edge-autoscroll while dragging past the viewport.
///   - **Mouse reporting** — DEC modes 1000 / 1002 / 1003 (click /
///     motion / any-event) with SGR 1006 and X10 fallback encodings;
///     the TUI receives `CSI < button ; col ; row M/m`. Release-button
///     handling, wheel reporting (buttons 64/65), middle-mouse, and
///     the option-modifier escape hatch that lets users bypass
///     reporting when a TUI captures the wheel.
///   - **Modifier-drag window move / resize** — with the configured
///     `Preferences.windowDragModifier` / `windowResizeModifier` held
///     (default `.command`), left-drag moves the window and right-drag
///     resizes from the nearest corner. Matches Amethyst-style tiling
///     workflows and Blackbird's own keybinding table.
///
/// Stored state (`isDragging`, `selection`) lives on the
/// class body — `TerminalView.swift` — because Swift requires stored
/// properties on the declaring type. The selection-autoscroll timer +
/// direction were hoisted out of the view into the owned
/// `selectionAutoscroller` (`SelectionAutoscroller`).
///
/// Hover-tooltip + URL-highlight clears (`cancelHoverTooltip`,
/// `clearHoveredLink`, `clearCmdHoverURLMatch`) live in
/// `TerminalView+Hover.swift` and are called from `scrollWheel`'s
/// grid-just-moved cleanup below; their visibility is `internal` for
/// exactly that cross-file invocation.
///
/// `sendMouseEvent` and `expandSelectionUnderAnchor` live in this
/// file — mouse reporting and selection expansion are mouse-layer
/// responsibilities. `sendMouseEvent` stays `internal` because the
/// DEC 1003 any-event path in `TerminalView+Hover.swift`'s
/// `mouseMoved` fires one motion report per cell transition.
extension TerminalView {

    // MARK: - Mouse reporting

    func mouseReportingEnabled() -> Bool {
        guard let mode = currentSnapshot?.termMode else { return false }
        return mode.contains(.mouseReportClick) || mode.contains(.mouseMotion) || mode.contains(.mouseDrag)
    }

    func sgrMouseEnabled() -> Bool {
        currentSnapshot?.termMode.contains(.sgrMouse) ?? false
    }

    public override func mouseDown(with event: NSEvent) {
        // ⌘-click on a URL → open it. Runs before mouse-reporting and
        // selection so TUIs can't swallow the gesture. Restricted to
        // non-mouse-reporting context (or ⌥-held inside a TUI) so that
        // vim's own <C-click> binding still works when the TUI asks for
        // the click.
        //
        // If no URL is under the click, ⌘-drag acts like a titlebar drag
        // and moves the window (matches iTerm2 "⌘-drag to move"). Any view
        // can initiate window drag by calling `performDrag(with:)`; the
        // call blocks until the mouse is released, so this returns cleanly
        // without triggering the selection path below.
        // ⌘-click on a URL → open it. URL-open stays bound to ⌘ (the
        // universal link-open convention) regardless of the configurable
        // window-drag modifier handled just below.
        if event.modifierFlags.contains(.command) {
            let underlyingOption = event.modifierFlags.contains(.option)
            // Suppress URL resolution when the click landed in the
            // titlebar inset region (above the text grid). The
            // `bufferPointFromEvent` Y-clamp snaps titlebar clicks to
            // displayRow 0; if row 0 happens to carry an OSC 8 link
            // cell at the click column, the gesture would silently
            // open that URL instead of starting a window-drag. The
            // intent of ⌘-drag-from-titlebar is unambiguous (it's the
            // chrome region, not text). Audit M12.
            let local = convert(event.locationInWindow, from: nil)
            let textAreaTop = bounds.height - titlebarOnlyTopInset
            let inTextArea = local.y < textAreaTop
            if inTextArea, !mouseReportingEnabled() || underlyingOption {
                let p = bufferPointFromEvent(event)
                // Buffer-relative line → screen row. OSC 8 attribution is
                // keyed on screen-space cells since the snapshot only carries
                // the visible viewport. When the user is scrolled back into
                // history the regex path still honours buffer coordinates
                // (URLDetector output uses buffer lines).
                let screenRow = Int(p.line) + (currentSnapshot?.displayOffset ?? 0)
                if let url = resolveClickURL(screenRow: screenRow, col: p.col) {
                    urlOpener.open(url)
                    return
                }
            }
        }
        // Configured window-drag modifier (default ⌘) → move the window like a
        // titlebar drag. Any view can initiate a window drag by calling
        // `performDrag(with:)`; the call blocks until the mouse is released,
        // so this returns cleanly without triggering the selection path below.
        let windowDragMask = Preferences.shared.windowDragModifier.modifierMask
        if !windowDragMask.isEmpty, event.modifierFlags.contains(windowDragMask) {
            window?.performDrag(with: event)
            return
        }
        let optionHeld = event.modifierFlags.contains(.option)
        if mouseReportingEnabled() && !optionHeld, let session {
            sendMouseEvent(event, button: 0, press: true, session: session)
            return
        }
        // Not URL-open / window-drag / mouse-reporting → a selection gesture.
        selectionController.beginSelection(with: event)
    }

    public override func mouseUp(with event: NSEvent) {
        if selectionController.endDrag() { return }
        let optionHeld = event.modifierFlags.contains(.option)
        if mouseReportingEnabled() && !optionHeld, let session {
            sendMouseEvent(event, button: 0, press: false, session: session)
        }
    }

    /// The single view-local → buffer mapping: nil-snap guard (M-17),
    /// titlebar-Y pre-clamp (F13), and the grid math. `bufferPointFromEvent`
    /// converts an `NSEvent`'s window location and delegates here; the
    /// selection autoscroll timer — which has no `NSEvent` to pass — calls this
    /// directly with the raw mouse location (hence `internal`, reached from
    /// `SelectionController`). Audit terminal-view-2 F2.
    func bufferPointFromLocalPoint(_ local: CGPoint) -> BufferPoint {
        // M-17 / pass-2: surface the pre-first-publish click race
        // before silently mapping into a synthetic 80×24 zero-history
        // grid. Pulling the nil-snap path out into a logged early-
        // return makes the regression discoverable in Release;
        // `logEarlyClickOnce` (on `TerminalView` proper) holds a one-shot
        // lock so repeated early clicks still produce at most one log line
        // per process.
        guard let snap = currentSnapshot else {
            TerminalView.logEarlyClickOnce()
            return BufferPoint(line: 0, col: 0)
        }
        // `.fullSizeContentView` means `bounds.height` includes the titlebar
        // region the text grid doesn't occupy. `bufferPoint` below derives the
        // display-row Y via `viewportHeight - local.y`; a click in the titlebar
        // region (AppKit Y-up → high y) would push that subtraction negative
        // and snap to row 0. Pre-clamp y to the text-area range so
        // titlebar-region clicks land on the first-real-row edge instead of
        // silently re-attributing to row 0. Audit findbar-selection F13.
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
        // Configured resize modifier (default ⌘) + right-drag → resize the
        // window from the corner nearest the click. Matches the borderless-
        // window idiom from apps like iTerm2 and VS Code: modifier-drag moves,
        // modifier-right-drag resizes. Anchor the OPPOSITE corner so dragging
        // from (say) the top-right pulls the top-right while bottom-left stays
        // pinned.
        let windowResizeMask = Preferences.shared.windowResizeModifier.modifierMask
        if !windowResizeMask.isEmpty, event.modifierFlags.contains(windowResizeMask), let win = window {
            windowResizeController.begin(
                localPoint: convert(event.locationInWindow, from: nil),
                in: bounds,
                startMouseGlobal: NSEvent.mouseLocation,
                windowFrame: win.frame
            )
            return
        }
        // ⌥+right-click escapes a TUI's mouse capture just like ⌥+left-click
        // and ⌥+scroll do elsewhere. Without this, vim / tmux / htop eat
        // every right-click and the Copy/Paste context menu is unreachable.
        let optionHeld = event.modifierFlags.contains(.option)
        guard mouseReportingEnabled() && !optionHeld, let session else {
            super.rightMouseDown(with: event)
            return
        }
        sendMouseEvent(event, button: 2, press: true, session: session)
    }

    public override func rightMouseDragged(with event: NSEvent) {
        if windowResizeController.isResizing, let win = window {
            // Clamp to contentMinSize (set by MainWindowController). The
            // controller pins the dragged edge on underflow; we just supply the
            // window-derived minimums.
            let minContent = win.contentMinSize
            let chrome = win.frame.height - (win.contentView?.bounds.height ?? win.frame.height)
            let minWidth  = max(minContent.width, 200)
            let minHeight = max(minContent.height + chrome, 120)
            let mouse = NSEvent.mouseLocation
            // Bound the dragged edges to the visibleFrame of the screen the
            // MOUSE is on (falling back to the window's screen): the gesture
            // applies a delta to the frame corner, so a grab far from the
            // corner could push the dragged edge past the monitor border /
            // menu bar / Dock — something native edge-drag can't do. Keying
            // the bound off the mouse's screen keeps multi-monitor drags
            // native too: carry the mouse onto the next display and the
            // window grows there.
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
        super.rightMouseDragged(with: event)
    }

    public override func rightMouseUp(with event: NSEvent) {
        if windowResizeController.end() {
            return
        }
        let optionHeld = event.modifierFlags.contains(.option)
        guard mouseReportingEnabled() && !optionHeld, let session else {
            super.rightMouseUp(with: event)
            return
        }
        sendMouseEvent(event, button: 2, press: false, session: session)
    }

    // MARK: - Middle-mouse button reporting
    //
    // xterm mouse protocol: button 1 = middle. Many TUIs (nvim, less,
    // tmux) expect middle-click to paste or to trigger a custom binding;
    // without these hooks the event never reaches the shell. Mirrors the
    // left/right handlers: ⌥ escapes reporting so the user can still
    // paste locally over a TUI. Audit terminal-view-2 F9.

    public override func otherMouseDown(with event: NSEvent) {
        let optionHeld = event.modifierFlags.contains(.option)
        guard mouseReportingEnabled() && !optionHeld, let session else {
            super.otherMouseDown(with: event)
            return
        }
        sendMouseEvent(event, button: 1, press: true, session: session)
    }

    public override func otherMouseDragged(with event: NSEvent) {
        let optionHeld = event.modifierFlags.contains(.option)
        guard mouseReportingEnabled() && !optionHeld, let session,
              anyEventMouseEnabled() || dragReportingEnabled() else {
            super.otherMouseDragged(with: event)
            return
        }
        // xterm motion reporting: button + 32 for drag-with-button-held.
        sendMouseEvent(event, button: 1 + 32, press: true, session: session)
    }

    public override func otherMouseUp(with event: NSEvent) {
        let optionHeld = event.modifierFlags.contains(.option)
        guard mouseReportingEnabled() && !optionHeld, let session else {
            super.otherMouseUp(with: event)
            return
        }
        sendMouseEvent(event, button: 1, press: false, session: session)
    }

    /// True when the TUI enabled DEC mode 1003 (any-event tracking —
    /// cursor motion without a button). Implied by the SGR mouse mode
    /// bit being set alongside motion; narrower predicate than
    /// `mouseReportingEnabled` so we only fire no-button motion
    /// reports when explicitly asked. Audit terminal-view-2 F14.
    func anyEventMouseEnabled() -> Bool {
        guard let mode = currentSnapshot?.termMode else { return false }
        return mode.contains(.mouseMotion)
    }

    /// DEC mode 1003 (any-event tracking) motion report. When a TUI asked for
    /// motion reports without requiring a button, emit one even in the no-button
    /// case — xterm uses button 35 (32 + the "release" bit 3, which the protocol
    /// reads as "no button currently pressed"). Fires ONLY when the hover cell
    /// actually changed (`lastReportedMotionCell`) so we don't flood the PTY at
    /// pointer-update cadence; Option bypasses reporting. Driven by
    /// `TerminalView+Hover`'s `mouseMoved` (the AppKit entry point), but the
    /// emission is a mouse-reporting concern so it lives here. Audit
    /// terminal-view-2 F14.
    func reportPointerMotionIfNeeded(for event: NSEvent, screenRow: Int, col: Int) {
        guard let session, mouseReportingEnabled(), anyEventMouseEnabled(),
              !event.modifierFlags.contains(.option),
              lastReportedMotionCell != BBXYPoint(col: col, row: screenRow) else {
            return
        }
        lastReportedMotionCell = BBXYPoint(col: col, row: screenRow)
        sendMouseEvent(event, button: 35, press: true, session: session)
    }

    private func dragReportingEnabled() -> Bool {
        guard let mode = currentSnapshot?.termMode else { return false }
        return mode.contains(.mouseDrag)
    }

    // The window-resize gesture state + frame math live in
    // `WindowResizeController` (`windowResizeController` on the view); the
    // rightMouse* overrides above just drive `begin` / `frameForCurrentDrag`
    // / `end`.

    public override func scrollWheel(with event: NSEvent) {
        // Scrolling moves the grid beneath the pointer — the cell the
        // user was dwelling on now has different content, so any pending
        // tooltip would pop up with a stale URL. Cancel both the pending
        // reveal and the accent underline; the next mouseMoved delivery
        // will repaint them against the fresh cell if appropriate.
        // Cancel the pending tooltip + the accent underline + the ⌘-hover
        // range, and drop the cached hover cell: the renderer's range is keyed
        // on buffer line but the *pointer* is at a fixed (row, col) whose buffer
        // line flipped with the scroll, and the stale cell would make the next
        // mouseMoved early-return on the same (row, col) and leave the link id
        // at zero. This is exactly `clearHover()`.
        hoverCoordinator.clearHover()
        guard let session else { super.scrollWheel(with: event); return }
        // ⌥-scroll bypasses mouse reporting so the user can always reach
        // scrollback locally, even inside a TUI that captured the wheel.
        // Matches the ⌥-click escape on mouseDown.
        let optionHeld = event.modifierFlags.contains(.option)
        if mouseReportingEnabled() && !optionHeld {
            // Mouse mode: forward as SGR/X10 scroll events.
            // xterm wheel-up (button 64) = "show older content" (less
            // scrolls back). wheel-down (button 65) = "show newer
            // content" (less advances).
            //
            // macOS `scrollingDeltaY` is pre-inverted by the system —
            // it reports the direction the user expects CONTENT to
            // move, not the raw finger / wheel motion. So:
            //
            //   Natural ON  + swipe up → deltaY > 0 (content goes up,
            //   user wants newer content from below) → button 65.
            //   Natural OFF + swipe up → deltaY < 0 (content goes
            //   down, user wants older content from above) → button 64.
            //
            // Pre-M7 the mapping was inverted (deltaY > 0 → button 64),
            // which gave the right answer for Natural ON via wishful
            // thinking but was backwards for Natural OFF — `less` /
            // `tmux` scrolled in the wrong direction. Audit M7.
            if event.scrollingDeltaY > 0 {
                sendMouseEvent(event, button: 65, press: true, session: session)
            } else if event.scrollingDeltaY < 0 {
                sendMouseEvent(event, button: 64, press: true, session: session)
            }
        } else {
            // Normal mode: scroll the display through scrollback history.
            // Two input types to reconcile:
            //
            //   Trackpad / Magic Mouse (hasPreciseScrollingDeltas == true):
            //     scrollingDeltaY is in points. Scaling by cellHeight gives
            //     pixel-accurate scrolling (move the pointer one row's worth
            //     of points → scroll one row). Multiply by 2 so a casual
            //     two-finger flick covers ~2 screenfuls, matching Terminal.app
            //     feel.
            //
            //   Classic wheel (hasPreciseScrollingDeltas == false):
            //     scrollingDeltaY is ~1 per physical click. 3 lines per click
            //     is the common terminal-emulator default (alacritty, kitty).
            //
            // Rounding away from zero ensures tiny trackpad flicks register
            // at least one line instead of truncating to 0. Clamp before
            // casting to Int32 — a misbehaving input device or a NaN delta
            // would otherwise trap the app in `Int32(Double)` on overflow.
            let delta = event.scrollingDeltaY
            let rawUnclamped: Double = event.hasPreciseScrollingDeltas
                ? Double(delta) / Double(metrics.cellHeight) * 2.0
                : Double(delta) * 3.0
            let raw = rawUnclamped.isFinite ? rawUnclamped : 0
            let clamped = min(Double(Int32.max), max(Double(Int32.min), raw))
            let lines = Int32(clamped.rounded(.toNearestOrAwayFromZero))
            if lines != 0 {
                session.scroll(delta: lines)
            }
        }
    }

    public override func mouseDragged(with event: NSEvent) {
        if selectionController.handleDrag(with: event) { return }
        // No selection in progress — forward to PTY if the app asked for
        // motion/drag reporting.
        if let mode = currentSnapshot?.termMode,
           (mode.contains(.mouseMotion) || mode.contains(.mouseDrag)),
           let session {
            sendMouseEvent(event, button: 32, press: true, session: session)
        }
    }

    func bufferPointFromEvent(_ event: NSEvent) -> BufferPoint {
        // `bufferPointFromLocalPoint` owns the whole mapping — the nil-snap
        // guard (M-17), the titlebar-Y pre-clamp (F13), and the grid math.
        // This entry point only converts the event's window location into
        // view-local coordinates first.
        bufferPointFromLocalPoint(convert(event.locationInWindow, from: nil))
    }

    // MARK: - Mouse reporting helpers

    /// Emit a single xterm mouse report. Internal rather than private
    /// because the DEC 1003 any-event path in
    /// `TerminalView+Hover.swift`'s `mouseMoved` reuses it for the
    /// no-button motion case.
    func sendMouseEvent(_ event: NSEvent, button: Int, press: Bool, session: TerminalSession) {
        let loc = convert(event.locationInWindow, from: nil)
        // Paranoia. `event.locationInWindow` is a CGFloat; a misbehaving
        // input device or a bridged NaN / Infinity can slip through, and
        // `Int(NaN)` / `Int(±Inf)` trap. Guard before the cast rather
        // than after — the scrollWheel path already uses this pattern.
        guard loc.x.isFinite, loc.y.isFinite else { return }
        // Audit fix-#19 (2026-05-11): clamp magnitude to `CGFloat.sanePx`
        // BEFORE the Int() cast. `Int(Double)` traps when the magnitude
        // exceeds Int.max (~9.2e18 on 64-bit) — `loc.y` is finite but bounded
        // only by Double.greatestFiniteMagnitude (~1.79e308), so a bridged
        // CGPoint with a finite-but-absurd value (fault injection,
        // accessibility tool synthesising motion, exotic tablet driver)
        // would trap inside the `min(maxCol, Int(colX))` expression below.
        // `loc` is already guaranteed finite by the guard above, so
        // `sanitizedPixel`'s non-finite→0 branch is dead here — the live
        // path is `min(max(0, loc.*), sanePx)`, the same clamp
        // Selection.bufferPoint applies. (see `CGFloat.sanitizedPixel`)
        let safeY = loc.y.sanitizedPixel
        let safeX = loc.x.sanitizedPixel
        let rowY = (bounds.height - titlebarOnlyTopInset - safeY) / metrics.cellHeight
        // Subtract the L inset so a click at view-x=horizontalContentInsetPoints
        // maps to col 0 (matches the renderer's cell origin). Negative results
        // collapse via the max(0, …) clamp below — clicks inside the inset
        // strip report col 0, never a phantom -1.
        let colX = (safeX - TerminalView.horizontalContentInsetPoints) / metrics.cellWidth
        // Clamp to a sane cell range so oversized coordinates (user
        // scrolled the window off the right edge of a 200k-col display)
        // don't overflow Int32 when MouseReportEncoder.encode stringifies them.
        // Division of a finite by a positive cellWidth/Height is finite,
        // so no second isFinite check is needed.
        let maxCol = 10_000, maxRow = 10_000
        let col = max(0, min(maxCol, Int(colX)))
        let row = max(0, min(maxRow, Int(rowY)))
        guard let bytes = MouseReportEncoder.encode(
            sgr: sgrMouseEnabled(),
            button: button,
            press: press,
            col: col,
            row: row
        ) else { return }
        session.send(bytes)
    }

}
