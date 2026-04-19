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
            var line = ""
            for col in 0..<snapshot.cols {
                line.append(snapshot.character(at: col, row: row) ?? " ")
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
                out.append(URLMatch(
                    url: url,
                    line: bufferLine,
                    startCol: r.location,
                    endCol: r.location + r.length - 1
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
