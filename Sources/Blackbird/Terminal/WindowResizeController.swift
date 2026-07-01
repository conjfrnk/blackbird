import AppKit

/// Owns the modifier-right-drag window-resize gesture, lifted off `TerminalView`
/// (REFACTOR.md Area 3 / §2: window move/resize fused into the mouse file →
/// its own controller). Holds the in-flight resize context privately so it's
/// no longer an `internal` view field, and exposes the corner-anchor + min-size
/// frame math as a PURE static (`resizedFrame`) that's unit-testable without a
/// real `NSWindow`.
///
/// Gesture: a right-drag with the configured resize modifier resizes the window
/// from the corner nearest the click, anchoring the OPPOSITE corner (drag the
/// top-right and the bottom-left stays pinned) — the borderless-window idiom
/// from iTerm2 / VS Code.
final class WindowResizeController {
    enum Corner { case topLeft, topRight, bottomLeft, bottomRight }

    private struct Context {
        let corner: Corner
        let startMouseGlobal: CGPoint
        let startFrame: NSRect
    }
    private var context: Context?

    /// True while a resize gesture is in flight.
    var isResizing: Bool { context != nil }

    /// Begin a corner resize. `local` is the click in the view's coordinates and
    /// `bounds` the view bounds (together they pick the nearest corner);
    /// `startMouseGlobal` is the screen-space mouse at press, `windowFrame` the
    /// window's frame to resize from.
    func begin(localPoint local: CGPoint, in bounds: CGRect,
               startMouseGlobal: CGPoint, windowFrame: NSRect) {
        let left = local.x < bounds.width / 2
        // AppKit's Y-axis points up, so "below the midline" = smaller y.
        let lower = local.y < bounds.height / 2
        let corner: Corner = switch (left, lower) {
            case (true,  true):  .bottomLeft
            case (false, true):  .bottomRight
            case (true,  false): .topLeft
            case (false, false): .topRight
        }
        context = Context(corner: corner, startMouseGlobal: startMouseGlobal, startFrame: windowFrame)
    }

    /// The new window frame for the current mouse position, clamped to
    /// `minWidth`/`minHeight`. Returns nil when no resize is in flight.
    func frameForCurrentDrag(currentMouseGlobal: CGPoint,
                             minWidth: CGFloat, minHeight: CGFloat) -> NSRect? {
        guard let ctx = context else { return nil }
        return Self.resizedFrame(
            corner: ctx.corner,
            startMouseGlobal: ctx.startMouseGlobal,
            startFrame: ctx.startFrame,
            currentMouseGlobal: currentMouseGlobal,
            minWidth: minWidth,
            minHeight: minHeight
        )
    }

    /// End the gesture. Returns true if one was in flight (and clears it).
    @discardableResult
    func end() -> Bool {
        let wasResizing = context != nil
        context = nil
        return wasResizing
    }

    /// Pure corner-anchored resize math + min-size clamp. Given the dragged
    /// `corner`, the press-time mouse + frame, and the current mouse, returns
    /// the new frame: the dragged corner follows the mouse while the opposite
    /// corner stays pinned. When the drag would shrink below `minWidth` /
    /// `minHeight`, the dragged edge is pinned instead of letting the opposite
    /// corner drift. No `NSWindow` needed — unit-testable.
    static func resizedFrame(corner: Corner,
                             startMouseGlobal: CGPoint,
                             startFrame: NSRect,
                             currentMouseGlobal: CGPoint,
                             minWidth: CGFloat,
                             minHeight: CGFloat) -> NSRect {
        let dx = currentMouseGlobal.x - startMouseGlobal.x
        let dy = currentMouseGlobal.y - startMouseGlobal.y
        var frame = startFrame
        switch corner {
        case .topLeft:
            frame.origin.x    += dx
            frame.size.width  -= dx
            frame.size.height += dy
        case .topRight:
            frame.size.width  += dx
            frame.size.height += dy
        case .bottomLeft:
            frame.origin.x    += dx
            frame.size.width  -= dx
            frame.origin.y    += dy
            frame.size.height -= dy
        case .bottomRight:
            frame.size.width  += dx
            frame.origin.y    += dy
            frame.size.height -= dy
        }
        // Clamp to the minimums. When the dragged corner would shrink the window
        // below the minimum, pin its corresponding edge instead of letting the
        // opposite corner drift.
        if frame.size.width < minWidth {
            if corner == .topLeft || corner == .bottomLeft {
                frame.origin.x = startFrame.maxX - minWidth
            }
            frame.size.width = minWidth
        }
        if frame.size.height < minHeight {
            if corner == .bottomLeft || corner == .bottomRight {
                frame.origin.y = startFrame.maxY - minHeight
            }
            frame.size.height = minHeight
        }
        return frame
    }
}
