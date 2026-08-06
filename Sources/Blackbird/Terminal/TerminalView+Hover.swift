import AppKit
import Foundation
import BBCore
import os

/// `TerminalView`'s NSResponder entry points for hover + ⌘-held URL
/// highlighting. The state and the OSC 8 / ⌘-regex engine live in
/// `HoverCoordinator` (`view.hoverCoordinator`); these overrides are just the
/// AppKit hooks that drive it. `mouseMoved` additionally drives the DEC 1003
/// any-event motion report, which is a mouse-reporting concern that lives in
/// `TerminalView+Mouse` (`reportPointerMotionIfNeeded`).
extension TerminalView {

    /// Install a full-bounds tracking area that delivers `mouseMoved` even when
    /// no buttons are down. Recreated on every bounds change; `.inVisibleRect`
    /// makes AppKit re-resolve the rect on each delivery so tab splits / window
    /// resizes don't leave a stale region.
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
                // `cursorUpdate(with:)`. Without it the override is dead code —
                // pointer style stays the default `.iBeam` even while the
                // pointer is over a clickable OSC 8 / ⌘-hover URL.
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
        let point = bufferPointFromEvent(event)
        let screenRow = Int(point.line) + (currentSnapshot?.displayOffset ?? 0)
        let col = point.col
        hoverCoordinator.handleMouseMoved(
            flags: event.modifierFlags,
            locationInWindow: event.locationInWindow
        )
        // DEC mode 1003 any-event motion report. A mouse-reporting
        // responsibility (`TerminalView+Mouse`), not a hover one; `mouseMoved`
        // is just the shared AppKit entry point that drives it.
        reportPointerMotionIfNeeded(for: event, screenRow: screenRow, col: col)
    }

    public override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hoverCoordinator.clearHover()
        // Mouse-reporting concern, kept next to the hover clear because they
        // share the trigger: the pointer left the grid, so the next entry must
        // re-report its cell to a DEC 1003 TUI even if it re-enters on the same
        // cell it left. Lives here rather than inside the hover coordinator —
        // that type has no business writing the reporting subsystem's dedupe.
        lastReportedMotionCell = nil
        lastReportedDragCell = nil
    }

    public override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        hoverCoordinator.handleFlagsChanged(flags: event.modifierFlags)
    }

    /// AppKit queries this when the pointer crosses into the view's cursor rect
    /// or when `invalidateCursorRects` is called. Return `pointingHand` whenever
    /// the pointer is over something clickable — an OSC 8 link (always) or a
    /// regex URL while ⌘ is held — for a consistent affordance matching the
    /// underline state.
    public override func cursorUpdate(with event: NSEvent) {
        if hoverCoordinator.wantsPointingHandCursor {
            NSCursor.pointingHand.set()
        } else {
            super.cursorUpdate(with: event)
        }
    }
}
