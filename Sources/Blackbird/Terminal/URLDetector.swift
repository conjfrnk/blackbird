import Foundation
import BBCore

/// `line` is buffer-relative.
public struct URLMatch {
    public let url: URL
    public let line: Int32
    public let startCol: Int
    public let endCol: Int   // inclusive
}

public enum URLDetector {
    // http(s) and ftp only. `file://` is excluded: NSWorkspace.open on a file URL executes
    // `.command`, `.app`, `.pkg`, `.workflow`, `.terminal`, `.scpt`, `.webloc` payloads.
    // `%` matches only as `%HH`, so the span is what `URL(string:)` accepts. Every quantified atom
    // is one character disjoint from the next atom, with no nested quantifier: linear-time.
    // Non-ASCII letters/marks/numbers are accepted from the first `/ ? #` on; the authority stays
    // ASCII-only. `isURLBodyScalar` must accept the same body alphabet.
    private static let regex: NSRegularExpression = {
        let percentEscape: String = "%[0-9A-Fa-f]{2}"
        var authorityAtom: String = #"(?:[A-Za-z0-9\-._~:@!$&'()*+,;=\[\]]|"#
        authorityAtom += percentEscape + ")"
        var bodyAtom: String = #"(?:[A-Za-z0-9\-._~:/?#\[\]@!$&'()*+,;=]"#
        bodyAtom += #"|(?![\x{115F}\x{1160}\x{3164}\x{FFA0}])[\p{L}\p{M}\p{N}]|"#
        bodyAtom += percentEscape + ")"
        let rest: String = "[/?#]" + bodyAtom + "*"
        var pattern: String = "(?i)(?:https?|ftp)://(?:"
        pattern += authorityAtom + "+(?:" + rest + ")?|" + rest + ")"
        return try! NSRegularExpression(pattern: pattern)
    }()

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

