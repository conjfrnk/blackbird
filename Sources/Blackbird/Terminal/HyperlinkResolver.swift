import AppKit
import Foundation
import BBCore

/// Minimal seam for "open this URL" so the ⌘-click path can be exercised in
/// tests without actually shelling out to NSWorkspace. Production uses
/// `DefaultURLOpener`; `HyperlinkTests` substitutes a recording fake.
public protocol URLOpener {
    func open(_ url: URL)
}

/// Production opener: hands the URL to the system workspace, which selects
/// the user's default handler for the scheme.
public struct DefaultURLOpener: URLOpener {
    public init() {}
    public func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}

/// Scheme allowlist applied to OSC 8 hyperlinks before we hand them to
/// `NSWorkspace`. OSC 8 payloads arrive over the PTY from whatever the
/// remote writes; a malicious shell can embed arbitrary URI schemes
/// (`javascript:`, `data:`, `jar:`, `shell:`, custom app handlers) and
/// `NSWorkspace.open` will launch the registered handler for *any*
/// scheme, including ones that exfiltrate data or trigger privileged
/// actions. Regex-detected URLs already restrict to `(https?|ftp|file)://`
/// upstream in `URLDetector`; OSC 8 was previously unfiltered — this
/// brings it to parity.
///
/// Allowlist rationale — schemes safe to open from an inline hyperlink:
///  - `http`, `https`: open in default browser
///  - `mailto`: compose mail — side-effect limited to mail app
/// Everything else is rejected. Users clicking a `ssh://host` in text can
/// still get there via the regex fallback — it won't, because the regex
/// itself excludes ssh — but we err on the side of the smaller blast
/// radius. iTerm2's `SemanticHistoryController` uses a similar approach.
///
/// `ftp` was removed in audit S4-022. macOS 14+ no longer ships a default
/// FTP client; clicks fall to whatever the user installed (or Safari,
/// which errors). FTP URLs commonly embed plaintext credentials in the
/// authority component, expanding the surface for credential exfil and
/// for FTP-client parsing CVEs. Users with a legitimate `ftp://` need
/// can copy the URL and `open` it manually.
enum OSC8URLPolicy {
    /// Schemes we accept for OSC 8 hyperlinks. Matched case-insensitively
    /// against `URL.scheme` after construction.
    ///
    /// `file://` is deliberately **not** on this list. `NSWorkspace.open`
    /// on a file URL dispatches to the registered opener, which for path
    /// extensions like `.command`, `.app`, `.pkg`, `.workflow`,
    /// `.terminal`, `.scpt`, `.webloc`, `.inetloc` means *immediate
    /// execution*. A remote emitting `ESC]8;;file:///tmp/x.command` and
    /// the user ⌘-clicking the embedded hyperlink would run the payload.
    /// The click is an explicit gesture but the user sees only the anchor
    /// text — they don't see the target extension unless they wait for
    /// the tooltip. Strict-allowlist side of the tradeoff: drop `file`.
    /// Users with a legitimate `file://` need, copy the path and `open`
    /// from the shell.
    static let allowedSchemes: Set<String> = ["http", "https", "mailto"]

    /// Schemes that require a host component. `mailto:` is excluded —
    /// its "host" part is the local address, handled by `isMailtoSafe`.
    private static let hostRequiredSchemes: Set<String> = ["http", "https"]

