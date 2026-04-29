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
///  - `ftp`: open in default FTP client / browser
///  - `mailto`: compose mail — side-effect limited to mail app
///  - `file`: open in Finder
/// Everything else is rejected. Users clicking a `ssh://host` in text can
/// still get there via the regex fallback — it won't, because the regex
/// itself excludes ssh — but we err on the side of the smaller blast
/// radius. iTerm2's `SemanticHistoryController` uses a similar approach.
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
    static let allowedSchemes: Set<String> = ["http", "https", "ftp", "mailto"]

    /// Schemes that require a host component. `mailto:` is excluded —
    /// its "host" part is the local address, handled by `isMailtoSafe`.
    private static let hostRequiredSchemes: Set<String> = ["http", "https", "ftp"]

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

    /// Extract the domain (right of the last `@`) from a `mailto:` URL.
    /// `URL.host` is unreliable for mailto on Foundation — depending on
    /// version, it may return nil even for valid mailto URLs. The
    /// canonical location is the path: `mailto:user@domain` parses with
    /// path == "user@domain". Returns nil when there's no `@` or the
    /// right side is empty.
    static func mailtoDomain(_ url: URL) -> String? {
        guard url.scheme?.lowercased() == "mailto" else { return nil }
        // For mailto URLs URL.path holds "user@domain" (no leading
        // slash). Foundation occasionally splits on '@' for
        // url.user/url.host, but the path form is consistent across
        // OS versions and is what RFC 6068 describes.
        let raw = url.path
        guard let at = raw.lastIndex(of: "@") else { return nil }
        let domain = raw[raw.index(after: at)...]
        if domain.isEmpty { return nil }
        return String(domain).lowercased()
    }

    /// True when the host contains non-ASCII characters or looks like an
    /// ACE-encoded (punycode) IDN. Either form is a homograph phishing
    /// vector on the OSC 8 click path. Case-insensitive — RFC 3986 host
    /// strings are case-insensitive after scheme normalisation.
    static func hostLooksLikeIDN(_ host: String) -> Bool {
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
        // Host-required schemes (http/https/ftp). Foundation's URL
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
        // Treat exact-match and "anchor is more specific than href" as
        // non-divergent — `www.apple.com` anchor for `apple.com` href
        // is not phishing.
        if normAnchor == normHref { return false }
        if normAnchor.hasSuffix("." + normHref) { return false }
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
        // Try mailto first — it's distinguishable by a fixed prefix
        // (case-insensitive) and unambiguous.
        if let mailto = findMailtoCandidate(in: anchorText) {
            return (URL(string: mailto), true)
        }
        // Then scheme://… for http/https/ftp.
        if let http = findHTTPCandidate(in: anchorText) {
            return (URL(string: http), true)
        }
        return nil
    }

    /// Scan for a `mailto:` candidate. Returns the substring from the
    /// `mailto:` prefix to the first whitespace or end-of-string. Empty
    /// payload (just `mailto:`) is treated as not-found.
    private static func findMailtoCandidate(in text: String) -> String? {
        let lower = text.lowercased()
        guard let prefixRange = lower.range(of: "mailto:") else { return nil }
        let originalStart = text.index(text.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: prefixRange.lowerBound))
        // Walk forward until whitespace.
        var end = originalStart
        let textEnd = text.endIndex
        while end < textEnd, !text[end].isWhitespace {
            end = text.index(after: end)
        }
        let candidate = String(text[originalStart..<end])
        // Reject "mailto:" with nothing after — not URL-shaped enough
        // to count as a claim.
        if candidate.lowercased() == "mailto:" { return nil }
        return candidate
    }

    /// Scan for an `http://`, `https://`, or `ftp://` candidate.
    /// Returns the substring from the scheme prefix to the first
    /// whitespace or end-of-string. The candidate is fed verbatim into
    /// `URL(string:)` — IPv6 brackets, percent-encoding, IDN, and
    /// non-ASCII all flow through Foundation's parser, closing the
    /// host-class gaps from the prior regex.
    private static func findHTTPCandidate(in text: String) -> String? {
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
        return String(text[start..<end])
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
        return items.allSatisfy { item in
            item.name.lowercased() == "subject"
        }
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
