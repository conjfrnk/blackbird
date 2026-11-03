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
    // drift). Every quantified atom is a single character (or `%HH`) from a
    // set that is disjoint from the next atom, with no nested quantifier, so
    // matching stays linear-time; no ReDoS shape introduced. Audit
    // cwd-hyperlink F6.
    //
    // Non-ASCII letters, marks and numbers (`\p{L}\p{M}\p{N}`) are accepted in
    // the path, query and fragment (everything from the first `/`, `?` or `#`
    // after the scheme), so an IRI like `…/wiki/Bücher`, `?q=café` or
    // `…/wiki/日本` is one match instead of ending at the first non-ASCII
    // scalar and opening a truncated page. `URL(string:)` percent-encodes them
    // (macOS 14+). The AUTHORITY (userinfo, host, port) stays ASCII-only: a
    // match can never carry a non-ASCII host, and a URL printed with prose
    // glued straight onto the host (`访问https://github.com中文`) keeps its
    // clean host link. Whitespace, symbols, punctuation (including fullwidth
    // `，。（）`), bidi/invisible format scalars and the invisible Hangul filler
    // letters (U+115F U+1160 U+3164 U+FFA0) all stay terminators.
    //
    // Known trade-off: prose written directly after the path with no space or
    // punctuation (`詳細はhttps://example.com/docs/を参照してください`) is absorbed
    // into the URL. `/wiki/日本` and `/docs/を参照` cannot be told apart without
    // a language model; other terminals' link detectors accept the same
    // trade-off. Fullwidth punctuation or a space ends the match as before.
    //
    // Combining scalars that the core folds into the previous cell are never
    // exported to the grid, so a decomposed (NFD) IRI reads without its accents.
    //
    // Trailing punctuation (.,);:]}>'") is trimmed post-match so URLs at
    // the end of sentences select cleanly; a `)`/`]` that closes a `(`/`[`
    // inside the URL stays (see `trailingPunctuationCount`).
    //
    // The wrapped-URL join walks the same alphabet through `isURLBodyScalar`,
    // its twin; `URLDetectorNonASCIIWrapTests` pins the two together.
    private static let regex: NSRegularExpression = {
        let percentEscape: String = "%[0-9A-Fa-f]{2}"
        // Authority atoms: ASCII only and no `/ ? #`, so it ends at the path.
        var authorityAtom: String = #"(?:[A-Za-z0-9\-._~:@!$&'()*+,;=\[\]]|"#
        authorityAtom += percentEscape + ")"
        // Path/query/fragment atoms: the ASCII set plus non-ASCII L/M/N, minus
        // the invisible Hangul fillers.
        var bodyAtom: String = #"(?:[A-Za-z0-9\-._~:/?#\[\]@!$&'()*+,;=]"#
        bodyAtom += #"|(?![\x{115F}\x{1160}\x{3164}\x{FFA0}])[\p{L}\p{M}\p{N}]|"#
        bodyAtom += percentEscape + ")"
        let rest: String = "[/?#]" + bodyAtom + "*"
        var pattern: String = "(?i)(?:https?|ftp)://(?:"
        pattern += authorityAtom + "+(?:" + rest + ")?|" + rest + ")"
        return try! NSRegularExpression(pattern: pattern)
    }()

    /// Enumerate http(s)/ftp URL candidates in `line` from UTF-16 offset
    /// `start`, with the trailing-punctuation trim already applied and
    /// zero-length results dropped. Shared by `scan` and the DEBUG-only
    /// `FakeHyperlinkSnapshot` so tests exercise the shipped pattern
    /// instead of a second copy of it.
    static func forEachURLRange(
        in line: String,
        nsLine: NSString,
        from start: Int = 0,
        _ body: (NSRange, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {
        regex.enumerateMatches(
            in: line,
            range: NSRange(location: start, length: nsLine.length - start)
        ) { result, _, stop in
            guard var r = result?.range else { return }
            // Every trimmed character is ASCII, so UTF-16 units == characters.
            r.length -= trailingPunctuationCount(in: nsLine.substring(with: r))
            guard r.length > 0 else { return }
            body(r, stop)
        }
    }

    /// How many trailing characters of `text` (a regex match, or a wrapped URL
    /// joined so far) are sentence/markup punctuation rather than URL.
    /// `.,;:}>'"` always are. `)` and `]` are only when no `(` / `[` earlier in
    /// `text` pairs with them: `…/Rust_(programming_language)` and `http://[::1]`
    /// keep their closer, `(see https://x.com)` and `[t](https://x.com)` lose
    /// theirs. Shared by the single-row match and the wrap-join so a wrapped URL
    /// trims exactly like its unwrapped form.
    private static func trailingPunctuationCount(in text: String) -> Int {
        // Openers minus closers; a trailing closer is unmatched while negative.
        var parens = 0
        var brackets = 0
        for u in text.utf16 {
            switch u {
            case 0x28: parens += 1      // (
            case 0x29: parens -= 1      // )
            case 0x5B: brackets += 1    // [
            case 0x5D: brackets -= 1    // ]
            default: break
            }
        }
        var count = 0
        for u in text.utf16.reversed() {
            switch u {
            case 0x29 where parens >= 0, 0x5D where brackets >= 0:
                return count
            case 0x29: parens += 1
            case 0x5D: brackets += 1
            case _ where ".,;:}>'\"".utf16.contains(u): break
            default: return count
            }
            count += 1
        }
        return count
    }

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

    /// Heuristic: is `ch` valid inside a URL's path/query/fragment? Mirrors the
    /// regex's body alphabet (the ASCII set, non-ASCII letters/marks/numbers
    /// minus the invisible Hangul fillers, and a bare `%`) -- used to
    /// reconstruct soft-wrapped URLs (F9). Returns false for nil (blank /
    /// out-of-range) cells so we only join rows that visually continue into
    /// the next row's leftmost column. Internal so the regex-parity test can
    /// reach it.
    static func isURLContinuationChar(_ ch: Character?) -> Bool {
        guard let ch else { return false }
        // `allSatisfy` keeps the old semantics: any non-member scalar
        // (including the extra scalars of a multi-scalar grapheme) rejects.
        return ch.unicodeScalars.allSatisfy { (scalar: Unicode.Scalar) -> Bool in
            Self.isURLBodyScalar(scalar)
        }
    }

    /// One scalar of the body alphabet. The 85 ASCII members are a pure scalar
    /// switch (no per-call allocation); non-ASCII scalars are admitted by
    /// general category, matching the regex's `\p{L}\p{M}\p{N}`.
    private static func isURLBodyScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "A"..."Z", "a"..."z", "0"..."9",
             "-", ".", "_", "~", ":", "/", "?", "#", "[", "]", "@",
             "!", "$", "&", "'", "(", ")", "*", "+", ",", ";", "=", "%":
            return true
        case "\u{115F}", "\u{1160}", "\u{3164}", "\u{FFA0}":
            // Invisible Hangul filler letters (category Lo) -- a URL must not
            // carry scalars the user cannot see.
            return false
        default:
            switch scalar.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter,
                 .modifierLetter, .otherLetter,
                 .nonspacingMark, .spacingMark, .enclosingMark,
                 .decimalNumber, .letterNumber, .otherNumber:
                return true
            default:
                return false
            }
        }
    }

    /// Whether the cell at (`col`, `row`) is the `LEADING_WIDE_CHAR_SPACER` pad:
    /// the blank last column of a row left over when a wide glyph did not fit
    /// and wrapped. `cellKind` reports it as `.spacer`, like the trailing half of
    /// a wide glyph, but it belongs to the NEXT row's first glyph.
    private static func isLeadingWideSpacer(col: Int, row: Int, snapshot: BBSnapshot) -> Bool {
        guard col >= 0, row >= 0, col < snapshot.cols, row < snapshot.rows else { return false }
        let idx = row * snapshot.cols + col
        guard idx < snapshot.cellCount else { return false }
        return snapshot.cellsPointer[idx].flags & UInt16(LEADING_WIDE_CHAR_SPACER) != 0
    }

    /// Scan every visible row of `snapshot`. Returns matches whose `line`
    /// is buffer-relative (i.e., row - displayOffset).
    ///
    /// Visible-grid bound: work is `O(rows × cols)` per scan — ~16 KB of
    /// character reads on a 200 × 80 grid in the worst case. Bounded by
    /// the viewport; a future "scan entire scrollback" feature would need
    /// to revisit the cap. Audit cwd-hyperlink F12.
    /// `rows`: when non-nil, only these SCREEN rows are scanned (a wrapped
    /// URL that starts in a scanned row may still consume the next row's
    /// prefix). Used by `HoverCoordinator` to rescan damaged rows and merge
    /// the result over its cache instead of walking the whole grid per
    /// published snapshot while ⌘ is held.
    public static func scan(snapshot: BBSnapshot, rows: Set<Int>? = nil) -> [URLMatch] {
        var out: [URLMatch] = []
        // Track ranges already consumed by a wrapped-URL join so the
        // per-row scan doesn't emit a second match for the continuation
        // fragment on its own. Keys are row indices that joined into the
        // previous row's URL. Audit cwd-hyperlink F9.
        var consumedNextRowPrefix: [Int: Int] = [:]  // row -> how many leading cols are part of a prior-row URL
        for row in 0..<snapshot.rows {
            if let rows, !rows.contains(row) { continue }
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
                // `character(at:)` reads a wide glyph's trailing spacer cell
                // back as " ", which would end a URL at every CJK character.
                // The glyph's leading cell already maps its UTF-16 units to the
                // right column, so the spacer contributes nothing.
                if snapshot.cellKind(at: col, row: row) == .spacer { continue }
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
            // Every URL match needs the literal `://`, so a row with no
            // ASCII ':' cannot match -- skip the regex pass entirely.
            if line.utf8.contains(0x3A) {
                forEachURLRange(
                    in: line,
                    nsLine: nsLine,
                    from: searchStartUTF16
                ) { r, _ in
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
                    var reachesRightEdge = endCol == snapshot.cols - 1
                    if endCol + 1 < snapshot.cols,
                       snapshot.cellKind(at: endCol + 1, row: row) == .spacer {
                        if Self.isLeadingWideSpacer(col: endCol + 1, row: row, snapshot: snapshot) {
                            // The next wide glyph did not fit and wrapped, so
                            // the URL may continue there. The pad is blank:
                            // keep the underline on the last real cell, but
                            // arm the wrap join.
                            reachesRightEdge = true
                        } else {
                            // A URL ending in a wide glyph maps to its leading
                            // cell; extend over the glyph's own spacer so the
                            // underline and hit-test cover the whole glyph.
                            endCol += 1
                            reachesRightEdge = endCol == snapshot.cols - 1
                        }
                    }
                    let finalURLString = Self.wrapJoinedURL(
                        firstRowSubstring: substring,
                        row: row,
                        reachesRightEdge: reachesRightEdge,
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


    /// Whether screen row `row` runs on into `row + 1`. On the primary screen
    /// that is the core's soft-wrap bit: a URL that merely ENDS at the last
    /// column before a hard newline (`printf 'https://…\r\n'`) is not
    /// continued, so the next line's text must not be glued onto it. On the
    /// alt screen, tmux and full-screen TUIs lay wrapped rows out with cursor
    /// motion and never set the bit, so there the join falls back to the
    /// edge-plus-URL-safe-leader guess (the guards in `wrapJoinedURL` still
    /// apply). That leaves a full-width URL followed by a hard newline on the
    /// alt screen joining the next line; it is unfixable from the grid alone
    /// and recorded in KNOWN_ISSUES.md.
    private static func rowContinues(_ row: Int, in snapshot: BBSnapshot) -> Bool {
        snapshot.termMode.contains(.altScreen) || snapshot.isSoftWrapped(row: row)
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
    /// to the first row. `reachesRightEdge` is the caller's verdict that the
    /// match ends in the row's last column (or in the column before a wrapped
    /// wide glyph's blank pad).
    private static func wrapJoinedURL(
        firstRowSubstring substring: String,
        row: Int,
        reachesRightEdge: Bool,
        snapshot: BBSnapshot,
        consumedNextRowPrefix: inout [Int: Int]
    ) -> String {
        var finalURLString = substring
        // Wrapped-URL heuristic: when the match ends at the right
        // edge of the grid AND the row soft-wrapped (see
        // `rowContinues`) AND the next row starts with URL-safe
        // characters, the URL continues there. Walk the continuation
        // rows, joining each into the parsed URL so the user can
        // ⌘-click the whole href. A URL can wrap across MANY rows (a
        // long path/query on a narrow grid), so the walk continues
        // while each consumed row is filled edge-to-edge and the
        // security guards below keep holding at every boundary.
        // Audit cwd-hyperlink F9 (single-row → multi-row walk).
        if reachesRightEdge,
           row + 1 < snapshot.rows,
           Self.rowContinues(row, in: snapshot),
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
            var accumulated = substring
            var contRow = row + 1
            while contRow < snapshot.rows,
                  Self.isURLContinuationChar(snapshot.character(at: 0, row: contRow)) {
                // Leading continuation run on `contRow`, walked cell by cell.
                // Each entry is one URL character and the column just past
                // everything it owns: a wide glyph's trailing spacer cell is
                // folded into its glyph (`character(at:)` would read it back
                // as " " and end the run), and the end-of-row pad ahead of a
                // wrapped wide glyph is folded into the last real character.
                // Recording COLUMNS keeps the dedup prefix below in the units
                // the row's own scan skips, not grapheme-count units. Audit
                // S3-004.
                var run: [(ch: Character, endColumn: Int)] = []
                var col = 0
                runWalk: while col < snapshot.cols {
                    switch snapshot.cellKind(at: col, row: contRow) {
                    case .character(let ch) where Self.isURLContinuationChar(ch):
                        run.append((ch: ch, endColumn: col + 1))
                    case .spacer where !run.isEmpty:
                        run[run.count - 1].endColumn = col + 1
                    default:
                        break runWalk
                    }
                    col += 1
                }
                var continuation = ""
                for entry in run { continuation.append(entry.ch) }
                // Whether this run reaches the row's right edge (filled
                // edge-to-edge) decides whether the URL plausibly
                // continues onto the NEXT row.
                let filledToEdge = (col == snapshot.cols)
                // Trim the trailing-punct set so a wrapped URL followed
                // by ", thanks" on the final row still yields a clean URL.
                // Balance is judged over the whole joined URL, not just this
                // row: the `(` may sit on an earlier row than its `)`.
                // The trimmed characters are ASCII punctuation, one cell and
                // one UTF-16 unit each, so the unit count is a count of
                // trailing run entries.
                let trimmedLen = max(0, run.count
                    - trailingPunctuationCount(in: accumulated + continuation))
                guard trimmedLen > 0 else { break }
                var trimmed = ""
                for entry in run.prefix(trimmedLen) { trimmed.append(entry.ch) }
                let candidate = accumulated + trimmed
                guard let joined = URL(string: candidate),
                      joined.host == subHost,
                      joined.port == subPort,
                      !urlStructureLeaders.contains(run[0].ch) else { break }
                // Commit this row into the URL.
                accumulated = candidate
                finalURLString = candidate
                // Record how many leading COLUMNS of this row were
                // consumed so its own scan skips exactly those cells
                // and doesn't double-emit the fragment. A wide glyph spans
                // two columns, so this is not `trimmedLen`.
                consumedNextRowPrefix[contRow] = run[trimmedLen - 1].endColumn
                // Continue onto the next row only when this row was
                // consumed in full edge-to-edge with no trailing punct
                // and wrapped (a hard newline right after a full row
                // ends the URL). A short or punct-trimmed run means the
                // URL ended here.
                if filledToEdge && trimmedLen == run.count
                    && Self.rowContinues(contRow, in: snapshot) {
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