    /// Decide whether an OSC 8 URL is safe to hand to `NSWorkspace`.
    /// Rejects URLs with no scheme (malformed / relative), a scheme
    /// outside the allowlist, or a `mailto:` URL carrying headers that
    /// could exfiltrate to an attacker. Also rejects host-requiring
    /// schemes whose host contains non-ASCII characters or looks like a
    /// punycode-encoded IDN — both are homograph phishing vectors.
    /// Case-insensitive — RFC 3986 says scheme is case-insensitive, and
    /// browsers canonicalise to lowercase.
    static func isAllowed(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        guard allowedSchemes.contains(scheme) else { return false }
        // H3: reject embedded `user:pass@host` credentials before any
        // other check. `URL.host` strips userinfo, so the host- and
        // divergence-gates would otherwise pass `https://attacker:pw@apple.com/`
        // and hand the credential URL to `NSWorkspace.open` (browser
        // exfil via URL bar / Referer / history) and to the hover
        // tooltip. Both `user` and `password` are checked: Foundation
        // can populate them independently (e.g. `https://:pw@host/`
        // sets password without user), so testing only `user` would
        // miss the pw-only edge case.
        if let user = url.user, !user.isEmpty { return false }
        if let password = url.password, !password.isEmpty { return false }
        // Pass-3 C0 bypass fix: a URL like
        // `mailto:user@apple.com%08evil.com` round-trips through
        // Foundation: `absoluteString` keeps the percent-encoded `%08`
        // while `path` normalises the C0 byte AWAY entirely, leaving
        // `mailtoDomain` reading `apple.comevil.com`. The anchor
        // divergence detector compares against the wrong domain (or
        // short-circuits when the anchor is empty), and Mail.app may
        // re-decode the `%08` to bounce the click to one of `apple.com`,
        // `apple.comevil.com`, or `evil.com` depending on its parser.
        // Reject any URL with percent-encoded C0 controls (00-1F) or
        // DEL (7F) before any per-scheme branch — there is no benign
        // reason to embed a control byte in an OSC 8 hyperlink, and
        // every interpretation downstream is a phishing vector.
        guard !containsPercentEncodedControlBytes(url.absoluteString) else { return false }
        if scheme == "mailto" {
            return isMailtoSafe(url)
        }
        if hostRequiredSchemes.contains(scheme) {
            // A hostless `https:///` URL parses but has nothing for
            // NSWorkspace to dispatch meaningfully — belt-and-braces
            // refusal. Audit cwd-hyperlink F14 (documented under the
            // same trust boundary as F8).
            guard let host = url.host, !host.isEmpty else { return false }
            // Reject homograph hosts — either direct non-ASCII (e.g.
            // Cyrillic а) or punycode encoding thereof. A hostile remote
            // emits OSC 8 with href `https://xn--pple-43d.com/` (Cyrillic
            // "аpple"); the user sees anchor text "apple.com" and clicks.
            // Browsers apply nuanced mixed-script confusable rules; a
            // terminal's cost/benefit tilts toward all-ASCII-only because
            // legitimate IDN traffic via OSC 8 is vanishingly rare.
            // Audit cwd-hyperlink F8.
            if hostLooksLikeIDN(host) { return false }
        }
        return true
    }

    /// Extract the domain (right of the `@`) from a `mailto:` URL.
    ///
    /// Both `URL.host` and `URL.path` are unreliable for mailto across
    /// Foundation versions — on macOS 14 (CI) `URL.path` returns the
    /// empty string for `mailto:user@host`, while macOS 15+ returns
    /// `"user@host"`. Earlier versions of this helper relied on
    /// `URL.path` and silently accepted hostile mailto URLs on the CI
    /// runner because every domain check short-circuited on a nil
    /// domain. Parse the mailto envelope ourselves from
    /// `absoluteString` so behaviour is identical across Foundation
    /// versions.
    ///
    /// Returns nil when there's no `@`, the right side is empty, OR
    /// the envelope contains more than one `@` (multi-recipient mailto
    /// per RFC 6068 — there is no single canonical "domain" so we
    /// cannot validate; fail closed).
    private static func mailtoDomain(_ url: URL) -> String? {
        return mailtoDomain(fromAbsoluteString: url.absoluteString)
    }

    /// Same as `mailtoDomain(_:)` but operates on a raw URL string.
    /// Splitting this out lets the helper avoid `URL.path`/`URL.host`
    /// entirely, which Foundation handles inconsistently for `mailto:`
    /// across macOS versions (see `mailtoDomain(_:)` doc).
    ///
    /// Algorithm (intentionally version-agnostic):
    ///  1. Build the mailto envelope (`mailto:` stripped, query/fragment
    ///     stripped) via `mailtoEnvelope(fromAbsoluteString:)`.
    ///  2. Fail closed when the envelope contains more than one `@`
    ///     (RFC 6068 multi-recipient mailto — no canonical domain).
    ///  3. Split on the single `@` and return the lowercased right
    ///     side, or nil when the right side is empty.
    private static func mailtoDomain(fromAbsoluteString s: String) -> String? {
        let envelope = mailtoEnvelope(fromAbsoluteString: s)
        if envelope.isEmpty { return nil }
        // Pass-3 fail-closed: RFC 6068 allows multi-recipient mailto
        // (`mailto:user@safe.com,b@evil.com`). Picking last via
        // `lastIndex(of: "@")` silently selects evil.com; picking first
        // ignores it. Neither choice is a "canonical" domain — we
        // cannot honestly validate, so refuse to emit one. Caller
        // treats nil as "no domain" → divergence/safety checks fail
        // closed and the click is blocked.
        let atCount = envelope.reduce(0) { $0 + ($1 == "@" ? 1 : 0) }
        guard atCount == 1 else { return nil }
        guard let at = envelope.firstIndex(of: "@") else { return nil }
        let domain = envelope[envelope.index(after: at)...]
        if domain.isEmpty { return nil }
        // Foundation percent-encodes non-ASCII bytes in
        // `absoluteString` (`mailto:user@аpple.com` → `mailto:user@%D0%B0pple.com`).
        // The IDN homograph defence relies on seeing the actual
        // non-ASCII codepoints, so decode before returning. Decoding
        // a pure-ASCII domain is a no-op, so the punycode (`xn--…`)
        // case still flows through unchanged.
        let decoded = String(domain).removingPercentEncoding ?? String(domain)
        return decoded.lowercased()
    }

