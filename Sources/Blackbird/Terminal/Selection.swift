import Foundation
import BBCore

/// A point in the terminal's addressable buffer. `line` is signed so
/// negative values refer to scrollback history, matching alacritty's
/// `Line(i32)`. `col` is 0-based from the left edge.
public struct BufferPoint: Equatable, Comparable {
    public var line: Int32
    public var col: Int

    public init(line: Int32, col: Int) {
        self.line = line
        self.col = col
    }

    public static func < (lhs: BufferPoint, rhs: BufferPoint) -> Bool {
        if lhs.line != rhs.line { return lhs.line < rhs.line }
        return lhs.col < rhs.col
    }
}

/// An active selection. `anchor` is the stable endpoint (where the drag
/// began); `cursor` is the live endpoint that moves during the drag.
/// Rectangular mode selects the bounding box of the two points instead of
/// the prose-style range.
public struct Selection: Equatable {
    public enum Mode: Equatable { case character, word, line, rectangular }

    public var anchor: BufferPoint
    public var cursor: BufferPoint
    public var mode: Mode

    /// `(top-left, bottom-right)` ordered so `start <= end`.
    public var normalized: (start: BufferPoint, end: BufferPoint) {
        if anchor <= cursor { return (anchor, cursor) }
        return (cursor, anchor)
    }

    public init(anchor: BufferPoint, cursor: BufferPoint, mode: Mode) {
        self.anchor = anchor
        self.cursor = cursor
        self.mode = mode
    }
}

/// Map a screen point (view-local, origin bottom-left per AppKit) to a
/// buffer point using cell metrics and the current display offset. The
/// grid is top-aligned within the view, so (bounds.height - localPoint.y)
/// gives a top-origin Y in points that we divide by cell height for the
/// display row.
///
/// Columns clamp to `[0, cols-1]`. `line` clamps upward at `rows - 1`
/// (so clicks below the last grid row snap to it) and downward into the
/// caller's history — we don't clamp negatively here because the caller
/// (TerminalView) knows `historySize` at call time.
public func bufferPoint(
    forView localPoint: CGPoint,
    cellWidth: CGFloat,
    cellHeight: CGFloat,
    viewportHeight: CGFloat,
    displayOffset: Int,
    cols: Int,
    rows: Int
) -> BufferPoint {
    let displayRow = max(0, Int((viewportHeight - localPoint.y) / cellHeight))
    let col = max(0, min(cols - 1, Int(localPoint.x / cellWidth)))
    let rawLine = displayRow - displayOffset
    // Clamp upward at rows-1; callers may clamp downward against -historySize.
    let clampedLine = min(rows - 1, rawLine)
    return BufferPoint(line: Int32(clampedLine), col: col)
}

/// Convert a buffer line to its display row in the current viewport.
/// Returns `nil` when the line is not visible (above or below the view).
public func displayRow(for bufferLine: Int32, displayOffset: Int, rows: Int) -> Int? {
    let row = Int(bufferLine) + displayOffset
    guard row >= 0 && row < rows else { return nil }
    return row
}
