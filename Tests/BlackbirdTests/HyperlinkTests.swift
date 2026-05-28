import XCTest
@testable import Blackbird
@testable import BBCore

/// OSC 8 hyperlink coverage across the FFI → Swift snapshot → click path.
///
/// **Compat-matrix pin:** this file backs the OSC 8 row in
/// `docs/compat-matrix.md`. `git grep "compat-matrix.md"` resolves to every
/// test that gates a row in that doc.
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

    /// Audit S4-002: extend the Rust core's `is_bidi_or_invisible_scalar`
    /// coverage to the Swift click-time URL scrub. Without this gate,
    /// hostile remotes could embed U+2060 / VS chars / BOM / tag block
    /// scalars (all invisible) in OSC 8 URLs, defeating the documented
    /// "no hidden chars in URL handed to NSWorkspace" invariant.
    func testOsc8UrlAllowlistRejectsExtendedInvisibleCodepoints() {
        // Each tuple: (URL, codepoint name) — for descriptive failure messages.
        let cases: [(String, String)] = [
            ("https://example.com/%C2%AD",       "U+00AD soft hyphen"),
            ("https://example.com/%D8%9C",       "U+061C Arabic letter mark"),
            ("https://example.com/%E1%A0%8E",    "U+180E Mongolian vowel separator"),
            ("https://example.com/%E2%81%A0",    "U+2060 Word Joiner"),
            ("https://example.com/%EF%B8%80",    "U+FE00 Variation Selector-1"),
            ("https://example.com/%EF%B8%8F",    "U+FE0F Variation Selector-16"),
            ("https://example.com/%EF%BB%BF",    "U+FEFF BOM / ZWNBSP"),
            ("https://example.com/%F3%A0%80%80", "U+E0000 tag block start"),
            ("https://example.com/%F3%A0%81%BF", "U+E007F tag block end"),
            ("https://example.com/%F3%A0%84%80", "U+E0100 Variation Selector-17"),
            ("https://example.com/%F3%A0%87%AF", "U+E01EF Variation Selector-256"),
        ]
        for (raw, name) in cases {
            guard let u = URL(string: raw) else {
                XCTFail("URL init failed for \(name): \(raw)")
                continue
            }
            XCTAssertFalse(
                OSC8URLPolicy.isAllowed(u),
                "percent-encoded \(name) must be rejected: \(raw)"
            )
        }
    }

    /// Sanity: the extended invisible-char filter must NOT block
    /// legitimate percent-encoded characters (printable, whitespace,
    /// non-ASCII visible glyphs).
    func testOsc8UrlAllowlistAcceptsLegitimatePercentEncoded() {
        for raw in [
            "https://example.com/path%20with%20spaces",   // %20 = space
            "https://example.com/?q=hello%20world",        // %20 in query
            "https://example.com/%2F",                     // %2F literal slash
            "https://example.com/%E2%9C%93",               // U+2713 ✓ visible
            "https://example.com/%C3%A9",                  // U+00E9 é visible
        ] {
            guard let u = URL(string: raw) else { continue }
            XCTAssertTrue(
                OSC8URLPolicy.isAllowed(u),
                "legitimate percent-encoded chars must pass: \(raw)"
            )
        }
    }

    /// Audit S4-022: `ftp://` is no longer on the allowlist. Modern macOS
    /// (Big Sur+) does not ship a default FTP client, and FTP credentials
    /// are routinely embedded in URLs (plaintext exfil) — both reasons to
    /// drop the scheme. Users wanting an FTP click-through can still copy
    /// the URL and `open` from their shell.
    func testOsc8UrlSchemeAllowlistRejectsFTPScheme() {
        for raw in [
            "ftp://ftp.example.com/file.tgz",
            "ftp://anon@ftp.evil.tld/payload.tar",
            "FTP://example.com/",
        ] {
            guard let u = URL(string: raw) else { continue }
            XCTAssertFalse(
                OSC8URLPolicy.isAllowed(u),
                "ftp:// must be rejected — vintage scheme without a default macOS handler: \(raw)"
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
        // still dispatches via the registered http/https/mailto
        // handler which is the user's browser / Mail.app.
        let ok = [
            "https://example.com:8443/path?q=1&x=2#frag",
            "http://[2001:db8::1]/",
            "mailto:root@example.com?subject=hi",
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
        for raw in ["https://apple.com/", "http://example.com/path"] {
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
    /// domain on a different-domain href. Pre-fix, `hostLooksLikeIDN`
    /// only ran for http(s)/ftp; `isMailtoSafe` accepted any domain.
    /// Pass-3 honesty rename (item 3): this test passes because of the
    /// *domain mismatch* (`evil.com` vs `аpple.com`), not because of
    /// the IDN substitution per se — the divergence detector would
    /// flag any unrelated domain pair. The new
    /// `testAnchorDivergence_mailtoIDNAnchorOnSameDomainFlagged` pins
    /// the IDN-on-same-domain axis specifically.
    func testAnchorDivergence_mailtoDifferentDomainFlagged() {
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

    /// Audit pass-3 (item 3). Pin that the divergence path detects an
    /// IDN substitution on the anchor SIDE when the href is the
    /// legitimate ASCII domain. Anchor visually claims `apple.com` but
    /// uses Cyrillic а; href is real apple.com. The detector flags the
    /// domain string mismatch (Cyrillic-аpple.com vs apple.com) — this
    /// pins that the IDN substitution is caught by the divergence
    /// detector, not just by `isAllowed`'s IDN gate on the href side.
    func testAnchorDivergence_mailtoIDNAnchorOnSameDomainFlagged() {
        let url = URL(string: "mailto:user@apple.com")!
        XCTAssertTrue(
            OSC8URLPolicy.anchorDivergesFromHost(
                anchorText: "mailto:user@\u{0430}pple.com",  // Cyrillic а
                url: url
            ),
            "IDN-look-alike anchor with same legitimate href must flag"
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

    // MARK: - Pass-3 hardening

    /// Pass-3 item 1 (CRITICAL). A URL like
    /// `mailto:user@apple.com%08evil.com` round-trips through
    /// Foundation: `absoluteString` keeps the `%08` while `path`
    /// silently drops it, so `mailtoDomain` reads `apple.comevil.com`
    /// and any subsequent comparison sees the wrong domain. Mail.app
    /// may then re-decode and bounce the click anywhere from
    /// `apple.com` to `evil.com`. `isAllowed` must reject any URL
    /// whose `absoluteString` contains percent-encoded C0 controls or
    /// DEL — there is no benign reason to embed a control byte in an
    /// OSC 8 hyperlink.
    func testIsAllowed_rejectsPercentEncodedControlBytes() {
        for byte: UInt8 in [0x00, 0x07, 0x08, 0x09, 0x0A, 0x0D, 0x1B, 0x7F] {
            let mailto = "mailto:user@apple.com%\(String(format: "%02X", byte))evil.com"
            let https  = "https://apple.com/path%\(String(format: "%02X", byte))evil"
            if let u = URL(string: mailto) {
                XCTAssertFalse(
                    OSC8URLPolicy.isAllowed(u),
                    "mailto with %\(String(format: "%02X", byte)) must be rejected"
                )
            }
            if let u = URL(string: https) {
                XCTAssertFalse(
                    OSC8URLPolicy.isAllowed(u),
                    "https with %\(String(format: "%02X", byte)) must be rejected"
                )
            }
        }
    }

    /// Audit fix-#09 (2026-05-21): the OSC 8 click-path control-byte
    /// gate previously only matched %00-%1F / %7F. Foundation preserves
    /// percent-encoded UTF-8 in URL.absoluteString, so a hostile OSC 8
    /// href containing %E2%80%AE (U+202E RLO), %C2%85 (U+0085 NEL / C1),
    /// or other percent-encoded bidi/C1 sequences passed the gate
    /// verbatim, reached NSWorkspace.open + NSPasteboard.general via
    /// Copy Link, and would render flipped in any URL-decoding
    /// downstream surface (Mail compose / bidi-rendering issue tracker).
    func testIsAllowed_rejectsPercentEncodedBidi() {
        // U+202E RIGHT-TO-LEFT OVERRIDE — %E2%80%AE.
        let rlo = URL(string: "https://safe.com/%E2%80%AEevil.tld/redir")!
        XCTAssertFalse(OSC8URLPolicy.isAllowed(rlo),
                       "URL with percent-encoded U+202E must be rejected")
        // U+202D LEFT-TO-RIGHT OVERRIDE — %E2%80%AD (same range).
        let lro = URL(string: "https://safe.com/%E2%80%ADevil")!
        XCTAssertFalse(OSC8URLPolicy.isAllowed(lro),
                       "URL with percent-encoded U+202D must be rejected")
        // U+200B ZERO-WIDTH SPACE — %E2%80%8B.
        let zwsp = URL(string: "https://safe.com/path%E2%80%8B/login")!
        XCTAssertFalse(OSC8URLPolicy.isAllowed(zwsp),
                       "URL with percent-encoded U+200B must be rejected")
    }

    func testIsAllowed_rejectsPercentEncodedC1Controls() {
        // U+0085 NEL (next-line) encoded as %C2%85.
        let nel = URL(string: "https://safe.com/%C2%85evil")!
        XCTAssertFalse(OSC8URLPolicy.isAllowed(nel),
                       "URL with percent-encoded C1 NEL must be rejected")
        // U+0090 DCS — %C2%90.
        let dcs = URL(string: "https://safe.com/%C2%90evil")!
        XCTAssertFalse(OSC8URLPolicy.isAllowed(dcs),
                       "URL with percent-encoded C1 DCS must be rejected")
    }

    /// Sanity: percent-encoded non-control bytes must still pass.
    /// %20 = space, %2F = '/', %3F = '?' — all legitimate in URLs and
    /// must not be confused with control-byte percent encodings.
    func testIsAllowed_acceptsBenignPercentEncodings() {
        let space = URL(string: "https://apple.com/some%20path")!
        XCTAssertTrue(OSC8URLPolicy.isAllowed(space),
                      "URL with %20 (space) must remain allowed")
        let slash = URL(string: "https://apple.com/a%2Fb")!
        XCTAssertTrue(OSC8URLPolicy.isAllowed(slash),
                      "URL with %2F (slash) must remain allowed")
    }

    /// Pass-3 item 2 (HIGH). Default-port confusion: previously the
    /// host comparison ignored ports, so `https://example.com` looked
    /// identical to `https://example.com:8443` and a hostile remote
    /// could front-end an attacker-controlled port behind an apex
    /// anchor. Compare (host, effectivePort) tuples; only divergent
    /// effective ports flag.
    func testAnchorDivergence_nondefaultPortFlagged() {
        let url = URL(string: "https://example.com:8443/")!
        XCTAssertTrue(
            OSC8URLPolicy.anchorDivergesFromHost(
                anchorText: "https://example.com/",
                url: url
            ),
            "anchor omitting non-default port must trip divergence"
        )
    }

    /// Pass-3 item 2 (HIGH). The other half of the port equivalence
    /// rule: an explicit default-port (`:443` for https) must compare
    /// equal to an omitted port. Otherwise we'd over-block legitimate
    /// links that happen to spell out `:443`.
    func testAnchorDivergence_defaultPortExplicitNotFlagged() {
        let url = URL(string: "https://example.com:443/")!
        XCTAssertFalse(
            OSC8URLPolicy.anchorDivergesFromHost(
                anchorText: "https://example.com/",
                url: url
            ),
            "explicit default port must equal omitted"
        )
    }

    /// Pass-3 item 4 (MEDIUM). The whitespace-walk candidate scanner
    /// keeps trailing punctuation, so `visit https://apple.com,
    /// please` produced the candidate `https://apple.com,` —
    /// Foundation accepted it with host `apple.com,` and divergence
    /// fired on a legitimate match. Trailing punctuation must be
    /// stripped before parsing.
    func testAnchorDivergence_trailingPunctuationStripped() {
        let url = URL(string: "https://apple.com/")!
        XCTAssertFalse(
            OSC8URLPolicy.anchorDivergesFromHost(
                anchorText: "visit https://apple.com, please",
                url: url
            ),
            "trailing comma in anchor must not trigger false-positive divergence"
        )
    }

    /// Pass-3 item 6 (MEDIUM). RFC 6068 multi-recipient mailto
    /// (`mailto:user@safe.com,b@evil.com`) used to silently pick the
    /// last `@`-separated segment via `lastIndex(of:)`, attributing
    /// the URL to evil.com without telling anyone. There is no honest
    /// "canonical" domain for a multi-recipient mailto — fail closed.
    func testMailto_multiAtFailsClosed() {
        guard let u = URL(string: "mailto:user@apple.com,b@evil.com") else { return }
        XCTAssertFalse(
            OSC8URLPolicy.isAllowed(u),
            "multi-@ mailto must be rejected (cannot determine canonical domain)"
        )
    }

    /// Pass-3 item 8 (MEDIUM). KNOWN LIMITATION: Foundation's
    /// `URL.host` doesn't normalise IPv6 long-form vs short-form, so
    /// the divergence detector sees them as different hosts and
    /// flags an over-broad mismatch. Security-correct (over-blocks
    /// rather than under-blocks); pinned here so any future "fix"
    /// has to consciously update this comment instead of accidentally
    /// changing the behaviour.
    ///
    /// If this test starts FAILING, IPv6 normalization has been
    /// added — confirm the new behavior is intentional and update
    /// this comment.
    func testAnchorDivergence_ipv6LongVsShortFormCurrentlyDiverges() {
        let url = URL(string: "https://[2001:db8::1]/")!
        XCTAssertTrue(
            OSC8URLPolicy.anchorDivergesFromHost(
                anchorText: "https://[2001:0db8:0000:0000:0000:0000:0000:0001]/",
                url: url
            ),
            "IPv6 long-form vs short-form currently diverges (Foundation does not normalise)"
        )
    }

    // MARK: - H3: embedded credentials in OSC 8 hyperlinks

    /// Audit H3. A URL like `https://attacker:hunter2@apple.com/` passes
    /// the host check (`URL.host == "apple.com"`) and the divergence
    /// check (anchor host matches href host) — but `NSWorkspace.open`
    /// then hands the credential-bearing URL to the browser, leaking
    /// `attacker:hunter2` via URL bar / Referer / history. Reject
    /// credential URLs at the policy gate before any of those surfaces
    /// see them.
    func testIsAllowed_rejectsURLWithUserAndPassword() {
        guard let u = URL(string: "https://user:pass@example.com/") else {
            XCTFail("URL(string:) should accept user:pass@ form")
            return
        }
        XCTAssertFalse(
            OSC8URLPolicy.isAllowed(u),
            "URL with embedded user:pass credentials must be rejected"
        )
    }

    /// Audit H3. The user-only form (`https://user@host/` with no
    /// password) is the same exfil shape — the username component is
    /// still attacker-controlled and still flows through the browser
    /// surfaces. Reject when `URL.user` is non-empty regardless of
    /// `URL.password`.
    func testIsAllowed_rejectsURLWithUserOnly() {
        guard let u = URL(string: "https://user@example.com/") else {
            XCTFail("URL(string:) should accept user@ form")
            return
        }
        XCTAssertFalse(
            OSC8URLPolicy.isAllowed(u),
            "URL with user-only credentials must be rejected"
        )
    }

    /// Audit H3. Percent-encoded userinfo (`%75ser` for "user") parses
    /// through Foundation: `URL.user` returns the decoded "user". Pin
    /// that the credential gate sees the decoded form and rejects, so
    /// a hostile remote can't bypass with `https://%75ser:pa%73s@host/`.
    func testIsAllowed_rejectsURLWithPercentEncodedCredentials() {
        guard let u = URL(string: "https://%75ser:pa%73s@example.com/") else {
            XCTFail("URL(string:) should accept percent-encoded user:pass form")
            return
        }
        XCTAssertNotNil(u.user, "Foundation must decode percent-encoded user before the gate sees it")
        XCTAssertFalse(
            OSC8URLPolicy.isAllowed(u),
            "URL with percent-encoded credentials must be rejected after Foundation decodes them"
        )
    }

    /// Audit H3. The redactor strips `user:pass@` from a URL string
    /// before it reaches the hover tooltip's NSTextField. Path, query,
    /// and fragment are preserved — only the userinfo is removed.
    func testRedactCredentialsForDisplay_stripsUserAndPassword() {
        XCTAssertEqual(
            OSC8URLPolicy.redactCredentialsForDisplay("https://user:pass@example.com/path?q=1#frag"),
            "https://example.com/path?q=1#frag",
            "redactor must strip user:pass and preserve path/query/fragment"
        )
    }

    /// Audit H3. Backward compatibility: a plain URL with no
    /// credentials passes the gate AND the redactor returns it
    /// unchanged. Pins that the H3 fix doesn't over-block legitimate
    /// hyperlinks or mangle their display string.
    func testCredentialFix_backwardCompatPlainURL() {
        guard let u = URL(string: "https://example.com/path") else {
            XCTFail("URL(string:) should accept plain https URL")
            return
        }
        XCTAssertTrue(
            OSC8URLPolicy.isAllowed(u),
            "plain URL with no credentials must still pass the gate"
        )
        XCTAssertEqual(
            OSC8URLPolicy.redactCredentialsForDisplay("https://example.com/path"),
            "https://example.com/path",
            "redactor must be a no-op on URLs without credentials"
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