    /// True when `s` contains a percent-encoded C0 control byte
    /// (`%00`–`%1F`) or DEL (`%7F`). Hex digits are matched
    /// case-insensitively. Used as the canonical click-time bypass
    /// guard in `isAllowed`: Foundation will retain percent-encoded
    /// control bytes in `absoluteString` while normalising them out of
    /// `path`/`host`, leaving the rest of the policy comparing the
    /// wrong substrings against the eventual handler's interpretation.
    /// Cheapest mitigation: reject the URL before any per-scheme
    /// comparison runs.
    private static func containsPercentEncodedControlBytes(_ s: String) -> Bool {
        // %00-%1F covers all C0 controls (NUL through US incl. BS, HT,
        // LF, CR, ESC). %7F covers DEL. Hex digits are case-insensitive
        // because Foundation may emit either case in absoluteString.
        //
        // Audit fix-#09 (2026-05-21): also reject percent-encoded UTF-8
        // sequences for the C1 control range (U+0080..U+009F → %C2%80..
        // %C2%9F) and the bidi/invisible formatting controls (notably
        // %E2%80%AE / RLO and the rest of U+2028..U+202E). The Rust
        // core's contains_bidi_or_invisible catches raw UTF-8 bytes of
        // those scalars in the OSC 8 URI but does not catch the
        // percent-encoded form — Foundation's URL(string:) preserves
        // the encoding in absoluteString. Without this gate the URL
        // flows verbatim to NSWorkspace.open / NSPasteboard.general
        // (right-click → Copy Link), letting a URL-decoding downstream
        // consumer render bidi-flipped text. Modern browsers display
        // the literal percent-encoded form so the practical visible
        // spoof is bounded, but mailing the URL to Mail compose / a
        // bidi-rendering surface re-introduces the spoof.
        let c0DelPattern = #"%(?i)(0[0-9A-F]|1[0-9A-F]|7F)"#
        // C1 controls (UTF-8 two-byte form): %C2 followed by %8X or %9X.
        let c1Pattern = #"%(?i)C2%(8[0-9A-F]|9[0-9A-F])"#
        // Audit S4-005 (lone single-byte %80-%9F not preceded by %C2):
        // deferred. A simple lookbehind regex over-blocks legitimate
        // UTF-8 continuation bytes — e.g. `%E2%9C%93` (U+2713 ✓) would
        // match the lone-%9C path. The correct mitigation needs a real
        // percent-decode + UTF-8 validation pass; tracked separately.
        // U+2028..U+202F (LS, PS, LRE, RLE, PDF, LRO, RLO, WJ, NBSP):
        // %E2%80 followed by %A8..%AF.
        // U+200B..U+200F (ZW joiners / LRM / RLM): %E2%80 followed by
        // %8B..%8F.
        let bidi80Pattern = #"%(?i)E2%80%(A[8-9A-F]|8[B-F])"#
        // U+2060 (Word Joiner) + U+2066..U+2069 (bidi isolates):
        // %E2%81%A0 and %E2%81%A[6-9]. Audit S4-002.
        let bidi81Pattern = #"%(?i)E2%81%A[06-9]"#
        // Audit S4-002: extend coverage to the rest of
        // `is_bidi_or_invisible_scalar` (core/src/lib.rs:492). The Rust
        // core catches raw UTF-8 byte sequences in the OSC 8 URI body;
        // these patterns catch the percent-encoded form that Foundation
        // preserves through to absoluteString.
        // U+00AD (soft hyphen): %C2%AD
        let shyPattern = #"%(?i)C2%AD"#
        // U+061C (Arabic letter mark): %D8%9C
        let almPattern = #"%(?i)D8%9C"#
        // U+180E (Mongolian vowel separator): %E1%A0%8E
        let mvsPattern = #"%(?i)E1%A0%8E"#
        // U+FE00..U+FE0F (Variation Selectors 1-16): %EF%B8%8X
        let vsPattern = #"%(?i)EF%B8%8[0-9A-F]"#
        // U+FEFF (BOM / ZWNBSP): %EF%BB%BF
        let bomPattern = #"%(?i)EF%BB%BF"#
        // U+E0000..U+E007F (tag block): %F3%A0%(80|81)%XX. Slightly
        // over-matches U+E0080..U+E00FF (reserved, still invisible).
        let tagBlockPattern = #"%(?i)F3%A0%(80|81)%[0-9A-F]{2}"#
        // U+E0100..U+E01EF (Variation Selectors 17-256):
        // %F3%A0%(84|85|86|87)%XX. Slightly over-matches U+E01F0..U+E01FF
        // (reserved, still invisible).
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

    /// True when the host contains non-ASCII characters or looks like an
    /// ACE-encoded (punycode) IDN. Either form is a homograph phishing
    /// vector on the OSC 8 click path. Case-insensitive — RFC 3986 host
    /// strings are case-insensitive after scheme normalisation.
    private static func hostLooksLikeIDN(_ host: String) -> Bool {
        for scalar in host.unicodeScalars {
            if scalar.value > 0x7F { return true }
        }
        // Punycode-encoded labels carry the IDNA ACE prefix "xn--" (case
        // insensitive). Any label starting with that prefix signals the
        // host was a non-ASCII IDN before encoding; reject the lot.
        let lower = host.lowercased()
        for label in lower.split(separator: ".") {
            if label.hasPrefix("xn--") { return true }
        }
        return false
    }

    /// True when the OSC 8 anchor text visually claims to be a URL but
    /// the href's host doesn't match what the anchor suggests. Classic
    /// OSC 8 phishing shape: anchor reads `https://apple.com/login`,
    /// href is `https://evil.tld/login`. A quick ⌘-click never gives the
    /// dwell tooltip a chance to surface the mismatch. This is a
    /// conservative detector — only fires when the anchor itself contains
    /// a recognisable URL-shaped token (scheme + host), and that token's
    /// host differs from the href's host after simple normalisation
    /// (case-fold, strip trailing dots). False-negatives are fine
    /// (plain-text anchors like "click here" return false, which is
    /// expected behaviour); false-positives would block legitimate link
    /// chrome. Audit cwd-hyperlink F2.
    static func anchorDivergesFromHost(anchorText: String, url: URL) -> Bool {
        let hrefScheme = url.scheme?.lowercased()
        // Locate the first URL-shaped token in the anchor text. Foundation's
        // `URL(string:)` lets us scheme-dispatch and inherit IPv6/IDN edge
        // handling for free — the prior regex `(?i)(?:https?|ftp)://([A-Za-z0-9.\-]+)`
        // missed `mailto:`, rejected IPv6 brackets, and never reached the
        // IDN gate. Audit pass-2 H-2 (canonical fix for S-3 + S-9 + S-10).
        guard let (anchorURL, hadURLShape) = extractAnchorURL(from: anchorText) else {
            // Anchor text contains no URL-shaped token whatsoever —
            // plain text like "click here". The visible content makes
            // no claim of identity, so divergence detection has nothing
            // to compare. Audit pass-1 SI baseline behaviour preserved.
            return false
        }
        guard let anchorURLValid = anchorURL else {
            // Anchor text *looked* URL-shaped (contains "://" or a known
            // scheme prefix) but failed to parse. Fail closed: a hostile
            // remote that crafts a syntactically broken URL-shaped anchor
            // shouldn't bypass the divergence gate by tripping a parser
            // edge case. H-2 explicit requirement.
            _ = hadURLShape
            return true
        }
        let anchorScheme = anchorURLValid.scheme?.lowercased()
        // Mailto branch: compare the right-of-`@` domain. Local-part
        // comparison is too strict for the realistic phishing axis —
        // attackers can re-use any local-part — but registering a
        // look-alike domain is the actual cost.
        if hrefScheme == "mailto" || anchorScheme == "mailto" {
            // Either side mailto and the other isn't → divergent
            // (a `mailto:` href under an `https://` anchor or vice-versa
            // is itself the spoof shape we're trying to catch).
            guard hrefScheme == "mailto", anchorScheme == "mailto" else {
                return true
            }
            guard
                let hrefDomain = mailtoDomain(url),
                let anchorDomain = mailtoDomain(anchorURLValid)
            else {
                // Either side has no `@domain`; we can't validate, fail
                // closed for the anchor-shaped-as-URL case.
                return true
            }
            let normHref = stripTrailingDots(hrefDomain)
            let normAnchor = stripTrailingDots(anchorDomain)
            if normAnchor == normHref { return false }
            if normAnchor.hasSuffix("." + normHref) { return false }
            return true
        }
        // Host-required schemes (http/https). Foundation's URL
        // parser handles IPv6 bracket-form and IDN automatically.
        guard let hrefHost = url.host?.lowercased(), !hrefHost.isEmpty else {
            // No href host to compare against. The click path already
            // rejects these via `isAllowed`'s host-required check; belt
            // and braces here.
            return false
        }
        guard let anchorHost = anchorURLValid.host?.lowercased(), !anchorHost.isEmpty else {
            // Anchor parsed as URL-shaped but produced no host. Likely
            // a malformed authority (e.g. `https://[::bad]/`); fail
            // closed per H-2 spec.
            return true
        }
        let normHref = stripTrailingDots(hrefHost)
        let normAnchor = stripTrailingDots(anchorHost)
        // Pass-3 default-port fix: previously this branch compared
        // hosts only — `https://example.com` and
        // `https://example.com:8443` looked identical, letting a
        // hostile remote front-end an attacker-controlled port behind
        // an apex-host anchor. Compare (host, effectivePort) tuples.
        // Default-port-on-href + omitted-on-anchor (and vice versa) is
        // legitimate; only divergent ports flag.
        let hrefPort = url.port ?? defaultPort(hrefScheme ?? "")
        let anchorPort = anchorURLValid.port ?? defaultPort(anchorScheme ?? "")
        // Treat exact-match (same host AND same effective port) and
        // "anchor is more specific than href" as non-divergent —
        // `www.apple.com` anchor for `apple.com` href is not phishing.
        if normAnchor == normHref && anchorPort == hrefPort { return false }
        if normAnchor.hasSuffix("." + normHref) && anchorPort == hrefPort { return false }
        // SI-01 — earlier we also accepted the inverse (anchor host is
        // a parent of href host) on the assumption it modelled the
        // `apple.com` ↔ `www.apple.com` case. That inverts trust on
        // wildcard-hosted domains: anchor `https://github.io/project`
        // with href `https://attacker.github.io/steal` would pass this
        // check because `attacker.github.io.hasSuffix(".github.io")`,
        // letting any subdomain of a wildcard host claim the apex.
        // Removed. Users who legitimately want to navigate to a
        // divergent host can dwell to see the tooltip and ⌥⌘-click.
        return true
    }

    /// Strip trailing `.` from a host/domain. Both `apple.com.` (trailing
    /// dot is RFC-legal absolute form) and `apple.com` should normalise
    /// the same way.
    private static func stripTrailingDots(_ s: String) -> String {
        var out = s
        while out.hasSuffix(".") { out.removeLast() }
        return out
    }

    /// Default port for the listed scheme — used to canonicalise
    /// `https://example.com` ≡ `https://example.com:443` for the
    /// divergence comparison. Returns nil for schemes outside the
    /// host-required allowlist (mailto handled separately).
    private static func defaultPort(_ scheme: String) -> Int? {
        switch scheme.lowercased() {
        case "http": return 80
        case "https": return 443
        case "ftp": return 21
        default: return nil
        }
    }

    /// Pull a URL-shaped token out of `anchorText`. Returns:
    ///   - `(parsedURL, true)` when a URL-shaped substring was found
    ///     and `URL(string:)` accepted it.
    ///   - `(nil, true)` when a URL-shaped substring was found but
    ///     `URL(string:)` rejected it (caller fails closed).
    ///   - `nil` when the anchor contains no URL-shaped token at all
    ///     (caller treats as plain text → no divergence).
    ///
    /// "URL-shaped" means: the substring contains `://` (http/https/ftp/
    /// scheme://host…) OR begins with a known mailto prefix. Both are
    /// the shapes a phishing anchor would imitate; everything else is
    /// plain text where the user already isn't being misled.
    ///
    /// Implementation uses a permissive-then-strict scan rather than a
    /// regex over the host class, because the host class is exactly
    /// the gap H-2 closes (IPv6 brackets, percent-encoded UTF-8, etc.).
    /// We hand the candidate substring to `URL(string:)` and let
    /// Foundation decide.
    private static func extractAnchorURL(from anchorText: String) -> (URL?, Bool)? {
        // Pass-3 ordering fix (item 5): previously this tried mailto
        // first, which biased the detector toward an embedded
        // `mailto:` substring even when an http(s)/ftp candidate
        // appeared earlier in the text. Worse, `findMailtoCandidate`
        // matched `mailto:` anywhere — an anchor like
        // `see https://example.com/mailto:foo` extracted `mailto:foo`
        // as the supposed URL claim. Resolve both ambiguities by
        // picking whichever candidate's prefix appears earliest in
        // the original string. Equal start positions tie-break to
        // mailto (mailto prefix is longer than `http://` so a
        // legitimately co-located shape is unambiguously mailto).
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
            // Pick whichever prefix appeared earlier in the source.
            return m.start <= h.start
                ? (URL(string: m.candidate), true)
                : (URL(string: h.candidate), true)
        }
    }