    /// `.,;:}>'"` always count; `)` and `]` only when no earlier `(` / `[` in `text` pairs with them.
    private static func trailingPunctuationCount(in text: String) -> Int {
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

    // The local part is bounded to 64 (RFC 5321), each domain label to 63 (RFC 1035), and the local
    // quantifier is possessive: these bounds, not `scan`'s `@`/`.` pre-check, keep matching linear.
    private static let emailRegex: NSRegularExpression = {
        let pattern = #"[A-Za-z0-9._+\-]{1,64}+@[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*\.[A-Za-z]{2,}"#
        return try! NSRegularExpression(pattern: pattern)
    }()

    static func isURLContinuationChar(_ ch: Character?) -> Bool {
        guard let ch else { return false }
        return ch.unicodeScalars.allSatisfy { (scalar: Unicode.Scalar) -> Bool in
            Self.isURLBodyScalar(scalar)
        }
    }

    private static func isURLBodyScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "A"..."Z", "a"..."z", "0"..."9",
             "-", ".", "_", "~", ":", "/", "?", "#", "[", "]", "@",
             "!", "$", "&", "'", "(", ")", "*", "+", ",", ";", "=", "%":
            return true
        case "\u{115F}", "\u{1160}", "\u{3164}", "\u{FFA0}":
            // Invisible Hangul filler letters (category Lo).
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

    /// The `LEADING_WIDE_CHAR_SPACER` pad is the blank last column left when a wide glyph wrapped.
    /// `cellKind` reports it as `.spacer`, but it belongs to the NEXT row's first glyph.
    private static func isLeadingWideSpacer(col: Int, row: Int, snapshot: BBSnapshot) -> Bool {
        guard col >= 0, row >= 0, col < snapshot.cols, row < snapshot.rows else { return false }
        let idx = row * snapshot.cols + col
        guard idx < snapshot.cellCount else { return false }
        return snapshot.cellsPointer[idx].flags & UInt16(LEADING_WIDE_CHAR_SPACER) != 0
    }

    /// `rows` are SCREEN rows; returned `line`s are buffer-relative (row - displayOffset).
    public static func scan(snapshot: BBSnapshot, rows: Set<Int>? = nil) -> [URLMatch] {
        var out: [URLMatch] = []
        var consumedNextRowPrefix: [Int: Int] = [:]  // row -> how many leading cols are part of a prior-row URL
        for row in 0..<snapshot.rows {
            if let rows, !rows.contains(row) { continue }
            // The regex's NSRange is in UTF-16 units; a non-BMP character is one cell but two units.
            var line = ""
            var utf16ToCol: [Int] = []  // index: UTF-16 offset, value: column
            utf16ToCol.reserveCapacity(snapshot.cols)
            for col in 0..<snapshot.cols {
                // `character(at:)` reads a wide glyph's trailing spacer back as " ", ending a URL there.
                if snapshot.cellKind(at: col, row: row) == .spacer { continue }
                let ch = snapshot.character(at: col, row: row) ?? " "
                let units = ch.utf16.count
                line.append(ch)
                for _ in 0..<units {
                    utf16ToCol.append(col)
                }
            }
            let nsLine = line as NSString
            let searchStart = consumedNextRowPrefix[row] ?? 0
            let searchStartUTF16: Int = {
                if searchStart == 0 { return 0 }
                for (i, cCol) in utf16ToCol.enumerated() where cCol >= searchStart {
                    return i
                }
                return nsLine.length
            }()
            var urlColRangesThisRow: [(startCol: Int, endCol: Int)] = []
            // Every URL match needs the literal `://`, so a row with no ASCII ':' cannot match.
            if line.utf8.contains(0x3A) {
                forEachURLRange(
                    in: line,
                    nsLine: nsLine,
                    from: searchStartUTF16
                ) { r, _ in
                    let substring = nsLine.substring(with: r)
                    let bufferLine = Int32(row - snapshot.displayOffset)
                    let startIdx = min(max(0, r.location), utf16ToCol.count - 1)
                    let endIdx = min(r.location + r.length - 1, utf16ToCol.count - 1)
                    let startCol = utf16ToCol[startIdx]
                    var endCol = utf16ToCol[endIdx]
                    var reachesRightEdge = endCol == snapshot.cols - 1
                    if endCol + 1 < snapshot.cols,
                       snapshot.cellKind(at: endCol + 1, row: row) == .spacer {
                        if Self.isLeadingWideSpacer(col: endCol + 1, row: row, snapshot: snapshot) {
                            // The next wide glyph wrapped: the URL may continue on the next row.
                            reachesRightEdge = true
                        } else {
                            // The URL ends in a wide glyph: cover the glyph's own spacer cell.
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
            // After the URL pass so emails inside a URL match (`https://user:pass@host.com`) are dropped.
            if line.contains("@"), line.contains(".") {
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
                    let overlaps = urlColRangesThisRow.contains { range in
                        startCol <= range.endCol && endCol >= range.startCol
                    }
                    if overlaps { return }
                    // Policy filtering is applied at click/hover time; this stays a pure detector.
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

    /// tmux and full-screen TUIs wrap with cursor motion and never set the soft-wrap bit, so on
    /// the alt screen every row is treated as continuing.
    private static func rowContinues(_ row: Int, in snapshot: BBSnapshot) -> Bool {
        snapshot.termMode.contains(.altScreen) || snapshot.isSoftWrapped(row: row)
    }

    /// The visible highlight stays on the first row while the dispatched URL carries the join, so
    /// every joined row is re-checked against the FIRST-row portion.
    private static func wrapJoinedURL(
        firstRowSubstring substring: String,
        row: Int,
        reachesRightEdge: Bool,
        snapshot: BBSnapshot,
        consumedNextRowPrefix: inout [Int: Int]
    ) -> String {
        var finalURLString = substring
        // The first-row host must be non-empty: with `host == nil` the host-equality check below
        // would be `nil == nil` and admit any continuation host.
        if reachesRightEdge,
           row + 1 < snapshot.rows,
           Self.rowContinues(row, in: snapshot),
           Self.isURLContinuationChar(snapshot.character(at: 0, row: row + 1)),
           let sub = URL(string: substring),
           let subHost = sub.host,
           !subHost.isEmpty {
            let subPort = sub.port
            // A continuation row must not start query / fragment / userinfo / path-parameter / port
            // structure. `:` is barred because after a trailing `/` Foundation parses `:8080/...` as path.
            let urlStructureLeaders: Set<Character> = ["?", "#", "&", "@", ";", ":"]
            var accumulated = substring
            var contRow = row + 1
            while contRow < snapshot.rows,
                  Self.isURLContinuationChar(snapshot.character(at: 0, row: contRow)) {
                // A wide glyph's trailing spacer folds into its glyph. `endColumn` is in COLUMNS,
                // the unit the row's own scan skips, not graphemes.
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
                let filledToEdge = (col == snapshot.cols)
                // Balance is judged over the whole joined URL: the `(` may sit on an earlier row.
                let trimmedLen = max(0, run.count
                    - trailingPunctuationCount(in: accumulated + continuation))
                guard trimmedLen > 0 else { break }
                var trimmed = ""
                for entry in run.prefix(trimmedLen) { trimmed.append(entry.ch) }
                let candidate = accumulated + trimmed
                // Host and port must equal the first row's: blocks `https://apple.com` +
                // `.evil.com/login` and `https://example.com` + `:8080/admin`.
                guard let joined = URL(string: candidate),
                      joined.host == subHost,
                      joined.port == subPort,
                      !urlStructureLeaders.contains(run[0].ch) else { break }
                accumulated = candidate
                finalURLString = candidate
                consumedNextRowPrefix[contRow] = run[trimmedLen - 1].endColumn
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

    public static func match(at point: BufferPoint, in matches: [URLMatch]) -> URLMatch? {
        matches.first {
            $0.line == point.line && point.col >= $0.startCol && point.col <= $0.endCol
        }
    }
}
