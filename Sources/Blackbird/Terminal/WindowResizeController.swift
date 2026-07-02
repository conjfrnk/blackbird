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
    /// `minWidth`/`minHeight` (and, when supplied, to `boundingFrame` —
    /// see `resizedFrame`). Returns nil when no resize is in flight.
    func frameForCurrentDrag(currentMouseGlobal: CGPoint,
                             minWidth: CGFloat, minHeight: CGFloat,
                             boundingFrame: NSRect? = nil) -> NSRect? {
        guard let ctx = context else { return nil }
        return Self.resizedFrame(
            corner: ctx.corner,
            startMouseGlobal: ctx.startMouseGlobal,
            startFrame: ctx.startFrame,
            currentMouseGlobal: currentMouseGlobal,
            minWidth: minWidth,
            minHeight: minHeight,
            boundingFrame: boundingFrame
        )
    }

    /// End the gesture. Returns true if one was in flight (and clears it).
    @discardableResult
    func end() -> Bool {
        let wasResizing = context != nil
        context = nil
        return wasResizing
    }

    /// Pure corner-anchored resize math + screen clamp + min-size clamp.
    /// Given the dragged `corner`, the press-time mouse + frame, and the
    /// current mouse, returns the new frame: the dragged corner follows the
    /// mouse while the opposite corner stays pinned.
    ///
    /// `boundingFrame` (the screen's `visibleFrame` in production) clamps
    /// only the DRAGGED edges — the gesture applies a mouse *delta* to the
    /// original frame corner, so a grab far from the corner could otherwise
    /// push the dragged edge well past the monitor border while the mouse
    /// is still on-screen. Native edge-drag can't do that (the edge tracks
    /// the screen-confined mouse); this restores that intuition. The
    /// ANCHORED edges are never touched: a window already overhanging
    /// another monitor keeps its overhang.
    ///
    /// When the drag would shrink below `minWidth` / `minHeight`, the
    /// dragged edge is pinned instead of letting the opposite corner drift.
    /// The min clamp runs LAST and wins over the bound — a usable window
    /// beats strict containment when the anchor itself sits off-screen.
    /// No `NSWindow` needed — unit-testable.
    static func resizedFrame(corner: Corner,
                             startMouseGlobal: CGPoint,
                             startFrame: NSRect,
                             currentMouseGlobal: CGPoint,
                             minWidth: CGFloat,
                             minHeight: CGFloat,
                             boundingFrame: NSRect? = nil) -> NSRect {
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

        // Screen clamp on the dragged edges only (AppKit Y-up: origin is
        // the bottom-left corner, `maxY` the top edge).
        //
        // Each directional clamp additionally requires the bound to leave
        // at least the minimum size measured from the ANCHORED edge —
        // otherwise the axis is left unclamped. On multi-monitor setups
        // the bound follows the mouse's screen, which can lie entirely on
        // the far side of the window's anchor (mouse crosses the display
        // seam mid-drag); clamping there would produce a negative
        // dimension that the min clamp "rescues" into a jarring
        // snap-to-minimum that oscillates as the mouse re-crosses the
        // seam. Skipping the axis keeps the drag continuous; the min
        // clamp below still bounds the result. The residual unclamped
        // overshoot is confined to anchors within min-size of the border
        // and bounded by the grab offset. (silent-failure review)
        if let bound = boundingFrame {
            let dragsLeft   = corner == .topLeft  || corner == .bottomLeft
            let dragsRight  = corner == .topRight || corner == .bottomRight
            let dragsTop    = corner == .topLeft  || corner == .topRight
            let dragsBottom = corner == .bottomLeft || corner == .bottomRight
            // Anchored edges at this point: left drags keep maxX, right
            // drags keep origin.x, top drags keep origin.y, bottom drags
            // keep maxY (each equals its startFrame value).
            if dragsLeft, frame.minX < bound.minX, frame.maxX - bound.minX >= minWidth {
                frame.size.width -= bound.minX - frame.origin.x
                frame.origin.x = bound.minX
            }
            if dragsRight, frame.maxX > bound.maxX, bound.maxX - frame.origin.x >= minWidth {
                frame.size.width = bound.maxX - frame.origin.x
            }
            if dragsTop, frame.maxY > bound.maxY, bound.maxY - frame.origin.y >= minHeight {
                frame.size.height = bound.maxY - frame.origin.y
            }
            if dragsBottom, frame.minY < bound.minY, frame.maxY - bound.minY >= minHeight {
                frame.size.height -= bound.minY - frame.origin.y
                frame.origin.y = bound.minY
            }
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