    /// A candidate URL substring extracted from anchor text plus the
    /// position of its scheme prefix in the original string. Position
    /// is preserved so `extractAnchorURL` can pick the earliest
    /// candidate when both http and mailto match (item 5 ordering).
    private struct AnchorCandidate {
        let candidate: String
        let start: String.Index
    }

    /// Scan for a `mailto:` candidate. Returns the substring from the
    /// `mailto:` prefix to the first whitespace, with trailing
    /// punctuation stripped. Empty payload (just `mailto:`) is
    /// treated as not-found.
    ///
    /// Pass-3 (item 5): only matches when `mailto:` appears at the
    /// start of the text, or is preceded by whitespace or an
    /// unambiguous separator. Inside a path like
    /// `https://example.com/mailto:foo` the substring used to match
    /// and the `foo` was extracted as if it were a mailto claim.
    private static func findMailtoCandidate(in text: String) -> AnchorCandidate? {
        let lower = text.lowercased()
        var searchStart = lower.startIndex
        while searchStart < lower.endIndex,
              let prefixRange = lower.range(of: "mailto:", range: searchStart..<lower.endIndex)
        {
            // Boundary check: previous char (if any) must be whitespace
            // or an unambiguous separator. This keeps embedded
            // `mailto:` substrings out of the candidate set without
            // requiring a full URL parser.
            let isBoundary: Bool
            if prefixRange.lowerBound == lower.startIndex {
                isBoundary = true
            } else {
                let prev = lower[lower.index(before: prefixRange.lowerBound)]
                // Same separator class used elsewhere for URL-text
                // boundaries: whitespace, common punctuation, brackets.
                isBoundary = prev.isWhitespace || "([{<,;\"'".contains(prev)
            }
            if isBoundary {
                let originalStart = text.index(
                    text.startIndex,
                    offsetBy: lower.distance(from: lower.startIndex, to: prefixRange.lowerBound)
                )
                // Walk forward until whitespace.
                var end = originalStart
                let textEnd = text.endIndex
                while end < textEnd, !text[end].isWhitespace {
                    end = text.index(after: end)
                }
                let trimmed = trimTrailingPunctuation(text[originalStart..<end])
                let candidate = String(trimmed)
                // Reject "mailto:" with nothing after — not URL-shaped
                // enough to count as a claim.
                if candidate.lowercased() == "mailto:" { return nil }
                return AnchorCandidate(candidate: candidate, start: originalStart)
            }
            searchStart = lower.index(after: prefixRange.lowerBound)
        }
        return nil
    }

