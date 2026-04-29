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

    // MARK: - H-2: scheme-dispatch (mailto + IPv6 + IDN-on-mailto)

    /// Audit pass-2 H-2. Pre-fix the anchor regex
    /// `(?i)(?:https?|ftp)://…` did not recognise `mailto:`, so the
    /// divergence detector silently returned false for an anchor that
    /// claimed one mail address while the href targeted another. A
    /// hostile remote emitted `\x1b]8;;mailto:attacker@evil.com\x1b\\
    /// Contact support@apple.com\x1b]8;;\x1b\\` — click composed mail
    /// to attacker. Post-fix the mailto candidate is recognised and the
    /// domain mismatch (`evil.com` vs `apple.com`) trips divergence.
    func testAnchorDivergence_mailtoPhishingFlagged() {
        let url = URL(string: "mailto:attacker@evil.com")!
        XCTAssertTrue(
            OSC8URLPolicy.anchorDivergesFromHost(
                anchorText: "Contact mailto:support@apple.com",
                url: url
            ),
            "hostile mailto href + visible apple.com mailto anchor must trip divergence"
        )
    }

    /// Audit pass-2 H-2. Same-domain mailto must NOT flag — visible
    /// "user@apple.com" with href "user@apple.com" is the legitimate
    /// case; over-blocking it would silence the gate's signal value.
    func testAnchorDivergence_mailtoSameDomainNotFlagged() {
        let url = URL(string: "mailto:user@apple.com")!
        XCTAssertFalse(
            OSC8URLPolicy.anchorDivergesFromHost(
                anchorText: "mailto:user@apple.com",
                url: url
            ),
            "matching mailto domain must not flag as divergent"
        )
    }

    /// Audit pass-2 H-2. Cyrillic а ("аpple") in the anchor's mailto
    /// domain is the IDN homograph variant — pre-fix, `hostLooksLikeIDN`
    /// only ran for http(s)/ftp; `isMailtoSafe` accepted any domain.
    /// Now the anchor parses with non-ASCII, the divergence detector
    /// flags the mismatch because the href is `evil.com`. (Even if the
    /// anchor were the same Cyrillic-aliased domain, `isAllowed` would
    /// reject the click separately via the extended IDN check.)
    func testAnchorDivergence_mailtoIDNHomographFlagged() {
        let url = URL(string: "mailto:attacker@evil.com")!
        // U+0430 (Cyrillic а) replaces U+0061 in "apple"
        let cyrillicAnchor = "mailto:user@\u{0430}pple.com"
        XCTAssertTrue(
            OSC8URLPolicy.anchorDivergesFromHost(
                anchorText: cyrillicAnchor,
                url: url
            ),
            "mailto IDN-look-alike anchor vs unrelated href must flag"
        )
    }

    /// Audit pass-2 H-2. The host-side IDN gate must also cover the
    /// mailto domain in `isAllowed`/`isMailtoSafe` — pre-fix a
    /// `mailto:user@аpple.com` (Cyrillic а) href passed `isAllowed`
    /// outright because the IDN check was scoped to host-required
    /// schemes only. Post-fix `isAllowed` rejects it.
    func testIsAllowed_rejectsMailtoIDNDomain() {
        // U+0430 Cyrillic а replaces U+0061 in "apple". URL(string:)
        // accepts this in macOS Foundation; the gate must reject.
        guard let u = URL(string: "mailto:user@\u{0430}pple.com") else {
            XCTFail("URL(string:) should accept mailto with Cyrillic domain")
            return
        }
        XCTAssertFalse(
            OSC8URLPolicy.isAllowed(u),
            "mailto with non-ASCII (IDN homograph) domain must be rejected"
        )
    }

    func testIsAllowed_rejectsMailtoPunycodeDomain() {
        // xn--pple-43d is the punycode for "аpple" (Cyrillic а). A
        // hostile remote sends the ACE-encoded form to bypass any
        // raw-non-ASCII filter. The IDN gate must catch both shapes.
        guard let u = URL(string: "mailto:user@xn--pple-43d.com") else {
            XCTFail("URL(string:) should accept mailto with punycode domain")
            return
        }
        XCTAssertFalse(
            OSC8URLPolicy.isAllowed(u),
            "mailto with punycode-encoded domain must be rejected"
        )
    }

    /// Audit pass-2 H-2. IPv6 anchors `https://[2001:db8::1]/` failed
    /// the prior regex's host class entirely, so the divergence
    /// detector returned false ("no URL claim in anchor") — the gate
    /// was effectively skipped for IPv6 hrefs. Post-fix Foundation's
    /// URL parser handles bracket-form authority and returns the
    /// expected host. Same anchor + href IPv6 host must NOT flag.
    func testAnchorDivergence_ipv6SameAddressNotFlagged() {
        let url = URL(string: "https://[2001:db8::1]/path")!
        XCTAssertFalse(
            OSC8URLPolicy.anchorDivergesFromHost(
                anchorText: "https://[2001:db8::1]/",
                url: url
            ),
            "matching IPv6 anchor and href hosts must not flag"
        )
    }

    /// Audit pass-2 H-2. Different IPv6 hosts (anchor claims one
    /// address, href is a different address) must flag. Pre-fix the
    /// regex never recognised either, so this check was silently a
    /// no-op.
    func testAnchorDivergence_ipv6MismatchFlagged() {
        let url = URL(string: "https://[2001:db8::2]/")!
        XCTAssertTrue(
            OSC8URLPolicy.anchorDivergesFromHost(
                anchorText: "https://[2001:db8::1]/",
                url: url
            ),
            "anchor IPv6 host differs from href IPv6 host — must flag"
        )
    }

    /// Audit pass-2 H-2. Anchor text that *looks* URL-shaped (contains
    /// "://" with a known scheme prefix) but fails Foundation's URL
    /// parser must fail closed. A hostile remote can craft a
    /// syntactically broken authority (`https://[::bad]/`) banking on
    /// the parser tripping and the gate skipping. The fix: when we see
    /// a URL prefix but URL(string:) rejects it, treat it as divergent.
    func testAnchorDivergence_malformedURLFailsClosed() {
        let url = URL(string: "https://evil.tld/login")!
        // `https://]not-a-host[/` — Foundation will reject. Pre-fix
        // the regex's `[A-Za-z0-9.\-]+` host class would have refused
        // to match too, so the previous outcome was also "no match" →
        // returned false (silent bypass). Post-fix we detect the URL
        // shape and fail closed when parsing fails.
        XCTAssertTrue(
            OSC8URLPolicy.anchorDivergesFromHost(
                anchorText: "https://]not-a-host[/path",
                url: url
            ),
            "URL-shaped anchor that fails to parse must fail closed (treated as divergent)"
        )
    }

    /// Audit pass-2 H-2. Cross-scheme spoof: href is mailto but anchor
    /// text claims an https URL, or vice-versa. Either form is the
    /// shape a phishing payload would use; both must flag.
    func testAnchorDivergence_crossSchemeSpoofFlagged() {
        let httpHref = URL(string: "https://evil.tld/login")!
        XCTAssertTrue(
            OSC8URLPolicy.anchorDivergesFromHost(
                anchorText: "mailto:support@apple.com",
                url: httpHref
            ),
            "mailto anchor under https href must flag"
        )
        let mailtoHref = URL(string: "mailto:attacker@evil.com")!
        XCTAssertTrue(
            OSC8URLPolicy.anchorDivergesFromHost(
                anchorText: "https://apple.com/contact",
                url: mailtoHref
            ),
            "https anchor under mailto href must flag"
        )
    }

    /// Audit SI-01: the previous `normHref.hasSuffix("." + anchorHost)`
    /// check inverted trust on wildcard-hosted domains. Anchor host
    /// `github.io` (a public-suffix wildcard) and href host
    /// `attacker.github.io` would pass the divergence check because
    /// `attacker.github.io.hasSuffix(".github.io")` — letting any
    /// subdomain of a wildcard host claim the apex visually. Removed.
    func testAnchorDivergence_wildcardHostPhishingFlagged() {
        let url = URL(string: "https://attacker.github.io/steal")!
        XCTAssertTrue(
            OSC8URLPolicy.anchorDivergesFromHost(
                anchorText: "https://github.io/project",
                url: url
            ),
            "wildcard-host subdomain phishing must flag"
        )
        let pagesURL = URL(string: "https://hostile.pages.dev/x")!
        XCTAssertTrue(
            OSC8URLPolicy.anchorDivergesFromHost(
                anchorText: "Visit https://pages.dev for the docs",
                url: pagesURL
            ),
            "wildcard-host subdomain phishing must flag for pages.dev too"
        )
    }

    // MARK: - High-1: anchor-divergence wired into the click path

    /// Audit high-1. The detector existed but `resolveClickURL` never
    /// invoked it — pure dead code. Pin the wiring so a future
    /// "simplify resolveClickURL" refactor can't unwire it without a
    /// red test. The fixture row contains the visible anchor (which
    /// claims `https://apple.com/login`); the span's URL is the
    /// hostile target. A divergent click must block.

    func testCmdClick_blocksDivergentAnchor() throws {
        let view = try XCTUnwrap(TerminalView.makeHeadlessForTests())
        let opener = RecordingURLOpener()
        view.urlOpenerForTests = opener
        let visibleAnchor = "https://apple.com/login"
        view.installHyperlinkSnapshotForTests(
            rows: [visibleAnchor + String(repeating: " ", count: 80 - visibleAnchor.count)],
            linkAt: [(row: 0, cols: 0..<visibleAnchor.count, url: "https://evil.tld/login")]
        )
        view.performCmdClickForTests(row: 0, col: 5)
        XCTAssertEqual(
            opener.opened, [],
            "divergent anchor (apple.com visible, evil.tld href) must block the click"
        )
    }

    func testCmdClick_allowsNonDivergentAnchor() throws {
        // Same anchor and href host — legitimate OSC 8 link. Must open.
        let view = try XCTUnwrap(TerminalView.makeHeadlessForTests())
        let opener = RecordingURLOpener()
        view.urlOpenerForTests = opener
        let visibleAnchor = "https://example.com/login"
        view.installHyperlinkSnapshotForTests(
            rows: [visibleAnchor + String(repeating: " ", count: 80 - visibleAnchor.count)],
            linkAt: [(row: 0, cols: 0..<visibleAnchor.count, url: "https://example.com/login")]
        )
        view.performCmdClickForTests(row: 0, col: 5)
        XCTAssertEqual(
            opener.opened.map(\.absoluteString),
            ["https://example.com/login"],
            "matching anchor and href host must open normally"
        )
    }

    func testCmdClick_allowsPlainTextAnchor() throws {
        // Anchor "click here" is plain text — no URL-shaped token, so
        // anchorDivergesFromHost returns false and the click goes
        // through. This prevents the gate from over-blocking the
        // common case where the visible link text isn't a URL.
        let view = try XCTUnwrap(TerminalView.makeHeadlessForTests())
        let opener = RecordingURLOpener()
        view.urlOpenerForTests = opener
        let anchor = "click here to log in"
        view.installHyperlinkSnapshotForTests(
            rows: [anchor + String(repeating: " ", count: 80 - anchor.count)],
            linkAt: [(row: 0, cols: 0..<anchor.count, url: "https://example.com/login")]
        )
        view.performCmdClickForTests(row: 0, col: 5)
        XCTAssertEqual(
            opener.opened.map(\.absoluteString),
            ["https://example.com/login"],
            "plain-text anchor with no URL token must not trigger divergence block"
        )
    }

    func testCmdClick_allowsSubdomainAnchorMatch() throws {
        // Anchor mentions www.example.com; href is example.com.
        // Same-origin, not phishing — must open.
        let view = try XCTUnwrap(TerminalView.makeHeadlessForTests())
        let opener = RecordingURLOpener()
        view.urlOpenerForTests = opener
        let anchor = "https://www.example.com/login"
        view.installHyperlinkSnapshotForTests(
            rows: [anchor + String(repeating: " ", count: 80 - anchor.count)],
            linkAt: [(row: 0, cols: 0..<anchor.count, url: "https://example.com/login")]
        )
        view.performCmdClickForTests(row: 0, col: 5)
        XCTAssertEqual(
            opener.opened.map(\.absoluteString),
            ["https://example.com/login"],
            "subdomain anchor for parent-host href must not block"
        )
    }

    // MARK: - M12: ⌘-click in titlebar inset region suppresses URL resolution

    /// Pre-fix: `bufferPointFromEvent` snaps any titlebar-region click
    /// to displayRow 0. If row 0 carries an OSC 8 link cell at the
    /// click column, ⌘-drag-from-titlebar would silently open that
    /// URL instead of starting a window-drag (the user's clear
    /// intent — chrome region, not text). Audit M12.
    ///
    /// The fix gates URL resolution on `local.y < textAreaTop`. We
    /// can't easily verify that `performDrag` was called (NSWindow
    /// black-box), but we CAN verify the URL is NOT opened — sufficient
    /// to pin the regression.
    func testCmdClick_inTitlebarInsetRegion_doesNotOpenUrl() throws {
        let view = try XCTUnwrap(TerminalView.makeHeadlessForTests())
        let opener = RecordingURLOpener()
        view.urlOpenerForTests = opener
        // Row 0 is fully covered by an OSC 8 hyperlink. A click on
        // any column of row 0 in the text area would open the URL
        // — but a click in the titlebar region must not.
        let anchor = "https://example.com/dangerous-row-0-link"
        view.installHyperlinkSnapshotForTests(
            rows: [anchor + String(repeating: " ", count: 80 - anchor.count)],
            linkAt: [(row: 0, cols: 0..<80, url: "https://example.com/dangerous-row-0-link")]
        )
        // titlebarOnlyTopInset returns 28 when window is nil; with
        // an 800×480 frame the textAreaTop is 480 - 28 = 452. Click
        // at y=470 — 18 points inside the titlebar inset region.
        let titlebarPoint = NSPoint(x: 50, y: 470)
        let ev = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: titlebarPoint,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        ))
        view.mouseDown(with: ev)
        XCTAssertEqual(
            opener.opened, [],
            "⌘-click in titlebar inset region must NOT open the row-0 OSC 8 URL"
        )
    }

    /// Sister: ⌘-click in the text area keeps the existing OSC 8
    /// resolution path (the M12 gate is one-directional — it
    /// suppresses titlebar clicks only, never text-area clicks). The
    /// existing `testCmdClickOpensOsc8Href` covers that path through
    /// `performCmdClickForTests` (bypasses mouseDown). The titlebar
    /// regression in this file is the new gate.

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
        // P2-01: cells with no link id now return "" (was nil) so the
        // divergence detector sees a defined "no claim of identity" and
        // short-circuits.
        XCTAssertEqual(
            resolver.osc8AnchorText(row: 0, col: 5),
            "",
            "cell with no link id must return empty string"
        )
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
