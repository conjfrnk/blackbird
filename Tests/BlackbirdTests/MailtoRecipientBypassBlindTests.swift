import XCTest
@testable import Blackbird
@testable import BBCore

/// Regression pin for the OSC 8 `mailto:` multi-recipient policy.
///
/// Documented contract (`HyperlinkTests.testMailto_multiAtFailsClosed`, the
/// `OSC8URLPolicy` doc comments): a `mailto:` href that addresses MORE THAN ONE
/// recipient is rejected outright, because a mail client composes a message to
/// every listed address while the visible anchor can name only the legitimate
/// one -- "picking last silently gives evil.com the win".
///
/// RFC 6068 lets `@` be written as `%40` and the recipient separator `,` as
/// `%2C` inside the `mailto:` path, and mail clients percent-decode the
/// envelope before building the To field. So the multi-recipient verdict has to
/// be reached on the DECODED envelope: all of the following address two people
/// and must be rejected exactly like `mailto:user@apple.com,b@evil.com`:
///
///  - `mailto:evil%40x.com,v@apple.com`        (one encoded `@`, one literal)
///  - `mailto:v@apple.com%2Cevil%40x.com`      (no literal comma)
///  - `mailto:a%40b.com,c%40d.com`             (no literal `@` at all)
///
/// Legitimate single-recipient links (plain, with a `subject`, with a comma
/// that lives in the subject rather than the recipient list) must keep opening
/// so the fix cannot be "reject every mailto".
///
/// Cost: every test is a handful of `isAllowed` calls on <100-byte strings;
/// the click-path test builds one headless `TerminalView` (the same rig
/// `HyperlinkTests` uses); the FFI test feeds one short OSC 8 sequence to an
/// 80x24 `BBTerm`. Microseconds to low milliseconds, a few KB of memory.
final class MailtoRecipientBypassBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    private func url(_ s: String, file: StaticString = #filePath, line: UInt = #line) throws -> URL {
        try XCTUnwrap(URL(string: s), "fixture must parse as a URL: \(s)", file: file, line: line)
    }

    /// Verdict for one raw href, with a message that prints the measured value.
    private func assertVerdict(
        _ raw: String, expectAllowed: Bool, _ why: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let u = try url(raw, file: file, line: line)
        XCTAssertEqual(
            OSC8URLPolicy.isAllowed(u), expectAllowed,
            "\(raw) -> isAllowed must be \(expectAllowed): \(why)",
            file: file, line: line
        )
    }

    // MARK: - The reported trigger and its variants (all must be rejected)

    /// Exact trigger from the report: one `%40`-encoded address plus a literal
    /// comma and a literal second address. The literal-`@` count is 1, so a gate
    /// that only counts raw `@` bytes waves it through; the compose window is
    /// addressed to evil@x.com AND v@apple.com.
    func testEncodedAtPlusLiteralCommaIsRejected() throws {
        try assertVerdict(
            "mailto:evil%40x.com,v@apple.com", expectAllowed: false,
            "decodes to evil@x.com,v@apple.com -- two recipients"
        )
    }

    /// Hand-tracked variant: no literal comma, the separator is `%2C`.
    func testEncodedCommaAfterVisibleRecipientIsRejected() throws {
        try assertVerdict(
            "mailto:v@apple.com%2Cevil%40x.com", expectAllowed: false,
            "decodes to v@apple.com,evil@x.com -- two recipients"
        )
    }

    /// Variant with no literal `@` anywhere: both addresses are %40-encoded and
    /// separated by a literal comma.
    func testTwoFullyEncodedAddressesAreRejected() throws {
        try assertVerdict(
            "mailto:a%40b.com,c%40d.com", expectAllowed: false,
            "decodes to a@b.com,c@d.com -- two recipients"
        )
    }

    /// Sweep over the encoding permutations of a two-recipient envelope. Every
    /// row addresses both v@apple.com and evil@x.com once percent-decoded.
    func testEveryEncodingOfATwoRecipientEnvelopeIsRejected() throws {
        let rows: [(raw: String, why: String)] = [
            ("mailto:evil%40x.com,v@apple.com", "encoded @ first, literal second"),
            ("mailto:v@apple.com,evil%40x.com", "literal first, encoded @ second"),
            ("mailto:v@apple.com%2Cevil%40x.com", "%2C separator, encoded @ second"),
            ("mailto:v@apple.com%2cevil%40x.com", "lowercase %2c separator"),
            ("mailto:v%40apple.com%2Cevil%40x.com", "everything encoded"),
            ("mailto:v%40apple.com,evil%40x.com", "both @ encoded, literal comma"),
            ("mailto:evil%40x.com,v@apple.com?subject=hi", "bypass shape plus a legal subject"),
            ("mailto:Evil%40X.com,V@Apple.com", "mixed-case addresses"),
            ("MAILTO:evil%40x.com,v@apple.com", "upper-case scheme"),
        ]
        for r in rows {
            try assertVerdict(r.raw, expectAllowed: false, r.why)
        }
    }

    /// A percent-decoded combining mark (`%CC%81` -> U+0301) grapheme-clusters
    /// with the `@` or `,` in front of it, so `"@\u{301}" != "@"` and
    /// `",\u{301}" != ","` when compared as Swift `Character`s. A recipient
    /// check that counts Characters on the decoded envelope therefore stops
    /// seeing the separators, while a mail client that splits the decoded
    /// to-part on the `,` scalar still addresses both people. Every row decodes
    /// to two comma/semicolon-separated addresses.
    func testCombiningMarkNextToSeparatorsDoesNotHideASecondRecipient() throws {
        let rows: [(raw: String, why: String)] = [
            ("mailto:v@%CC%81apple.com,%CC%81evil@x.com",
             "marks fuse with the first @ and the comma; one bare @ is left"),
            ("mailto:evil@%CC%81x.com,%CC%81v@apple.com",
             "same shape with the attacker address first"),
            ("mailto:v@%CC%81apple.com%2C%CC%81evil@x.com",
             "comma written as %2C"),
            ("mailto:v@%CC%81apple.com;%CC%81evil@x.com",
             "semicolon separator"),
            ("mailto:a@%CC%81b.com,%CC%81c@%CC%81d.com",
             "marks fuse with every @ and the comma; no bare @ is left at all"),
        ]
        for r in rows {
            try assertVerdict(r.raw, expectAllowed: false, r.why)
        }
    }

    // MARK: - Already-rejected shapes stay rejected (guards)

    func testLiteralTwoRecipientEnvelopesStayRejected() throws {
        for raw in [
            "mailto:user@apple.com,b@evil.com",
            "mailto:v@apple.com%2Cevil@x.com",
            "mailto:v@apple.com,evil@x.com,third@y.com",
        ] {
            try assertVerdict(raw, expectAllowed: false, "literal multi-recipient envelope")
        }
    }

    // MARK: - Legitimate mailto links must keep opening (guards)

    func testSingleRecipientMailtoStillAllowed() throws {
        try assertVerdict("mailto:v@apple.com", expectAllowed: true, "plain single recipient")
        try assertVerdict(
            "mailto:alice@example.com?subject=Hello%20there", expectAllowed: true,
            "single recipient with the one permitted subject header"
        )
        try assertVerdict(
            "Mailto:alice@example.com", expectAllowed: true,
            "scheme is case-insensitive"
        )
    }

    /// A comma inside the SUBJECT is not a second recipient; only the envelope
    /// (before `?`) is the To list. Rejecting this would be an over-block.
    func testCommaInSubjectIsNotASecondRecipient() throws {
        try assertVerdict(
            "mailto:v@apple.com?subject=Hello,%20world", expectAllowed: true,
            "comma lives in the subject header, recipient list is one address"
        )
    }

    // MARK: - End to end through the real OSC 8 parser

    /// Feed the literal escape sequence from the report to a real `BBTerm`,
    /// read the href back out of the snapshot's link table, and run the policy
    /// on it. Asserts the href survives the Rust parser byte-for-byte first so
    /// the verdict assertion can never pass vacuously on a mangled link.
    func testOsc8SequenceFromReportIsRejectedAfterFFIRoundTrip() throws {
        let href = "mailto:evil%40x.com,v@apple.com"
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 80, rows: 24)))
        term.input("\u{1B}]8;;\(href)\u{1B}\\visible text\u{1B}]8;;\u{1B}\\")
        let snap = try XCTUnwrap(term.snapshot())

        let id = snap.linkID(row: 0, col: 0)
        XCTAssertNotEqual(id, 0, "precondition: the cell under the OSC 8 span carries a link id")
        XCTAssertEqual(
            snap.linkURL(id: id), href,
            "precondition: the href must round-trip through the core unchanged"
        )

        let parsed = try url(try XCTUnwrap(snap.linkURL(id: id)))
        XCTAssertEqual(
            OSC8URLPolicy.isAllowed(parsed), false,
            "OSC 8 href \(href) addresses two recipients and must be refused"
        )
    }

    // MARK: - End to end through the real command-click resolution

    /// Positive control + attack through `TerminalView.resolveClickURL` (the
    /// path shared by command-click and the context menu's gate): the single
    /// recipient link opens, the multi-recipient links open nothing.
    func testCmdClickOnMultiRecipientMailtoOpensNothing() throws {
        let view = try XCTUnwrap(TerminalView.makeHeadlessForTests())
        let opener = RecordingURLOpener()
        view.urlOpenerForTests = opener

        // Anchor text is deliberately not URL-shaped so the click-time
        // anchor/host divergence gate has nothing to compare: the policy gate
        // is the only thing standing between the click and NSWorkspace.
        let anchor = "Contact support team"
        let row = anchor + String(repeating: " ", count: 40 - anchor.count)
        let cols = 0..<anchor.count
        let control = "mailto:v@apple.com"
        let attacks = [
            "mailto:evil%40x.com,v@apple.com",
            "mailto:v@apple.com%2Cevil%40x.com",
            "mailto:a%40b.com,c%40d.com",
        ]

        view.installHyperlinkSnapshotForTests(
            rows: [row], linkAt: [(row: 0, cols: cols, url: control)]
        )
        view.performCmdClickForTests(row: 0, col: 3)
        XCTAssertEqual(
            opener.opened.map(\.absoluteString), [control],
            "precondition: a single-recipient mailto must open through this rig"
        )

        for attack in attacks {
            opener.opened.removeAll()
            view.installHyperlinkSnapshotForTests(
                rows: [row], linkAt: [(row: 0, cols: cols, url: attack)]
            )
            view.performCmdClickForTests(row: 0, col: 3)
            XCTAssertEqual(
                opener.opened.map(\.absoluteString), [],
                "command-click on \(attack) must not hand a two-recipient compose URL to the system"
            )
        }
    }
}