    /// Scan for an `http://`, `https://`, or `ftp://` candidate.
    /// Returns the substring from the scheme prefix to the first
    /// whitespace, with trailing punctuation stripped. The candidate
    /// is fed verbatim into `URL(string:)` — IPv6 brackets,
    /// percent-encoding, IDN, and non-ASCII all flow through
    /// Foundation's parser, closing the host-class gaps from the
    /// prior regex.
    private static func findHTTPCandidate(in text: String) -> AnchorCandidate? {
        let lower = text.lowercased()
        // Find the earliest of the three scheme prefixes. (Anchor that
        // mentions multiple URLs is the rare phishing shape; first
        // wins — the divergence detector is a heuristic, not a parser.)
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

    /// Strip trailing punctuation from a candidate URL substring.
    ///
    /// Pass-3 (item 4): the previous regex `[^A-Za-z0-9.\-]` stopped
    /// at any non-host char; the new whitespace-walk continues
    /// through punctuation so a sentence like
    /// `visit https://apple.com, please` produced the candidate
    /// `https://apple.com,` — Foundation accepted it with host
    /// `apple.com,` and divergence fired on a legitimate match.
    /// Trim the standard URL-extraction trailing-punctuation set
    /// before handing the substring to `URL(string:)`. One pass is
    /// enough for the realistic shapes; we don't need to look at
    /// the next char because the candidate ends at whitespace.
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

    /// `mailto:` syntax (RFC 6068) allows query headers:
    /// `mailto:to@host?cc=…&bcc=…&subject=…&body=…`. An OSC 8 payload
    /// like `mailto:you@example.com?bcc=attacker@evil.com&subject=...`
    /// visually claims to email "you" but silently BCCs the attacker
    /// when the user clicks. Other dangerous headers: `Reply-To`
    /// (redirects replies), `In-Reply-To` (threads into an attacker
    /// thread), arbitrary `X-Custom-Header`. RFC 6068 restricts the
    /// allowed headers but NSWorkspace hands the raw URL to Mail.app
    /// which trusts it.
    ///
    /// Policy: only accept `mailto:address`, or `mailto:address?subject=…`
    /// with nothing else. Subject-only is enough for UX (GitHub issue
    /// templates etc.) without the exfil risk.
    private static func isMailtoSafe(_ url: URL) -> Bool {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return false
        }
        // Pass-3 item 6: RFC 6068 multi-recipient mailto carries
        // multiple `@`-separated addresses
        // (`mailto:user@safe.com,b@evil.com`). There is no honest
        // canonical "domain" for the URL — picking last silently
        // gives evil.com the win, picking first silently ignores it.
        // Reject before mailtoDomain has a chance to lie. (Note: a
        // `mailto:` with NO `@` at all — `mailto:?subject=hi` — is
        // allowed below; this guard fires only on >1 `@` in the
        // envelope.)
        //
        // Foundation cross-version note: on macOS 14 `URL.path` returns
        // the empty string for mailto URLs, which silently collapsed
        // the `@`-count to zero and let multi-recipient mailtos
        // through. Compute the count from the absoluteString envelope
        // (mailto:…?…) so behaviour is identical across versions. See
        // `mailtoDomain(fromAbsoluteString:)` for the parser.
        let envelope = mailtoEnvelope(url)
        let atCount = envelope.reduce(0) { $0 + ($1 == "@" ? 1 : 0) }
        if atCount > 1 { return false }
        // H-2: extend IDN homograph defence to mailto domain. A
        // hostile remote emitting `mailto:user@аpple.com` (Cyrillic а)
        // visually claims apple.com but sends mail to a registered
        // lookalike domain. Same threat model as the http(s)/ftp host
        // path; same defence.
        if let domain = mailtoDomain(url), hostLooksLikeIDN(domain) {
            return false
        }
        guard let items = comps.queryItems, !items.isEmpty else {
            return true
        }
        // Audit S4-003: accept at MOST ONE `subject` item. The old
        // `allSatisfy { name == "subject" }` admitted repeated subject items
        // (`?subject=Invoice&subject=Wire%20transfer`); RFC 6068 expects a
        // single Subject, and a mail client that concatenates or honours the
        // last value would compose a subject the user never saw in any single
        // visible token — the visible-vs-actual mismatch this per-header
        // allowlist exists to prevent. With the empty-items case already
        // handled above, a safe non-empty query is exactly one subject item.
        // (cc/bcc/reply-to/body/X-* remain rejected: they fail this check.)
        return items.count == 1 && items[0].name.lowercased() == "subject"
    }

