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

    /// Ordered pair: start <= end.
    /// - Prose modes (`.character`, `.word`, `.line`): line-major, col-minor —
    ///   so a cross-line selection unfolds as `start.line < end.line`.
    /// - `.rectangular`: the bounding rectangle — `start` is the top-left
    ///   (min line, min col) and `end` is the bottom-right (max line, max
    ///   col). Important: without this, a rectangular drag that went from
    ///   (line 2, col 10) down-and-left to (line 5, col 3) would normalize
    ///   under line-major to `((2,10), (5,3))`, and the copy path in the
    ///   Rust core (which expects `s_col <= e_col` for rect mode) returns an
    ///   empty string.
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
    // Guard against two trap classes at Int(Double):
    //   1. NaN / ±Infinity — a stray Core Animation value through
    //      NSEvent.locationInWindow during unusual drags.
    //   2. Finite-but-absurd values — e.g. 1e20 from a misbehaving
    //      bridged CGPoint, where Int can't hold the magnitude.
    // Clamp both to a sane pixel count per axis first. Zero for
    // non-finite, then clamp to [0, 1_000_000] regardless. Mirrors
    // CellMetrics.grid exactly.
    let sanePx: CGFloat = 1_000_000
    let safeY = localPoint.y.isFinite ? min(max(0, localPoint.y), sanePx) : 0
    let safeX = localPoint.x.isFinite ? min(max(0, localPoint.x), sanePx) : 0
    let safeVH = viewportHeight.isFinite ? min(max(0, viewportHeight), sanePx) : 0
    let displayRow = max(0, Int((safeVH - safeY) / cellHeight))
    let col = max(0, min(cols - 1, Int(safeX / cellWidth)))
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

/// Characters that break word runs for double-click selection. Tuned
/// for shell / source-code workflows where `$PATH`, `user@host.com`,
/// `env=VALUE`, `#define FOO`, and `&ref` should double-click as single
/// units (audit findbar-selection F14). Prose punctuation (comma,
/// semicolon, question, exclamation) still breaks. Matches iTerm2's
/// "selectionWords" default more closely than Terminal.app's aggressive
/// default.
private let wordBreakers: Set<Character> = [
    " ", "\t", "\n", "\r",
    // `.` and `:` are OMITTED — paths (`/usr/local/bin`), dotted
    // identifiers (`config.ini`), and host:port (`example.com:8080`)
    // should select as single units.
    // `$ & # @ = ! | < >` are also OMITTED — shell sigils + env
    // assignments + HTML/doc sigils belong to their neighbouring token.
    // Remaining breakers are prose punctuation + bracket pairs + quotes +
    // `?` (URL query / shell glob boundary) + unary `~` (home dir, stays
    // via prose fallback in most contexts).
    ",", ";", "?",
    "(", ")", "[", "]", "{", "}",
    "'", "\"", "`",
]

/// Extend `point` outward along its line until a word-break character
/// is hit. Returns `(start, end)` inclusive, or `nil` when the point is
/// not on a line currently visible in `snapshot` (required because
/// `BBSnapshot.character(at:row:)` is display-row addressed).
public func wordRange(
    around point: BufferPoint,
    in snapshot: BBSnapshot,
    displayOffset: Int
) -> (BufferPoint, BufferPoint)? {
    guard let row = displayRow(for: point.line, displayOffset: displayOffset, rows: snapshot.rows) else {
        return nil
    }
    let cols = snapshot.cols
    func ch(_ c: Int) -> Character? { snapshot.character(at: c, row: row) }

    // Wide-char (CJK, wide emoji) cells occupy two columns; the trailing
    // column has ch=0 (spacer) even though the logical word continues
    // through it. If the click landed on the trailing half, back up one
    // to the leading cell so the expansion finds the real character —
    // otherwise double-click on the right half of "中" returned nil and
    // the selection didn't expand. Audit findbar-selection F36.
    let anchorCol: Int
    if ch(point.col) != nil {
        anchorCol = point.col
    } else if point.col > 0, ch(point.col - 1) != nil {
        anchorCol = point.col - 1
    } else {
        return nil
    }

    // Point is on a blank / break / empty cell — there is no word to
    // expand. Return nil so callers (e.g. .word selection expansion) keep
    // their existing range instead of collapsing to a zero-width point.
    guard let here = ch(anchorCol), !wordBreakers.contains(here) else {
        return nil
    }

    var l = anchorCol
    while l > 0, let c = ch(l - 1), !wordBreakers.contains(c) { l -= 1 }
    var r = anchorCol
    while r + 1 < cols, let c = ch(r + 1), !wordBreakers.contains(c) { r += 1 }

    return (BufferPoint(line: point.line, col: l), BufferPoint(line: point.line, col: r))
}
