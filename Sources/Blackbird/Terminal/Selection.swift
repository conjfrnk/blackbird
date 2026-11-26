import Foundation
import os
import BBCore

private enum BufferPointDiag {
    static let logger = Logger(subsystem: "dev.conjfrnk.blackbird",
                               category: "selection")
    static let didLogBadCellDim = OSAllocatedUnfairLock(initialState: false)
}

/// `line` is signed: negative values address scrollback history. `col` is 0-based.
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

public struct Selection: Equatable {
    public enum Mode: Equatable { case character, word, line, rectangular }

    public var anchor: BufferPoint
    public var cursor: BufferPoint
    public var mode: Mode

    /// `.rectangular` normalizes to the bounding box: the core's rect copy path
    /// requires start col <= end col and returns an empty string otherwise.
    public var normalized: (start: BufferPoint, end: BufferPoint) {
        switch mode {
        case .rectangular:
            let loLine = min(anchor.line, cursor.line)
            let hiLine = max(anchor.line, cursor.line)
            let loCol = min(anchor.col, cursor.col)
            let hiCol = max(anchor.col, cursor.col)
            return (BufferPoint(line: loLine, col: loCol),
                    BufferPoint(line: hiLine, col: hiCol))
        case .character, .word, .line:
            return anchor <= cursor ? (anchor, cursor) : (cursor, anchor)
        }
    }

    public init(anchor: BufferPoint, cursor: BufferPoint, mode: Mode) {
        self.anchor = anchor
        self.cursor = cursor
        self.mode = mode
    }
}

/// `localPoint` is view-local with AppKit's bottom-left origin; the grid is top-aligned.
/// Returns (0, 0) when a cell dimension is non-positive or non-finite.
public func bufferPoint(
    forView localPoint: CGPoint,
    cellWidth: CGFloat,
    cellHeight: CGFloat,
    viewportHeight: CGFloat,
    displayOffset: Int,
    cols: Int,
    rows: Int,
    historySize: Int,
    leftInsetPoints: CGFloat
) -> BufferPoint {
    guard cellWidth.isFinite, cellWidth > 0,
          cellHeight.isFinite, cellHeight > 0 else {
        BufferPointDiag.didLogBadCellDim.withLock { didLog in
            if !didLog {
                didLog = true
                BufferPointDiag.logger.warning("bufferPoint: bad cell dims, returning origin sentinel — cellWidth=\(cellWidth, privacy: .public) cellHeight=\(cellHeight, privacy: .public) viewportHeight=\(viewportHeight, privacy: .public)")
            }
        }
        return BufferPoint(line: 0, col: 0)
    }
    let safeY = localPoint.y.sanitizedPixel
    // Subtract the left inset before the clamp so a point inside the inset maps to col 0.
    let insetSubtractedX = localPoint.x.isFinite
        ? localPoint.x - leftInsetPoints
        : 0
    let safeX = insetSubtractedX.sanitizedPixel
    let safeVH = viewportHeight.sanitizedPixel
    // `viewportHeight` includes the bottom inset, so clamp the display row: a point in
    // that strip otherwise maps to the line below the viewport when scrolled back.
    let displayRow = min(max(0, rows - 1), max(0, Int((safeVH - safeY) / cellHeight)))
    let col = max(0, min(cols - 1, Int(safeX / cellWidth)))
    let rawLine = displayRow - displayOffset
    let upper = rows - 1
    let upperClamped = min(upper, rawLine)
    let clampedLine = max(-historySize, upperClamped)
    return BufferPoint(line: Int32(clampedLine), col: col)
}

public func displayRow(for bufferLine: Int32, displayOffset: Int, rows: Int) -> Int? {
    let row = Int(bufferLine) + displayOffset
    guard row >= 0 && row < rows else { return nil }
    return row
}

/// `.`, `:` and `$ & # @ = ! | < >` are deliberately not breakers: paths, host:port
/// and shell sigils select as one unit.
private let wordBreakers: Set<Character> = [
    " ", "\t", "\n", "\r",
    ",", ";", "?",
    "(", ")", "[", "]", "{", "}",
    "'", "\"", "`",
]

/// Inclusive range; nil when the point's line is not visible in `snapshot`
/// (snapshot cells are display-row addressed).
public func wordRange(
    around point: BufferPoint,
    in snapshot: BBSnapshot,
    displayOffset: Int
) -> (BufferPoint, BufferPoint)? {
    guard let row = displayRow(for: point.line, displayOffset: displayOffset, rows: snapshot.rows) else {
        return nil
    }
    let cols = snapshot.cols

    // Walk by cellKind: `character(at:row:)` collapses spacer and empty into nil,
    // and a wide glyph's spacer cell must not terminate the word.
    func kindAt(_ c: Int) -> BBSnapshot.CellKind {
        snapshot.cellKind(at: c, row: row)
    }
    func characterAt(_ c: Int) -> Character? {
        if case .character(let ch) = kindAt(c) { return ch }
        return nil
    }

    let anchorCol: Int
    switch kindAt(point.col) {
    case .character:
        anchorCol = point.col
    case .spacer:
        var c = point.col - 1
        while c >= 0, case .spacer = kindAt(c) { c -= 1 }
        guard c >= 0, case .character = kindAt(c) else { return nil }
        anchorCol = c
    case .empty:
        return nil
    }

    guard let here = characterAt(anchorCol), !wordBreakers.contains(here) else {
        return nil
    }

    var l = anchorCol
    backwardLoop: while l > 0 {
        switch kindAt(l - 1) {
        case .character(let ch):
            if wordBreakers.contains(ch) { break backwardLoop }
            l -= 1
        case .spacer:
            l -= 1
        case .empty:
            break backwardLoop
        }
    }

    var r = anchorCol
    forwardLoop: while r + 1 < cols {
        switch kindAt(r + 1) {
        case .character(let ch):
            if wordBreakers.contains(ch) { break forwardLoop }
            r += 1
        case .spacer:
            r += 1
        case .empty:
            break forwardLoop
        }
    }

    return (BufferPoint(line: point.line, col: l), BufferPoint(line: point.line, col: r))
}

extension Selection {
    func copyRange(cols: Int) -> (start: BufferPoint, end: BufferPoint) {
        let (a, b) = normalized
        switch mode {
        case .line:
            return (
                BufferPoint(line: a.line, col: 0),
                BufferPoint(line: b.line, col: max(0, cols - 1))
            )
        case .character, .word, .rectangular:
            return (a, b)
        }
    }
}
