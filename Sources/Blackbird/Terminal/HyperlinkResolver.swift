import AppKit
import Foundation
import BBCore

public protocol URLOpener {
    func open(_ url: URL)
}

public struct DefaultURLOpener: URLOpener {
    public init() {}
    public func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}

/// Scheme allowlist for OSC 8 hyperlinks: the payload is remote-controlled and `NSWorkspace.open` launches the handler of any scheme.
enum OSC8URLPolicy {
    /// `file` is deliberately excluded: `NSWorkspace.open` on a `.command`, `.app`, `.pkg`, `.workflow`, `.terminal`, `.scpt`,
    /// `.webloc` or `.inetloc` file URL executes it. `ftp` is excluded too: its URLs commonly embed plaintext credentials.
    static let allowedSchemes: Set<String> = ["http", "https", "mailto"]

    private static let hostRequiredSchemes: Set<String> = ["http", "https"]

    /// Refused in the percent-decoded `mailto:` envelope: recipient separators and header/escape delimiters.
    private static let mailtoEnvelopeSeparators: Set<Unicode.Scalar> =
        [",", ";", "?", "&", "=", "%"]

    private static let mailtoSubjectValueSeparators: Set<Unicode.Scalar> =
        ["&", ";", "=", "%"]

    static func isAllowed(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        guard allowedSchemes.contains(scheme) else { return false }
        // `URL.host` strips userinfo, and Foundation can populate `password` without `user` (`https://:pw@host/`).
        if let user = url.user, !user.isEmpty { return false }
        if let password = url.password, !password.isEmpty { return false }
        // Foundation keeps a percent-encoded control byte in `absoluteString` but normalises it out of `path`
        // (`mailto:user@apple.com%08evil.com`), so every later check would compare the wrong substring.
        guard !containsPercentEncodedControlBytes(url.absoluteString) else { return false }
        if scheme == "mailto" {
            return isMailtoSafe(url)
        }
        if hostRequiredSchemes.contains(scheme) {
            guard let host = url.host, !host.isEmpty else { return false }
            // Homograph hosts: `https://xn--pple-43d.com/` (Cyrillic "аpple") under the anchor text "apple.com".
            if hostLooksLikeIDN(host) { return false }
        }
        return true
    }

    /// Parsed from `absoluteString`: `URL.path` is empty for `mailto:user@host` on macOS 14.
    private static func mailtoDomain(_ url: URL) -> String? {
        return mailtoDomain(fromAbsoluteString: url.absoluteString)
    }

    private static func mailtoDomain(fromAbsoluteString s: String) -> String? {
        guard let envelope = mailtoEnvelope(fromAbsoluteString: s), !envelope.isEmpty else {
            return nil
        }
        // RFC 6068 multi-recipient mailto (`mailto:user@safe.com,b@evil.com`) has no canonical domain: fail closed.
        guard atSignCount(in: envelope) == 1 else { return nil }
        // Split on the `@` scalar, not the `Character`: a decoded combining mark right after the `@` fuses with it.
        let scalars = envelope.unicodeScalars
        guard let at = scalars.firstIndex(of: "@") else { return nil }
        let domain = scalars[scalars.index(after: at)...]
        if domain.isEmpty { return nil }
        // Already percent-decoded; a second pass would read `%2541` as `A` where the mail client sees `%41`.
        return String(domain).lowercased()
    }

    /// The Rust core catches these scalars as raw UTF-8 in an OSC 8 URI, but not percent-encoded, which `absoluteString` preserves.
    private static func containsPercentEncodedControlBytes(_ s: String) -> Bool {
        guard s.utf8.contains(0x25) else { return false }
        let c0DelPattern = #"%(?i)(0[0-9A-F]|1[0-9A-F]|7F)"#
        // A lone %80-%9F is not matched: that would over-block UTF-8 continuation bytes such as `%E2%9C%93`.
        let c1Pattern = #"%(?i)C2%(8[0-9A-F]|9[0-9A-F])"#
        // U+2028..U+202F: %E2%80%A8..%AF. U+200B..U+200F: %E2%80%8B..%8F.
        let bidi80Pattern = #"%(?i)E2%80%(A[8-9A-F]|8[B-F])"#
        // U+2060 (word joiner) and U+2066..U+2069 (bidi isolates).
        let bidi81Pattern = #"%(?i)E2%81%A[06-9]"#
        let shyPattern = #"%(?i)C2%AD"#
        let almPattern = #"%(?i)D8%9C"#
        let mvsPattern = #"%(?i)E1%A0%8E"#
        let vsPattern = #"%(?i)EF%B8%8[0-9A-F]"#
        let bomPattern = #"%(?i)EF%BB%BF"#
        // U+E0000..U+E007F tag block; over-matches the reserved, still invisible U+E0080..U+E00FF.
        let tagBlockPattern = #"%(?i)F3%A0%(80|81)%[0-9A-F]{2}"#
        // U+E0100..U+E01EF (VS17-256); over-matches the reserved, still invisible U+E01F0..U+E01FF.
        let vs17Pattern = #"%(?i)F3%A0%(84|85|86|87)%[0-9A-F]{2}"#
        for pattern in [
            c0DelPattern, c1Pattern,
            bidi80Pattern, bidi81Pattern,
            shyPattern, almPattern, mvsPattern,
            vsPattern, bomPattern,
            tagBlockPattern, vs17Pattern,
        ] {
            if s.range(of: pattern, options: .regularExpression) != nil {
                return true
            }
        }
        return false
    }

