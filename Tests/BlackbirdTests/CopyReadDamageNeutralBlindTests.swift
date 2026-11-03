import XCTest
import AppKit
import Metal
@testable import Blackbird
import BBCore

/// Regression suite for cr-1b: **reading the selection text for Cmd-C, the
/// Services menu, Look Up and copy-on-select must be damage-neutral.**
///
/// Observable contract. The terminal core keeps one piece of bookkeeping per
/// session that every full-grid snapshot CONSUMES: the damage set ("which rows
/// changed since the previous snapshot") and a per-session, strictly
/// increasing snapshot sequence id. The renderer relies on both: it repaints
/// only the damaged rows of the next published frame, and it reads a gap in
/// the sequence ids as "snapshots I never saw existed". So a code path that is
/// NOT the frame pipeline must not take a snapshot of its own:
///
///  - a snapshot taken "just to read the selection" swallows the damage that
///    accumulated since the last published frame. The next published frame
///    then reports no changed rows, and rows that changed between the two
///    frames stay stale on screen until they next change;
///  - it burns a sequence id, so the next published frame is not `previous + 1`;
///  - and `validRequestor(forSendType:returnType:)` (AppKit calls it to
///    validate the Services submenu: on every right-click, on every menu
///    open) is a validation predicate. It has to be O(1) and side-effect
///    free: it may not hop onto the core queue (which can be busy parsing a
///    burst) and it may not touch the grid.
///
/// None of these reads may change what they return either: the clipboard
/// still receives the rows the user HIGHLIGHTED (the cr-1 contract, pinned in
/// `CopyStaleDisplayedFrameBlindTests`), even when the core has scrolled on
/// past the displayed frame.
///
/// How the state is modelled, deterministically. A headless `TerminalSession`
/// plus a headless `TerminalView` (the same rig as the cr-1 suite): the user
/// selects rows 3 and 4 with real `mouseDown` / `mouseDragged` events; the
/// frame that is "on screen" is taken from the core and installed with
/// `render(snapshot:)`, which drains the core's damage. Then the program
/// keeps producing output: bytes are handed straight to the core
/// (`bbterm.input` on the core queue), which is exactly the state in the app
/// between "the core parsed a chunk" and "the burst-tail snapshot for that
/// chunk was taken". Then the trigger (copy / Services / validation) runs,
/// and the NEXT snapshot the pipeline takes (`takeSnapshotForTests()`, the
/// same call the tail work item makes) is inspected:
///
///   - its `sequenceID` must be exactly the published one + 1;
///   - it must repaint every row that changed since the published frame
///     (`damageIsFull`, or `damagedRows` containing them).
///
/// A control (`test_control_*`) pins that this rig really yields a partial
/// damage set that names the changed rows when no trigger runs, so the
/// assertions can fail only because the trigger consumed damage.
///
/// Memory + time budget (CLAUDE.md test-authoring rule): one headless
/// `TerminalView` (800 x ~170, never added to a window, never drawn), one
/// PTY-less `TerminalSession` of 40 x 8 = 320 cells per test, at most 33 short
/// lines fed, one rig per test. No `NSWindow`, no `MainWindowController`, no
/// real shell, no runloop pumping. The one deliberately slow test holds the
/// core queue for at most 1.5 s. The tests share the system pasteboard and
/// `Preferences.copyOnSelect` with the host, so both are saved in `setUp` and
/// restored in `tearDown`.
final class CopyReadDamageNeutralBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Fixture constants

    private let gridCols = 40
    private let gridRows = 8
    private let totalLines = 30
    /// Display rows the user highlights (0-based). With 30 labelled lines in an
    /// 8-row grid the screen shows LN022...LN029, so these are LN025 / LN026.
    private let fromRow = 3
    private let toRow = 4
    /// Column the drag ends on (row text is 32 columns wide, so this is
    /// mid-text and the last selected row is a partial row).
    private let dragEndCol = 11
    private let sentinel = "copy-did-not-run"
    /// Rows the streaming program rewrites in place (0-based, not highlighted,
    /// no scrolling), so a partial damage set must name exactly these (plus,
    /// possibly, cursor rows).
    private let changedRows = [1, 6]

    /// `LN012-abcdefghijklmnopqrstuvwxyz` (32 cols, never wraps in 40).
    private func label(_ n: Int) -> String { String(format: "LN%03d", n) }
    private func rowText(_ n: Int) -> String { label(n) + "-abcdefghijklmnopqrstuvwxyz" }

    // MARK: - Host state hygiene (pasteboard + copy-on-select preference)

    private var savedItems: [NSPasteboardItem] = []
    private var savedCopyOnSelect = false

    override func setUp() {
        super.setUp()
        let pb = NSPasteboard.general
        savedItems = (pb.pasteboardItems ?? []).map { (original: NSPasteboardItem) -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in original.types {
                if let data = original.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
        savedCopyOnSelect = Preferences.shared.copyOnSelect
        Preferences.shared.copyOnSelect = false
    }

    override func tearDown() {
        Preferences.shared.copyOnSelect = savedCopyOnSelect
        let pb = NSPasteboard.general
        pb.clearContents()
        if !savedItems.isEmpty {
            pb.writeObjects(savedItems)
        }
        savedItems = []
        super.tearDown()
    }

    private func armPasteboard(_ pb: NSPasteboard = NSPasteboard.general) {
        pb.clearContents()
        pb.setString(sentinel, forType: .string)
    }

    // MARK: - Rig

    private final class Rig {
        let view: TerminalView
        let session: TerminalSession
        /// Label number of the next line `advanceCore` will print.
        var nextLabel: Int
        init(view: TerminalView, session: TerminalSession, nextLabel: Int) {
            self.view = view
            self.session = session
            self.nextLabel = nextLabel
        }
    }

    /// The state every test starts from: the user has highlighted display rows
    /// `fromRow...toRow`, and `published` is the frame on screen (the
    /// pipeline's last snapshot; the core's damage has been drained into it).
    private struct Scenario {
        let rig: Rig
        let published: BBSnapshot
    }

    private func makeRig(file: StaticString = #filePath, line: UInt = #line) throws -> Rig {
        let device = try requireMetalDevice(file: file, line: line)
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480),
                                device: device)

        // Size the frame like a real 8-row window (the 0.5 pt slack keeps the
        // floating-point grid computation from rounding 8.0 down to 7).
        let ch = view.metrics.cellHeight
        let top = view.titlebarOnlyTopInset
        let height = top + CGFloat(gridRows) * ch
            + TerminalView.bottomContentInsetPoints + 0.5
        view.setFrameSize(NSSize(width: 800, height: height))
        let usable = TerminalView.usableViewSize(forBounds: view.bounds.size,
                                                 titlebarTopInset: top,
                                                 metrics: view.metrics)
        let grid = view.metrics.grid(forPixelSize: usable)
        XCTAssertEqual(grid.rows, gridRows,
                       "precondition: the view frame must model a real \(gridRows)-row window "
                       + "(measured \(grid.rows) rows; bounds \(view.bounds.size), cellHeight \(ch))",
                       file: file, line: line)

        let session = TerminalSession.makeHeadlessForTests()
        addTeardownBlock { session.terminate() }
        let applied = session.coreQueue.sync {
            session.bbterm.resize(to: .init(cols: UInt16(gridCols), rows: UInt16(gridRows)))
        }
        XCTAssertEqual(Int(applied?.cols ?? 0), gridCols,
                       "precondition: headless grid widened to \(gridCols) cols",
                       file: file, line: line)
        XCTAssertEqual(Int(applied?.rows ?? 0), gridRows,
                       "precondition: headless grid is \(gridRows) rows",
                       file: file, line: line)

        // No trailing newline: the cursor rests on the last printed line, so
        // every further "\r\nLNnnn..." scrolls the primary screen by exactly
        // one line.
        let payload = (0..<totalLines).map { (n: Int) -> String in rowText(n) }
            .joined(separator: "\r\n")
        session.feedBytesForTests(Data(payload.utf8))
        // Let the feed's burst-tail snapshot (and anything else queued on the
        // core) finish, so nothing but the test touches the core from here on.
        session.waitForFeedsForTests()
        session.coreQueue.sync {}

        // The initial displayed frame, installed before the user touches the
        // view (mouse coordinates are mapped against the displayed frame).
        view.session = session
        let first = try XCTUnwrap(session.takeSnapshotForTests(),
                                  "core snapshot() returned nil", file: file, line: line)
        view.render(snapshot: first)
        XCTAssertEqual(first.rows, gridRows, "precondition: snapshot rows", file: file, line: line)
        XCTAssertEqual(first.cols, gridCols, "precondition: snapshot cols", file: file, line: line)
        return Rig(view: view, session: session, nextLabel: totalLines)
    }

    // MARK: - Gesture helpers

    /// View-local point at horizontal fraction `frac` of cell `col` on grid
    /// row `row`. The view is not flipped; mirrors the other headless
    /// selection suites.
    private func point(row: Int, col: Int, frac: CGFloat = 0.5, in view: TerminalView) -> NSPoint {
        let textAreaHeight = view.bounds.height - view.titlebarOnlyTopInset
        return NSPoint(
            x: TerminalView.horizontalContentInsetPoints + (CGFloat(col) + frac) * view.metrics.cellWidth,
            y: textAreaHeight - (CGFloat(row) + 0.5) * view.metrics.cellHeight
        )
    }

    private func mouseEvent(_ type: NSEvent.EventType,
                            at p: NSPoint,
                            timestamp: TimeInterval,
                            file: StaticString = #filePath,
                            line: UInt = #line) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type,
            location: p,
            modifierFlags: [],
            timestamp: timestamp,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        ), "NSEvent.mouseEvent returned nil", file: file, line: line)
    }

    private func dragSelection(_ rig: Rig,
                               file: StaticString = #filePath,
                               line: UInt = #line) throws {
        let view = rig.view
        view.mouseDown(with: try mouseEvent(.leftMouseDown,
                                            at: point(row: fromRow, col: 0, frac: 0.2, in: view),
                                            timestamp: 0, file: file, line: line))
        view.mouseDragged(with: try mouseEvent(.leftMouseDragged,
                                               at: point(row: toRow, col: dragEndCol, in: view),
                                               timestamp: 0.01, file: file, line: line))
        let sel = try XCTUnwrap(view.selection,
                                "a press + drag must leave a selection", file: file, line: line)
        XCTAssertEqual(sel.mode, .character,
                       "precondition: a plain click-drag is a character selection",
                       file: file, line: line)
    }

    private func releaseMouse(_ rig: Rig,
                              file: StaticString = #filePath,
                              line: UInt = #line) throws {
        rig.view.mouseUp(with: try mouseEvent(.leftMouseUp,
                                              at: point(row: toRow, col: dragEndCol, in: rig.view),
                                              timestamp: 0.02, file: file, line: line))
    }

    /// Build the shared starting state. `release: false` leaves the button
    /// down (for the copy-on-select trigger, which IS the mouse-up).
    private func makeScenario(release: Bool,
                              file: StaticString = #filePath,
                              line: UInt = #line) throws -> Scenario {
        let rig = try makeRig(file: file, line: line)
        try dragSelection(rig, file: file, line: line)
        if release {
            try releaseMouse(rig, file: file, line: line)
        }

        // The frame that is on screen: one pipeline snapshot, which drains
        // the core's damage, installed in the view.
        rig.session.waitForFeedsForTests()
        rig.session.coreQueue.sync {}
        let published = try XCTUnwrap(rig.session.takeSnapshotForTests(),
                                      "core snapshot() returned nil", file: file, line: line)
        rig.view.render(snapshot: published)

        XCTAssertEqual(rig.view.currentSnapshot?.sequenceID, published.sequenceID,
                       "precondition: the snapshot just rendered is the displayed frame",
                       file: file, line: line)
        let rows = published.visibleRowsAsText()
        let firstVisible = totalLines - gridRows
        XCTAssertEqual(rows.count, gridRows, "precondition: visible row count",
                       file: file, line: line)
        if rows.count == gridRows {
            for r in 0..<gridRows where !rows[r].hasPrefix(label(firstVisible + r)) {
                XCTFail("precondition: display row \(r) should show \(label(firstVisible + r)); "
                        + "got \(String(reflecting: rows[r]))", file: file, line: line)
            }
        }
        let sel = try XCTUnwrap(rig.view.selection,
                                "precondition: the highlight is on screen", file: file, line: line)
        XCTAssertEqual(Int(sel.anchor.line), fromRow,
                       "precondition: highlight starts on display row \(fromRow) "
                       + "(anchor line \(sel.anchor.line))", file: file, line: line)
        XCTAssertEqual(Int(sel.cursor.line), toRow,
                       "precondition: highlight ends on display row \(toRow) "
                       + "(cursor line \(sel.cursor.line))", file: file, line: line)
        return Scenario(rig: rig, published: published)
    }

    // MARK: - Core activity

    /// The streaming program rewrites rows `changedRows` in place (cursor
    /// addressing + erase line, no scrolling) and the core parses it. The
    /// bytes go straight into the core, NOT through the feed path, so no
    /// burst-tail snapshot is taken: the damage sits in the core until the
    /// pipeline's next snapshot (or a stray one) collects it.
    private func rewriteRowsInCore(_ rig: Rig) {
        var text = ""
        for r in changedRows {
            text += "\u{1B}[\(r + 1);1H\u{1B}[2KCHANGED-ROW-\(r)-fresh-output"
        }
        rig.session.coreQueue.sync { rig.session.bbterm.input(text) }
    }

    /// The streaming program prints `lines` more lines (the primary screen
    /// scrolls) that the core parses; again no burst-tail snapshot.
    private func scrollCore(_ rig: Rig, by lines: Int) {
        var text = ""
        for _ in 0..<lines {
            text += "\r\n" + rowText(rig.nextLabel)
            rig.nextLabel += 1
        }
        rig.session.coreQueue.sync { rig.session.bbterm.input(text) }
    }

    // MARK: - Assertions

    /// The next snapshot the pipeline takes after the trigger ran.
    private func assertNextFrameIsIntact(_ scenario: Scenario, via: String,
                                         expectChangedRowsDamaged: Bool = true,
                                         file: StaticString = #filePath,
                                         line: UInt = #line) throws {
        let next = try XCTUnwrap(scenario.rig.session.takeSnapshotForTests(),
                                 "core snapshot() returned nil", file: file, line: line)

        // Precondition: the core really did change the rows (so there was
        // damage to lose).
        if expectChangedRowsDamaged {
            let nextRows = next.visibleRowsAsText()
            for r in changedRows {
                let got = r < nextRows.count ? nextRows[r] : "<row \(r) missing>"
                XCTAssertTrue(got.hasPrefix("CHANGED-ROW-\(r)"),
                              "precondition: the core must show the rewritten row \(r); "
                              + "got \(String(reflecting: got))", file: file, line: line)
            }
        }

        XCTAssertEqual(Int(next.sequenceID), Int(scenario.published.sequenceID) + 1,
                       "\(via) must not take a snapshot of its own: the next published frame "
                       + "should be sequence \(scenario.published.sequenceID) + 1 but is "
                       + "\(next.sequenceID) (published \(scenario.published.sequenceID))",
                       file: file, line: line)

        if expectChangedRowsDamaged {
            let damaged = Set(next.damagedRows)
            let missing: [Int] = next.damageIsFull
                ? []
                : changedRows.filter { (r: Int) -> Bool in !damaged.contains(r) }
            XCTAssertEqual(missing, [],
                           "\(via) swallowed the core's damage: rows \(changedRows) changed since the "
                           + "published frame, so the next frame must repaint them, but it reports "
                           + "damageIsFull=\(next.damageIsFull) damagedRows=\(next.damagedRows.sorted()) "
                           + "(stale rows left on screen: \(missing))",
                           file: file, line: line)
        }
    }

    /// Per-line trailing-blank-trimmed, no leading/trailing blank lines.
    private func normalized(_ s: String?) -> String {
        guard let s else { return "<nil>" }
        let lines: [String] = s.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .map { (line: String) -> String in
                var t = line
                while let last = t.last, last == " " || last == "\r" { t.removeLast() }
                return t
            }
        return lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
    }

    /// The text must be exactly the highlighted rows: LN025 in full, LN026
    /// up to the drag end column. `firstVisible + fromRow` = 25.
    private func assertHighlightedRowsRead(_ text: String?, via: String,
                                           file: StaticString = #filePath,
                                           line: UInt = #line) {
        let firstLabel = totalLines - gridRows + fromRow
        let lastLabel = totalLines - gridRows + toRow
        let lines = normalized(text).components(separatedBy: "\n")
        XCTAssertEqual(lines.map { (l: String) -> String in String(l.prefix(5)) },
                       [label(firstLabel), label(lastLabel)],
                       "\(via) must deliver the rows the user highlighted; "
                       + "read \(String(reflecting: text ?? "<nil>"))", file: file, line: line)
        XCTAssertTrue(lines.first?.hasPrefix(rowText(firstLabel)) ?? false,
                      "\(via): the first row must be \(label(firstLabel)) from column 0; "
                      + "read \(String(reflecting: text ?? "<nil>"))", file: file, line: line)
        XCTAssertTrue(lines.last?.hasPrefix(String(rowText(lastLabel).prefix(dragEndCol))) ?? false,
                      "\(via): the last row must be \(label(lastLabel)) up to column \(dragEndCol); "
                      + "read \(String(reflecting: text ?? "<nil>"))", file: file, line: line)
    }

    // MARK: - Control (passes today; proves the damage oracle can discriminate)

    /// With NO trigger, the next snapshot after in-place output is exactly
    /// `published + 1` and carries a partial damage set that names the
    /// rewritten rows. If this rig could not produce that, the trigger tests
    /// below would pass vacuously.
    func test_control_noTrigger_nextSnapshotReportsTheChangedRows() throws {
        let scenario = try makeScenario(release: true)
        rewriteRowsInCore(scenario.rig)

        let next = try XCTUnwrap(scenario.rig.session.takeSnapshotForTests(),
                                 "core snapshot() returned nil")
        XCTAssertEqual(Int(next.sequenceID), Int(scenario.published.sequenceID) + 1,
                       "with no trigger the next pipeline snapshot is published + 1 "
                       + "(published \(scenario.published.sequenceID), next \(next.sequenceID))")
        XCTAssertEqual(next.damageIsFull, false,
                       "in-place output with no scroll must give a PARTIAL damage set "
                       + "(damagedRows \(next.damagedRows.sorted())), otherwise the damage "
                       + "assertions in this suite cannot discriminate")
        let damaged = Set(next.damagedRows)
        let missing: [Int] = changedRows.filter { (r: Int) -> Bool in !damaged.contains(r) }
        XCTAssertEqual(missing, [],
                       "rewritten rows \(changedRows) must be in the damage set; "
                       + "damagedRows \(next.damagedRows.sorted())")
    }

    // MARK: - Services validation (right-click / Services menu open)

    /// Opening the Services submenu validates every service with
    /// `validRequestor`. With a live highlight it must answer "yes, this view"
    /// without disturbing the core.
    func test_validRequestor_liveSelection_leavesTheNextFrameDamageIntact() throws {
        let scenario = try makeScenario(release: true)
        rewriteRowsInCore(scenario.rig)

        // A menu open validates many service items; repeat to amplify.
        var answers: [Bool] = []
        for _ in 0..<3 {
            let requestor = scenario.rig.view.validRequestor(forSendType: .string, returnType: nil)
            answers.append((requestor as AnyObject?) === scenario.rig.view)
        }
        XCTAssertEqual(answers, [true, true, true],
                       "precondition: a live highlight must be offered to the Services menu "
                       + "(validRequestor returns the view for a string send type)")

        try assertNextFrameIsIntact(scenario, via: "Services validation (validRequestor)")
    }

    /// The validation predicate must be O(1): it may not queue behind the core.
    /// The core queue is made busy (as it is while parsing a burst) and held
    /// for at most 1.5 s; a validation that hops onto the core queue (to take
    /// a snapshot "to see if there is text") cannot return before then, so it
    /// stalls the main thread (the menu) behind the parser.
    func test_validRequestor_liveSelection_doesNotWaitForTheCoreQueue() throws {
        let scenario = try makeScenario(release: true)
        let session = scenario.rig.session

        let gate = DispatchSemaphore(value: 0)
        let coreIsBusy = DispatchSemaphore(value: 0)
        addTeardownBlock { _ = gate.signal() }   // never leave the core queue blocked
        session.coreQueue.async {
            _ = coreIsBusy.signal()
            _ = gate.wait(timeout: .now() + 5)
        }
        let busy = coreIsBusy.wait(timeout: .now() + 5)
        XCTAssertEqual(busy == .success, true,
                       "precondition: the core queue must be busy before validating")

        // Watchdog: frees the core queue after 1.5 s so a validation that
        // (wrongly) waits on it returns late instead of hanging the test.
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { _ = gate.signal() }

        let start = CACurrentMediaTime()
        let requestor = scenario.rig.view.validRequestor(forSendType: .string, returnType: nil)
        let elapsed = CACurrentMediaTime() - start
        _ = gate.signal()

        XCTAssertEqual((requestor as AnyObject?) === scenario.rig.view, true,
                       "precondition: a live highlight must be offered to the Services menu")
        XCTAssertLessThan(elapsed, 0.75,
                          "validRequestor took \(String(format: "%.3f", elapsed)) s while the core "
                          + "queue was busy: a menu-validation predicate must not wait for the core "
                          + "(expected well under 0.75 s, a hop onto the core queue costs about 1.5 s)")
    }

    // MARK: - Cmd-C

    func test_cmdC_leavesTheNextFrameDamageIntact_andCopiesTheHighlightedRows() throws {
        let scenario = try makeScenario(release: true)
        rewriteRowsInCore(scenario.rig)

        armPasteboard()
        scenario.rig.view.copy(nil)
        let copied = NSPasteboard.general.string(forType: .string)
        XCTAssertEqual(copied == sentinel, false,
                       "precondition: Cmd-C must have written the clipboard in this rig")
        assertHighlightedRowsRead(copied, via: "Cmd-C")

        try assertNextFrameIsIntact(scenario, via: "Cmd-C")
    }

    /// Cmd-C while the core has scrolled past the displayed frame: the
    /// clipboard must still receive the highlighted rows (compensating for the
    /// scrolled lines) WITHOUT publishing / taking a snapshot to find out how
    /// far the core got.
    func test_cmdC_coreScrolledPastDisplayedFrame_copiesHighlightedRowsWithoutTakingASnapshot() throws {
        let k = 3
        let scenario = try makeScenario(release: true)
        scrollCore(scenario.rig, by: k)

        armPasteboard()
        scenario.rig.view.copy(nil)
        let copied = NSPasteboard.general.string(forType: .string)
        XCTAssertEqual(copied == sentinel, false,
                       "precondition: Cmd-C must have written the clipboard in this rig")
        assertHighlightedRowsRead(copied, via: "Cmd-C with the core \(k) lines ahead")

        let next = try XCTUnwrap(scenario.rig.session.takeSnapshotForTests(),
                                 "core snapshot() returned nil")
        XCTAssertEqual(Int(next.linesScrolled) - Int(scenario.published.linesScrolled), k,
                       "precondition: the core must be \(k) scrolled lines ahead of the displayed frame "
                       + "(core linesScrolled \(next.linesScrolled), displayed \(scenario.published.linesScrolled))")
        XCTAssertEqual(Int(next.sequenceID), Int(scenario.published.sequenceID) + 1,
                       "Cmd-C with the core \(k) lines ahead must compensate without taking a snapshot: "
                       + "the next published frame should be sequence \(scenario.published.sequenceID) + 1 "
                       + "but is \(next.sequenceID)")
    }

    // MARK: - Services / Look Up

    func test_servicesWriteSelection_leavesTheNextFrameDamageIntact_andDeliversTheHighlightedRows() throws {
        let servicePasteboard = NSPasteboard.withUniqueName()
        addTeardownBlock { servicePasteboard.releaseGlobally() }

        let scenario = try makeScenario(release: true)
        rewriteRowsInCore(scenario.rig)

        armPasteboard(servicePasteboard)
        let accepted = scenario.rig.view.writeSelection(to: servicePasteboard, types: [.string])
        XCTAssertEqual(accepted, true,
                       "the Services writer must accept a string request for a live selection")
        assertHighlightedRowsRead(servicePasteboard.string(forType: .string),
                                  via: "Services writeSelection(to:types:)")

        try assertNextFrameIsIntact(scenario, via: "Services writeSelection(to:types:)")
    }

    func test_lookUp_selectedStringForServices_leavesTheNextFrameDamageIntact() throws {
        let scenario = try makeScenario(release: true)
        rewriteRowsInCore(scenario.rig)

        let text = scenario.rig.view.selectedStringForServices()
        assertHighlightedRowsRead(text, via: "Look Up (selectedStringForServices)")

        try assertNextFrameIsIntact(scenario, via: "Look Up (selectedStringForServices)")
    }

    // MARK: - Copy-on-select

    /// Copy-on-select reads the selection on mouse-up, in the middle of
    /// streaming output. The read must not eat the damage either.
    func test_copyOnSelect_mouseUp_leavesTheNextFrameDamageIntact_andCopiesTheHighlightedRows() throws {
        Preferences.shared.copyOnSelect = true
        let scenario = try makeScenario(release: false)
        rewriteRowsInCore(scenario.rig)

        armPasteboard()
        try releaseMouse(scenario.rig)
        let copied = NSPasteboard.general.string(forType: .string)
        XCTAssertEqual(copied == sentinel, false,
                       "precondition: copy-on-select mouse-up must have written the clipboard in this rig")
        assertHighlightedRowsRead(copied, via: "copy-on-select mouse-up")

        try assertNextFrameIsIntact(scenario, via: "copy-on-select mouse-up")
    }
}
