import XCTest
import AppKit
import Metal
@testable import Blackbird
import BBCore

/// Blind regression tests for: Look Up (three-finger tap, Ctrl-Cmd-D) on a
/// large selection lays out the WHOLE selection in an unbounded label.
///
/// Spec (observable behaviour, independent of how the preview is built):
///
///  - Look Up on a terminal selection shows a small PREVIEW popover of the
///    selected text, not the entire selection: the preview is intended to be
///    about six lines tall. A selection of 7 or more lines must NOT make the
///    popover taller than that; a selection of hundreds of lines must not
///    produce a popover as tall as the screen.
///  - Building the preview must cost O(preview), not O(selection): a
///    Cmd-A selection of a deep scrollback must not stall the main thread
///    for the time it takes to typeset every selected line (measured by the
///    reporter at ~145 ms for 10k lines, ~1.4 s for 100k lines).
///  - Control (passes before and after any fix): a selection of up to six
///    lines is previewed in full, so the popover grows with each line.
///
/// Oracle: the real `TerminalView.quickLook(with:)` is invoked with a real
/// `NSEvent`, and the popover it raises is measured from the outside: the
/// popover window that appears (`NSApp.windows` difference), so the
/// assertions hold wherever the fix lives (label, text view, truncation in
/// the view or in a helper). AppKit only realises a popover for a window
/// that is on screen, so the host window is ordered front (a plain
/// standalone `NSWindow`, never part of a tab group, parked for the process
/// lifetime and ordered out in teardown with animations disabled).
///
/// Fixture: headless `TerminalView` hosted in one standalone `NSWindow` +
/// PTY-less headless `TerminalSession` (real BBTerm, no shell, no
/// `MainWindowController`), 80x10 grid, lines of 79 columns. Memory/time
/// budget (CLAUDE.md test-authoring rule): the small rigs hold at most 520
/// lines (about 40 KB of text); the stress rig holds 20 000 lines x 80
/// columns = 1.6 M cells, roughly 40 MB of scrollback in the core and 1.6 MB
/// of text, fed in 200-line chunks (far under the 4 MiB feed budget). Worst
/// case on a buggy build: four `quickLook` calls of about 0.6 s each; on a
/// fixed build every call is tens of milliseconds. One view, one window and
/// one session per test; popovers are dismissed between calls.
final class LookUpLargeSelectionBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Fixture

    private static var parkedWindows: [NSWindow] = []

    private let gridCols = 80
    private let gridRows = 10
    private let textWidth = 79

    private struct Rig {
        let view: TerminalView
        let session: TerminalSession
        let window: NSWindow
        let textLines: Int
    }

    private struct LookUp {
        /// Wall time `quickLook(with:)` blocked the main thread for.
        let blocked: TimeInterval
        /// Height of the popover window it raised, in points.
        let popoverHeight: CGFloat
    }

    /// Buffer line (signed, negative = scrollback) holding text line `index`
    /// after `total` CRLF-terminated lines were fed to a `gridRows`-row grid:
    /// the cursor rests on the blank last grid row, so the final text line
    /// sits on grid row `gridRows - 2`.
    private func bufferLine(ofTextLine index: Int, total: Int) -> Int32 {
        Int32((gridRows - 2) - (total - 1 - index))
    }

    private func label(_ index: Int) -> String { String(format: "L%06d", index) }

    private func makeRig(textLines total: Int,
                         file: StaticString = #filePath, line: UInt = #line) throws -> Rig {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device on this host",
                                   file: file, line: line)
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 400), device: device)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 400),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.contentView = view
        window.setFrameOrigin(NSPoint(x: 200, y: 200))
        Self.parkedWindows.append(window)
        window.orderFront(nil)
        addTeardownBlock { window.orderOut(nil) }
        XCTAssertTrue(window.isVisible,
                      "precondition: the host window must be on screen, otherwise AppKit never realises the popover",
                      file: file, line: line)

        // Size the content so the view's own grid is exactly gridCols x
        // gridRows: the view then never re-resizes the session behind the
        // test's back (a different grid would reflow the fixture mid-test).
        let metrics = view.metrics
        let contentSize = NSSize(
            width: 2 * TerminalView.horizontalContentInsetPoints
                + CGFloat(gridCols) * metrics.cellWidth + 0.5,
            height: view.titlebarOnlyTopInset + CGFloat(gridRows) * metrics.cellHeight
                + TerminalView.bottomContentInsetPoints + 0.5)
        window.setContentSize(contentSize)
        let usable = TerminalView.usableViewSize(forBounds: view.bounds.size,
                                                 titlebarTopInset: view.titlebarOnlyTopInset,
                                                 metrics: view.metrics)
        let viewGrid = view.metrics.grid(forPixelSize: usable)
        XCTAssertEqual(viewGrid.cols, gridCols,
                       "precondition: the hosted view's own grid must be \(gridCols) columns (bounds \(view.bounds.size))",
                       file: file, line: line)
        XCTAssertEqual(viewGrid.rows, gridRows,
                       "precondition: the hosted view's own grid must be \(gridRows) rows (bounds \(view.bounds.size))",
                       file: file, line: line)

        let session = TerminalSession.makeHeadlessForTests()
        addTeardownBlock { session.terminate() }
        let applied = session.coreQueue.sync {
            session.bbterm.resize(to: .init(cols: UInt16(gridCols), rows: UInt16(gridRows)))
        }
        XCTAssertEqual(Int(applied?.cols ?? 0), gridCols, "precondition: headless grid width",
                       file: file, line: line)
        XCTAssertEqual(Int(applied?.rows ?? 0), gridRows, "precondition: headless grid height",
                       file: file, line: line)

        var chunk = ""
        for i in 0..<total {
            var text = label(i) + " "
            while text.count < textWidth { text += "x" }
            chunk += text + "\r\n"
            if i % 200 == 199 {
                session.feedBytesForTests(Data(chunk.utf8))
                chunk = ""
            }
        }
        if !chunk.isEmpty { session.feedBytesForTests(Data(chunk.utf8)) }

        view.session = session
        let snap = try XCTUnwrap(session.coreQueue.sync { session.bbterm.snapshot() },
                                 "snapshot() returned nil", file: file, line: line)
        view.currentSnapshot = snap
        XCTAssertEqual(snap.historySize, total - (gridRows - 1),
                       "precondition: every fed line beyond the visible grid is retained as scrollback",
                       file: file, line: line)
        return Rig(view: view, session: session, window: window, textLines: total)
    }

    /// Select the last `count` text lines (a plain character selection, as a
    /// drag or Cmd-A would leave) and prove the production copy pipeline sees
    /// exactly that many lines, so the test is not vacuous.
    private func select(_ rig: Rig, lastLines count: Int,
                        file: StaticString = #filePath, line: UInt = #line) {
        let first = rig.textLines - count
        let last = rig.textLines - 1
        rig.view.selection = Selection(
            anchor: BufferPoint(line: bufferLine(ofTextLine: first, total: rig.textLines), col: 0),
            cursor: BufferPoint(line: bufferLine(ofTextLine: last, total: rig.textLines),
                                col: textWidth - 1),
            mode: .character)
        let text: String = rig.view.selectedStringForServices() ?? ""
        let rows: [Substring] = text.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(rows.count, count,
                       "precondition: the selection must cover exactly \(count) lines (copy pipeline returned \(rows.count))",
                       file: file, line: line)
        let firstRow: String = rows.first.map { String($0) } ?? "<none>"
        let lastRow: String = rows.last.map { String($0) } ?? "<none>"
        XCTAssertTrue(firstRow.hasPrefix(label(first)),
                      "precondition: the selection must start at \(label(first)); got \(String(reflecting: firstRow))",
                      file: file, line: line)
        XCTAssertTrue(lastRow.hasPrefix(label(last)),
                      "precondition: the selection must end at \(label(last)); got \(String(reflecting: lastRow))",
                      file: file, line: line)
    }

    private func pump(until timeout: TimeInterval, _ condition: () -> Bool) {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if condition() { return }
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
    }

    private func lookUpEvent(_ rig: Rig, file: StaticString = #filePath, line: UInt = #line) throws -> NSEvent {
        let location = rig.view.convert(NSPoint(x: 100, y: 200), to: nil)
        return try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: location,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: rig.window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        ), "NSEvent.mouseEvent returned nil", file: file, line: line)
    }

    /// Fire Look Up for the last `count` lines, measure how long the call
    /// blocks, then measure the popover that appeared, then dismiss it.
    private func lookUp(_ rig: Rig, selecting count: Int,
                        file: StaticString = #filePath, line: UInt = #line) throws -> LookUp {
        select(rig, lastLines: count, file: file, line: line)
        let event = try lookUpEvent(rig, file: file, line: line)
        let before = Set(NSApp.windows.map { ObjectIdentifier($0) })

        let start = CFAbsoluteTimeGetCurrent()
        rig.view.quickLook(with: event)
        let blocked = CFAbsoluteTimeGetCurrent() - start

        func raised() -> [NSWindow] {
            NSApp.windows.filter { !before.contains(ObjectIdentifier($0)) && $0 !== rig.window }
        }
        pump(until: 3.0) { !raised().isEmpty }
        // Let the show animation settle so the frame is final.
        pump(until: 0.25) { false }
        let popovers = raised()
        // A headless CI runner has no Look Up / Dictionary service to host the
        // popover, so there is nothing to measure there; locally the popover
        // appears and the tests below measure it.
        guard !popovers.isEmpty else {
            throw XCTSkip("Look Up on a \(count)-line selection raised no popover on this host (no window server popover); the preview path is unobservable here")
        }
        let height: CGFloat = popovers.map { $0.frame.height }.max() ?? 0

        for popover in popovers {
            popover.animationBehavior = .none
            rig.window.removeChildWindow(popover)
            popover.orderOut(nil)
        }
        pump(until: 0.05) { false }
        return LookUp(blocked: blocked, popoverHeight: height)
    }

    // MARK: - Control: small selections are previewed in full

    /// Passes before and after the fix. One line, three lines and six lines
    /// must each give a strictly taller popover than the one before: the
    /// preview shows what is selected, one text row per selected line. Also
    /// establishes the per-line height the other tests express their bound in.
    func test_lookUp_selectionUpToSixLines_isPreviewedInFull() throws {
        let rig = try makeRig(textLines: 40)
        _ = try lookUp(rig, selecting: 1)  // warm-up: the first popover pays one-off AppKit setup
        let one = try lookUp(rig, selecting: 1).popoverHeight
        let three = try lookUp(rig, selecting: 3).popoverHeight
        let six = try lookUp(rig, selecting: 6).popoverHeight

        XCTAssertGreaterThan(three, one,
                             "a 3-line selection must preview taller than a 1-line one (heights \(one) -> \(three))")
        XCTAssertGreaterThan(six, three,
                             "a 6-line selection must preview taller than a 3-line one (heights \(three) -> \(six))")
        XCTAssertEqual(six - three, (three - one) * 3.0 / 2.0, accuracy: 4.0,
                       "preview height must grow by one text row per selected line (1/3/6 lines -> \(one)/\(three)/\(six) pt)")
    }

    // MARK: - The bug: the preview follows the selection size

    /// A selection just past six lines, then tens of lines, then hundreds,
    /// must keep the popover at the 6-line preview height (plus a small
    /// allowance for an ellipsis / "more" line), never grow it with the
    /// selection, and never make it screen-tall.
    func test_lookUp_selectionBeyondSixLines_keepsPopoverAtSixLinePreviewHeight() throws {
        let rig = try makeRig(textLines: 520)
        _ = try lookUp(rig, selecting: 1)  // warm-up
        let one = try lookUp(rig, selecting: 1).popoverHeight
        let six = try lookUp(rig, selecting: 6).popoverHeight
        let rowHeight = (six - one) / 5.0
        XCTAssertGreaterThan(rowHeight, 4.0,
                             "precondition: a popover row must be measurable (1 line = \(one) pt, 6 lines = \(six) pt)")

        // Six preview rows plus three rows of slack for a truncation marker.
        let bound = six + 3.0 * rowHeight
        for count in [12, 60, 500] {
            let height = try lookUp(rig, selecting: count).popoverHeight
            XCTAssertLessThanOrEqual(
                height, bound,
                "Look Up on a \(count)-line selection must stay a ~6-line preview: popover is \(height) pt tall, "
                + "but a 6-line selection is \(six) pt (row \(rowHeight) pt, allowed up to \(bound) pt); "
                + "the whole selection is being laid out instead of a bounded preview")
        }
    }

    // MARK: - The hang: cost must not scale with the selection

    /// Cmd-A over a deep scrollback (20 000 lines here; the reporter measured
    /// 1.4 s at 100 000) must cost about the same as Look Up on six lines:
    /// the preview may not typeset the whole selection on the main thread.
    func test_lookUp_hugeSelection_costsNoMoreThanSixLineSelection() throws {
        let total = 20_000
        let rig = try makeRig(textLines: total)
        _ = try lookUp(rig, selecting: 1)  // warm-up
        let smallA = try lookUp(rig, selecting: 6).blocked
        let smallB = try lookUp(rig, selecting: 6).blocked
        let hugeA = try lookUp(rig, selecting: total).blocked
        let hugeB = try lookUp(rig, selecting: total).blocked
        let small = min(smallA, smallB)
        let huge = min(hugeA, hugeB)

        let excess = huge - small
        XCTAssertLessThan(
            excess, 0.15,
            "Look Up on a \(total)-line selection blocked the main thread for \(Int(huge * 1000)) ms vs "
            + "\(Int(small * 1000)) ms for a 6-line selection (+\(Int(excess * 1000)) ms): "
            + "cost must be bounded by the preview, not by the selection size")
    }
}
