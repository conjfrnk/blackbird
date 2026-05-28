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

    // Bare email → `mailto:` URL detection. Conservative by design:
    //
    //   - Local part: one or more of A–Z / a–z / 0–9 / `.` / `_` / `+` / `-`.
    //     RFC 5321 allows more, but we stay within the common-case ASCII
    //     set to minimise false positives in shell / log output. SSH URLs
    //     like `user@host:path` can't match because `host` lacks a TLD.
    //     Edge cases (leading-hyphen local part, leading-dot local part,
    //     trailing-dot local part) are accepted by the regex and then
    //     either pass or fail `URL(string:)`; we favour lenient detection
    //     with the click-time `OSC8URLPolicy.isAllowed` gate as the
    //     authoritative trust boundary.
    //   - Domain: at least one label, each label starting with an alnum,
    //     followed by optional alnum/`-`; the final label is a literal
    //     `.` + two-or-more-letter TLD. `.` alone isn't enough.
    //
    // **Performance note:** this pattern has O(n²) worst-case backtracking
    // on inputs like `a@aaaaa…aaaa` (one `@`, long run of alphanumerics,
    // no `.`). `scan` gates invocation behind an `@`-AND-`.`-present
    // pre-check, which is O(n) and eliminates the adversarial case — a
    // malicious remote can paste thousands of `a`s after `@`, but the
    // regex never runs without a `.` elsewhere on the line. Lines that
    // do contain both characters are already linear in practice because
    // a valid domain is bounded in length.
    //
    // Emails that land inside an already-matched `http(s)://…@…` URL
    // are filtered out after the scan (see `scan(snapshot:)`), so
    // `https://user:pass@host.com` produces one match (the https URL),
    // not two.
    private static let emailRegex: NSRegularExpression = {
        let pattern = #"[A-Za-z0-9._+\-]+@[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)*\.[A-Za-z]{2,}"#
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
            // Column ranges of http/ftp URLs matched on THIS row — used to
            // suppress email matches that fall inside a URL (e.g. the
            // `user@host.com` substring of `https://user:pass@host.com`).
            var urlColRangesThisRow: [(startCol: Int, endCol: Int)] = []
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
                        // Wrap-join is a display-vs-dispatch trade-off: the
                        // highlighted span stops at the right edge (the user
                        // only SEES the first-row portion) but the dispatched
                        // URL carries the joined string. Five guards keep
                        // the join honest. Audit S4-001 / cwd-hyperlink F9.
                        //
                        // (1) Joined URL must parse — sanity gate.
                        // (2) Substring URL must parse AND have a non-empty
                        //     host. A first-row substring that parses with
                        //     `host == nil` (e.g. `https://?`) makes the
                        //     host-equality check below evaluate `nil == nil`
                        //     and admit arbitrary continuation hosts.
                        //     `OSC8URLPolicy.isAllowed` would block it
                        //     downstream, but the two gates must not be
                        //     load-bearing for each other.
                        // (3) host(substring) == host(joined). Blocks the
                        //     classic S4-001 shape where the row-edge break
                        //     landed mid-host: row N ends `https://apple.com`,
                        //     row N+1 starts `.evil.com/login` → joined host
                        //     `apple.com.evil.com` ≠ `apple.com` → REJECT.
                        // (4) port(substring) == port(joined). Blocks the
                        //     port-injection variant: substring
                        //     `https://example.com` + continuation
                        //     `:8080/admin` → joined host equals substring
                        //     host but joined.port = 8080. The user saw the
                        //     apex URL underlined; dispatching to a non-
                        //     default port silently re-targets an internal
                        //     console (`:8443`, `:9200`, `:6379`, etc.).
                        // (5) Continuation's first character must NOT be one
                        //     of `?`, `#`, `&`, `@`, `;`, `:`. These
                        //     introduce query / fragment / userinfo /
                        //     path-parameter / port-or-path-coercion
                        //     structure that doesn't exist in the visible
                        //     substring. The legitimate long-URL-path-wrap
                        //     case (continuation starting with alnum / `/` /
                        //     `.` / `-` / `_` / `~`) is unaffected.
                        //
                        // The `:` case (audit S4-007): when the substring
                        // ends with `/`, Foundation parses a continuation
                        // `:8080/...` as part of the PATH rather than the
                        // port delimiter — host/port equality guards 3 and
                        // 4 both pass (both ports default to scheme
                        // default). Forbidding `:` as a leader closes that
                        // gap without affecting any legitimate wrap shape
                        // (a real `:port/...` only appears when the
                        // substring also lacks the trailing `/`, in which
                        // case guard 4 catches it).
                        //
                        // Acknowledged residual: a continuation that begins
                        // with a benign char but contains `?`/`#` later
                        // (e.g. `/oauth?return_to=evil`) still slips. That
                        // shape is same-host injection — the trust target
                        // matches what the user saw — and is bounded by the
                        // remote endpoint's own redirect/SSO policy. The
                        // structural fix would be to extend the highlight
                        // across rows so the dispatched URL matches the
                        // visible span; F9 notes that as a future
                        // improvement.
                        let urlStructureLeaders: Set<Character> = ["?", "#", "&", "@", ";", ":"]
                        if let joined = URL(string: candidate),
                           let sub = URL(string: substring),
                           let subHost = sub.host,
                           !subHost.isEmpty,
                           subHost == joined.host,
                           sub.port == joined.port,
                           let firstContChar = continuation.first,
                           !urlStructureLeaders.contains(firstContChar) {
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
                urlColRangesThisRow.append((startCol: startCol, endCol: endCol))
            }
            // Email pass — runs after the URL pass so we can suppress
            // emails inside URL matches (the `user@host.com` substring of
            // `https://user:pass@host.com`).
            //
            // Pre-check: the emailRegex has O(n²) worst-case backtracking
            // on `@`-present/`.`-absent input. Require both chars on the
            // line before invoking the regex. Both `contains` calls are
            // O(n) — cheap — and they eliminate the adversarial no-TLD
            // shape entirely.
            //
            // Also respect `consumedNextRowPrefix[row]` — when the
            // previous row's URL wrap-joined into our leading cells, the
            // email regex must skip those same cells so a string like
            // `bob@corp.com/path` in the consumed prefix of a wrapped
            // http URL doesn't emit a duplicate mailto match.
            if !utf16ToCol.isEmpty,
               line.contains("@"), line.contains(".") {
                emailRegex.enumerateMatches(
                    in: line,
                    range: NSRange(location: searchStartUTF16, length: nsLine.length - searchStartUTF16)
                ) { result, _, _ in
                    guard let r = result?.range, r.length > 0 else { return }
                    let substring = nsLine.substring(with: r)
                    let bufferLine = Int32(row - snapshot.displayOffset)
                    let startIdx = min(max(0, r.location), utf16ToCol.count - 1)
                    let endIdx = min(r.location + r.length - 1, utf16ToCol.count - 1)
                    let startCol = utf16ToCol[startIdx]
                    let endCol = utf16ToCol[endIdx]
                    // Drop emails that fall inside a URL match on the same
                    // row. Overlap test: any cell shared between the two
                    // ranges disqualifies the email.
                    let overlaps = urlColRangesThisRow.contains { range in
                        startCol <= range.endCol && endCol >= range.startCol
                    }
                    if overlaps { return }
                    // Policy filtering (scheme allowlist, IDN/punycode
                    // defence, mailto header defence) is applied at
                    // click/hover time in `TerminalView.resolveClickURL`
                    // and `reevaluateCmdHoverHighlight`. URLDetector
                    // stays a pure detector to match the existing
                    // http/ftp path.
                    guard let url = URL(string: "mailto:\(substring)") else { return }
                    out.append(URLMatch(
                        url: url,
                        line: bufferLine,
                        startCol: startCol,
                        endCol: endCol
                    ))
                }
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