    /// Return the substring between `mailto:` and the first `?`
    /// (query) or `#` (fragment), or the entire post-prefix string
    /// when neither is present. Empty string when the URL isn't a
    /// mailto. Used by `isMailtoSafe` for the multi-`@` count and by
    /// `mailtoDomain(fromAbsoluteString:)` for the `@`-split, both
    /// without touching `URL.path` (see `mailtoDomain` doc for why
    /// `URL.path` is unsafe here).
    private static func mailtoEnvelope(_ url: URL) -> Substring {
        return mailtoEnvelope(fromAbsoluteString: url.absoluteString)
    }

    /// H3: strip `user:pass@` from a URL string before display. The
    /// hover tooltip's NSTextField renders the OSC 8 href verbatim
    /// (after C0/bidi scrub); without this redaction a hostile remote
    /// could render `https://victim:secret@example.com/` and the
    /// tooltip + AX surface + screen capture would disclose the
    /// embedded secret. Returns the original string when URLComponents
    /// can't parse it — fail-loud is preferable but the tooltip path
    /// is best-effort, and this redactor sits AFTER `isAllowed` (which
    /// already rejected credential URLs at the click gate), so this
    /// helper protects only the display surface for any code path that
    /// might surface a string before policy gating.
    static func redactCredentialsForDisplay(_ urlString: String) -> String {
        guard var comps = URLComponents(string: urlString) else { return urlString }
        comps.user = nil
        comps.password = nil
        return comps.string ?? urlString
    }