    private static func hostLooksLikeIDN(_ host: String) -> Bool {
        for scalar in host.unicodeScalars {
            if scalar.value > 0x7F { return true }
        }
        // `xn--` is the IDNA ACE (punycode) prefix.
        let lower = host.lowercased()
        for label in lower.split(separator: ".") {
            if label.hasPrefix("xn--") { return true }
        }
        return false
    }

    /// True when the anchor text holds a URL-shaped token whose host differs from the href's. Plain-text anchors return false.
    static func anchorDivergesFromHost(anchorText: String, url: URL) -> Bool {
        let hrefScheme = url.scheme?.lowercased()
        guard let (anchorURL, hadURLShape) = extractAnchorURL(from: anchorText) else {
            return false
        }
        guard let anchorURLValid = anchorURL else {
            // URL-shaped but unparseable: fail closed so a parser edge case cannot bypass the gate.
            _ = hadURLShape
            return true
        }
        let anchorScheme = anchorURLValid.scheme?.lowercased()
        // mailto compares the domain only: an attacker can re-use any local part.
        if hrefScheme == "mailto" || anchorScheme == "mailto" {
            guard hrefScheme == "mailto", anchorScheme == "mailto" else {
                return true
            }
            guard
                let hrefDomain = mailtoDomain(url),
                let anchorDomain = mailtoDomain(anchorURLValid)
            else {
                return true
            }
            let normHref = stripTrailingDots(hrefDomain)
            let normAnchor = stripTrailingDots(anchorDomain)
            if normAnchor == normHref { return false }
            if normAnchor.hasSuffix("." + normHref) { return false }
            return true
        }
        guard let hrefHost = url.host?.lowercased(), !hrefHost.isEmpty else {
            return false
        }
        guard let anchorHost = anchorURLValid.host?.lowercased(), !anchorHost.isEmpty else {
            return true
        }
        let normHref = stripTrailingDots(hrefHost)
        let normAnchor = stripTrailingDots(anchorHost)
        // Compare (host, effective port): `https://example.com:8443` must not pass for `https://example.com`.
        let hrefPort = url.port ?? defaultPort(hrefScheme ?? "")
        let anchorPort = anchorURLValid.port ?? defaultPort(anchorScheme ?? "")
        if normAnchor == normHref && anchorPort == hrefPort { return false }
        if normAnchor.hasSuffix("." + normHref) && anchorPort == hrefPort { return false }
        // The inverse (anchor host is a parent of the href host) is divergent: on a wildcard-hosted
        // domain, anchor `github.io` would vouch for href `attacker.github.io`.
        return true
    }

    private static func stripTrailingDots(_ s: String) -> String {
        var out = s
        while out.hasSuffix(".") { out.removeLast() }
        return out
    }

    private static func defaultPort(_ scheme: String) -> Int? {
        switch scheme.lowercased() {
        case "http": return 80
        case "https": return 443
        case "ftp": return 21
        default: return nil
        }
    }

    /// `(url, true)`: a URL-shaped token parsed. `(nil, true)`: URL-shaped but rejected by `URL(string:)`,
    /// the caller fails closed. `nil`: no URL-shaped token (`://` or a `mailto:` prefix) at all.
    private static func extractAnchorURL(from anchorText: String) -> (URL?, Bool)? {
        let mailto = findMailtoCandidate(in: anchorText)
        let http = findHTTPCandidate(in: anchorText)
        switch (mailto, http) {
        case (nil, nil):
            return nil
        case (let m?, nil):
            return (URL(string: m.candidate), true)
        case (nil, let h?):
            return (URL(string: h.candidate), true)
        case let (m?, h?):
            // The earliest prefix wins; a tie goes to mailto.
            return m.start <= h.start
                ? (URL(string: m.candidate), true)
                : (URL(string: h.candidate), true)
        }
    }

