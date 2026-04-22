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
        // No href host → can't compare. The click path already rejects
        // these via `isAllowed`'s host-required check, so this is belt
        // and braces.
        guard let hrefHost = url.host?.lowercased(), !hrefHost.isEmpty else {
            return false
        }
        // Extract a URL-shaped token from the anchor. NSDataDetector is
        // overkill; a minimal regex suffices: scheme + "://" + host-ish
        // characters up to the next path/punct boundary.
        let pattern = #"(?i)(?:https?|ftp)://([A-Za-z0-9.\-]+)"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return false }
        let ns = anchorText as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let match = re.firstMatch(in: anchorText, range: range), match.numberOfRanges >= 2 else {
            return false
        }
        let anchorHostRange = match.range(at: 1)
        guard anchorHostRange.location != NSNotFound else { return false }
        var anchorHost = ns.substring(with: anchorHostRange).lowercased()
        while anchorHost.hasSuffix(".") { anchorHost.removeLast() }
        var normHref = hrefHost
        while normHref.hasSuffix(".") { normHref.removeLast() }
        // Treat a subdomain match as non-divergent — "www.apple.com"
        // anchor for an "apple.com" href isn't phishing.
        if anchorHost == normHref { return false }
        if anchorHost.hasSuffix("." + normHref) { return false }
        if normHref.hasSuffix("." + anchorHost) { return false }
        return true
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
    func osc8AnchorText(row: Int, col: Int) -> String? {
        let anchorID = snapshot.linkID(row: row, col: col)
        guard anchorID != 0 else { return nil }
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
        return out.isEmpty ? nil : out
    }
}
