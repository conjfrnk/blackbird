import AppKit
import Foundation
import BBCore
import os

extension TerminalView {

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
                // Without `.cursorUpdate` AppKit never dispatches `cursorUpdate(with:)`.
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
        wakeRenderLoop()
        super.mouseMoved(with: event)
        let point = bufferPointFromEvent(event)
        let screenRow = Int(point.line) + (currentSnapshot?.displayOffset ?? 0)
        let col = point.col
        hoverCoordinator.handleMouseMoved(
            flags: event.modifierFlags,
            locationInWindow: event.locationInWindow
        )
        reportPointerMotionIfNeeded(for: event, screenRow: screenRow, col: col)
    }

    public override func mouseExited(with event: NSEvent) {
        // A partial wheel line must not carry into the next gesture.
        wheelAccumulator.reset()
        super.mouseExited(with: event)
        hoverCoordinator.clearHover()
        // The next entry must re-report its cell to a DEC 1003 TUI even if it re-enters on the same cell.
        lastReportedMotionCell = nil
        lastReportedDragCell = nil
    }

    public override func flagsChanged(with event: NSEvent) {
        wakeRenderLoop()
        super.flagsChanged(with: event)
        hoverCoordinator.handleFlagsChanged(flags: event.modifierFlags)
    }

    public override func cursorUpdate(with event: NSEvent) {
        if hoverCoordinator.wantsPointingHandCursor {
            NSCursor.pointingHand.set()
        } else {
            super.cursorUpdate(with: event)
        }
    }
}