    private struct AnchorCandidate {
        let candidate: String
        let start: String.Index
    }

    /// Matches `mailto:` only at a boundary, so the tail of `https://example.com/mailto:foo` is not taken as a mailto claim.
    private static func findMailtoCandidate(in text: String) -> AnchorCandidate? {
        let lower = text.lowercased()
        var searchStart = lower.startIndex
        while searchStart < lower.endIndex,
              let prefixRange = lower.range(of: "mailto:", range: searchStart..<lower.endIndex)
        {
            let isBoundary: Bool
            if prefixRange.lowerBound == lower.startIndex {
                isBoundary = true
            } else {
                let prev = lower[lower.index(before: prefixRange.lowerBound)]
                isBoundary = prev.isWhitespace || "([{<,;\"'".contains(prev)
            }
            if isBoundary {
                let originalStart = text.index(
                    text.startIndex,
                    offsetBy: lower.distance(from: lower.startIndex, to: prefixRange.lowerBound)
                )
                var end = originalStart
                let textEnd = text.endIndex
                while end < textEnd, !text[end].isWhitespace {
                    end = text.index(after: end)
                }
                let trimmed = trimTrailingPunctuation(text[originalStart..<end])
                let candidate = String(trimmed)
                if candidate.lowercased() == "mailto:" { return nil }
                return AnchorCandidate(candidate: candidate, start: originalStart)
            }
            searchStart = lower.index(after: prefixRange.lowerBound)
        }
        return nil
    }

    private static func findHTTPCandidate(in text: String) -> AnchorCandidate? {
        let lower = text.lowercased()
        var best: String.Index? = nil
        for prefix in ["https://", "http://", "ftp://"] {
            if let r = lower.range(of: prefix), best == nil || r.lowerBound < best! {
                best = r.lowerBound
            }
        }
        guard let lowerStart = best else { return nil }
        let start = text.index(text.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: lowerStart))
        var end = start
        let textEnd = text.endIndex
        while end < textEnd, !text[end].isWhitespace {
            end = text.index(after: end)
        }
        let trimmed = trimTrailingPunctuation(text[start..<end])
        return AnchorCandidate(candidate: String(trimmed), start: start)
    }

    /// Without this, `visit https://apple.com, please` yields the host `apple.com,` and a false divergence.
    private static func trimTrailingPunctuation(_ s: Substring) -> Substring {
        let trail: Set<Character> = [".", ",", ";", ":", "!", "?", ")", "]", "}", ">"]
        var end = s.endIndex
        while end > s.startIndex {
            let prev = s.index(before: end)
            if !trail.contains(s[prev]) { break }
            end = prev
        }
        return s[s.startIndex..<end]
    }

    /// Accepts only `mailto:address` or `mailto:address?subject=…`: RFC 6068 headers (`bcc`, `cc`, `Reply-To`,
    /// `body`) reach Mail.app verbatim, so `mailto:you@example.com?bcc=attacker@evil.com` silently copies the attacker.
    private static func isMailtoSafe(_ url: URL) -> Bool {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return false
        }
        // The checks run on the percent-decoded envelope (mail clients decode before splitting recipients) and walk
        // `unicodeScalars`, never `Character`s: a decoded combining mark fuses with the `@` or `,` in front of it.
        guard let envelope = mailtoEnvelope(url) else { return false }
        // RFC 6068 writes a literal `#` as `%23`; a mail client may scan the tail of a raw one for addresses.
        if url.absoluteString.utf8.contains(0x23) { return false }
        // Likewise a second raw `?`: a lenient client may restart header parsing there.
        let rawURLString: String = url.absoluteString
        if let firstQuestion = rawURLString.firstIndex(of: "?"),
           rawURLString[rawURLString.index(after: firstQuestion)...].contains("?") {
            return false
        }
        // Also catches a separator hidden behind a `%XX` escape (`mailto:v%3Fbcc=evil@x.com`).
        if envelope.unicodeScalars.contains(where: { (s: Unicode.Scalar) -> Bool in
            mailtoEnvelopeSeparators.contains(s)
        }) {
            return false
        }
        if atSignCount(in: envelope) > 1 { return false }
        if let domain = mailtoDomain(url), hostLooksLikeIDN(domain) {
            return false
        }
        guard let items = comps.queryItems, !items.isEmpty else {
            return true
        }
        // At most one `subject`: a client that concatenates repeats or honours the last composes a subject the user never saw.
        guard items.count == 1, items[0].name.lowercased() == "subject" else {
            return false
        }
        // `queryItems` has percent-decoded the value once. A decoded `&` `;` `=` is a second header to a client
        // that decodes before it splits, and a decoded `%` exposes one on a further round.
        if let value = items[0].value,
           value.unicodeScalars.contains(where: { (s: Unicode.Scalar) -> Bool in
               mailtoSubjectValueSeparators.contains(s)
           }) {
            return false
        }
        return true
    }

    /// The percent-decoded text between `mailto:` and the first `?` or `#`, cut on the raw string so a `%3F` stays
    /// in the envelope. Empty when the URL is not a mailto; nil when the envelope is not valid percent-encoded UTF-8.
    private static func mailtoEnvelope(_ url: URL) -> String? {
        return mailtoEnvelope(fromAbsoluteString: url.absoluteString)
    }

    private static func atSignCount(in envelope: String) -> Int {
        var count = 0
        for scalar in envelope.unicodeScalars where scalar == "@" {
            count += 1
        }
        return count
    }

    /// Strips `user:pass@` before display (tooltip, AX, screen capture). Returns the input when it does not parse.
    static func redactCredentialsForDisplay(_ urlString: String) -> String {
        guard var comps = URLComponents(string: urlString) else { return urlString }
        comps.user = nil
        comps.password = nil
        return comps.string ?? urlString
    }

    private static func mailtoEnvelope(fromAbsoluteString s: String) -> String? {
        let prefix = "mailto:"
        guard s.count >= prefix.count,
              s.prefix(prefix.count).lowercased() == prefix
        else {
            return ""
        }
        var envelope = Substring(s.dropFirst(prefix.count))
        if let qIdx = envelope.firstIndex(of: "?") {
            envelope = envelope[envelope.startIndex..<qIdx]
        }
        if let fIdx = envelope.firstIndex(of: "#") {
            envelope = envelope[envelope.startIndex..<fIdx]
        }
        return String(envelope).removingPercentEncoding
    }
}

