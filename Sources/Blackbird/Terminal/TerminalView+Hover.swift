import AppKit
import Foundation
import BBCore
import os

/// Hover and ⌘-held URL highlighting for `TerminalView`. Two sibling
/// concerns kept in one extension because they share a large piece of
/// state:
///
///   - **OSC 8 hover** — when the pointer rests on a cell carrying an
///     explicit `link_id`, we underline every cell with that id and
///     reveal a tooltip after a 500 ms dwell. Always-on; author-
///     asserted links deserve a visible affordance.
///   - **⌘-held regex hover** — holding ⌘ over a regex-detected URL
///     in plain scrollback underlines that URL's cell range and flips
///     the cursor to `pointingHand`. Matches Terminal.app's "hold ⌘
///     to reveal links" model. Cached match list keyed on
///     `snapshot.sequenceID` keeps the O(rows × cols) scan off the
///     mouse-move hot path.
///
/// Focus safety: `didResignKeyNotification` (see the main class's
/// window observer) force-resets the modifier + hover state so a
/// missed ⌘-release during Cmd-Tab can't keep the highlight painted
/// across focus boundaries. `mouseMoved` also reconciles the modifier
/// state against `NSEvent.modifierFlags` on every delivery.
///
/// Every property this file mutates is declared on the class body
/// (`TerminalView.swift`) because Swift requires stored properties
/// on the declaring type. Visibility was relaxed from `private` to
/// internal for exactly this extension split — see the inline
/// comments next to each property.
extension TerminalView {

    // MARK: - Hover dwell tooltip + accent underline

    /// Install a full-bounds tracking area that delivers `mouseMoved` even
    /// when no buttons are down. Recreated on every bounds change; the
    /// `.inVisibleRect` option makes AppKit re-resolve the rect on each
    /// delivery so tab splits / window resizes don't leave a stale region.
    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = hoverTrackingArea {
            removeTrackingArea(existing)
            hoverTrackingArea = nil
        }
        let ta = NSTrackingArea(
            rect: .zero,
            options: [
                .mouseMoved,
                .mouseEnteredAndExited,
                // `.cursorUpdate` is what drives AppKit's dispatch of
                // `cursorUpdate(with:)`. Without it the override is dead
                // code — pointer style stays the default `.iBeam` even
                // while the pointer is over a clickable OSC 8 / ⌘-hover
                // URL. With it, AppKit queries us whenever the pointer
                // crosses in or when `invalidateCursorRects` is called.
                .cursorUpdate,
                .activeInKeyWindow,
                .inVisibleRect,
            ],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(ta)
        hoverTrackingArea = ta
    }

