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

    /// Decide whether an OSC 8 URL is safe to hand to `NSWorkspace`.
    /// Rejects URLs with no scheme (malformed / relative) or a scheme
    /// outside the allowlist. Case-insensitive — RFC 3986 says scheme is
    /// case-insensitive, and browsers canonicalise to lowercase.
    static func isAllowed(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return allowedSchemes.contains(scheme)
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
final class SnapshotHyperlinkResolver: HyperlinkResolver {
    let snapshot: BBSnapshot
    /// Lazily computed so a click that lands on OSC 8 never pays the regex
    /// scan cost. The full-snapshot scan is ~grid-area work.
    private lazy var regexMatches: [URLMatch] = URLDetector.scan(snapshot: snapshot)

    init(snapshot: BBSnapshot) {
        self.snapshot = snapshot
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
        return URLDetector.match(at: point, in: regexMatches)?.url
    }
}