protocol HyperlinkResolver: AnyObject {
    func osc8URL(row: Int, col: Int) -> URL?

    /// Only consulted when `osc8URL` returned nil: OSC 8 wins.
    func regexURL(row: Int, col: Int) -> URL?

    /// Empty when the cell has no OSC 8 attribution; the divergence detector treats that as no claim of identity.
    func osc8AnchorText(row: Int, col: Int) -> String
}

extension HyperlinkResolver {
    /// Non-optional so a conformer cannot structurally opt out of `anchorDivergesFromHost`.
    func osc8AnchorText(row: Int, col: Int) -> String { "" }
}

/// Pass `regexMatches` when several queries hit the same snapshot: the lazy scan is O(rows × cols).
final class SnapshotHyperlinkResolver: HyperlinkResolver {
    let snapshot: BBSnapshot
    private var cachedMatches: [URLMatch]?

    init(snapshot: BBSnapshot, regexMatches: [URLMatch]? = nil) {
        self.snapshot = snapshot
        self.cachedMatches = regexMatches
    }

    func osc8URL(row: Int, col: Int) -> URL? {
        let id = snapshot.linkID(row: row, col: col)
        guard id != 0, let s = snapshot.linkURL(id: id) else { return nil }
        guard let url = URL(string: s), OSC8URLPolicy.isAllowed(url) else { return nil }
        return url
    }

    func regexURL(row: Int, col: Int) -> URL? {
        let bufferLine = Int32(row - snapshot.displayOffset)
        let point = BufferPoint(line: bufferLine, col: col)
        if cachedMatches == nil {
            cachedMatches = URLDetector.scan(snapshot: snapshot)
        }
        return URLDetector.match(at: point, in: cachedMatches ?? [])?.url
    }

    func osc8AnchorText(row: Int, col: Int) -> String {
        let anchorID = snapshot.linkID(row: row, col: col)
        guard anchorID != 0 else { return "" }
        var out = ""
        var l = col
        while l > 0 && snapshot.linkID(row: row, col: l - 1) == anchorID {
            l -= 1
        }
        var r = col
        while r + 1 < snapshot.cols && snapshot.linkID(row: row, col: r + 1) == anchorID {
            r += 1
        }
        for c in l...r {
            if let ch = snapshot.character(at: c, row: row) {
                out.append(ch)
            }
        }
        return out
    }
}