    private static func mailtoEnvelope(fromAbsoluteString s: String) -> Substring {
        let prefix = "mailto:"
        guard s.count >= prefix.count,
              s.prefix(prefix.count).lowercased() == prefix
        else {
            return Substring("")
        }
        var envelope = Substring(s.dropFirst(prefix.count))
        if let qIdx = envelope.firstIndex(of: "?") {
            envelope = envelope[envelope.startIndex..<qIdx]
        }
        if let fIdx = envelope.firstIndex(of: "#") {
            envelope = envelope[envelope.startIndex..<fIdx]
        }
        return envelope
    }
}

/// Narrow protocol consumed by `TerminalView`'s ⌘-click path. Production
/// wraps a real `BBSnapshot`; tests inject a fake that answers both OSC 8
/// lookups and regex fallback queries without constructing a live BBTerm.
///
/// Keeping the two lookups on one protocol (rather than splitting OSC 8 onto
/// a BBCore protocol and regex onto Blackbird) lets the test fake supply
/// both answers inline — no detour through URLDetector/NSRegularExpression
/// on a hand-built snapshot.
protocol HyperlinkResolver: AnyObject {
    /// OSC 8 link URL for the cell at (row, col), or nil when the cell has
    /// no attribution. Returns an already-parsed `URL` so the click path
    /// can dispatch directly.
    func osc8URL(row: Int, col: Int) -> URL?

