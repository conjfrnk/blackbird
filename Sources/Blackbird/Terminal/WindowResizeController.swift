import AppKit

final class WindowResizeController {
    enum Corner { case topLeft, topRight, bottomLeft, bottomRight }

    private struct Context {
        let corner: Corner
        let startMouseGlobal: CGPoint
        let startFrame: NSRect
    }
    private var context: Context?

    var isResizing: Bool { context != nil }

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

    @discardableResult
    func end() -> Bool {
        let wasResizing = context != nil
        context = nil
        return wasResizing
    }

    /// `boundingFrame` clamps only the dragged edges; anchored edges keep any overhang.
    /// The min-size clamp runs last and wins over the bound.
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

        // An axis is clamped only if the bound leaves the minimum size from the anchored edge: the
        // mouse's screen can lie wholly past the anchor, and clamping there snaps to minimum.
        if let bound = boundingFrame {
            let dragsLeft   = corner == .topLeft  || corner == .bottomLeft
            let dragsRight  = corner == .topRight || corner == .bottomRight
            let dragsTop    = corner == .topLeft  || corner == .topRight
            let dragsBottom = corner == .bottomLeft || corner == .bottomRight
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

        // Below the minimum, pin the dragged edge instead of letting the opposite corner drift.
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
