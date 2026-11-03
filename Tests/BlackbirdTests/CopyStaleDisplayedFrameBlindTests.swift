import XCTest
import AppKit
import Metal
@testable import Blackbird
import BBCore

/// Regression suite for cr-1: **Copy / copy-on-select / Services must put the
/// text the user HIGHLIGHTED on the clipboard, even when the terminal core has
/// already moved on past the frame that is on screen.**
///
/// Observable contract (terminal / macOS convention): what is highlighted on
/// screen is what a copy delivers. Cmd-C, a Services / Look Up invocation and
/// copy-on-select (mouse-up) all act on the selection the user can SEE, in the
/// frame the user can see. A streaming program (a build, `tail -f`, a log
/// printer) that scrolls the primary screen between the moment the displayed
/// frame was produced and the moment the copy runs must not change which text
/// gets copied: the user selected `LN012`, so `LN012` is what lands on the
/// clipboard, not `LN015`.
///
/// How the gap is modelled, deterministically. In the app the displayed frame
/// is a snapshot published to the main thread; the core runs on its own queue
/// and can be several lines ahead of that snapshot whenever the main thread is
/// busy (any stall of T ms at lambda lines/s opens a window of about
/// lambda x T lines). Here a headless `TerminalSession` plus a headless
/// `TerminalView` reproduce exactly that state: the displayed frame is
/// installed through `render(snapshot:)`, the user selects text with real
/// `mouseDown` / `mouseDragged` events, and then `k` more output lines are fed
/// into the core WITHOUT the main runloop ever being pumped, so the view's
/// displayed frame stays the old one (this is asserted as a precondition on
/// every test, along with "the core really is `k` lines ahead"). The copy then
/// runs against that state.
///
/// Oracle. Every row carries a unique label (`LN012-abcdefghijklmnopqrstuvwxyz`)
/// so a shifted copy is unmistakable. The expected text is the string the same
/// selection yields while display and core agree (`selectedStringForServices()`
/// captured right after the drag, before any extra output), cross-checked
/// against the labels of the rows that are highlighted in the displayed
/// snapshot. Nothing here depends on how a fix is implemented: shifting the
/// selection by the core's `linesScrolled` delta, reading from the displayed
/// snapshot, or pulling a fresh snapshot first all yield the same text.
///
/// Controls (`test_control_*`) pin the paths that already work today, so a fix
/// cannot go green by breaking the in-sync copy, the copy-on-select write
/// itself, or the case where the display has caught up with the core.
///
/// Memory + time budget (CLAUDE.md test-authoring rule): one headless
/// `TerminalView` (about 800 x 200, never added to a window, never drawn) and
/// one PTY-less headless `TerminalSession` of 40 x 8 = 320 cells per rig, at
/// most 41 short lines fed, at most two rigs per test. No `NSWindow`, no
/// `MainWindowController`, no real shell, no runloop pumping. The tests share
/// the system pasteboard and `Preferences.copyOnSelect` with the host, so both
/// are saved in `setUp` and restored in `tearDown`.
final class CopyStaleDisplayedFrameBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Fixture constants

    private let gridCols = 40
    private let gridRows = 8
    /// Column the drag ends on (row text is 32 columns wide, so this is
    /// mid-text and the last selected row is a partial row).
    private let dragEndCol = 11
    private let sentinel = "copy-did-not-run"

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
        /// Lines the viewport is scrolled back when the display frame was taken.
        let scrolledBack: Int
        /// Label number of the next line `advanceCore` will print.
        var nextLabel: Int
        init(view: TerminalView, session: TerminalSession, scrolledBack: Int, nextLabel: Int) {
            self.view = view
            self.session = session
            self.scrolledBack = scrolledBack
            self.nextLabel = nextLabel
        }
    }

    /// What the user sees and has selected before the core moves on.
    private struct Frame {
        /// `selectedStringForServices()` with display and core in agreement.
        let baseline: String
        /// Labels of the rows highlighted in the displayed frame, top to bottom.
        let highlightedLabels: [String]
        let displayedRows: [String]
        let displayedLinesScrolled: UInt64
        let anchor: BufferPoint
        let cursor: BufferPoint
    }

    /// Headless view + session, `totalLines` labelled lines printed
    /// (`LN000` ...), the viewport scrolled back `k` lines (`0` = live
    /// bottom), and that state installed as the DISPLAYED frame through
    /// `render(snapshot:)` (what the session's snapshot sink does).
    private func makeRig(totalLines: Int,
                         scrolledBack k: Int = 0,
                         file: StaticString = #filePath,
                         line: UInt = #line) throws -> Rig {
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
        // one line once the grid is full.
        let payload = (0..<totalLines).map { (n: Int) -> String in rowText(n) }
            .joined(separator: "\r\n")
        session.feedBytesForTests(Data(payload.utf8))
        if k != 0 {
            session.coreQueue.sync { session.bbterm.scroll(delta: Int32(k)) }
        }

        view.session = session
        let snap = try XCTUnwrap(session.takeSnapshotForTests(),
                                 "snapshot() returned nil", file: file, line: line)
        view.render(snapshot: snap)

        XCTAssertEqual(snap.rows, gridRows, "precondition: snapshot rows", file: file, line: line)
        XCTAssertEqual(snap.cols, gridCols, "precondition: snapshot cols", file: file, line: line)
        XCTAssertEqual(snap.displayOffset, k,
                       "precondition: viewport scrolled back exactly \(k) lines",
                       file: file, line: line)
        XCTAssertEqual(view.currentSnapshot?.linesScrolled, snap.linesScrolled,
                       "precondition: the snapshot just rendered is the displayed frame",
                       file: file, line: line)

        // The displayed frame shows the labels the test thinks it shows.
        let visible = snap.visibleRowsAsText()
        let firstVisible = max(0, totalLines - gridRows) - k
        XCTAssertEqual(visible.count, gridRows, "precondition: visible row count",
                       file: file, line: line)
        if visible.count == gridRows {
            for r in 0..<gridRows where !visible[r].hasPrefix(label(firstVisible + r)) {
                XCTFail("precondition: display row \(r) should show \(label(firstVisible + r)); "
                        + "got \(String(reflecting: visible[r]))", file: file, line: line)
            }
        }
        return Rig(view: view, session: session, scrolledBack: k, nextLabel: totalLines)
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

    private func describe(_ p: BufferPoint) -> String { "(line \(p.line), col \(p.col))" }

    /// Press at column 0 of display row `fromRow`, drag to `dragEndCol` of
    /// display row `toRow`, and STOP (no release). Returns the frame the user
    /// is looking at plus the text this selection yields while the core and
    /// the display agree.
    private func pressAndDrag(_ rig: Rig, fromRow: Int, toRow: Int,
                              file: StaticString = #filePath,
                              line: UInt = #line) throws -> Frame {
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
        let k = rig.scrolledBack
        XCTAssertEqual(describe(sel.anchor),
                       describe(BufferPoint(line: Int32(fromRow - k), col: 0)),
                       "precondition: anchor sits at column 0 of display row \(fromRow) "
                       + "(buffer line \(fromRow - k))", file: file, line: line)
        XCTAssertEqual(describe(sel.cursor),
                       describe(BufferPoint(line: Int32(toRow - k), col: dragEndCol)),
                       "precondition: cursor sits at column \(dragEndCol) of display row \(toRow) "
                       + "(buffer line \(toRow - k))", file: file, line: line)

        let displayed = try XCTUnwrap(view.currentSnapshot,
                                      "no displayed frame", file: file, line: line)
        let rows = displayed.visibleRowsAsText()
        let highlighted: [String] = (fromRow...toRow).map { (r: Int) -> String in
            r < rows.count ? String(rows[r].prefix(5)) : "<row \(r) missing>"
        }
        let baseline = try XCTUnwrap(view.selectedStringForServices(),
                                     "the selection must read back while display and core agree",
                                     file: file, line: line)

        // The fixture must really discriminate: the in-sync text starts with
        // the first highlighted label, carries every highlighted label, and
        // spans exactly the highlighted rows.
        let lines = baseline.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, toRow - fromRow + 1,
                       "precondition: in-sync selection spans \(toRow - fromRow + 1) row(s); "
                       + "read \(String(reflecting: baseline))", file: file, line: line)
        XCTAssertEqual(lines.map { (l: String) -> String in String(l.prefix(5)) }, highlighted,
                       "precondition: in-sync selection reads back the highlighted rows "
                       + "\(highlighted); read \(String(reflecting: baseline))", file: file, line: line)
        let firstNumber = Int(String(highlighted[0].dropFirst(2))) ?? -1
        let firstRowStart = String(rowText(firstNumber).prefix(dragEndCol))
        XCTAssertTrue(lines.first?.hasPrefix(firstRowStart) ?? false,
                      "precondition: the first copied row starts at column 0 of \(highlighted[0]) "
                      + "(\(String(reflecting: firstRowStart))); read \(String(reflecting: baseline))",
                      file: file, line: line)

        return Frame(baseline: baseline,
                     highlightedLabels: highlighted,
                     displayedRows: rows,
                     displayedLinesScrolled: displayed.linesScrolled,
                     anchor: sel.anchor,
                     cursor: sel.cursor)
    }

    /// Release the button where the drag ended (column `dragEndCol` of `toRow`).
    private func release(_ rig: Rig, toRow: Int,
                         file: StaticString = #filePath, line: UInt = #line) throws {
        rig.view.mouseUp(with: try mouseEvent(.leftMouseUp,
                                              at: point(row: toRow, col: dragEndCol, in: rig.view),
                                              timestamp: 0.02, file: file, line: line))
    }

    /// The streaming program prints `lines` more lines that the core parses
    /// while the main thread (and so the displayed frame) is stalled.
    private func advanceCore(_ rig: Rig, by lines: Int) {
        var text = ""
        for _ in 0..<lines {
            text += "\r\n" + rowText(rig.nextLabel)
            rig.nextLabel += 1
        }
        rig.session.feedBytesForTests(Data(text.utf8))
    }

    /// The state this suite is about: the core is exactly `k` lines ahead of
    /// the displayed frame, the displayed frame and the selection are exactly
    /// what they were, so a copy is a copy "against a stale display".
    private func assertDisplayIsStale(_ rig: Rig, frame: Frame, coreAhead k: Int,
                                      file: StaticString = #filePath,
                                      line: UInt = #line) throws {
        let core = try XCTUnwrap(rig.session.takeSnapshotForTests(),
                                 "core snapshot() returned nil", file: file, line: line)
        XCTAssertEqual(Int(core.linesScrolled) - Int(frame.displayedLinesScrolled), k,
                       "precondition: the core must be \(k) scrolled lines ahead of the displayed "
                       + "frame (core linesScrolled \(core.linesScrolled), displayed \(frame.displayedLinesScrolled))",
                       file: file, line: line)
        XCTAssertEqual(rig.view.currentSnapshot?.visibleRowsAsText() ?? [], frame.displayedRows,
                       "precondition: the on-screen frame must not have changed (no runloop pumped)",
                       file: file, line: line)
        let sel = try XCTUnwrap(rig.view.selection,
                                "precondition: the user's selection is still there",
                                file: file, line: line)
        XCTAssertEqual("\(describe(sel.anchor)) .. \(describe(sel.cursor))",
                       "\(describe(frame.anchor)) .. \(describe(frame.cursor))",
                       "precondition: the highlight has not moved on screen",
                       file: file, line: line)
    }

    // MARK: - Comparison helpers

    /// Per-line trailing-blank-trimmed, no leading/trailing blank lines:
    /// copy paths may pad or trim row ends differently; the labelled text is
    /// what matters.
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

    private func labelsOf(_ s: String?) -> [String] {
        guard let s else { return [] }
        return normalized(s).components(separatedBy: "\n")
            .map { (l: String) -> String in String(l.prefix(5)) }
    }

    private func assertCopied(_ copied: String?, equals frame: Frame, coreAhead k: Int, via: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(normalized(copied), normalized(frame.baseline),
                       "\(via) with the core \(k) line(s) ahead of the displayed frame: the user "
                       + "highlighted \(frame.highlightedLabels) but the copy holds \(labelsOf(copied)); "
                       + "copied \(String(reflecting: copied ?? "<nil>")), expected "
                       + "\(String(reflecting: frame.baseline))",
                       file: file, line: line)
    }

    // MARK: - Cmd-C

    /// Headline repro. A build is streaming; the user drags across two rows
    /// of visible output and presses Cmd-C. By the time the copy runs the
    /// core has scrolled `k` more lines; the clipboard must still hold the two
    /// rows that were highlighted, not the two rows `k` lines further down.
    func test_cmdC_coreScrolledPastDisplayedFrame_copiesTheHighlightedRows() throws {
        for k in [1, 6] {
            let rig = try makeRig(totalLines: 30)
            let frame = try pressAndDrag(rig, fromRow: 3, toRow: 4)
            try release(rig, toRow: 4)   // copy-on-select is off

            armPasteboard()
            advanceCore(rig, by: k)
            try assertDisplayIsStale(rig, frame: frame, coreAhead: k)

            rig.view.copy(nil)
            assertCopied(NSPasteboard.general.string(forType: .string), equals: frame,
                         coreAhead: k, via: "Cmd-C")
        }
    }

    /// The same bug needs no scrollback at all: a fresh screen that is just
    /// full, one selected row, a few lines of output behind the display.
    func test_cmdC_noScrollbackAtSelectionTime_copiesTheHighlightedRow() throws {
        for k in [1, 5] {
            let rig = try makeRig(totalLines: 8)
            let before = try XCTUnwrap(rig.view.currentSnapshot, "no displayed frame")
            XCTAssertEqual(before.historySize, 0, "precondition: no scrollback when the row is selected")
            let frame = try pressAndDrag(rig, fromRow: 3, toRow: 3)
            try release(rig, toRow: 3)

            armPasteboard()
            advanceCore(rig, by: k)
            try assertDisplayIsStale(rig, frame: frame, coreAhead: k)

            rig.view.copy(nil)
            assertCopied(NSPasteboard.general.string(forType: .string), equals: frame,
                         coreAhead: k, via: "Cmd-C of a row selected with no scrollback")
        }
    }

    /// A user reading back through history while output keeps streaming: the
    /// viewport is scrolled back, the selection is on history rows, and the
    /// core is still ahead of the displayed frame.
    func test_cmdC_viewportScrolledBack_copiesTheHighlightedRows() throws {
        let k = 4
        let rig = try makeRig(totalLines: 30, scrolledBack: 4)
        let frame = try pressAndDrag(rig, fromRow: 2, toRow: 3)
        try release(rig, toRow: 3)

        armPasteboard()
        advanceCore(rig, by: k)
        try assertDisplayIsStale(rig, frame: frame, coreAhead: k)

        rig.view.copy(nil)
        assertCopied(NSPasteboard.general.string(forType: .string), equals: frame,
                     coreAhead: k, via: "Cmd-C while scrolled back")
    }

    // MARK: - Services / Look Up

    /// Services menu and Look Up share `selectedStringForServices()`; the
    /// Services writer hands it to a service-owned pasteboard. Both must
    /// describe the highlighted rows.
    func test_services_coreScrolledPastDisplayedFrame_deliversTheHighlightedRows() throws {
        let k = 3
        let servicePasteboard = NSPasteboard.withUniqueName()
        addTeardownBlock { servicePasteboard.releaseGlobally() }

        let rig = try makeRig(totalLines: 30)
        let frame = try pressAndDrag(rig, fromRow: 3, toRow: 4)
        try release(rig, toRow: 4)

        armPasteboard(servicePasteboard)
        advanceCore(rig, by: k)
        try assertDisplayIsStale(rig, frame: frame, coreAhead: k)

        let accepted = rig.view.writeSelection(to: servicePasteboard, types: [.string])
        XCTAssertTrue(accepted, "the Services writer must accept a string request for a live selection")
        assertCopied(servicePasteboard.string(forType: .string), equals: frame,
                     coreAhead: k, via: "Services writeSelection(to:types:)")
        assertCopied(rig.view.selectedStringForServices(), equals: frame,
                     coreAhead: k, via: "Look Up (selectedStringForServices)")
    }

    // MARK: - Copy-on-select

    /// Copy-on-select fires on mouse-up. The mouse-up lands after the core has
    /// moved on (a stall between the last drag and the release); the clipboard
    /// must still receive the rows that were highlighted when the user let go.
    func test_copyOnSelect_mouseUpAfterCoreScrolled_copiesTheHighlightedRows() throws {
        let k = 4
        Preferences.shared.copyOnSelect = true
        let rig = try makeRig(totalLines: 30)
        let frame = try pressAndDrag(rig, fromRow: 3, toRow: 4)

        armPasteboard()
        advanceCore(rig, by: k)
        try assertDisplayIsStale(rig, frame: frame, coreAhead: k)

        try release(rig, toRow: 4)
        assertCopied(NSPasteboard.general.string(forType: .string), equals: frame,
                     coreAhead: k, via: "copy-on-select mouse-up")
    }

    // MARK: - Controls (pass today; guard against an over-correcting fix)

    /// Display and core agree: copy-on-select must write the highlighted rows.
    /// Also proves the copy-on-select path really runs in this headless rig,
    /// so the stale-frame test above cannot pass by never copying.
    func test_control_copyOnSelect_displayAndCoreInSync_copiesTheHighlightedRows() throws {
        Preferences.shared.copyOnSelect = true
        let rig = try makeRig(totalLines: 30)
        let frame = try pressAndDrag(rig, fromRow: 3, toRow: 4)

        armPasteboard()
        try release(rig, toRow: 4)
        let copied = NSPasteboard.general.string(forType: .string)
        XCTAssertNotEqual(copied, sentinel,
                          "precondition: copy-on-select mouse-up must have written the clipboard in this rig")
        assertCopied(copied, equals: frame, coreAhead: 0, via: "copy-on-select mouse-up (in sync)")
    }

    /// Display and core agree: Cmd-C and Services return the highlighted rows.
    /// Proves the clipboard comparison itself (scrub, trailing blanks) is
    /// sound so the stale-frame tests fail only on the shifted text.
    func test_control_cmdCAndServices_displayAndCoreInSync_copyTheHighlightedRows() throws {
        let rig = try makeRig(totalLines: 30)
        let frame = try pressAndDrag(rig, fromRow: 3, toRow: 4)
        try release(rig, toRow: 4)

        armPasteboard()
        rig.view.copy(nil)
        let copied = NSPasteboard.general.string(forType: .string)
        XCTAssertNotEqual(copied, sentinel, "precondition: Cmd-C must have written the clipboard")
        assertCopied(copied, equals: frame, coreAhead: 0, via: "Cmd-C (in sync)")
        assertCopied(rig.view.selectedStringForServices(), equals: frame, coreAhead: 0,
                     via: "selectedStringForServices (in sync)")
    }

    /// The core got ahead, but the display has since caught up (the next
    /// snapshot was rendered): the selection tracks its content and a copy
    /// still returns the highlighted rows. Guards a fix that corrects for the
    /// gap twice (once in the selection, once at copy time).
    func test_control_displayCaughtUpWithCore_copiesTheHighlightedRows() throws {
        let k = 4
        let rig = try makeRig(totalLines: 30)
        let frame = try pressAndDrag(rig, fromRow: 3, toRow: 4)
        try release(rig, toRow: 4)

        advanceCore(rig, by: k)
        let fresh = try XCTUnwrap(rig.session.takeSnapshotForTests(), "core snapshot() returned nil")
        XCTAssertEqual(Int(fresh.linesScrolled) - Int(frame.displayedLinesScrolled), k,
                       "precondition: the fresh snapshot is \(k) scrolled lines ahead of the old frame")
        rig.view.render(snapshot: fresh)
        XCTAssertEqual(rig.view.currentSnapshot?.linesScrolled, fresh.linesScrolled,
                       "precondition: the display caught up with the core")

        armPasteboard()
        rig.view.copy(nil)
        assertCopied(NSPasteboard.general.string(forType: .string), equals: frame,
                     coreAhead: 0, via: "Cmd-C after the display caught up")
        assertCopied(rig.view.selectedStringForServices(), equals: frame, coreAhead: 0,
                     via: "selectedStringForServices after the display caught up")
    }
}