    /// Regex-detected URL for the cell at (row, col), or nil. Only consulted
    /// when `osc8URL` returned nil — OSC 8 wins when both are available.
    func regexURL(row: Int, col: Int) -> URL?

    /// Anchor text rendered under an OSC 8 link at (row, col). Used by
    /// the click-time divergence detector to flag phishing-shaped links
    /// where the visible text claims one host but the href points
    /// elsewhere. Returns the empty string when the cell has no OSC 8
    /// attribution or the anchor can't be reconstructed — divergence
    /// detection treats empty-anchor as "no URL-shaped claim of
    /// identity in the visible text" and lets the URL through. Audit
    /// high-1, P2-01.
    func osc8AnchorText(row: Int, col: Int) -> String
}

extension HyperlinkResolver {
    /// Default returns the empty string. P2-01: making this non-nil
    /// (was `String?` returning nil) means future conformers — including
    /// test fakes that only inject URLs — cannot structurally opt out
    /// of `anchorDivergesFromHost` evaluation. An empty anchor is safe:
    /// the divergence detector's URL regex finds no match and lets the
    /// click through, matching the previous "no anchor → no claim → no
    /// divergence" semantics without leaving the bypass open.
    func osc8AnchorText(row: Int, col: Int) -> String { "" }
}

/// Production resolver backed by a real `BBSnapshot`. OSC 8 goes through
/// the snapshot's FFI accessors; regex fallback runs the existing
/// `URLDetector` against the live grid so behaviour matches the pre-Task-7
/// ⌘-click path exactly when a cell has no OSC 8 attribution.
///
/// Callers that perform multiple queries against the same snapshot (⌘-click
/// + dwell + context menu can all hit the resolver) should pass a
/// pre-computed `regexMatches` slice. Constructing without one still works —
/// the matches are computed lazily on first query — but the hot production
/// path on `TerminalView` caches the scan in a snapshot-keyed store and
/// passes the slice in so repeated queries avoid the O(rows × cols) scan.
/// Audit cwd-hyperlink F7.
final class SnapshotHyperlinkResolver: HyperlinkResolver {
    let snapshot: BBSnapshot
    /// Pre-computed regex matches for this snapshot. Nil until first
    /// consulted (or populated via the caller-supplied initializer).
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

    /// Read the anchor text rendered under an OSC 8 link id on the
    /// supplied screen row. Walks contiguous cells at `row` that share
    /// the same link id as (row, col) and joins their characters into a
    /// single string. Used by the click-time divergence detector
    /// (`OSC8URLPolicy.anchorDivergesFromHost`) to flag phishing-shaped
    /// OSC 8 hyperlinks. Audit cwd-hyperlink F2.
    ///
    /// Returns the empty string when (row, col) carries no link id or
    /// the cell-character lookup yielded nothing — divergence detection
    /// treats empty as "no host claim in the anchor text" and the
    /// click is allowed to proceed. P2-01.
    func osc8AnchorText(row: Int, col: Int) -> String {
        let anchorID = snapshot.linkID(row: row, col: col)
        guard anchorID != 0 else { return "" }
        var out = ""
        // Walk left from (row, col) until the link id changes, then right.
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
