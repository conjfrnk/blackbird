import Foundation
import BBCore

/// A URL found in the visible viewport of a snapshot. `line` is buffer-
/// relative so the match stays valid as the user scrolls — resolution
/// happens against the current snapshot, but the match's line is stable
/// until the grid re-flows.
public struct URLMatch {
    public let url: URL
    public let line: Int32
    public let startCol: Int
    public let endCol: Int   // inclusive
}

public enum URLDetector {
    // Matches http(s):// and ftp:// only. Intentionally excludes `file://`:
    // NSWorkspace.open on a file URL dispatches to the registered opener,
    // which for extensions like `.command`, `.app`, `.pkg`, `.workflow`,
    // `.terminal`, `.scpt`, `.webloc` triggers *execution* of the payload.
    // A remote printing `see file:///tmp/x.command` in plain output and
    // the user ⌘-clicking is a one-keystroke RCE. Users with a legitimate
    // local path should copy and `open <path>` from the shell.
    //
    // Greedy over URL-safe characters; trims trailing punctuation that's
    // typically glued to URLs in prose.
    private static let regex: NSRegularExpression = {
        let pattern = #"(?i)(?:https?|ftp)://[A-Za-z0-9\-._~:/?#\[\]@!$&'()*+,;=%]+"#
        return try! NSRegularExpression(pattern: pattern)
    }()

    /// Scan every visible row of `snapshot`. Returns matches whose `line`
    /// is buffer-relative (i.e., row - displayOffset).
    public static func scan(snapshot: BBSnapshot) -> [URLMatch] {
        var out: [URLMatch] = []
        for row in 0..<snapshot.rows {
            // Build the line AND a parallel UTF-16-offset → column map so
            // the regex's NSRange (UTF-16 units) can be translated back to
            // cell columns. A non-BMP character (e.g. 😀 = U+1F600 = 2
            // UTF-16 units) occupies one cell but two UTF-16 positions; the
            // old code used `r.location` directly as a column, which
            // mis-columned every match that appeared after a non-BMP glyph
            // on the same row (audit swift-tests-core F6).
            var line = ""
            var utf16ToCol: [Int] = []  // index: UTF-16 offset, value: column
            utf16ToCol.reserveCapacity(snapshot.cols)
            for col in 0..<snapshot.cols {
                let ch = snapshot.character(at: col, row: row) ?? " "
                let before = line.utf16.count
                line.append(ch)
                let after = line.utf16.count
                for _ in before..<after {
                    utf16ToCol.append(col)
                }
            }
            let nsLine = line as NSString
            regex.enumerateMatches(
                in: line,
                range: NSRange(location: 0, length: nsLine.length)
            ) { result, _, _ in
                guard var r = result?.range else { return }
                while r.length > 0 {
                    let last = nsLine.character(at: r.location + r.length - 1)
                    if ".,);:]}>'\"".utf16.contains(last) { r.length -= 1 } else { break }
                }
                guard r.length > 0 else { return }
                let substring = nsLine.substring(with: r)
                guard let url = URL(string: substring) else { return }
                let bufferLine = Int32(row - snapshot.displayOffset)
                // Defensive bounds — the map is always the exact length of
                // `nsLine.length`, but pin the reads just in case a future
                // snapshot helper returns an odd-width cell (e.g. a
                // combining-mark preceding a base glyph).
                let startIdx = min(max(0, r.location), utf16ToCol.count - 1)
                let endIdx = min(r.location + r.length - 1, utf16ToCol.count - 1)
                out.append(URLMatch(
                    url: url,
                    line: bufferLine,
                    startCol: utf16ToCol[startIdx],
                    endCol: utf16ToCol[endIdx]
                ))
            }
        }
        return out
    }

    /// Find the match under `point`, or nil.
    public static func match(at point: BufferPoint, in matches: [URLMatch]) -> URLMatch? {
        matches.first {
            $0.line == point.line && point.col >= $0.startCol && point.col <= $0.endCol
        }
    }
}
