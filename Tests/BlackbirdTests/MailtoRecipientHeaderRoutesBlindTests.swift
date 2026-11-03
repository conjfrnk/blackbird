import XCTest
import AppKit
import Metal
@testable import Blackbird
@testable import BBCore

/// Regression pin for the remaining recipient-adding routes of the OSC 8
/// `mailto:` policy.
///
/// Documented contract (`HyperlinkTests.testMailto_multiAtFailsClosed`,
/// `testMailto_rejectsDuplicateSubjectItems`, `MailtoRecipientBypassBlindTests`,
/// the `OSC8URLPolicy` doc comments): a `mailto:` href handed to the system
/// mail client must address EXACTLY ONE recipient and carry no
/// recipient-bearing header. The visible anchor can name only one person, so
/// anything that makes the compose window address somebody else is a hidden
/// recipient and the link fails closed. Harmless headers (`subject`) may stay.
///
/// RFC 6068 gives a `mailto:` URI several ways to add a recipient besides
/// writing a second address in the path. This suite pins each of them:
///
///  1. Query headers `to=`, `cc=`, `bcc=` (any letter case, any position,
///     repeated, with a literal or percent-encoded value, with or without an
///     envelope address).
///  2. Percent-encoded header NAMES (`%62cc=` is `bcc=`): mail clients decode
///     the name before matching it.
///  3. Anything riding behind a raw `#`: RFC 6068 requires `#` to be written
///     `%23`, so a raw `#` is outside the grammar and clients are free to
///     keep scanning the text after it for addresses.
///  4. Separators that only appear once the envelope is percent-decoded
///     (`%3F` `?`, `%26` `&`, `%3D` `=`, `%25` `%`). A client that decodes the
///     path first and then splits sees a header block (or, for `%25`, a second
///     decoding round) that the raw string never showed.
///  5. The one permitted `subject` header is still free text. A decoded `&`,
///     `;`, `=` or `%` in its VALUE (`subject=hi%26bcc%3Devil%40x.com` is
///     `hi&bcc=evil@x.com`) hands a client that decodes before it splits a
///     second header, or a second decoding round. A second raw `?` inside the
///     query is outside the RFC 6068 grammar for the same reason.
///
/// A refused link must be refused IDENTICALLY by the three surfaces that
/// consume the policy: the hover underline + dwell tooltip (+ Force-Touch
/// preview), the command-click path, and the right-click context menu. The
/// end-to-end tests below drive a real `BBTerm` -> `BBSnapshot` -> `TerminalView`
/// rig through all three and compare the verdicts.
///
/// Fixtures use the visible recipient `visible@example.com` and the attacker
/// `evil@x.com`. Rows whose attack would ALSO trip the pre-existing "more than
/// one `@`" gate are deliberately avoided in the decoded-separator group (they
/// carry exactly one `@`, or none for the `Boss` address-book-alias variants),
/// so a pass cannot come from the older gate.
///
/// Cost pre-flight (CLAUDE.md test-authoring rule): the policy tests are a few
/// dozen `isAllowed` calls on <100-byte strings. The end-to-end tests build ONE
/// 800 x 480 `TerminalView` (real `MTLDevice`, never windowed, never drawn) and
/// one 80 x 24 `BBTerm` (~30 KB snapshot) per href, all kept alive in
/// `liveTerms` until `tearDown`: about 60 hrefs x (one tiny term + three
/// lookups), well under a second and under 5 MB at peak. No PTY, no `TerminalSession`, no
/// `MainWindowController`, no window, no event injection (the right-click is a
/// synthetic `NSEvent` handed straight to `menu(for:)`, never posted).
final class MailtoRecipientHeaderRoutesBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Fixture tables

    private struct Row {
        let href: String
        let why: String
    }

    /// 1. Recipient-bearing query headers. Every row addresses `evil@x.com`
    /// (or a second `to`) in addition to, or instead of, the visible person.
    private static let queryHeaderRows: [Row] = [
        Row(href: "mailto:visible@example.com?bcc=evil@x.com",
            why: "bcc header: the reported trigger, a silent blind-copy"),
        Row(href: "mailto:visible@example.com?cc=evil@x.com",
            why: "cc header adds a second recipient"),
        Row(href: "mailto:visible@example.com?to=evil@x.com",
            why: "to header adds a second recipient"),
        Row(href: "mailto:visible@example.com?BCC=evil@x.com",
            why: "header names are case-insensitive: BCC"),
        Row(href: "mailto:visible@example.com?Cc=evil@x.com",
            why: "header names are case-insensitive: Cc"),
        Row(href: "mailto:visible@example.com?To=evil@x.com",
            why: "header names are case-insensitive: To"),
        Row(href: "mailto:visible@example.com?subject=hi&bcc=evil@x.com",
            why: "harmless subject first, then bcc"),
        Row(href: "mailto:visible@example.com?bcc=evil@x.com&subject=hi",
            why: "bcc first, then a harmless subject"),
        Row(href: "mailto:visible@example.com?body=hi&cc=evil@x.com",
            why: "body then cc"),
        Row(href: "mailto:visible@example.com?bcc=evil%40x.com",
            why: "percent-encoded VALUE of a bcc header"),
        Row(href: "mailto:visible@example.com?cc=a@x.com,b@x.com",
            why: "cc header carrying two addresses"),
        Row(href: "mailto:?to=evil@x.com",
            why: "no envelope address at all, the to header is the only recipient"),
        Row(href: "mailto:?bcc=evil@x.com",
            why: "no envelope address, a bcc-only compose"),
    ]

    /// 1b. Repeated recipient headers.
    private static let repeatedHeaderRows: [Row] = [
        Row(href: "mailto:visible@example.com?cc=a@x.com&cc=b@x.com",
            why: "cc repeated"),
        Row(href: "mailto:visible@example.com?to=a@x.com&to=b@x.com",
            why: "to repeated"),
        Row(href: "mailto:visible@example.com?bcc=a@x.com&bcc=b@x.com",
            why: "bcc repeated"),
        Row(href: "mailto:visible@example.com?cc=evil@x.com&bcc=evil@x.com",
            why: "cc and bcc together"),
        Row(href: "mailto:visible@example.com?to=a@x.com&cc=b@x.com&bcc=c@x.com",
            why: "all three recipient headers together"),
    ]

    /// 2. Percent-encoded header names. Each decodes to a recipient header.
    private static let encodedNameRows: [Row] = [
        Row(href: "mailto:visible@example.com?%62cc=evil@x.com",
            why: "%62cc is bcc"),
        Row(href: "mailto:visible@example.com?b%63c=evil@x.com",
            why: "b%63c is bcc"),
        Row(href: "mailto:visible@example.com?bc%63=evil@x.com",
            why: "bc%63 is bcc"),
        Row(href: "mailto:visible@example.com?%62%63%63=evil@x.com",
            why: "every letter of bcc encoded"),
        Row(href: "mailto:visible@example.com?%63c=evil@x.com",
            why: "%63c is cc"),
        Row(href: "mailto:visible@example.com?c%63=evil@x.com",
            why: "c%63 is cc"),
        Row(href: "mailto:visible@example.com?%43c=evil@x.com",
            why: "%43c is Cc (upper-case C)"),
        Row(href: "mailto:visible@example.com?%74o=evil@x.com",
            why: "%74o is to"),
        Row(href: "mailto:visible@example.com?t%6Fa=evil@x.com&t%6F=evil@x.com",
            why: "an unrelated name then t%6F (to)"),
        Row(href: "mailto:visible@example.com?%62cc=evil%40x.com",
            why: "encoded name AND encoded value"),
        Row(href: "mailto:visible@example.com?subject=hi&%62cc=evil@x.com",
            why: "harmless subject, then an encoded-name bcc"),
        Row(href: "mailto:visible@example.com?%62cc=a@x.com&%62cc=b@x.com",
            why: "repeated encoded-name bcc"),
        Row(href: "mailto:?%74o=evil@x.com",
            why: "encoded to with no envelope address"),
    ]

    /// 3. Recipients behind a raw `#`.
    private static let rawHashRows: [Row] = [
        Row(href: "mailto:visible@example.com#evil@x.com",
            why: "second address in the fragment"),
        Row(href: "mailto:visible@example.com#,evil@x.com",
            why: "comma-separated second address in the fragment"),
        Row(href: "mailto:visible@example.com#evil%40x.com",
            why: "second address in the fragment, @ percent-encoded"),
        Row(href: "mailto:visible@example.com#%2Cevil%40x.com",
            why: "fragment spelling a comma and an address entirely in escapes"),
        Row(href: "mailto:visible@example.com#bcc=evil@x.com",
            why: "bcc header spelled in the fragment"),
        Row(href: "mailto:visible@example.com#?bcc=evil@x.com",
            why: "a query-looking tail behind the raw #"),
        Row(href: "mailto:visible@example.com?subject=hi#bcc=evil@x.com",
            why: "legal subject, then # and a bcc header"),
        Row(href: "mailto:visible@example.com?subject=hi#,evil@x.com",
            why: "legal subject, then # and a second address"),
    ]

    /// 4. Separators that appear only after the envelope is percent-decoded.
    /// Every row has at most ONE `@` raw and decoded, so the older multi-`@`
    /// gate cannot be what rejects it.
    private static let decodedSeparatorRows: [Row] = [
        Row(href: "mailto:visible%3Fbcc=evil@x.com",
            why: "decoded ? opens a header block: visible?bcc=evil@x.com"),
        Row(href: "mailto:visible%3fcc%3Devil@x.com",
            why: "decoded ? and = (lower-case hex): visible?cc=evil@x.com"),
        Row(href: "mailto:visible@example.com%3Fbcc%3DBoss",
            why: "decoded ? and = with an address-book alias, no second @"),
        Row(href: "mailto:visible@example.com%3Fto%3DBoss",
            why: "decoded ?to= with an address-book alias"),
        Row(href: "mailto:visible@example.com%26bcc%3DBoss",
            why: "decoded & and =: visible@example.com&bcc=Boss"),
        Row(href: "mailto:vis%3Fible@example.com",
            why: "decoded ? alone in the envelope"),
        Row(href: "mailto:vis%26ible@example.com",
            why: "decoded & alone in the envelope"),
        Row(href: "mailto:vis%3Dible@example.com",
            why: "decoded = alone in the envelope"),
        Row(href: "mailto:vis%25ible@example.com",
            why: "decoded % alone in the envelope"),
        Row(href: "mailto:visible%252Cevil@x.com",
            why: "decoded % : a client that decodes twice sees visible,evil@x.com"),
        Row(href: "mailto:visible&bcc=evil@x.com",
            why: "literal & and = in the envelope"),
    ]

    /// 5. Recipient headers smuggled inside the VALUE of the one permitted
    /// `subject` item, or behind a second raw `?`. Each has exactly one `@`
    /// in the envelope, so the multi-`@` gate is not what refuses it.
    private static let subjectValueRows: [Row] = [
        Row(href: "mailto:visible@example.com?subject=hi%26bcc%3Devil%40x.com",
            why: "decoded subject value is hi&bcc=evil@x.com"),
        Row(href: "mailto:visible@example.com?subject=hi%26bcc%3Devil@x.com",
            why: "same, with a literal @ in the value"),
        Row(href: "mailto:visible@example.com?subject=hi%26cc%3DBoss",
            why: "decoded & and = with an address-book alias, no second @"),
        Row(href: "mailto:visible@example.com?subject=hi%26to%3DBoss",
            why: "decoded &to= with an address-book alias"),
        Row(href: "mailto:visible@example.com?subject=hi;bcc=evil@x.com",
            why: "literal ; between the subject and a bcc pair"),
        Row(href: "mailto:visible@example.com?subject=hi%3Bbcc%3Devil@x.com",
            why: "decoded ; and = in the subject value"),
        Row(href: "mailto:visible@example.com?subject=hi%2526bcc%253Devil@x.com",
            why: "double-encoded & and =: a second decoding round exposes bcc"),
        Row(href: "mailto:visible@example.com?subject=hi%2526bcc%253Devil%2540x.com",
            why: "double-encoded bcc header with a double-encoded address"),
        Row(href: "mailto:visible@example.com?subject=hi%25",
            why: "decoded % in the subject value starts a second decoding round"),
        Row(href: "mailto:visible@example.com?subject=a%3Db",
            why: "decoded = in the subject value"),
        Row(href: "mailto:visible@example.com?subject=hi?bcc=evil@x.com",
            why: "second raw ? restarts header parsing in a lenient client"),
        Row(href: "mailto:visible@example.com?subject=hi?to=Boss",
            why: "second raw ? followed by a to header, no second @"),
    ]

    /// Single-recipient links that MUST keep opening, so the fix cannot be
    /// "reject every mailto".
    private static let legitimateRows: [Row] = [
        Row(href: "mailto:visible@example.com", why: "plain single recipient"),
        Row(href: "mailto:visible@example.com?subject=Hello%20there",
            why: "single recipient with the one permitted subject header"),
        Row(href: "mailto:visible@example.com?subject=Hello,%20world",
            why: "a comma inside the SUBJECT is not a second recipient"),
        Row(href: "mailto:visible@example.com?subject=What%3F",
            why: "an encoded ? in the SUBJECT is ordinary text"),
        Row(href: "mailto:first.last+tag@example.com",
            why: "dots and a plus tag in the local part"),
        Row(href: "MAILTO:visible@example.com", why: "scheme is case-insensitive"),
    ]

    /// Every refused href, for the end-to-end consistency sweep.
    private static var allRefusedRows: [Row] {
        queryHeaderRows + repeatedHeaderRows + encodedNameRows
            + rawHashRows + decodedSeparatorRows + subjectValueRows
    }

    // MARK: - Policy-level helpers

    private func parsed(_ raw: String, file: StaticString = #filePath, line: UInt = #line) throws -> URL {
        try XCTUnwrap(URL(string: raw), "fixture must parse as a URL: \(raw)", file: file, line: line)
    }

    /// Assert the policy verdict for every row, with the measured value in the
    /// message. Collects ALL mismatches (no early exit) so one run reports
    /// every encoding that still slips through.
    private func assertPolicy(
        _ rows: [Row], expectAllowed: Bool,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        XCTAssertFalse(rows.isEmpty, "fixture table must not be empty", file: file, line: line)
        for r in rows {
            let u = try parsed(r.href, file: file, line: line)
            let verdict: Bool = OSC8URLPolicy.isAllowed(u)
            XCTAssertEqual(
                verdict, expectAllowed,
                "isAllowed(\(r.href)) = \(verdict), must be \(expectAllowed): \(r.why)",
                file: file, line: line
            )
        }
    }

    // MARK: - 1. Query headers

    /// The reported trigger and its to/cc/bcc siblings: the compose window is
    /// addressed to somebody the visible text never names.
    func testRecipientQueryHeadersAreRefused() throws {
        try assertPolicy(Self.queryHeaderRows, expectAllowed: false)
    }

    func testRepeatedRecipientHeadersAreRefused() throws {
        try assertPolicy(Self.repeatedHeaderRows, expectAllowed: false)
    }

    // MARK: - 2. Percent-encoded header names

    /// `%62cc` is `bcc` to a mail client. A gate that compares the RAW query
    /// text against `"subject"` / `"bcc"` sees an unknown name and either
    /// waves the link through or, worse, treats it as harmless.
    func testPercentEncodedRecipientHeaderNamesAreRefused() throws {
        try assertPolicy(Self.encodedNameRows, expectAllowed: false)
    }

    // MARK: - 3. Raw '#'

    func testRecipientsBehindRawHashAreRefused() throws {
        try assertPolicy(Self.rawHashRows, expectAllowed: false)
    }

    // MARK: - 4. Decoded separators in the envelope

    func testDecodedQuerySeparatorsInEnvelopeAreRefused() throws {
        try assertPolicy(Self.decodedSeparatorRows, expectAllowed: false)
    }

    // MARK: - 5. Subject value and second raw '?'

    func testRecipientHeadersSmuggledInSubjectValueAreRefused() throws {
        try assertPolicy(Self.subjectValueRows, expectAllowed: false)
    }

    // MARK: - Guards: single-recipient links keep opening

    func testLegitimateSingleRecipientLinksStillAllowed() throws {
        try assertPolicy(Self.legitimateRows, expectAllowed: true)
    }

    // MARK: - End to end: hover, click and context menu must agree

    /// Everything the three policy consumers decided about one OSC 8 href.
    /// Equatable + CustomStringConvertible so a mismatch prints every surface.
    private struct SurfaceVerdict: Equatable, CustomStringConvertible {
        /// `hoverCoordinator.hoveredLinkID != 0`: the underline is painted.
        var hoverUnderline: Bool
        /// `view.hoverTooltipItem != nil`: the dwell tooltip is armed.
        var tooltipArmed: Bool
        /// `hoveredLinkURLForPreview()`: the Force-Touch / Quick Look URL.
        var previewURL: String?
        /// `resolveClickURL`, i.e. the URL command-click resolves.
        var clickURL: String?
        /// URLs the recording opener received from a simulated command-click
        /// (`performCmdClickForTests`), i.e. what would reach NSWorkspace.
        var openedByClick: [String]
        /// Link-related titles in the right-click menu ("Open Link",
        /// "Copy Link", "Copy Link (host mismatch)").
        var menuLinkItems: [String]

        var description: String {
            "hover underline=\(hoverUnderline) tooltip armed=\(tooltipArmed) "
                + "preview=\(previewURL ?? "nil") click=\(clickURL ?? "nil") "
                + "opened=\(openedByClick) menu link items=\(menuLinkItems)"
        }

        static let refused = SurfaceVerdict(
            hoverUnderline: false, tooltipArmed: false,
            previewURL: nil, clickURL: nil, openedByClick: [], menuLinkItems: []
        )

        static func opened(_ href: String) -> SurfaceVerdict {
            SurfaceVerdict(
                hoverUnderline: true, tooltipArmed: true,
                previewURL: href, clickURL: href, openedByClick: [href],
                menuLinkItems: ["Open Link", "Copy Link"]
            )
        }
    }

    private let probeRow = 2
    private let probeCol = 3
    /// Deliberately not URL-shaped: the anchor/host divergence gate has
    /// nothing to compare, so the mailto policy is the only thing that can
    /// refuse the link.
    private let probeAnchor = "Contact support team"

    private var liveTerms: [BBTerm] = []
    private var probeView: TerminalView?

    override func tearDown() {
        probeView?.hoverCoordinator.cancelHoverTooltip()
        probeView?.hoverCoordinator.clearHover()
        probeView = nil
        liveTerms.removeAll()
        super.tearDown()
    }

    private let opener = RecordingURLOpener()

    private func makeProbeView() throws -> TerminalView {
        if let v = probeView { return v }
        let device = try requireMetalDevice()
        let v = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480), device: device)
        v.urlOpenerForTests = opener
        probeView = v
        return v
    }

    /// Window-space point that lies inside cell (row, col), cross-checked
    /// against the view's own inverse mapping so a geometry change fails as a
    /// fixture error, not as a policy failure.
    private func windowPoint(
        _ view: TerminalView, row: Int, col: Int,
        file: StaticString = #filePath, line: UInt = #line
    ) -> NSPoint {
        let origin = view.cellOriginPx(row: row, col: col)
        let insideTopDown = CGPoint(x: origin.x + 1, y: origin.y + 1)
        let mapped = view.cellAt(point: insideTopDown)
        XCTAssertEqual(mapped.row, row, "fixture geometry: row mapping", file: file, line: line)
        XCTAssertEqual(mapped.col, col, "fixture geometry: col mapping", file: file, line: line)
        return NSPoint(x: insideTopDown.x, y: view.bounds.height - insideTopDown.y)
    }

    private func rightClick(at p: NSPoint) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .rightMouseDown, location: p, modifierFlags: [],
                timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
                clickCount: 1, pressure: 1.0
            ),
            "NSEvent.mouseEvent must synthesise a .rightMouseDown"
        )
    }

    /// Feed one OSC 8 link into a fresh term, publish its snapshot on the view
    /// and read back what hover, click and the context menu decided. The href
    /// is asserted to survive the Rust core byte-for-byte first, so a refusal
    /// below can never be the result of a mangled or dropped link.
    private func probe(
        href: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> SurfaceVerdict {
        let view = try makeProbeView()
        let term = try XCTUnwrap(
            BBTerm(size: .init(cols: 80, rows: 24)),
            "BBTerm init must succeed", file: file, line: line
        )
        liveTerms.append(term)
        term.input(
            "\u{1B}[\(probeRow + 1);1H"
                + "\u{1B}]8;;\(href)\u{1B}\\" + probeAnchor + "\u{1B}]8;;\u{1B}\\"
        )
        let snap = try XCTUnwrap(term.snapshot(), "snapshot() must return a handle", file: file, line: line)

        let id = snap.linkID(row: probeRow, col: probeCol)
        XCTAssertNotEqual(
            id, 0,
            "precondition: the cell under the OSC 8 span must carry a link id (\(href))",
            file: file, line: line
        )
        XCTAssertEqual(
            snap.linkURL(id: id), href,
            "precondition: the href must round-trip through the core unchanged",
            file: file, line: line
        )

        // Fresh pointer state for this href.
        view.hoverCoordinator.cancelHoverTooltip()
        view.hoverCoordinator.clearHover()
        opener.opened.removeAll()

        view.currentSnapshot = snap
        view.hoverCoordinator.handleSnapshotPublished()

        // Hover (underline + dwell tooltip + preview).
        let point = windowPoint(view, row: probeRow, col: probeCol, file: file, line: line)
        view.hoverCoordinator.handleMouseMoved(flags: [], locationInWindow: point)
        let hoverUnderline = view.hoverCoordinator.hoveredLinkID != 0
        let tooltipArmed = view.hoverTooltipItem != nil
        let previewURL = view.hoveredLinkURLForPreview()?.absoluteString

        // Click.
        let clickURL = view.resolveClickURL(screenRow: probeRow, col: probeCol)?.absoluteString
        view.performCmdClickForTests(row: probeRow, col: probeCol)
        let openedByClick: [String] = opener.opened.map { (u: URL) -> String in u.absoluteString }

        // Context menu.
        let menu = try XCTUnwrap(
            view.menu(for: try rightClick(at: point)),
            "menu(for:) must always return a menu", file: file, line: line
        )
        let allTitles: [String] = menu.items.map { (item: NSMenuItem) -> String in item.title }
        let linkTitles: [String] = allTitles.filter { (t: String) -> Bool in t.contains("Link") }

        // Never leave a dwell tooltip armed: it would fire on the main queue
        // after the test and try to show a panel for a windowless view.
        view.hoverCoordinator.cancelHoverTooltip()
        view.hoverCoordinator.clearHover()

        return SurfaceVerdict(
            hoverUnderline: hoverUnderline, tooltipArmed: tooltipArmed,
            previewURL: previewURL, clickURL: clickURL,
            openedByClick: openedByClick, menuLinkItems: linkTitles
        )
    }

    /// Positive control: a plain single-recipient link is opened by every
    /// surface through this exact rig. Without it a refusal anywhere else in
    /// this file could just mean the rig never wired up the link.
    func testSingleRecipientMailtoIsOpenedByHoverClickAndMenu() throws {
        let href = "mailto:visible@example.com?subject=Hello%20there"
        let got = try probe(href: href)
        XCTAssertEqual(
            got, SurfaceVerdict.opened(href),
            "a single-recipient mailto with a subject must be live on every surface; measured \(got)"
        )
    }

    /// Every refused encoding is refused by hover (underline, tooltip,
    /// preview), command-click and the context menu alike, and none of them
    /// leaves a path that would hand the URL to NSWorkspace.
    func testEveryRecipientAddingHrefIsRefusedOnHoverClickAndContextMenu() throws {
        // Non-vacuity: the rig must light up all four surfaces for a good link.
        let control = "mailto:visible@example.com"
        let controlVerdict = try probe(href: control)
        XCTAssertEqual(
            controlVerdict, SurfaceVerdict.opened(control),
            "precondition: the control link must be live on every surface; measured \(controlVerdict)"
        )

        let rows = Self.allRefusedRows
        XCTAssertGreaterThan(rows.count, 40, "fixture tables must cover all four routes")

        for r in rows {
            let got = try probe(href: r.href)
            XCTAssertEqual(
                got, SurfaceVerdict.refused,
                "\(r.href) must be refused on every surface (\(r.why)); measured \(got)"
            )
        }
    }
}
