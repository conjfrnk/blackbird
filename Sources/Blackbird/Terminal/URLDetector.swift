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
    // **Performance / ReDoS resistance (audit S3S-001):** the local part is
    // bounded to `{1,64}` (RFC 5321 caps a local part at 64 octets) and every
    // domain label run is bounded to 63 characters (RFC 1035). The local-part
    // quantifier is *possessive* (`{1,64}+`): `@` is not in the local-char
    // class, so a local run is always delimited by a non-local char and never
    // needs to give back — possessive matching is therefore semantically
    // identical to greedy here while eliminating the per-start-position
    // backtrack. Previously the unbounded greedy local part (`+`) made the
    // engine re-scan the whole run at every start position looking for an
    // `@`, which is O(n²) on inputs like `a@aaaa…a.` (one `@`, a long run, no
    // valid TLD); the bounds + possessive quantifier make every start
    // position O(63) work, so a full attacker-controlled row scans in linear
    // time (measured ~2 ms for a 1000-col row vs ~17 ms before; the old
    // pattern grew quadratically). `scan` still gates the regex behind a
    // cheap `@`-AND-`.`-present pre-check as a fast-path skip, but — unlike
    // the old comment claimed — that pre-check is *not* what makes the
    // pattern safe (the adversarial string contains both characters); the
    // length bounds are.
    //
    // Emails that land inside an already-matched `http(s)://…@…` URL
    // are filtered out after the scan (see `scan(snapshot:)`), so
    // `https://user:pass@host.com` produces one match (the https URL),
    // not two.
    private static let emailRegex: NSRegularExpression = {
        let pattern = #"[A-Za-z0-9._+\-]{1,64}+@[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*\.[A-Za-z]{2,}"#
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
                // Take the width from the incoming grapheme rather than by
                // differencing `line.utf16.count` before and after the
                // append. That was correct but cost two O(n) UTF-16 counts
                // over the string being built — quadratic across the row.
                // Appending is additive in UTF-16 code units even when the
                // grapheme merges with the previous one, so the count is
                // identical.
                let units = ch.utf16.count
                line.append(ch)
                for _ in 0..<units {
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
                let endCol = utf16ToCol[endIdx]
                let finalURLString = Self.wrapJoinedURL(
                    firstRowSubstring: substring,
                    row: row,
                    endCol: endCol,
                    snapshot: snapshot,
                    consumedNextRowPrefix: &consumedNextRowPrefix
                )
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
            // Fast-path pre-check: skip the regex on lines without both an
            // `@` and a `.`. This is a cheap O(n) skip, NOT the ReDoS guard —
            // the emailRegex is linear by construction (see its length bounds
            // + possessive local part). The adversarial `x@aaa…a.` shape
            // contains both characters and passes this pre-check; the bounds
            // are what keep the scan linear. Audit S3S-001.
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


    /// Multi-row wrapped-URL join + its five phishing guards. When a first-row
    /// URL match ends at the grid's right edge with a URL-safe continuation on
    /// the next row, walk the continuation rows, joining each into the dispatched
    /// URL — re-checking host/port equality and the continuation-leader rules at
    /// EVERY row boundary against the FIRST-row portion (S4-001 / S4-007 /
    /// cwd-hyperlink F9). Returns the joined URL string, or `substring` unchanged
    /// when the URL doesn't wrap. Records the consumed leading columns of each
    /// joined row in `consumedNextRowPrefix` so the per-row scan doesn't
    /// double-emit the continuation fragment. The visible highlight stays clamped
    /// to the first row (the caller's `endCol` is already `cols - 1` in the wrap
    /// case, per the `endCol == snapshot.cols - 1` gate below).
    private static func wrapJoinedURL(
        firstRowSubstring substring: String,
        row: Int,
        endCol: Int,
        snapshot: BBSnapshot,
        consumedNextRowPrefix: inout [Int: Int]
    ) -> String {
        var finalURLString = substring
        // Wrapped-URL heuristic: when the match ends at the right
        // edge of the grid AND the next row starts with URL-safe
        // characters, soft-wrap is the likely explanation. Walk the
        // continuation rows, joining each into the parsed URL so the
        // user can ⌘-click the whole href. BBSnapshot doesn't surface
        // alacritty's wrap flag today; this heuristic gets ~99% of
        // long CI/build-output URLs right. A URL can wrap across MANY
        // rows (a long path/query on a narrow grid), so the walk
        // continues while each consumed row is filled edge-to-edge and
        // the security guards below keep holding at every boundary.
        // Audit cwd-hyperlink F9 (single-row → multi-row walk).
        if endCol == snapshot.cols - 1,
           row + 1 < snapshot.rows,
           Self.isURLContinuationChar(snapshot.character(at: 0, row: row + 1)),
           let sub = URL(string: substring),
           let subHost = sub.host,
           !subHost.isEmpty {
            // Wrap-join is a display-vs-dispatch trade-off: the
            // highlighted span stops at the right edge (the user only
            // SEES the first-row portion) but the dispatched URL
            // carries the joined string. Five guards, re-evaluated at
            // EVERY row boundary against the FIRST-row portion, keep
            // the join honest. Audit S4-001 / S4-007 / cwd-hyperlink F9.
            //
            // (1) Joined URL must parse — sanity gate.
            // (2) Substring URL must parse AND have a non-empty host
            //     (checked once in the entry condition above). A first-
            //     row substring that parses with `host == nil` (e.g.
            //     `https://?`) would make the host-equality check
            //     evaluate `nil == nil` and admit arbitrary
            //     continuation hosts. `OSC8URLPolicy.isAllowed` would
            //     block it downstream, but the gates must not be
            //     load-bearing for each other.
            // (3) host(joined) == host(first-row). Blocks the classic
            //     S4-001 shape where a row-edge break lands mid-host:
            //     row N ends `https://apple.com`, row N+1 starts
            //     `.evil.com/login` → joined host `apple.com.evil.com`
            //     ≠ `apple.com` → REJECT (and stop the walk). Because
            //     the host is fixed to what the user saw on the first
            //     row, no later row can re-point it.
            // (4) port(joined) == port(first-row). Blocks the port-
            //     injection variant: `https://example.com` +
            //     `:8080/admin` → same host, port 8080. The user saw
            //     the apex URL underlined; a non-default port silently
            //     re-targets an internal console (`:8443`, `:9200`, …).
            // (5) Each continuation row's first character must NOT be
            //     one of `?`, `#`, `&`, `@`, `;`, `:`. These introduce
            //     query / fragment / userinfo / path-parameter / port-
            //     or-path-coercion structure that doesn't exist in the
            //     visible substring. The legitimate path-wrap case
            //     (alnum / `/` / `.` / `-` / `_` / `~`) is unaffected.
            //     The `:` case (S4-007): when the substring ends with
            //     `/`, Foundation parses a continuation `:8080/...` as
            //     PATH not port — guards 3/4 both pass — so forbidding
            //     `:` as a leader closes that gap.
            //
            // Acknowledged residual (unchanged by the multi-row walk):
            // a continuation beginning with a benign char but
            // containing `?`/`#` later (`/oauth?return_to=evil`) still
            // slips. That shape is same-host injection — the trust
            // target matches what the user saw — and is bounded by the
            // remote endpoint's own redirect/SSO policy. The structural
            // fix would be a multi-row highlight so the dispatched URL
            // matches the visible span; F9 notes that as future work.
            let subPort = sub.port
            let urlStructureLeaders: Set<Character> = ["?", "#", "&", "@", ";", ":"]
            let trimSet = Set<Character>([".", ",", ";", ":", ")", "]", "}", ">", "'", "\""])
            var accumulated = substring
            var contRow = row + 1
            while contRow < snapshot.rows,
                  Self.isURLContinuationChar(snapshot.character(at: 0, row: contRow)) {
                // Leading continuation run on `contRow`.
                var contEnd = 0
                while contEnd < snapshot.cols,
                      Self.isURLContinuationChar(snapshot.character(at: contEnd, row: contRow)) {
                    contEnd += 1
                }
                // Build the continuation text, tracking how many
                // COLUMNS each grapheme consumes so the dedup prefix
                // recorded below is in column units (what the row's own
                // scan skips), not grapheme-count units. They coincide
                // today (isURLContinuationChar admits only single-scalar
                // ASCII: one cell == one grapheme == one column), but
                // recording a grapheme count as a column index is a
                // latent unit confusion that would mis-skip if a wide /
                // non-BMP continuation char ever landed here. Audit
                // S3-004.
                var continuation = ""
                var graphemeEndColumn: [Int] = []
                for c in 0..<contEnd {
                    if let ch = snapshot.character(at: c, row: contRow) {
                        continuation.append(ch)
                        graphemeEndColumn.append(c + 1)
                    }
                }
                // Whether this run reaches the row's right edge (filled
                // edge-to-edge) decides whether the URL plausibly
                // continues onto the NEXT row.
                let filledToEdge = (contEnd == snapshot.cols)
                // Trim the trailing-punct set so a wrapped URL followed
                // by ", thanks" on the final row still yields a clean URL.
                var trimmedLen = continuation.count
                while trimmedLen > 0 {
                    let last = continuation[continuation.index(continuation.startIndex, offsetBy: trimmedLen - 1)]
                    if trimSet.contains(last) { trimmedLen -= 1 } else { break }
                }
                guard trimmedLen > 0 else { break }
                let trimmed = String(continuation.prefix(trimmedLen))
                let candidate = accumulated + trimmed
                guard let joined = URL(string: candidate),
                      joined.host == subHost,
                      joined.port == subPort,
                      let firstContChar = trimmed.first,
                      !urlStructureLeaders.contains(firstContChar) else { break }
                // Commit this row into the URL.
                accumulated = candidate
                finalURLString = candidate
                // Record how many leading COLUMNS of this row were
                // consumed so its own scan skips exactly those cells
                // and doesn't double-emit the fragment. (graphemeEnd-
                // Column[k] = columns consumed through grapheme k;
                // equals trimmedLen today but stays correct if a
                // grapheme ever spans >1 column.)
                consumedNextRowPrefix[contRow] = graphemeEndColumn[trimmedLen - 1]
                // Continue onto the next row only when this row was
                // consumed in full edge-to-edge with no trailing punct.
                // A short or punct-trimmed run means the URL ended here.
                if filledToEdge && trimmedLen == contEnd {
                    contRow += 1
                } else {
                    break
                }
            }
        }
        return finalURLString
    }

    /// Find the match under `point`, or nil.
    public static func match(at point: BufferPoint, in matches: [URLMatch]) -> URLMatch? {
        matches.first {
            $0.line == point.line && point.col >= $0.startCol && point.col <= $0.endCol
        }
    }
}
