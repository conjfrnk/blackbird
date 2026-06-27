import Foundation
import os
import BBCore

/// Diagnostic channel for `bufferPoint`'s defensive guards. `bufferPoint`
/// is a free function so the logger lives in a private namespace. One-shot
/// because a sustained zero-cell-dim state would otherwise flood the
/// unified log every time a click event fires. NO `#if DEBUG` gate —
/// Release diagnosability matters (mirrors H-2 / M-4 / M-5 lesson).
private enum BufferPointDiag {
    static let logger = Logger(subsystem: "dev.conjfrnk.blackbird",
                               category: "selection")
    static let didLogBadCellDim = OSAllocatedUnfairLock(initialState: false)
}

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
/// (so clicks below the last grid row snap to it). `line` also clamps
/// downward at `-historySize` — a drag that overshoots the top of
/// retained scrollback lands on the oldest visible line instead of
/// producing an unreachable negative line that copies as empty. Audit
/// M11. `historySize` is required (M-17 / EC-4): pass `0` only at
/// call sites that genuinely have no history info, with a comment
/// explaining why.
///
/// Contract (M-17 / L-17 / EC-4 / EC-6):
///   - Returns `BufferPoint(line: 0, col: 0)` when `cellWidth` or
///     `cellHeight` is non-positive or non-finite. Without that
///     guard, `safeX / 0` traps as `Int(±Inf)`. Sentinel chosen to
///     match the natural "origin" mapping when the grid has no
///     well-defined cell size.
///   - All `localPoint` / `viewportHeight` non-finite values clamp
///     to 0; finite-but-huge values clamp to ±1_000_000 px.
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
    // L-17 / EC-6: cell dims are public-API divisors. A degenerate
    // 0 / NaN / -Inf would trap at `Int(safeX / cellWidth)` because
    // the result is ±Infinity which Int can't represent. Return the
    // origin sentinel — there's no meaningful cell to land on when
    // the grid has no cell size.
    guard cellWidth.isFinite, cellWidth > 0,
          cellHeight.isFinite, cellHeight > 0 else {
        // The guard prevents an `Int(±Inf)` trap, but the user-visible
        // shape is a broken selection (every click maps to the
        // origin). Surface it once so a font-load regression or a
        // pre-metrics click race is discoverable in Release.
        BufferPointDiag.didLogBadCellDim.withLock { didLog in
            if !didLog {
                didLog = true
                BufferPointDiag.logger.warning("bufferPoint: bad cell dims, returning origin sentinel — cellWidth=\(cellWidth, privacy: .public) cellHeight=\(cellHeight, privacy: .public) viewportHeight=\(viewportHeight, privacy: .public)")
            }
        }
        return BufferPoint(line: 0, col: 0)
    }
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
    // Subtract the renderer's left inset BEFORE the max(0, …) clamp so a
    // finite localPoint inside the inset region (x < leftInsetPoints)
    // collapses to col 0 rather than producing a negative col.
    let insetSubtractedX = localPoint.x.isFinite
        ? localPoint.x - leftInsetPoints
        : 0
    let safeX = insetSubtractedX.isFinite ? min(max(0, insetSubtractedX), sanePx) : 0
    let safeVH = viewportHeight.isFinite ? min(max(0, viewportHeight), sanePx) : 0
    let displayRow = max(0, Int((safeVH - safeY) / cellHeight))
    let col = max(0, min(cols - 1, Int(safeX / cellWidth)))
    let rawLine = displayRow - displayOffset
    // Clamp upward at rows-1; downward at -historySize. Pass 0 at
    // call sites without history info; that effectively disables the
    // lower clamp for live-grid-only clicks.
    let upper = rows - 1
    let upperClamped = min(upper, rawLine)
    let clampedLine = max(-historySize, upperClamped)
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

    // Audit fix-#02 (2026-05-11): walk via BBSnapshot.cellKind so spacer
    // cells (continuation of a wide glyph) are skipped through rather
    // than treated as word-terminators. character(at:row:) collapses
    // .spacer and .empty into nil, so the previous walk broke at the
    // first spacer — double-clicking the leading half of `中文` selected
    // only `中` because ch(1)==nil. cellKind distinguishes them.
    func kindAt(_ c: Int) -> BBSnapshot.CellKind {
        snapshot.cellKind(at: c, row: row)
    }
    func characterAt(_ c: Int) -> Character? {
        if case .character(let ch) = kindAt(c) { return ch }
        return nil
    }

    // Wide-char (CJK, wide emoji) cells occupy two columns; the trailing
    // column is a spacer. If the click landed on a spacer, back up to
    // the leading character cell so the expansion finds the real word.
    // Audit findbar-selection F36 + fix-#02.
    let anchorCol: Int
    switch kindAt(point.col) {
    case .character:
        anchorCol = point.col
    case .spacer:
        // Trailing-half-of-wide-char click: walk left to the character.
        // A run of leading-spacer cells is unusual but handled.
        var c = point.col - 1
        while c >= 0, case .spacer = kindAt(c) { c -= 1 }
        guard c >= 0, case .character = kindAt(c) else { return nil }
        anchorCol = c
    case .empty, .invalid:
        return nil
    }

    // Point is on a blank / break / empty cell — there is no word to
    // expand. Return nil so callers (e.g. .word selection expansion) keep
    // their existing range instead of collapsing to a zero-width point.
    guard let here = characterAt(anchorCol), !wordBreakers.contains(here) else {
        return nil
    }

    // Backward walk: extend left over (character|spacer)+ until hitting
    // an empty/invalid cell or a character that's a word-breaker.
    var l = anchorCol
    backwardLoop: while l > 0 {
        switch kindAt(l - 1) {
        case .character(let ch):
            if wordBreakers.contains(ch) { break backwardLoop }
            l -= 1
        case .spacer:
            // Continuation cell of a wide glyph at some earlier column —
            // walk through it; the character itself will be evaluated
            // on the next iteration.
            l -= 1
        case .empty, .invalid:
            break backwardLoop
        }
    }

    // Forward walk: extend right symmetrically. Final position is the
    // last cell of the run (may be a trailing spacer for the rightmost
    // wide glyph) so the visual selection covers the full glyph extent.
    var r = anchorCol
    forwardLoop: while r + 1 < cols {
        switch kindAt(r + 1) {
        case .character(let ch):
            if wordBreakers.contains(ch) { break forwardLoop }
            r += 1
        case .spacer:
            r += 1
        case .empty, .invalid:
            break forwardLoop
        }
    }

    return (BufferPoint(line: point.line, col: l), BufferPoint(line: point.line, col: r))
}

extension Selection {
    /// Compute the (start, end) buffer points to pass into
    /// `TerminalSession.textRange` for this selection given the current grid
    /// width. Pure so the mode-specific fixups can be unit-tested.
    ///
    /// `.line` mode highlights full rows on screen; mirror that in the copy
    /// so triple-click + drag yields "every whole line between the anchor
    /// and the pointer" instead of truncating the first/last line to the
    /// pointer's column. All other modes copy the normalized pair as-is.
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
