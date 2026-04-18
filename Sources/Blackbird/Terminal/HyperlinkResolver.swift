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
        return URL(string: s)
    }

    func regexURL(row: Int, col: Int) -> URL? {
        let bufferLine = Int32(row - snapshot.displayOffset)
        let point = BufferPoint(line: bufferLine, col: col)
        return URLDetector.match(at: point, in: regexMatches)?.url
    }
}
