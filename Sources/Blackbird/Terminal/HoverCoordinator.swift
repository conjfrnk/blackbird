import AppKit
import Foundation
import BBCore
import os

/// `view` is unowned (the view owns this controller); the dwell work item captures `[weak self]` and
/// returns before touching `view` once the view is gone.
final class HoverCoordinator {
    unowned let view: TerminalView

    init(view: TerminalView) {
        self.view = view
    }

    // MARK: - State

    /// View-local pointer position. The hovered cell is derived from it on demand, not baked at `mouseMoved`:
    /// the grid can scroll, or a TUI repaint the cell, under a stationary pointer.
    private(set) var lastHoverPointInView: CGPoint?

    var lastHoverCell: (row: Int, col: Int)? {
        guard lastHoverPointInView != nil, let snap = view.currentSnapshot else { return nil }
        // Prefer AppKit's live pointer position: the view can move or resize under the pointer with no mouse
        // event (tab-group frame fan-out, fullscreen, ⌘-right-drag resize). The stored point is the fallback.
        let point: CGPoint = {
            guard let window = view.window else { return lastHoverPointInView! }
            return view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        }()
        // `bufferPointFromLocalPoint` clamps out-of-range points into the grid: without a bounds test a pointer in
        // the titlebar band resolves to row 0, an affordance the click path (`inTextArea`) refuses to open.
        guard view.bounds.contains(point),
              point.y < view.bounds.height - view.titlebarOnlyTopInset else { return nil }
        let bufferPoint = view.bufferPointFromLocalPoint(point)
        return (row: Int(bufferPoint.line) + snap.displayOffset, col: bufferPoint.col)
    }

    private var resolvedHoverCell: (row: Int, col: Int)?

    /// Only valid for `view.currentSnapshot`: the core assigns link ids per snapshot, in grid-scan order
    /// over the distinct URIs on screen, so the same id can mean a different URL one frame later.
    private(set) var hoveredLinkID: UInt32 = 0

    private(set) var hoveredLinkURLString: String?

    /// AppKit dispatches `cursorUpdate(with:)` on tracking-area entry/exit, not on moves inside the area, so
    /// cursor rects are invalidated whenever this answer flips.
    private var lastWantsPointingHandCursor = false
    var cmdModifierHeld: Bool = false
    private var cmdHoverURLMatch: URLMatch?
    private(set) var cachedURLMatches: [URLMatch] = []
    private(set) var cachedURLMatchesSeq: UInt64?
    private var cachedURLMatchesOffset: Int = 0
    private var cachedURLMatchesCols: Int = 0
    private var cachedURLMatchesRows: Int = 0

    func invalidateURLMatchCache() {
        cachedURLMatches = []
        cachedURLMatchesSeq = nil
        cachedURLMatchesOffset = 0
        cachedURLMatchesCols = 0
        cachedURLMatchesRows = 0
    }

    static func incrementalRescanRows(damaged: [Int], rows: Int) -> Set<Int> {
        var out = Set<Int>()
        for r in damaged {
            for d in (r - 1)...(r + 1) where d >= 0 && d < rows {
                out.insert(d)
            }
        }
        return out
    }
    // The scheduled tooltip reveal (`hoverTooltipItem`) lives on the view: its `deinit` cancels it, and
    // reaching through this controller's `unowned view` during the view's own deinit would trap.

    #if DEBUG
    private static let hoverLogger = Logger(subsystem: "dev.conjfrnk.blackbird",
                                            category: "hover")

    func setHoverPointForTests(_ point: CGPoint?) {
        lastHoverPointInView = point
    }
    #endif

    var wantsPointingHandCursor: Bool {
        hoveredLinkID != 0 || cmdHoverURLMatch != nil
    }

    // MARK: - Mouse / flags entry points

    func handleMouseMoved(flags: NSEvent.ModifierFlags, locationInWindow: NSPoint) {
        // `flagsChanged` doesn't fire for a ⌘ release while another window is key (Cmd-Tab); reconcile here.
        let cmdChanged = syncCmdModifierHeld(fromEventFlags: flags)
        lastHoverPointInView = view.convert(locationInWindow, from: nil)
        // Derive the cell via `lastHoverCell`, not the event: AppKit's live pointer can be ahead of a queued event.
        guard let cell = lastHoverCell else {
            clearHoverDerivedState()
            return
        }
        updateHover(screenRow: cell.row, col: cell.col, tooltipAnchor: locationInWindow)
        if cmdChanged || cmdModifierHeld {
            reevaluateCmdHoverHighlight()
        }
    }

    func handleSnapshotPublished() {
        guard let cell = lastHoverCell else {
            clearHoveredLink()
            if cmdModifierHeld { reevaluateCmdHoverHighlight() }
            return
        }
        updateHover(screenRow: cell.row, col: cell.col, tooltipAnchor: nil)
        if cmdModifierHeld {
            reevaluateCmdHoverHighlight()
        }
    }

