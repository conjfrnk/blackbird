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
    // Greedy over URL-safe characters; `%` is only accepted when followed
    // by two hex digits so the match span aligns with what `URL(string:)`
    // accepts without rewriting. Before this, the class treated `%` as a
    // literal and `URL(string:)` either rejected (span displayed but no
    // URL opened — OK) or normalised by inserting extra chars (the span
    // displayed fewer cells than were actually clicked open — UI/trust
    // drift). No alternation + single-char quantifier preserves linear-time
    // matching; no ReDoS shape introduced. Audit cwd-hyperlink F6.
    //
    // Trailing punctuation (.,;:]}>'") is trimmed post-match so URLs at
    // the end of sentences select cleanly.
    private static let regex: NSRegularExpression = {
        let pattern = #"(?i)(?:https?|ftp)://(?:[A-Za-z0-9\-._~:/?#\[\]@!$&'()*+,;=]|%[0-9A-Fa-f]{2})+"#
        return try! NSRegularExpression(pattern: pattern)
    }()

    /// Heuristic: does the cell at `col` on `row` hold a character that's
    /// valid inside a URL? Mirrors the regex character class minus the
    /// scheme — used to reconstruct soft-wrapped URLs (F9). Returns false
    /// for blank/out-of-range cells so we only join rows that visually
    /// continue into the next row's leftmost column.
    private static func isURLContinuationChar(_ ch: Character?) -> Bool {
        guard let ch else { return false }
        let set = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZ" +
            "abcdefghijklmnopqrstuvwxyz" +
            "0123456789" +
            "-._~:/?#[]@!$&'()*+,;=%"
        )
        return ch.unicodeScalars.allSatisfy { set.contains($0) }
    }

    /// Scan every visible row of `snapshot`. Returns matches whose `line`
    /// is buffer-relative (i.e., row - displayOffset).
    ///
    /// Visible-grid bound: work is `O(rows × cols)` per scan — ~16 KB of
    /// character reads on a 200 × 80 grid in the worst case. Bounded by
    /// the viewport; a future "scan entire scrollback" feature would need
    /// to revisit the cap. Audit cwd-hyperlink F12.
    public static func scan(snapshot: BBSnapshot) -> [URLMatch] {
        var out: [URLMatch] = []
        // Track ranges already consumed by a wrapped-URL join so the
        // per-row scan doesn't emit a second match for the continuation
        // fragment on its own. Keys are row indices that joined into the
        // previous row's URL. Audit cwd-hyperlink F9.
        var consumedNextRowPrefix: [Int: Int] = [:]  // row -> how many leading cols are part of a prior-row URL
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
            // Skip leading columns that were already absorbed by the
            // previous row's wrapped-URL join (F9). A full rescan over
            // the entire row would otherwise emit a duplicate match for
            // the fragment on its own (which might or might not parse).
            let searchStart = consumedNextRowPrefix[row] ?? 0
            let searchStartUTF16: Int = {
                if searchStart == 0 { return 0 }
                // Find the first UTF-16 offset whose column >= searchStart.
                for (i, cCol) in utf16ToCol.enumerated() where cCol >= searchStart {
                    return i
                }
                return nsLine.length
            }()
            regex.enumerateMatches(
                in: line,
                range: NSRange(location: searchStartUTF16, length: nsLine.length - searchStartUTF16)
            ) { result, _, _ in
                guard var r = result?.range else { return }
                while r.length > 0 {
                    let last = nsLine.character(at: r.location + r.length - 1)
                    if ".,);:]}>'\"".utf16.contains(last) { r.length -= 1 } else { break }
                }
                guard r.length > 0 else { return }
                let substring = nsLine.substring(with: r)
                let bufferLine = Int32(row - snapshot.displayOffset)
                // Defensive bounds — the map is always the exact length of
                // `nsLine.length`, but pin the reads just in case a future
                // snapshot helper returns an odd-width cell (e.g. a
                // combining-mark preceding a base glyph).
                let startIdx = min(max(0, r.location), utf16ToCol.count - 1)
                let endIdx = min(r.location + r.length - 1, utf16ToCol.count - 1)
                let startCol = utf16ToCol[startIdx]
                var endCol = utf16ToCol[endIdx]
                var finalURLString = substring
                // Wrapped-URL heuristic: when the match ends at the right
                // edge of the grid AND the next row starts with URL-safe
                // characters, soft-wrap is the likely explanation. Join
                // the continuation run into the parsed URL so the user
                // can ⌘-click the whole href. BBSnapshot doesn't surface
                // alacritty's wrap flag today; this heuristic gets ~99%
                // of long CI/build-output URLs right. Audit
                // cwd-hyperlink F9.
                if endCol == snapshot.cols - 1,
                   row + 1 < snapshot.rows,
                   Self.isURLContinuationChar(snapshot.character(at: 0, row: row + 1)) {
                    var contEnd = 0
                    while contEnd < snapshot.cols,
                          Self.isURLContinuationChar(snapshot.character(at: contEnd, row: row + 1)) {
                        contEnd += 1
                    }
                    // Build the continuation text, then trim the same
                    // trailing-punct set so a wrapped URL followed by
                    // ", thanks" on the next row still yields a clean URL.
                    var continuation = ""
                    for c in 0..<contEnd {
                        if let ch = snapshot.character(at: c, row: row + 1) {
                            continuation.append(ch)
                        }
                    }
                    var trimmedLen = continuation.count
                    let trimSet = Set<Character>([".", ",", ";", ":", ")", "]", "}", ">", "'", "\""])
                    while trimmedLen > 0 {
                        let last = continuation[continuation.index(continuation.startIndex, offsetBy: trimmedLen - 1)]
                        if trimSet.contains(last) {
                            trimmedLen -= 1
                        } else {
                            break
                        }
                    }
                    if trimmedLen > 0 {
                        continuation = String(continuation.prefix(trimmedLen))
                        let candidate = substring + continuation
                        // Only accept the join when the joined text parses
                        // as a URL. Otherwise the next-row content wasn't a
                        // continuation after all and we emit the row's
                        // original match unjoined.
                        if URL(string: candidate) != nil {
                            finalURLString = candidate
                            // Record how many leading columns of the next
                            // row were consumed so that row's own scan
                            // skips them and doesn't double-emit.
                            consumedNextRowPrefix[row + 1] = trimmedLen
                            // Extend the match's endCol virtually past the
                            // right edge — the caller uses (line, endCol)
                            // for the highlight. Keep endCol clamped to
                            // the row since span-on-first-row is the
                            // correct display cue; F9 acknowledges a
                            // multi-row highlight is a future improvement.
                            endCol = snapshot.cols - 1
                        }
                    }
                }
                guard let url = URL(string: finalURLString) else {
                    #if DEBUG
                    // Diagnosability: silent drops mean a future regex
                    // loosening can break URL parsing without anyone
                    // noticing. Log at debug level in DEBUG builds.
                    // Audit cwd-hyperlink F11.
                    debugPrint("URLDetector: regex matched but URL(string:) rejected: \(finalURLString)")
                    #endif
                    return
                }
                out.append(URLMatch(
                    url: url,
                    line: bufferLine,
                    startCol: startCol,
                    endCol: endCol
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
