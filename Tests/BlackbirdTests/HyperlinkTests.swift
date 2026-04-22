import XCTest
@testable import Blackbird
@testable import BBCore

/// OSC 8 hyperlink coverage across the FFI → Swift snapshot → click path.
///
/// Three guarantees we pin here:
///
///  1. The Rust OSC 8 parser's link table reaches the Swift `BBSnapshot`
///     via `linkID(row:col:)` + `linkURL(id:)`. An attributed cell returns
///     a non-zero id and the URL round-trips intact; unattributed cells
///     return 0.
///
///  2. `TerminalView`'s ⌘-click path consults the snapshot's OSC 8 link
///     table first. If the cell under the click carries an OSC 8 href,
///     that URL opens — no regex scan.
///
///  3. When the clicked cell has no OSC 8 attribution, the ⌘-click path
///     falls back to the regex URLDetector. This is the path that matters
///     for plain `ls`/`cat` output where tools don't emit OSC 8.
final class HyperlinkTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    func testOsc8AttributesFlowToSwiftSnapshot() throws {
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 80, rows: 24)))
        // ESC]8;;https://example.com ESC\ hi ESC]8;; ESC\
        term.input("\u{1B}]8;;https://example.com\u{1B}\\hi\u{1B}]8;;\u{1B}\\")
        let snap = try XCTUnwrap(term.snapshot())

        let id0 = snap.linkID(row: 0, col: 0)
        let id1 = snap.linkID(row: 0, col: 1)
        XCTAssertNotEqual(id0, 0, "cell under OSC 8 must carry a non-zero link id")
        XCTAssertEqual(id0, id1, "both covered cells share one link id")
        XCTAssertEqual(
            snap.linkURL(id: id0),
            "https://example.com",
            "url resolution round-trips through the FFI"
        )
        XCTAssertEqual(
            snap.linkID(row: 0, col: 2), 0,
            "cell past the 'hi' must be unattributed"
        )
        XCTAssertNil(
            snap.linkURL(id: 0),
            "id 0 must resolve to nil — sentinel for 'no link'"
        )
    }

    func testCmdClickOpensOsc8Href() throws {
        let view = try XCTUnwrap(TerminalView.makeHeadlessForTests())
        let opener = RecordingURLOpener()
        view.urlOpenerForTests = opener
        view.installHyperlinkSnapshotForTests(
            rows: ["hi                                      "],
            linkAt: [(row: 0, cols: 0..<2, url: "https://example.com")]
        )
        view.performCmdClickForTests(row: 0, col: 1)
        XCTAssertEqual(
            opener.opened.map(\.absoluteString),
            ["https://example.com"],
            "OSC 8 attribution takes precedence over regex"
        )
    }

    func testOsc8UrlSchemeAllowlistAccepts() {
        // host-required schemes use explicit host so F14's hostless-URL
        // rejection doesn't conflict; mailto: is host-less by design
        // (the "host" is the local-part of the address).
        let fixtures: [(scheme: String, raw: String)] = [
            ("http",    "http://example.com/"),
            ("https",   "https://example.com/"),
            ("ftp",     "ftp://example.com/"),
            ("mailto",  "mailto:alice@example.com"),
            ("HTTPS",   "HTTPS://example.com/"),
            ("Mailto",  "Mailto:alice@example.com"),
        ]
        for (scheme, raw) in fixtures {
            let u = URL(string: raw)!
            XCTAssertTrue(
                OSC8URLPolicy.isAllowed(u),
                "allowlist must accept the canonical safe scheme \(scheme)"
            )
        }
    }

    func testOsc8UrlSchemeAllowlistRejectsFileScheme() {
        // file:// is deliberately excluded. NSWorkspace.open on a file URL
        // dispatches to the registered opener — for .command / .app / .pkg
        // / .workflow / .terminal that's *immediate execution*. A single
        // ⌘-click on a crafted OSC 8 file:// hyperlink shouldn't be a
        // one-keystroke RCE.
        for raw in [
            "file:///tmp/malicious.command",
            "file:///Applications/Calculator.app",
            "file:///etc/passwd",
            "file://localhost/tmp/readme.md",
        ] {
            guard let u = URL(string: raw) else { continue }
            XCTAssertFalse(
                OSC8URLPolicy.isAllowed(u),
                "file:// must be rejected — execution hazard: \(raw)"
            )
        }
    }

    func testOsc8UrlAllowlistRejectsSchemelessURLs() {
        // URL(string: "/relative") succeeds but has no scheme. Must be
        // rejected — there's nothing NSWorkspace can meaningfully dispatch.
        // A similar failure mode: `URL(string: "bare-host")` produces a
        // relative reference with a nil scheme.
        for raw in ["/usr/local/bin/less", "relative-path", "just-text"] {
            guard let u = URL(string: raw) else { continue }
            XCTAssertFalse(
                OSC8URLPolicy.isAllowed(u),
                "URL without a scheme must be rejected: \(raw)"
            )
        }
    }

    func testOsc8UrlAllowlistAcceptsLegitimateVariants() {
        // URL(string:) accepts plenty of shapes — ports, query strings,
        // auth components, IPv6 literals. All should pass the scheme
        // gate; none should surface unsafe behaviour because NSWorkspace
        // still dispatches via the registered http/https/ftp/mailto
        // handler which is the user's browser / Mail.app.
        let ok = [
            "https://example.com:8443/path?q=1&x=2#frag",
            "http://[2001:db8::1]/",
            "mailto:root@example.com?subject=hi",
            "ftp://ftp.example.com/pub/file.tgz",
        ]
        for raw in ok {
            guard let u = URL(string: raw) else {
                XCTFail("URL init failed for \(raw)")
                continue
            }
            XCTAssertTrue(
                OSC8URLPolicy.isAllowed(u),
                "URL with legitimate shape must pass allowlist: \(raw)"
            )
        }
    }

    func testOsc8UrlAllowlistHandlesPercentEncodedScheme() {
        // Edge case: URL(string:) accepts some percent-encoded schemes
        // like \`http%00:\`. Those should be treated as an unknown
        // scheme (the NUL byte isn't part of "http" for allowlist
        // purposes). Verify the lowercased scheme check isn't fooled.
        for raw in [
            "http%00://example.com",
            "ht%00tp://example.com",
            "http\u{0}://example.com",
        ] {
            guard let u = URL(string: raw) else { continue }
            XCTAssertFalse(
                OSC8URLPolicy.isAllowed(u),
                "percent-encoded / embedded-NUL scheme must be rejected: \(raw)"
            )
        }
    }

    func testOsc8UrlSchemeAllowlistRejectsDangerous() {
        // Classic OSC 8 injection vectors: a shell on a compromised host
        // can emit a hyperlink with any scheme; without the allowlist,
        // NSWorkspace.open would dispatch to the registered handler for
        // javascript: / data: / shell: / jar: — any of which can execute.
        let attacks = [
            "javascript:alert(1)",
            "data:text/html,<script>alert(1)</script>",
            "jar:file:///etc/passwd",
            "shell:Startup",
            "vbscript:msgbox",
            "x-apple-launch://local/App.app",
            "file\0://trick",   // URL parses, scheme "file\0" — belt and braces
        ]
        for raw in attacks {
            guard let u = URL(string: raw) else { continue }
            XCTAssertFalse(
                OSC8URLPolicy.isAllowed(u),
                "scheme from attack string \(raw) must be rejected"
            )
        }
    }

    // MARK: - F8: IDN / punycode rejection

    /// Audit cwd-hyperlink F8. A punycode-encoded IDN (`xn--…`) is a
    /// homograph vector — anchor text may read "apple.com" while href is
    /// a Cyrillic lookalike. Reject host-having schemes with punycode
    /// hosts before NSWorkspace.open sees them.
    func testOsc8UrlAllowlistRejectsPunycodeHost() {
        // xn--pple-43d is the punycode for "аpple" with a Cyrillic а.
        let attacks = [
            "https://xn--pple-43d.com/login",
            "http://xn--e1awd7f.com/",     // "домен"
            "https://safe.xn--hostname.com/", // mid-label xn-- (belt and braces)
        ]
        for raw in attacks {
            guard let u = URL(string: raw) else { continue }
            XCTAssertFalse(
                OSC8URLPolicy.isAllowed(u),
                "punycode/IDN host must be rejected: \(raw)"
            )
        }
    }

    func testOsc8UrlAllowlistRejectsNonASCIIHost() {
        // Some URL(string:) implementations accept raw non-ASCII in the
        // host. Either form is a homograph vector and must be rejected.
        guard let u = URL(string: "https://аpple.com/") else { return }
        XCTAssertFalse(
            OSC8URLPolicy.isAllowed(u),
            "raw non-ASCII host must be rejected"
        )
    }

    func testOsc8UrlAllowlistAcceptsPureASCIIHost() {
        // Sanity: the all-ASCII path still passes. Verifies the IDN gate
        // didn't accidentally snag legitimate hosts.
        for raw in ["https://apple.com/", "http://example.com/path", "ftp://mirror.example.org/"] {
            guard let u = URL(string: raw) else { continue }
            XCTAssertTrue(
                OSC8URLPolicy.isAllowed(u),
                "plain-ASCII host must still pass: \(raw)"
            )
        }
    }

    func testOsc8UrlAllowlistRejectsHostlessHttpURL() {
        // F14 (same trust boundary as F8): a hostless https:/// has
        // nothing for NSWorkspace to meaningfully dispatch.
        guard let u = URL(string: "https:///path/only") else { return }
        XCTAssertFalse(
            OSC8URLPolicy.isAllowed(u),
            "hostless http(s) URL must be rejected"
        )
    }

    // MARK: - F2: anchor / href divergence

    /// Audit cwd-hyperlink F2. Classic OSC 8 phishing: anchor text
    /// displays one URL, href points elsewhere. Detector fires only when
    /// the anchor itself looks URL-shaped (contains `scheme://host…`)
    /// and that host differs from the href's.
    func testAnchorDivergence_detectsPhishingShape() {
        let url = URL(string: "https://evil.tld/login")!
        XCTAssertTrue(
            OSC8URLPolicy.anchorDivergesFromHost(
                anchorText: "https://apple.com/login",
                url: url
            ),
            "visible apple.com vs. href evil.tld must flag as divergent"
        )
    }

    func testAnchorDivergence_plainTextAnchorReturnsFalse() {
        let url = URL(string: "https://evil.tld/x")!
        XCTAssertFalse(
            OSC8URLPolicy.anchorDivergesFromHost(
                anchorText: "click here to log in",
                url: url
            ),
            "anchor text with no URL-shaped token should not trigger divergence"
        )
    }

    func testAnchorDivergence_sameHostReturnsFalse() {
        let url = URL(string: "https://apple.com/login")!
        XCTAssertFalse(
            OSC8URLPolicy.anchorDivergesFromHost(
                anchorText: "https://apple.com/login",
                url: url
            ),
            "identical host must not flag"
        )
    }

    func testAnchorDivergence_subdomainMatch_notFlagged() {
        let url = URL(string: "https://apple.com/login")!
        // Anchor says "www.apple.com", href is "apple.com" — legitimate
        // same-origin case, not phishing.
        XCTAssertFalse(
            OSC8URLPolicy.anchorDivergesFromHost(
                anchorText: "See https://www.apple.com/login for details",
                url: url
            ),
            "subdomain relationship must not flag as divergent"
        )
    }

    // MARK: - F7: resolver cache reuse

    /// Audit cwd-hyperlink F7. The cache is reusable when the caller
    /// passes pre-computed matches. The resolver should consult the
    /// caller's slice instead of running a fresh scan.
    func testResolver_acceptsPreComputedMatches() throws {
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 80, rows: 24)))
        term.input("Visit https://example.com/path for info")
        let snap = try XCTUnwrap(term.snapshot())
        // Scan once.
        let matches = URLDetector.scan(snapshot: snap)
        XCTAssertFalse(matches.isEmpty, "setup must produce at least one match")
        // Build a resolver with pre-computed matches — second query
        // should still find the URL without re-scanning the snapshot
        // (verified indirectly by feeding a non-empty set).
        let resolver = SnapshotHyperlinkResolver(snapshot: snap, regexMatches: matches)
        // Point at a cell inside "https://…" on row 0.
        let url = resolver.regexURL(row: 0, col: 10)
        XCTAssertNotNil(url, "cached matches must be consulted for regexURL")
    }

    func testResolver_anchorTextWalksLinkID() throws {
        // OSC 8 sequence paints 2 cells under one link id. osc8AnchorText
        // should return "hi" — the full run, not just the clicked cell.
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 80, rows: 24)))
        term.input("\u{1B}]8;;https://example.com\u{1B}\\hi\u{1B}]8;;\u{1B}\\")
        let snap = try XCTUnwrap(term.snapshot())
        let resolver = SnapshotHyperlinkResolver(snapshot: snap)
        XCTAssertEqual(resolver.osc8AnchorText(row: 0, col: 0), "hi")
        XCTAssertEqual(resolver.osc8AnchorText(row: 0, col: 1), "hi")
        XCTAssertNil(resolver.osc8AnchorText(row: 0, col: 5),
                     "cell with no link id must return nil")
    }

    func testCmdClickBlocksJavascriptOsc8() throws {
        // An OSC 8 payload can contain any URI scheme. Without the
        // scheme allowlist, NSWorkspace would dispatch to whatever
        // app registered the `javascript:` or custom-scheme handler.
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 80, rows: 24)))
        term.input("\u{1B}]8;;javascript:alert(1)\u{1B}\\hi\u{1B}]8;;\u{1B}\\")
        let snap = try XCTUnwrap(term.snapshot())
        let resolver = SnapshotHyperlinkResolver(snapshot: snap)
        XCTAssertNil(
            resolver.osc8URL(row: 0, col: 0),
            "javascript: OSC 8 URLs must not surface through the click resolver"
        )
    }

    func testCmdClickFallsBackToRegexWhenNoOsc8() throws {
        let view = try XCTUnwrap(TerminalView.makeHeadlessForTests())
        let opener = RecordingURLOpener()
        view.urlOpenerForTests = opener
        view.installHyperlinkSnapshotForTests(
            rows: ["see https://foo.test/ok                 "],
            linkAt: []
        )
        // Column 8 is inside "https://foo.test/ok" (starts at col 4).
        view.performCmdClickForTests(row: 0, col: 8)
        XCTAssertEqual(
            opener.opened.map(\.absoluteString),
            ["https://foo.test/ok"],
            "cells without OSC 8 attribution fall through to regex detection"
        )
    }
}

/// Recording opener used by the click tests. Captures the URLs that the
/// ⌘-click path would have launched so assertions can match them exactly.
final class RecordingURLOpener: URLOpener {
    var opened: [URL] = []
    func open(_ url: URL) { opened.append(url) }
}