    func handleFlagsChanged(flags: NSEvent.ModifierFlags) {
        guard syncCmdModifierHeld(fromEventFlags: flags) else { return }
        reevaluateCmdHoverHighlight()
        view.window?.invalidateCursorRects(for: view)
    }

    /// No early return on an unchanged cell (ids renumber per snapshot; contents change under a still pointer).
    /// `tooltipAnchor` is nil for a content-driven refresh, which may dismiss a tooltip but never pops one.
    private func updateHover(screenRow: Int, col: Int, tooltipAnchor: NSPoint?) {
        // Gate on `OSC8URLPolicy`: no underline or tooltip for a target whose click is blocked.
        let resolved: (id: UInt32, urlString: String?) = {
            #if DEBUG
            if let override = view.hyperlinkResolverOverride {
                guard let url = override.osc8URL(row: screenRow, col: col) else { return (0, nil) }
                return (UInt32(bitPattern: Int32(-1)), url.absoluteString)
            }
            #endif
            guard let snap = view.currentSnapshot else { return (0, nil) }
            let id = snap.linkID(row: screenRow, col: col)
            guard id != 0,
                  let raw = snap.linkURL(id: id),
                  let url = URL(string: raw),
                  OSC8URLPolicy.isAllowed(url)
            else { return (0, nil) }
            return (id, raw)
        }()

        let cellChanged = resolvedHoverCell.map { $0.row != screenRow || $0.col != col } ?? true
        let hrefChanged = resolved.urlString != hoveredLinkURLString
        resolvedHoverCell = (row: screenRow, col: col)

        if resolved.id != hoveredLinkID {
            hoveredLinkID = resolved.id
            // Push to the renderer too: a cleared id must drop the underline even if no frame is scheduled.
            view.renderer.setHoveredLinkID(UInt16(truncatingIfNeeded: resolved.id))
            view.needsDisplay = true
        }
        hoveredLinkURLString = resolved.urlString
        refreshPointingHandCursorIfNeeded()

        // Hot path on a repainting TUI: must not cancel and re-arm the tooltip on every frame.
        guard cellChanged || hrefChanged else { return }

        view.hoverTooltipItem?.cancel()
        view.hoverTooltipItem = nil
        dismissHoverTooltip()

        guard let anchor = tooltipAnchor, let urlString = resolved.urlString else { return }

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.showHoverTooltip(urlString: urlString, anchor: anchor)
        }
        view.hoverTooltipItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func refreshPointingHandCursorIfNeeded() {
        let wants = wantsPointingHandCursor
        guard wants != lastWantsPointingHandCursor else { return }
        lastWantsPointingHandCursor = wants
        view.window?.invalidateCursorRects(for: view)
    }

    func clearHover() {
        lastHoverPointInView = nil
        clearHoverDerivedState()
    }

    /// Keeps the pointer position: AppKit delivers no `mouseMoved` for a scroll, so nil-ing it would leave
    /// hover off until the mouse physically moves.
    func clearHoverDerivedState() {
        resolvedHoverCell = nil
        cancelHoverTooltip()
        clearHoveredLink()
        clearCmdHoverURLMatch()
    }

    // MARK: - ⌘-held regex URL highlight

    /// Calls `setCmdHoverRange` even when the local match is already nil: the renderer dedups, and skipping
    /// the call would leave a renderer-state desync in place.
    func clearCmdHoverURLMatch() {
        let wasSet = cmdHoverURLMatch != nil
        cmdHoverURLMatch = nil
        view.renderer.setCmdHoverRange(bufferLine: 0, startCol: -1, endCol: -1)
        if wasSet { view.needsDisplay = true }
        // `cmdHoverURLMatch` is the other disjunct of `wantsPointingHandCursor`: refresh the cursor cache too.
        refreshPointingHandCursorIfNeeded()
    }