    public override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        // Reconcile ⌘-held state with the live event flags. `flagsChanged`
        // doesn't fire when a key release happens while another window is
        // key (Cmd-Tab release case), so a ⌘-up missed during focus loss
        // would otherwise leave us painting the highlight forever.
        let cmdChanged = syncCmdModifierHeld(fromEventFlags: event.modifierFlags)
        let point = bufferPointFromEvent(event)
        let screenRow = Int(point.line) + (currentSnapshot?.displayOffset ?? 0)
        let col = point.col
        updateHover(screenRow: screenRow, col: col, locationInWindow: event.locationInWindow)
        // Run the ⌘-hover pass when either the modifier flipped OR the
        // hover cell moved. `updateHover` already updates `lastHoverCell`
        // before returning, so we see the new cell here.
        if cmdChanged || cmdModifierHeld {
            reevaluateCmdHoverHighlight()
        }
        // DEC mode 1003 — any-event tracking. When the TUI has asked for
        // motion reports (without requiring a button), emit a motion
        // event even in the no-button case. xterm uses button 35 (32 +
        // 3 "release", which the protocol uses to mean "no button
        // currently pressed"). Fires only when the hover cell actually
        // changed so we don't flood the PTY at pointer-update cadence.
        // Audit terminal-view-2 F14.
        if let session, mouseReportingEnabled(), anyEventMouseEnabled(),
           !event.modifierFlags.contains(.option),
           lastReportedMotionCell != BBXYPoint(col: col, row: screenRow) {
            lastReportedMotionCell = BBXYPoint(col: col, row: screenRow)
            sendMouseEvent(event, button: 35, press: true, session: session)
        }
    }

    // `BBXYPoint` and `lastReportedMotionCell` are declared on the
    // class body in `TerminalView.swift`. Extensions can't add stored
    // properties; see the main file for their definitions.

    public override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        clearHover()
    }

    private func updateHover(screenRow: Int, col: Int, locationInWindow: NSPoint) {
        // Resolve the OSC 8 link id for the cell under the pointer. A
        // test-supplied fake may override; otherwise consult the live
        // snapshot directly. `linkID` bounds-checks internally, so an
        // out-of-grid coordinate just returns 0 (which clears the hover).
        //
        // Gate on `OSC8URLPolicy` so cells whose OSC 8 target fails the
        // scheme allowlist (javascript:, data:, custom handlers) don't
        // paint a hover underline or fire a tooltip. The click path is
        // already blocked upstream — showing an affordance for a no-op
        // click would be misleading.
        let newLinkID: UInt32 = {
            #if DEBUG
            if let override = hyperlinkResolverOverride {
                // Fakes answer via osc8URL — collapse URL presence into a
                // stable non-zero id so the renderer underline path still
                // fires without us needing a real link-id table in tests.
                return override.osc8URL(row: screenRow, col: col) != nil ? UInt32(bitPattern: Int32(-1)) : 0
            }
            #endif
            guard let snap = currentSnapshot else { return 0 }
            let id = snap.linkID(row: screenRow, col: col)
            guard id != 0,
                  let raw = snap.linkURL(id: id),
                  let url = URL(string: raw),
                  OSC8URLPolicy.isAllowed(url)
            else { return 0 }
            return id
        }()

        // Same cell as last move → nothing to update except the tooltip
        // position is already correct. Bail to avoid timer churn.
        if let last = lastHoverCell, last.row == screenRow, last.col == col {
            return
        }
        lastHoverCell = (row: screenRow, col: col)

        if newLinkID != hoveredLinkID {
            hoveredLinkID = newLinkID
            // Redraw so the accent underline picks up / drops off the cells
            // sharing the new hovered id.
            needsDisplay = true
        }

        // Reset any pending tooltip when the pointer moves to a different
        // cell. Production matches VS Code / iTerm2 feel: tooltip appears
        // only after a steady dwell.
        hoverTooltipItem?.cancel()
        hoverTooltipItem = nil
        dismissHoverTooltip()

        guard newLinkID != 0 else { return }

        // Resolve the URL so the tooltip shows the href, not just "there is
        // a link here". For the test fake this goes through osc8URL; for
        // production it's the snapshot's link table.
        let resolvedURLString: String? = {
            #if DEBUG
            if let override = hyperlinkResolverOverride {
                return override.osc8URL(row: screenRow, col: col)?.absoluteString
            }
            #endif
            return currentSnapshot?.linkURL(id: newLinkID)
        }()
        guard let urlString = resolvedURLString else { return }

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.showHoverTooltip(urlString: urlString, anchor: locationInWindow)
        }
        hoverTooltipItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func clearHover() {
        lastHoverCell = nil
        cancelHoverTooltip()
        clearHoveredLink()
        clearCmdHoverURLMatch()
    }

    // MARK: - ⌘-held regex URL highlight

    /// Drop the ⌘-hover underline and tell the renderer so the next frame
    /// repaints cleanly. Separate from `clearHoveredLink` (OSC 8 hover)
    /// because the two states live independently — an OSC 8 cell under
    /// the pointer keeps its underline even when ⌘ is released, and vice
    /// versa.
    ///
    /// Unconditionally calls through to `setCmdHoverRange` even when the
    /// local `cmdHoverURLMatch` is already nil: the renderer's dedup
    /// guard makes the no-op free, and skipping the call would trap a
    /// renderer-state desync if our local state ever drifted (e.g., a
    /// direct test setter). Only the `needsDisplay` nudge is gated on
    /// "something actually changed locally".
    func clearCmdHoverURLMatch() {
        let wasSet = cmdHoverURLMatch != nil
        cmdHoverURLMatch = nil
        renderer.setCmdHoverRange(bufferLine: 0, startCol: -1, endCol: -1)
        if wasSet { needsDisplay = true }
    }

    /// Refresh the regex-URL match cache when the current snapshot has a
    /// new sequence id. Called only on the ⌘-hover fast path so the O(rows
    /// × cols) scan runs at most once per snapshot instead of once per
    /// `mouseMoved` delivery. Audit cwd-hyperlink F7.
    private func refreshURLMatchCacheIfNeeded() {
        guard let snap = currentSnapshot else {
            cachedURLMatches = []
            cachedURLMatchesSeq = nil
            // Snapshot disappeared — drop the hover cell too. Its row was
            // computed against the now-vanished snapshot's displayOffset
            // and would mis-translate against any successor.
            lastHoverCell = nil
            return
        }
        if cachedURLMatchesSeq != snap.sequenceID {
            // Capture whether we had a populated cache before — only a
            // *replacement* invalidates the previously-baked hover row,
            // not the initial population on a fresh view (where mouseMoved
            // may have already primed lastHoverCell against this very
            // snapshot before any cmd-hover refresh ran).
            let cacheWasPopulated = (cachedURLMatchesSeq != nil)
            cachedURLMatches = URLDetector.scan(snapshot: snap)
            cachedURLMatchesSeq = snap.sequenceID
            if cacheWasPopulated {
                // `lastHoverCell.row` is screen-space — it was baked
                // against the PREVIOUS snapshot's displayOffset at
                // mouseMoved time. When the snapshot identity changes,
                // that baked offset goes stale: any successor whose
                // displayOffset shifted (output between mouseMoved and
                // reevaluate, alt-screen toggle, scroll) makes
                // `last.row - snap.displayOffset` resolve to a buffer
                // line one or more rows off, and the cmd-hover underline
                // lands on the wrong row. The next real mouseMoved will
                // repopulate this against the live snapshot; dropping
                // it here is the safe fallback for the in-between
                // reevaluate calls (flagsChanged, snapshot updates) that
                // don't pass a fresh event.
                lastHoverCell = nil
            }
        }
    }

    /// Resolve the regex URL under the current hover cell (if any) and push
    /// its cell range to the renderer as a ⌘-hover highlight. OSC 8 wins
    /// on cells with an explicit link id — the existing hover underline
    /// and tooltip already handle those, and re-painting them here would
    /// double the redraw work.
    ///
    /// Called whenever the hover cell, current snapshot, or
    /// `cmdModifierHeld` changes. Safe to call with no snapshot, no
    /// hover cell, or no window focus — it only pushes updates to the
    /// renderer when the resolved range differs from what the renderer
    /// already knows.
    func reevaluateCmdHoverHighlight() {
        guard cmdModifierHeld,
              let last = lastHoverCell,
              let snap = currentSnapshot
        else {
            clearCmdHoverURLMatch()
            return
        }
        // OSC 8 cells already carry their own hover affordance; skip the
        // regex overlay so we don't paint two underlines on the same run.
        if snap.linkID(row: last.row, col: last.col) != 0 {
            clearCmdHoverURLMatch()
            return
        }
        refreshURLMatchCacheIfNeeded()
        let bufferLine = Int32(last.row - snap.displayOffset)
        let point = BufferPoint(line: bufferLine, col: last.col)
        guard let match = URLDetector.match(at: point, in: cachedURLMatches) else {
            #if DEBUG
            // Diagnosability: this branch silently clears. If the cache
            // is populated for this buffer line but no match covers the
            // pointer cell, the user experience is "highlight flickers
            // off for no apparent reason" — log the near-miss so a
            // future column-mapping or wrap-join regression is
            // observable instead of invisible.
            if !cachedURLMatches.isEmpty,
               cachedURLMatches.contains(where: { $0.line == bufferLine }) {
                Self.hoverLogger.debug(
                    "cmd-hover: cache populated for line \(bufferLine, privacy: .public) but match(at:) miss at col \(last.col, privacy: .public)"
                )
            }
            #endif
            clearCmdHoverURLMatch()
            return
        }
        guard OSC8URLPolicy.isAllowed(match.url) else {
            // Policy reject (non-http/https/ftp/mailto). Intentional —
            // don't log; matches `resolveClickURL`'s silent drop.
            clearCmdHoverURLMatch()
            return
        }
        // Same cell range as last time → nothing to push. Prevents
        // needsDisplay churn on every intra-URL pointer move.
        if let existing = cmdHoverURLMatch,
           existing.line == match.line,
           existing.startCol == match.startCol,
           existing.endCol == match.endCol {
            return
        }
        cmdHoverURLMatch = match
        renderer.setCmdHoverRange(
            bufferLine: match.line,
            startCol: Int32(match.startCol),
            endCol: Int32(match.endCol)
        )
        needsDisplay = true
    }

    /// Sync `cmdModifierHeld` with the latest modifier state. Called from
    /// `flagsChanged` (fast path) and from `mouseMoved` (reconcile path —
    /// `flagsChanged` doesn't fire if the key release happened while
    /// another window was key). Returns `true` when the state actually
    /// changed so callers can drive re-evaluation.
    @discardableResult
    func syncCmdModifierHeld(fromEventFlags flags: NSEvent.ModifierFlags) -> Bool {
        let nowHeld = flags.contains(.command)
        guard nowHeld != cmdModifierHeld else { return false }
        cmdModifierHeld = nowHeld
        return true
    }

    public override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        guard syncCmdModifierHeld(fromEventFlags: event.modifierFlags) else { return }
        reevaluateCmdHoverHighlight()
        // Cursor should refresh immediately when the modifier changes
        // (AppKit's cursorUpdate normally fires on mouse movement).
        window?.invalidateCursorRects(for: self)
    }

    /// AppKit queries this when the pointer crosses into the view's
    /// cursor rect or when `invalidateCursorRects` is called. Return
    /// `pointingHand` whenever the pointer is over something clickable —
    /// an OSC 8 link (always) or a regex URL while ⌘ is held. That gives
    /// the user a consistent affordance matching the underline state.
    public override func cursorUpdate(with event: NSEvent) {
        if hoveredLinkID != 0 || cmdHoverURLMatch != nil {
            NSCursor.pointingHand.set()
        } else {
            super.cursorUpdate(with: event)
        }
    }

    /// Clear all modifier / hover state. Called when the window resigns
    /// key (tab switch, Cmd-Tab to another app) so stale "⌘ held" state
    /// from a missed flagsChanged can't survive focus boundaries. Also
    /// drops `lastHoverCell` and the URL-match cache so the next
    /// `mouseMoved` after focus regain re-resolves from scratch (the
    /// view may have missed several snapshots during focus loss).
    func resetModifierAndHoverState() {
        cmdModifierHeld = false
        lastHoverCell = nil
        cachedURLMatches = []
        cachedURLMatchesSeq = nil
        clearCmdHoverURLMatch()
        clearHoveredLink()
        cancelHoverTooltip()
    }

    /// Cancel any pending tooltip reveal and drop the tooltip panel if it's
    /// up. Does NOT clear the accent underline / hovered-link id — that
    /// belongs to `clearHoveredLink()`. Called from keyDown so typing
    /// dismisses the dwell tooltip without simultaneously stripping the
    /// underline off the link the user is still hovering. (Previously this
    /// did clear the link id too, so a single keystroke killed the underline
    /// until the pointer physically moved off and back onto the link.)
    func cancelHoverTooltip() {
        hoverTooltipItem?.cancel()
        hoverTooltipItem = nil
        dismissHoverTooltip()
    }

    /// Drop the accent underline + hovered-link id and force a repaint.
    /// Called from `clearHover` (mouseExited / scroll-invalidates-cache) and
    /// `deinit`. Decoupled from the tooltip so keyDown can dismiss the
    /// tooltip alone without disturbing the underline.
    func clearHoveredLink() {
        guard hoveredLinkID != 0 else { return }
        hoveredLinkID = 0
        // Push the cleared id straight to the renderer so the next frame
        // drops the underline even before the usual draw-path plumbing runs.
        renderer.setHoveredLinkID(0)
        needsDisplay = true
    }

    private func showHoverTooltip(urlString: String, anchor: NSPoint) {
        guard let window else { return }
        let panel: NSPanel
        let label: NSTextField
        if let existingPanel = hoverTooltipPanel, let existingLabel = hoverTooltipLabel {
            panel = existingPanel
            label = existingLabel
        } else {
            // .nonactivatingPanel keeps the terminal's key-window / first-
            // responder state intact while the tooltip is visible, so a
            // hover-peek doesn't disrupt typing.
            panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 200, height: 20),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: true
            )
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = true
            panel.hasShadow = true
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.ignoresMouseEvents = true

            let container = NSView(frame: .zero)
            container.wantsLayer = true
            container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            container.layer?.cornerRadius = 4
            container.layer?.borderWidth = 0.5
            container.layer?.borderColor = NSColor.separatorColor.cgColor

            let lbl = NSTextField(labelWithString: "")
            lbl.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
            lbl.textColor = .labelColor
            lbl.lineBreakMode = .byTruncatingMiddle
            lbl.maximumNumberOfLines = 1
            container.addSubview(lbl)
            panel.contentView = container

            hoverTooltipPanel = panel
            hoverTooltipLabel = lbl
            label = lbl
        }
        // Clamp the displayed URL. A misbehaving remote could stuff
        // megabytes of OSC 8 target into the link table; sizing an
        // NSTextField against it would hang the UI and push the panel
        // off-screen. 512 chars covers every realistic URL; anything
        // over that gets an ellipsis so the user still sees the origin.
        let maxDisplay = 512
        label.stringValue = urlString.count > maxDisplay
            ? String(urlString.prefix(maxDisplay)) + "…"
            : urlString
        label.sizeToFit()
        let padX: CGFloat = 8, padY: CGFloat = 4
        let labelFrame = NSRect(
            x: padX, y: padY,
            width: min(label.frame.width, 600),
            height: label.frame.height
        )
        label.frame = labelFrame
        let panelSize = NSSize(
            width: labelFrame.width + padX * 2,
            height: labelFrame.height + padY * 2
        )
        panel.contentView?.frame = NSRect(origin: .zero, size: panelSize)

        // Anchor just below the pointer. Convert the view-local anchor to
        // screen space via the window's coordinate system.
        let windowPoint = anchor
        let screenPoint = window.convertPoint(toScreen: windowPoint)
        let origin = NSPoint(
            x: screenPoint.x + 12,
            y: screenPoint.y - panelSize.height - 12
        )
        panel.setFrame(
            NSRect(origin: origin, size: panelSize),
            display: true
        )
        panel.orderFront(nil)
    }

    private func dismissHoverTooltip() {
        hoverTooltipPanel?.orderOut(nil)
    }

    // `expandSelectionUnderAnchor()` and `sendMouseEvent(...)` moved to
    // `TerminalView+Mouse.swift`. Those helpers had no intra-Hover
    // callers except this file's DEC 1003 any-event report (which
    // still calls `sendMouseEvent` cross-file via its internal
    // visibility there).

}
