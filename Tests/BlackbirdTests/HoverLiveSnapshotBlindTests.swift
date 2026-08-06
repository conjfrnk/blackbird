import XCTest
import AppKit
import Metal
@testable import Blackbird
@testable import BBCore

/// Blind-authored coverage for "the hover affordance must track the LIVE
/// snapshot".
///
/// The author of this file has not read `TerminalView+Hover.swift`,
/// `HoverCoordinator.swift`, `TerminalView+Mouse.swift` or `MetalRenderer.swift`
/// (project policy, CLAUDE.md "Author new behavior tests blind"). Everything
/// below is derived from the written contract, the FFI surface in
/// `Sources/BBCore/BBTerm.swift`, the OSC 8 id-assignment rules in
/// `core/src/snapshot.rs` (`resolve_link_id` → 1-based, cell-scan order,
/// deduped per URI), the policy gate in `HyperlinkTests.swift`, and the
/// geometry helpers `TerminalView.cellOriginPx(row:col:)` /
/// `TerminalView.cellAt(point:)`.
///
/// **Why this file exists.** An OSC 8 link id is a PER-SNAPSHOT integer: the
/// core hands out 1…N in grid-scan order, keyed on the URI. It is only
/// meaningful for the snapshot that produced it. Claude Code repaints
/// continuously under a stationary pointer, so a hover implementation that
/// (a) resolves link state only on physical pointer motion, or (b) caches a
/// numeric id across snapshots, either loses the underline entirely or paints
/// it for a link the pointer is not over.
///
/// Contracts pinned, one `MARK` section each:
///
///   1. `lastHoverCell` is derived from the pointer position, not baked at
///      mouse-move time: it survives an arbitrary number of repaints and is
///      dropped only by an explicit "pointer is gone" event.
///   2. OSC 8 hover **re-resolves** on `handleSnapshotPublished()` under a
///      stationary pointer — link appears / disappears / renumbers.
///   3. A `javascript:` OSC 8 href never produces hover state.
///   4. The ⌘-held regex-URL highlight survives repaints.
///   5. Force-Touch / Quick Look never surfaces an unvetted URL —
///      `hoveredLinkURLForPreview()` is policy-gated and resolved against the
///      live snapshot.
///
/// **Note for the integrator:** `CmdHoverHighlightTests`
/// `.test_snapshotChange_clearsStaleHoverCell` pins the OPPOSITE of contract 1
/// (it asserts a snapshot identity bump nils `lastHoverCell`). That test
/// encodes the design this change replaces and must be deleted or rewritten;
/// the two cannot both be green.
///
/// **Memory / time pre-flight** (CLAUDE.md test-authoring rule):
///   - Grids are 80 × 24 = 1 920 cells. `BBCell` is 16 B, so a snapshot's cell
///     array is ≈ 30 KB. The widest test holds 4 snapshots live at once
///     (≈ 120 KB). No test resizes, and none writes past the last row, so no
///     scrollback is ever allocated.
///   - Each `TerminalView` is 800 × 480 with a real `MTLDevice` but is never
///     added to a window, never asked for a drawable, and `draw(in:)` is never
///     called — no command buffers are submitted and no glyph atlas pages are
///     built beyond first-use.
///   - No PTY, no `TerminalSession`, no `MainWindowController`. Per-test wall
///     time is dominated by `MTLCreateSystemDefaultDevice()`; well under 100 ms.
final class HoverLiveSnapshotBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    /// Terms are kept alive for the duration of a test. `BBSnapshot` owns its
    /// own retained handle and link table, so this is belt-and-braces rather
    /// than a lifetime requirement — but a dangling term would surface as a
    /// confusing crash rather than a failed assertion, so we hold them.
    private var liveTerms: [BBTerm] = []

    override func tearDown() {
        liveTerms.removeAll()
        super.tearDown()
    }

    // MARK: - Fixture helpers

    /// A view big enough to carry a realistic grid. `makeHeadlessForTests()`
    /// is 100 × 100 — after the titlebar inset that is roughly 4 rows × 10
    /// columns, too small to host a `https://…` URL, so these tests use the
    /// same 800 × 480 shape as `HorizontalInsetHelperTests`.
    private func makeView() throws -> TerminalView {
        let device = try requireMetalDevice()
        return TerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 480),
            device: device
        )
    }

    /// Fresh 80 × 24 term, registered for the test's lifetime.
    private func makeTerm(
        cols: UInt16 = 80,
        rows: UInt16 = 24,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> BBTerm {
        let term = try XCTUnwrap(
            BBTerm(size: .init(cols: cols, rows: rows)),
            "BBTerm init must succeed for \(cols)×\(rows)",
            file: file, line: line
        )
        liveTerms.append(term)
        return term
    }

    /// Build a snapshot from a list of writes against a brand-new term. Each
    /// call yields an independent link table, which is exactly what the
    /// renumbering test needs.
    private func makeSnapshot(
        _ writes: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> BBSnapshot {
        let term = try makeTerm(file: file, line: line)
        for w in writes { term.input(w) }
        return try XCTUnwrap(
            term.snapshot(),
            "snapshot() must return a live handle",
            file: file, line: line
        )
    }

    /// CUP to a 0-based (row, col) then write `text`.
    private func at(row: Int, col: Int, _ text: String) -> String {
        "\u{1B}[\(row + 1);\(col + 1)H" + text
    }

    /// `ESC ] 8 ; ; <uri> ESC \` … `ESC ] 8 ; ; ESC \`. The closing pair
    /// returns the grid to "no attribution" so following cells aren't tagged.
    private func osc8(_ uri: String, _ text: String) -> String {
        "\u{1B}]8;;\(uri)\u{1B}\\" + text + "\u{1B}]8;;\u{1B}\\"
    }

    /// Window-space point that genuinely lies inside cell (row, col).
    ///
    /// `cellOriginPx` is in top-down view pixels; AppKit event locations are
    /// bottom-up. The view has no window and a frame origin of (0, 0), so
    /// window space and view space coincide and the only conversion needed is
    /// the y flip. The mapping is **sanity-checked against the view's own
    /// inverse** (`cellAt(point:)`) on every call, so a future geometry change
    /// fails as "this fixture's point is wrong" instead of masquerading as a
    /// hover regression.
    private func hoverPoint(
        _ view: TerminalView,
        row: Int,
        col: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> NSPoint {
        let origin = view.cellOriginPx(row: row, col: col)
        let insideTopDown = CGPoint(x: origin.x + 1, y: origin.y + 1)
        let mapped = view.cellAt(point: insideTopDown)
        XCTAssertEqual(
            mapped.row, row,
            "fixture geometry: a point 1px inside cellOriginPx(row: \(row)) must map back to row \(row)",
            file: file, line: line
        )
        XCTAssertEqual(
            mapped.col, col,
            "fixture geometry: a point 1px inside cellOriginPx(col: \(col)) must map back to col \(col)",
            file: file, line: line
        )
        return NSPoint(x: insideTopDown.x, y: view.bounds.height - insideTopDown.y)
    }

    /// Drive one pointer move. The coordinator is handed BOTH the resolved
    /// (row, col) and the window location, and the location is computed from
    /// the view's own geometry so the two genuinely agree — an implementation
    /// that derives the cell from the point and one that trusts the passed-in
    /// row/col must both see the same cell here.
    private func moveHover(
        _ view: TerminalView,
        row: Int,
        col: Int,
        flags: NSEvent.ModifierFlags = [],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let point = hoverPoint(view, row: row, col: col, file: file, line: line)
        view.hoverCoordinator.handleMouseMoved(
            flags: flags,
            locationInWindow: point
        )
    }

    /// The render path's publish step: install the snapshot, then tell the
    /// hover coordinator content changed underneath the (possibly stationary)
    /// pointer.
    private func publish(_ snapshot: BBSnapshot, to view: TerminalView) {
        view.currentSnapshot = snapshot
        view.hoverCoordinator.handleSnapshotPublished()
    }

    private func assertHoverCell(
        _ view: TerminalView,
        row: Int,
        col: Int,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let cell = try XCTUnwrap(
            view.hoverCoordinator.lastHoverCell,
            message,
            file: file, line: line
        )
        XCTAssertEqual(cell.row, row, message, file: file, line: line)
        XCTAssertEqual(cell.col, col, message, file: file, line: line)
    }

    /// Resolve whatever the coordinator currently believes is hovered, against
    /// the snapshot that is currently installed on the view. Returns nil when
    /// nothing is hovered.
    private func hoveredURLString(_ view: TerminalView) throws -> String? {
        let id = view.hoverCoordinator.hoveredLinkID
        guard id != 0 else { return nil }
        let snap = try XCTUnwrap(
            view.currentSnapshot,
            "a hovered link id is only meaningful with a snapshot installed"
        )
        return snap.linkURL(id: id)
    }

    // Fixture constants. Anchor text is deliberately NOT URL-shaped so the
    // anchor/href divergence gate (see HyperlinkTests) can never be the reason
    // a link is rejected — these tests are about liveness and scheme policy.
    private let anchorText = "LINKLINK"          // 8 cells, cols 0…7
    private let urlBeta  = "https://beta.example.com/b"
    private let urlAlpha = "https://alpha.example.com/a"
    private let hoverRow = 2
    private let hoverCol = 3

    // MARK: - (1) lastHoverCell is derived from the pointer, not baked

    /// Contract 1. After one `mouseMoved`, the hovered cell is whatever the
    /// pointer is over — and it stays that cell across an arbitrary number of
    /// repaints. Under Claude Code the terminal republishes many times per
    /// second while the pointer sits still; an implementation that drops the
    /// cached cell on every snapshot change loses the underline until the user
    /// jiggles the mouse.
    ///
    /// The test asserts the snapshot identity genuinely changed on every
    /// publish (`sequenceID` is freshly allocated per `snapshot()` call), so a
    /// "no repaint actually happened" false green is impossible.
    func test_lastHoverCell_survivesRepeatedSnapshotPublishes() throws {
        let view = try makeView()
        let term = try makeTerm()
        term.input(at(row: hoverRow, col: 0, "PLAIN TEXT ROW"))
        let first = try XCTUnwrap(term.snapshot(), "snapshot() must return a live handle")
        publish(first, to: view)

        moveHover(view, row: hoverRow, col: hoverCol)
        try assertHoverCell(
            view, row: hoverRow, col: hoverCol,
            "a mouseMoved inside cell (\(hoverRow), \(hoverCol)) must record that cell as hovered"
        )

        var previous = first
        for tick in 0..<5 {
            // Repaint: change an unrelated row so the snapshot is genuinely
            // new content, not just a new handle over an identical grid.
            term.input(at(row: 6, col: 0, "repaint \(tick)   "))
            let next = try XCTUnwrap(term.snapshot(), "snapshot() must return a live handle")
            XCTAssertNotEqual(
                previous.sequenceID, next.sequenceID,
                "fixture: publish #\(tick) must be a genuinely new snapshot identity, "
                + "otherwise this test never exercises the repaint path"
            )
            publish(next, to: view)
            try assertHoverCell(
                view, row: hoverRow, col: hoverCol,
                "publish #\(tick): a new snapshot must NOT clear the hovered cell — the cell is a "
                + "property of where the pointer is, not of the snapshot that was live when it moved"
            )
            previous = next
        }
    }

    /// Contract 1, the other half: an explicit "pointer left the view" DOES
    /// clear the cell. Without this the underline would stick after the
    /// pointer leaves.
    func test_mouseExited_clearsHoverCell() throws {
        let view = try makeView()
        publish(try makeSnapshot([at(row: hoverRow, col: 0, "PLAIN TEXT ROW")]), to: view)
        moveHover(view, row: hoverRow, col: hoverCol)
        try assertHoverCell(
            view, row: hoverRow, col: hoverCol,
            "precondition: the pointer must be hovering a cell before we test exit"
        )

        let exit = try XCTUnwrap(
            NSEvent.enterExitEvent(
                with: .mouseExited,
                location: hoverPoint(view, row: hoverRow, col: hoverCol),
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                eventNumber: 0,
                trackingNumber: 0,
                userData: nil
            ),
            "NSEvent.enterExitEvent must synthesise a .mouseExited event"
        )
        view.mouseExited(with: exit)

        XCTAssertNil(
            view.hoverCoordinator.lastHoverCell,
            "mouseExited means the pointer is no longer over any cell — the hovered cell must clear"
        )
    }

    /// Contract 1. `clearHover()` is the coordinator-level "nothing is hovered
    /// any more" primitive; it must drop the cell as well as the link id.
    func test_clearHover_dropsHoverCellAndLinkID() throws {
        let view = try makeView()
        publish(try makeSnapshot([at(row: hoverRow, col: 0, osc8(urlBeta, anchorText))]), to: view)
        moveHover(view, row: hoverRow, col: hoverCol)
        XCTAssertNotEqual(
            view.hoverCoordinator.hoveredLinkID, 0,
            "precondition: the OSC 8 link under the pointer must be hovered before clearHover()"
        )

        view.hoverCoordinator.clearHover()

        XCTAssertNil(
            view.hoverCoordinator.lastHoverCell,
            "clearHover() must drop the hovered cell"
        )
        XCTAssertEqual(
            view.hoverCoordinator.hoveredLinkID, 0,
            "clearHover() must drop the hovered link id — a stale id would keep the underline painted"
        )
    }

    /// Contract 1. `resetModifierAndHoverState()` is the harder reset (used
    /// when the window loses key / the app deactivates): it clears the hovered
    /// cell AND the sticky ⌘ state, so a modifier released off-window can't
    /// leave the regex highlight latched on.
    func test_resetModifierAndHoverState_clearsCellAndModifier() throws {
        let view = try makeView()
        publish(
            try makeSnapshot([at(row: hoverRow, col: 0, "see https://example.com/x here")]),
            to: view
        )
        moveHover(view, row: hoverRow, col: 8, flags: [.command])
        XCTAssertTrue(
            view.hoverCoordinator.cmdModifierHeld,
            "precondition: a move carrying .command must record ⌘ as held"
        )

        view.hoverCoordinator.resetModifierAndHoverState()

        XCTAssertNil(
            view.hoverCoordinator.lastHoverCell,
            "resetModifierAndHoverState() must clear the hovered cell"
        )
        XCTAssertFalse(
            view.hoverCoordinator.cmdModifierHeld,
            "resetModifierAndHoverState() must clear the sticky ⌘-held flag"
        )
        XCTAssertFalse(
            view.hoverCoordinator.wantsPointingHandCursor,
            "with no hovered cell and no ⌘, nothing justifies the pointing-hand cursor"
        )
    }

    // MARK: - (2) OSC 8 hover re-resolves under a stationary pointer

    /// Contract 2a. Baseline: a snapshot with no link under the pointer yields
    /// no hover state, and repainting that same link-free content never
    /// invents one.
    func test_osc8Hover_noLinkUnderPointer_staysZeroAcrossRepaints() throws {
        let view = try makeView()
        let term = try makeTerm()
        term.input(at(row: hoverRow, col: 0, "PLAIN TEXT ROW"))
        publish(try XCTUnwrap(term.snapshot()), to: view)

        moveHover(view, row: hoverRow, col: hoverCol)
        XCTAssertEqual(
            view.hoverCoordinator.hoveredLinkID, 0,
            "a cell with no OSC 8 attribution must not produce a hovered link id"
        )

        for tick in 0..<3 {
            term.input(at(row: 6, col: 0, "repaint \(tick)   "))
            publish(try XCTUnwrap(term.snapshot()), to: view)
            XCTAssertEqual(
                view.hoverCoordinator.hoveredLinkID, 0,
                "publish #\(tick): repainting link-free content must not conjure a hovered link id"
            )
        }
        XCTAssertFalse(
            view.hoverCoordinator.wantsPointingHandCursor,
            "no link and no ⌘ hover means no pointing-hand cursor"
        )
    }

    /// Contract 2b — the headline case. The pointer never moves; a repaint
    /// paints an OSC 8 link under it. The underline must light up on the
    /// publish, resolved against the snapshot that introduced the link.
    ///
    /// This is exactly the Claude Code shape: the user parks the pointer, the
    /// TUI redraws, and a hyperlink lands beneath the cursor.
    func test_osc8Hover_linkAppearsUnderStationaryPointer_resolvesWithoutMouseMove() throws {
        let view = try makeView()
        let before = try makeSnapshot([at(row: hoverRow, col: 0, "PLAIN TEXT ROW")])
        publish(before, to: view)

        moveHover(view, row: hoverRow, col: hoverCol)
        XCTAssertEqual(
            view.hoverCoordinator.hoveredLinkID, 0,
            "precondition: no link is present before the repaint"
        )

        let after = try makeSnapshot([at(row: hoverRow, col: 0, osc8(urlBeta, anchorText))])
        XCTAssertNotEqual(
            after.linkID(row: hoverRow, col: hoverCol), 0,
            "fixture: the repainted snapshot must carry OSC 8 attribution at (\(hoverRow), \(hoverCol))"
        )

        // No further mouseMoved — the publish alone must re-resolve.
        publish(after, to: view)

        XCTAssertNotEqual(
            view.hoverCoordinator.hoveredLinkID, 0,
            "a link painted under a stationary pointer must become the hovered link on publish — "
            + "resolving only on physical pointer motion loses the affordance entirely"
        )
        XCTAssertEqual(
            try hoveredURLString(view), urlBeta,
            "the hovered id must resolve, against the live snapshot, to the URL actually under the pointer"
        )
        XCTAssertTrue(
            view.hoverCoordinator.wantsPointingHandCursor,
            "a hovered OSC 8 link must request the pointing-hand cursor"
        )
    }

    /// Contract 2c. The mirror image: the link is repainted away while the
    /// pointer sits still. A stale id would keep the underline (and the
    /// pointing-hand cursor) alive over content that is no longer a link.
    func test_osc8Hover_linkRemovedUnderStationaryPointer_clearsLinkID() throws {
        let view = try makeView()
        publish(try makeSnapshot([at(row: hoverRow, col: 0, osc8(urlBeta, anchorText))]), to: view)
        moveHover(view, row: hoverRow, col: hoverCol)
        XCTAssertEqual(
            try hoveredURLString(view), urlBeta,
            "precondition: the link must be hovered before it is repainted away"
        )

        let gone = try makeSnapshot([at(row: hoverRow, col: 0, "PLAIN TEXT ROW")])
        XCTAssertEqual(
            gone.linkID(row: hoverRow, col: hoverCol), 0,
            "fixture: the follow-up snapshot must have no attribution at the hovered cell"
        )
        publish(gone, to: view)

        XCTAssertEqual(
            view.hoverCoordinator.hoveredLinkID, 0,
            "when the link is repainted away under a stationary pointer the hovered id must clear — "
            + "keeping it underlines plain text and offers a click target that no longer exists"
        )
        XCTAssertFalse(
            view.hoverCoordinator.wantsPointingHandCursor,
            "no link under the pointer means no pointing-hand cursor"
        )
    }

    /// Contract 2d — the sharpest case, and the one that a "cache the numeric
    /// id" implementation fails.
    ///
    /// Link ids are per-snapshot and assigned 1…N in grid-scan order
    /// (`core/src/snapshot.rs::resolve_link_id`). Snapshot 1 has a single link
    /// (`urlBeta`) on row 2, so it owns id 1. Snapshot 2 additionally paints a
    /// DIFFERENT link (`urlAlpha`) on row 0 — an EARLIER row — so `urlAlpha`
    /// takes id 1 and `urlBeta` is renumbered to id 2.
    ///
    /// The pointer never leaves row 2. An implementation that keeps the old
    /// numeric id resolves it against the new table and reports `urlAlpha` —
    /// a URL that is nowhere near the pointer, and one the user would then
    /// ⌘-click. The test asserts BOTH halves: that the stale id really does
    /// now name the wrong URL (so the trap is genuinely armed), and that the
    /// coordinator reports the right one.
    func test_osc8Hover_idsRenumber_resolvesURLActuallyUnderPointer() throws {
        let view = try makeView()

        let onlyBeta = try makeSnapshot([at(row: hoverRow, col: 0, osc8(urlBeta, anchorText))])
        publish(onlyBeta, to: view)
        moveHover(view, row: hoverRow, col: hoverCol)

        let staleID = view.hoverCoordinator.hoveredLinkID
        XCTAssertNotEqual(staleID, 0, "precondition: the row-2 link must be hovered first")
        XCTAssertEqual(
            onlyBeta.linkURL(id: staleID), urlBeta,
            "precondition: the hovered id must name urlBeta in the snapshot that produced it"
        )

        // Repaint: a second, different link appears on an EARLIER row.
        let alphaThenBeta = try makeSnapshot([
            at(row: 0, col: 0, osc8(urlAlpha, "AAAAAAAA")),
            at(row: hoverRow, col: 0, osc8(urlBeta, anchorText)),
        ])

        // Fixture validity — if any of these fail, the renumbering trap did
        // not arm and the test below would pass for the wrong reason.
        let alphaID = alphaThenBeta.linkID(row: 0, col: 0)
        let betaID = alphaThenBeta.linkID(row: hoverRow, col: hoverCol)
        XCTAssertNotEqual(alphaID, 0, "fixture: row 0 must carry OSC 8 attribution")
        XCTAssertNotEqual(betaID, 0, "fixture: row \(hoverRow) must still carry OSC 8 attribution")
        XCTAssertNotEqual(
            alphaID, betaID,
            "fixture: two distinct URIs must receive two distinct per-snapshot ids"
        )
        XCTAssertEqual(
            alphaThenBeta.linkURL(id: staleID), urlAlpha,
            "fixture: the ids must have RENUMBERED — the old id must now name urlAlpha, "
            + "otherwise a 'keep the cached id' implementation would accidentally be correct "
            + "and this test would prove nothing"
        )
        XCTAssertNotEqual(
            staleID, betaID,
            "fixture: urlBeta must have moved to a different id in the new snapshot"
        )

        publish(alphaThenBeta, to: view)

        XCTAssertEqual(
            view.hoverCoordinator.hoveredLinkID, betaID,
            "after a renumbering repaint the hovered id must be re-derived from the pointer's cell "
            + "in the LIVE snapshot, not carried over from the previous one"
        )
        XCTAssertEqual(
            try hoveredURLString(view), urlBeta,
            "the hover must resolve to the URL actually under the pointer (urlBeta), NOT the "
            + "unrelated link that inherited the old numeric id (urlAlpha)"
        )
    }

    // MARK: - (3) Scheme policy gates hover state

    /// Contract 3. A hostile remote can emit any URI in an OSC 8 sequence. The
    /// core will happily attribute the cells (`linkID != 0`) — the scheme
    /// allowlist lives in the Swift layer. A `javascript:` href must therefore
    /// produce NO hover state at all: no underline, no pointing hand, nothing
    /// to ⌘-click.
    func test_osc8Hover_disallowedScheme_producesNoHoverState() throws {
        let view = try makeView()
        let hostile = "javascript:alert(1)"
        let snap = try makeSnapshot([at(row: hoverRow, col: 0, osc8(hostile, anchorText))])

        // Precondition: the core DID attribute the cell. Without this, the
        // assertion below would pass simply because there is no link at all.
        let coreID = snap.linkID(row: hoverRow, col: hoverCol)
        XCTAssertNotEqual(
            coreID, 0,
            "fixture: the core must attribute the cell so the Swift policy gate is the thing under test"
        )
        XCTAssertEqual(
            snap.linkURL(id: coreID), hostile,
            "fixture: the attributed URI must be the javascript: payload"
        )

        publish(snap, to: view)
        moveHover(view, row: hoverRow, col: hoverCol)

        XCTAssertEqual(
            view.hoverCoordinator.hoveredLinkID, 0,
            "an OSC 8 href failing the scheme allowlist must never become hover state"
        )
        XCTAssertFalse(
            view.hoverCoordinator.wantsPointingHandCursor,
            "a policy-rejected href must not advertise itself as clickable"
        )

        // And it must stay rejected across repaints — the re-resolve path has
        // to run the same gate the move path does.
        publish(try makeSnapshot([at(row: hoverRow, col: 0, osc8(hostile, anchorText))]), to: view)
        XCTAssertEqual(
            view.hoverCoordinator.hoveredLinkID, 0,
            "the snapshot-published re-resolve must apply the scheme allowlist too, "
            + "not just the mouse-moved path"
        )
    }

    // MARK: - (4) ⌘-held regex highlight survives repaints

    /// Contract 4. Holding ⌘ over a plain-text `https://` URL (no OSC 8)
    /// underlines it. Claude Code repaints while the user is still holding ⌘,
    /// so the highlight has to be re-derived on each publish rather than being
    /// a one-shot computed at key-down/mouse-move time.
    ///
    /// `wantsPointingHandCursor` is the observable: it is true when an OSC 8
    /// link is hovered OR a ⌘-hover regex match is active. This fixture has no
    /// OSC 8 attribution anywhere, so a true here can only come from the regex
    /// path — and the no-modifier control below proves the pointer position
    /// alone isn't what flips it.
    func test_cmdHoverRegexHighlight_survivesRepeatedRepaints() throws {
        let view = try makeView()
        let rowText = "see https://example.com/x here"   // URL occupies cols 4…24
        let urlCol = 8
        let term = try makeTerm()
        term.input(at(row: hoverRow, col: 0, rowText))
        let first = try XCTUnwrap(term.snapshot(), "snapshot() must return a live handle")
        XCTAssertEqual(
            first.linkID(row: hoverRow, col: urlCol), 0,
            "fixture: this row must be plain text — no OSC 8 attribution, so only the regex "
            + "path can light the highlight"
        )
        publish(first, to: view)

        // Control: same cell, no ⌘ → no highlight.
        moveHover(view, row: hoverRow, col: urlCol)
        XCTAssertFalse(
            view.hoverCoordinator.wantsPointingHandCursor,
            "control: hovering a plain-text URL WITHOUT ⌘ must not offer a click affordance"
        )

        // Now hold ⌘ over the same cell.
        moveHover(view, row: hoverRow, col: urlCol, flags: [.command])
        XCTAssertTrue(
            view.hoverCoordinator.cmdModifierHeld,
            "precondition: the move must have recorded ⌘ as held"
        )
        XCTAssertTrue(
            view.hoverCoordinator.wantsPointingHandCursor,
            "⌘ held over a regex-detected URL must activate the click affordance"
        )

        // Repaint three times, keeping the URL on the same row (only an
        // unrelated row changes). The pointer never moves and ⌘ is never
        // released, so the highlight must stay lit the whole way.
        for tick in 0..<3 {
            term.input(at(row: 6, col: 0, "repaint \(tick)   "))
            let next = try XCTUnwrap(term.snapshot(), "snapshot() must return a live handle")
            publish(next, to: view)
            XCTAssertTrue(
                view.hoverCoordinator.wantsPointingHandCursor,
                "publish #\(tick): the ⌘-hover highlight must survive a repaint that leaves the "
                + "URL on the same row — dropping it makes the underline flicker off under Claude Code"
            )
            try assertHoverCell(
                view, row: hoverRow, col: urlCol,
                "publish #\(tick): the hovered cell must survive the repaint too"
            )
        }
    }

    // MARK: - (5) Quick Look / Force Touch never surfaces an unvetted URL

    /// Contract 5. `quickLook(with:)` presents whatever the hover resolved to.
    /// Driving `quickLook` directly in a headless test would raise a real
    /// `NSPopover` on a windowless view, so the contract is pinned on the
    /// resolution helper the preview path is required to route through:
    /// `hoveredLinkURLForPreview()`.
    ///
    /// Allowed scheme → the URL, resolved against the live snapshot.
    func test_hoveredLinkURLForPreview_returnsAllowedHoveredURL() throws {
        let view = try makeView()
        publish(try makeSnapshot([at(row: hoverRow, col: 0, osc8(urlBeta, anchorText))]), to: view)
        moveHover(view, row: hoverRow, col: hoverCol)

        XCTAssertEqual(
            view.hoveredLinkURLForPreview()?.absoluteString, urlBeta,
            "an allowed-scheme OSC 8 link under the pointer must be previewable"
        )
    }

    /// Contract 5. A `javascript:` href must never reach the preview surface.
    /// The cell IS attributed by the core, so this pins the Swift-side gate.
    func test_hoveredLinkURLForPreview_nilForDisallowedScheme() throws {
        let view = try makeView()
        let hostile = "javascript:alert(1)"
        let snap = try makeSnapshot([at(row: hoverRow, col: 0, osc8(hostile, anchorText))])
        XCTAssertNotEqual(
            snap.linkID(row: hoverRow, col: hoverCol), 0,
            "fixture: the core must attribute the cell so the policy gate is what's under test"
        )
        publish(snap, to: view)
        moveHover(view, row: hoverRow, col: hoverCol)

        XCTAssertNil(
            view.hoveredLinkURLForPreview(),
            "Force Touch / Quick Look must not surface a policy-rejected href — the preview "
            + "popover would render an unvetted javascript: URL as if Blackbird endorsed it"
        )
    }

    /// Contract 5. The preview URL is resolved against the LIVE snapshot, so
    /// the renumbering trap from contract 2d must not leak into Quick Look
    /// either: previewing the wrong link is the same trust failure as
    /// underlining it.
    func test_hoveredLinkURLForPreview_resolvesAgainstLiveSnapshotAfterRenumber() throws {
        let view = try makeView()
        let onlyBeta = try makeSnapshot([at(row: hoverRow, col: 0, osc8(urlBeta, anchorText))])
        publish(onlyBeta, to: view)
        moveHover(view, row: hoverRow, col: hoverCol)
        let staleID = view.hoverCoordinator.hoveredLinkID
        XCTAssertNotEqual(staleID, 0, "precondition: the row-2 link must be hovered first")

        let alphaThenBeta = try makeSnapshot([
            at(row: 0, col: 0, osc8(urlAlpha, "AAAAAAAA")),
            at(row: hoverRow, col: 0, osc8(urlBeta, anchorText)),
        ])
        XCTAssertEqual(
            alphaThenBeta.linkURL(id: staleID), urlAlpha,
            "fixture: the ids must have renumbered so a stale-id preview would show urlAlpha"
        )
        publish(alphaThenBeta, to: view)

        XCTAssertEqual(
            view.hoveredLinkURLForPreview()?.absoluteString, urlBeta,
            "the preview must show the link under the pointer, not the unrelated link that "
            + "inherited the old numeric id"
        )
    }

    /// Contract 5. Nothing hovered → nothing to preview. Pins that the helper
    /// is driven by live hover state rather than by a last-seen value, so a
    /// pointer that has left the view can't leave a preview armed.
    func test_hoveredLinkURLForPreview_nilAfterHoverCleared() throws {
        let view = try makeView()
        publish(try makeSnapshot([at(row: hoverRow, col: 0, osc8(urlBeta, anchorText))]), to: view)
        moveHover(view, row: hoverRow, col: hoverCol)
        XCTAssertEqual(
            view.hoveredLinkURLForPreview()?.absoluteString, urlBeta,
            "precondition: the link must be previewable before the hover is cleared"
        )

        view.hoverCoordinator.clearHover()

        XCTAssertNil(
            view.hoveredLinkURLForPreview(),
            "with no hovered cell there is nothing to preview — a non-nil result here means the "
            + "helper is reading a cached URL rather than the live hover state"
        )
    }

    /// Contract 5. A cell with no link at all is not previewable either — the
    /// helper must not fall back to, say, the nearest link on the row.
    func test_hoveredLinkURLForPreview_nilWhenHoveredCellHasNoLink() throws {
        let view = try makeView()
        // Link on cols 0…7 of row 2; hover well past its right edge.
        let snap = try makeSnapshot([at(row: hoverRow, col: 0, osc8(urlBeta, anchorText))])
        let emptyCol = 40
        XCTAssertEqual(
            snap.linkID(row: hoverRow, col: emptyCol), 0,
            "fixture: col \(emptyCol) must sit outside the OSC 8 span"
        )
        publish(snap, to: view)
        moveHover(view, row: hoverRow, col: emptyCol)

        XCTAssertNil(
            view.hoveredLinkURLForPreview(),
            "hovering a cell outside the link span must not preview the row's link"
        )
        XCTAssertEqual(
            view.hoverCoordinator.hoveredLinkID, 0,
            "hovering outside the link span must not produce a hovered link id"
        )
    }
}