    private func refreshURLMatchCacheIfNeeded() {
        guard let snap = view.currentSnapshot else {
            invalidateURLMatchCache()
            return
        }
        guard cachedURLMatchesSeq != snap.sequenceID else { return }
        // Incremental path: published snapshots can be dropped (`SnapshotCoalescer`) and damage is drained per
        // snapshot taken, so only `sequenceID == cached + 1` (same offset and size) makes the damage the full delta.
        if let prev = cachedURLMatchesSeq,
           snap.sequenceID == prev &+ 1,
           !snap.damageIsFull,
           snap.displayOffset == cachedURLMatchesOffset,
           snap.cols == cachedURLMatchesCols,
           snap.rows == cachedURLMatchesRows {
            let damaged = snap.damagedRows
            if damaged.isEmpty {
                cachedURLMatchesSeq = snap.sequenceID
                return
            }
            if damaged.count < (snap.rows + 1) / 2 {
                let rescan = Self.incrementalRescanRows(damaged: damaged, rows: snap.rows)
                let offset = snap.displayOffset
                let rescanLines = Set(rescan.map { Int32($0 - offset) })
                let lastCol = snap.cols - 1
                let wrapRisk = cachedURLMatches.contains { m in
                    m.endCol >= lastCol && rescan.contains(Int(m.line) + offset + 1) && !rescanLines.contains(m.line)
                }
                if wrapRisk {
                    cachedURLMatches = URLDetector.scan(snapshot: snap)
                    cachedURLMatchesSeq = snap.sequenceID
                    return
                }
                let kept = cachedURLMatches.filter { !rescanLines.contains($0.line) }
                cachedURLMatches = kept + URLDetector.scan(snapshot: snap, rows: rescan)
                cachedURLMatchesSeq = snap.sequenceID
                return
            }
        }
        cachedURLMatches = URLDetector.scan(snapshot: snap)
        cachedURLMatchesSeq = snap.sequenceID
        cachedURLMatchesOffset = snap.displayOffset
        cachedURLMatchesCols = snap.cols
        cachedURLMatchesRows = snap.rows
    }

    func reevaluateCmdHoverHighlight() {
        guard cmdModifierHeld,
              let last = lastHoverCell,
              let snap = view.currentSnapshot
        else {
            clearCmdHoverURLMatch()
            return
        }
        if snap.linkID(row: last.row, col: last.col) != 0 {
            clearCmdHoverURLMatch()
            return
        }
        refreshURLMatchCacheIfNeeded()
        let bufferLine = Int32(last.row - snap.displayOffset)
        let point = BufferPoint(line: bufferLine, col: last.col)
        guard let match = URLDetector.match(at: point, in: cachedURLMatches) else {
            #if DEBUG
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
            clearCmdHoverURLMatch()
            return
        }
        if let existing = cmdHoverURLMatch,
           existing.line == match.line,
           existing.startCol == match.startCol,
           existing.endCol == match.endCol {
            return
        }
        cmdHoverURLMatch = match
        view.renderer.setCmdHoverRange(
            bufferLine: match.line,
            startCol: Int32(match.startCol),
            endCol: Int32(match.endCol)
        )
        view.needsDisplay = true
        refreshPointingHandCursorIfNeeded()
    }

    @discardableResult
    func syncCmdModifierHeld(fromEventFlags flags: NSEvent.ModifierFlags) -> Bool {
        let nowHeld = flags.contains(.command)
        guard nowHeld != cmdModifierHeld else { return false }
        cmdModifierHeld = nowHeld
        return true
    }

    func resetModifierAndHoverState() {
        cmdModifierHeld = false
        lastHoverPointInView = nil
        resolvedHoverCell = nil
        invalidateURLMatchCache()
        clearCmdHoverURLMatch()
        clearHoveredLink()
        cancelHoverTooltip()
    }

    /// Does not clear the underline / hovered-link id: keyDown dismisses the tooltip alone.
    func cancelHoverTooltip() {
        view.hoverTooltipItem?.cancel()
        view.hoverTooltipItem = nil
        dismissHoverTooltip()
    }

    func clearHoveredLink() {
        hoveredLinkURLString = nil
        defer { refreshPointingHandCursorIfNeeded() }
        guard hoveredLinkID != 0 else { return }
        hoveredLinkID = 0
        view.renderer.setHoveredLinkID(0)
        view.needsDisplay = true
    }

    /// Not equivalent to re-resolving `hoveredLinkID` against `currentSnapshot`: ids are per-snapshot, so a
    /// stale id can name a different URL, one that never passed `OSC8URLPolicy`.
    func hoveredLinkURL() -> URL? {
        guard let urlString = hoveredLinkURLString,
              let url = URL(string: urlString),
              OSC8URLPolicy.isAllowed(url)
        else { return nil }
        return url
    }

    /// The one place a hostile href becomes displayable: credential redaction, C0/bidi scrub, then length clamp.
    static func displayString(forHref urlString: String) -> String {
        let redacted = OSC8URLPolicy.redactCredentialsForDisplay(urlString)
        let scrubbed = PasteSanitizer.scrubURLForDisplay(redacted)
        // Clamp after the scrub so a bidi byte can't hide past the ellipsis; a megabyte href would hang sizing.
        let maxDisplay = 512
        return scrubbed.count > maxDisplay
            ? String(scrubbed.prefix(maxDisplay)) + "…"
            : scrubbed
    }

    private func showHoverTooltip(urlString: String, anchor: NSPoint) {
        guard let window = view.window else { return }
        let display = Self.displayString(forHref: urlString)
        let screenPoint = window.convertPoint(toScreen: anchor)
        view.tooltipController.show(text: display, near: screenPoint)
    }

    private func dismissHoverTooltip() {
        view.tooltipController.dismiss()
    }
}
