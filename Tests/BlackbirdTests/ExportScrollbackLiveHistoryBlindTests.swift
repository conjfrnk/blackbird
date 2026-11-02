import XCTest
import AppKit
import Metal
@testable import Blackbird
@testable import BBCore

/// Blind regression tests for bug app-lifecycle-2: File > Export Scrollback
/// silently drops the OLDEST lines when the foreground process keeps
/// printing while the save sheet is open.
///
/// Authored without reading the implementation of `exportScrollback(_:)`
/// beyond its signature and doc comment (project policy, CLAUDE.md "Author
/// new behavior tests blind"). The contract comes from the menu item's
/// documented meaning: "the whole retained buffer as UTF-8 text, scrollback
/// first".
///
/// Contract (observable, end to end):
///
///   The file the user saves must contain the whole retained buffer, in
///   order, oldest line first, as of the moment they CLICK SAVE. The sheet
///   being open for a while (the user browses folders, types a name slowly,
///   walks away) must not change what "the whole buffer" means, so lines the
///   foreground process printed while the sheet was open are part of the
///   file, and - the part this bug breaks - the lines that were ALREADY in
///   the buffer before the sheet opened must all still be there. A terminal
///   whose history is below its scrollback cap never discards a line, so an
///   export that starts at anything other than the first line ever printed
///   has silently lost the head of the log.
///
/// How the tests drive the real code path:
///   1. A real `TerminalView` (Metal device) hosted in ONE standalone
///      `NSWindow`, bound to a headless `TerminalSession` (real BBTerm, no
///      PTY, no shell, no `MainWindowController`).
///   2. Numbered lines `L0001`, `L0002`, ... are fed through the real VT
///      parser (`feedBytesForTests`) so they scroll into real history.
///   3. `view.exportScrollback(nil)` is invoked exactly as the menu item
///      does; the `NSSavePanel` sheet it opens is found on
///      `window.attachedSheet`.
///   4. While the sheet is open, MORE numbered lines are fed (the `tail -f`
///      / build-log case) and the main runloop is pumped until the view has
///      received the newer snapshot.
///   5. Save is committed by ending the sheet with `.OK` (what the Save
///      button does) - no keystroke / event injection. The destination is
///      steered into a temp directory via the panel's remembered root
///      directory, and the test refuses to save anywhere else.
///   6. The written file is read back and the numbered lines in it are
///      compared against the lines that were printed.
///
/// The oracle only looks at lines of the form `L` + 4 digits, so it is
/// insensitive to how trailing blank rows / trailing whitespace are
/// rendered, to the exact grid size the window layout picks, and to the
/// panel's choice of file name.
///
/// Why the tests are not vacuous:
///   - the control test (no output while the sheet is open) must pass today
///     and proves the harness - panel, save, read-back, oracle - works;
///   - every "output during the sheet" test asserts, before saving, that
///     the buffer really had history when the sheet opened, that the sheet
///     really is up, and that the view really has caught up to the newer
///     output (so a fix that reads the live snapshot has something live to
///     read);
///   - history stays far below the 100 000-line scrollback cap, so no line
///     is legitimately discarded and every missing line is a bug.
///
/// Pre-flight cost (CLAUDE.md test rule): at most 400 lines of <= 5 bytes in
/// a ~40-100 column grid (a few tens of KB), one window, one headless
/// session, no PTY, no child process. Each test pumps the main runloop for
/// well under 10 s of wall time in the worst (timeout) case, typically
/// ~1 s.
final class ExportScrollbackLiveHistoryBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Fixture

    /// A window that has hosted a sheet must not be closed or ordered out
    /// mid-process (CLAUDE.md: closing windows in this host poisons a
    /// deferred CoreAnimation flush). Park every window for process
    /// lifetime and never touch it again after the test.
    private static var parkedWindows: [NSWindow] = []

    private struct Rig {
        let window: NSWindow
        let view: TerminalView
        let session: TerminalSession
    }

    private var tempDirs: [URL] = []

    override func tearDown() {
        for dir in tempDirs { try? FileManager.default.removeItem(at: dir) }
        tempDirs.removeAll()
        super.tearDown()
    }

    private func makeRig(file: StaticString = #filePath, line: UInt = #line) throws -> Rig {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(),
                                   "Metal device required", file: file, line: line)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = "bb-export-blind-\(UUID().uuidString)"
        Self.parkedWindows.append(window)

        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400), device: device)
        window.contentView = view

        let session = TerminalSession.makeHeadlessForTests()
        session.resize(to: .init(cols: 60, rows: 12))
        view.session = session

        // Let any layout-driven resize settle BEFORE the test starts
        // counting history, so the grid is stable for the whole test.
        settle(0.3)
        return Rig(window: window, view: view, session: session)
    }

    /// Pump the main runloop in 5 ms slices until `condition` holds or
    /// `timeout` elapses. Returns whether the condition was met.
    @discardableResult
    private func pump(until timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.005))
        }
        return condition()
    }

    private func settle(_ seconds: TimeInterval) {
        pump(until: seconds) { false }
    }

    private static func label(_ n: Int) -> String { String(format: "L%04d", n) }

    /// Print lines `range` (one per row) through the real parser and wait
    /// until the VIEW's snapshot shows the last one on screen.
    private func feedLines(_ rig: Rig, lines range: ClosedRange<Int>,
                       file: StaticString = #filePath, line: UInt = #line) {
        let text = range.map { Self.label($0) }.joined(separator: "\r\n") + "\r\n"
        rig.session.feedBytesForTests(Data(text.utf8))
        let last = Self.label(range.upperBound)
        let landed = pump(until: 5.0) {
            guard let snap = rig.view.currentSnapshot else { return false }
            return snap.visibleRowsAsText().contains { $0.hasPrefix(last) }
        }
        XCTAssertTrue(landed,
                      "fixture: the view must receive a snapshot showing \(last) within 5 s",
                      file: file, line: line)
    }

    private func historySize(_ rig: Rig) -> Int { rig.view.currentSnapshot?.historySize ?? -1 }

    /// The sheet `exportScrollback` opened plus the empty directory it was
    /// steered into (see `openExportSheet`).
    private struct OpenSheet {
        let panel: NSSavePanel
        let saveDir: URL
    }

    private struct FixtureError: Error, CustomStringConvertible {
        let description: String
    }

    /// Open the export sheet exactly as File > Export Scrollback does and
    /// return the `NSSavePanel` that the window now hosts.
    ///
    /// The panel is the out-of-process kind: `directoryURL` /
    /// `nameFieldStringValue` set from the test do NOT feed back into
    /// `panel.url`, so the destination is steered the way a user's last
    /// choice is: through the panel's remembered root directory
    /// (`NSNavLastRootDirectory`), pointed at a fresh temp directory BEFORE
    /// the panel is created and restored afterwards. The file name comes
    /// from the window title (the panel's suggested name), which is unique
    /// per test run. `commitSave` refuses to save anywhere but that temp
    /// directory, so the test can never write into the user's folders.
    private func openExportSheet(_ rig: Rig,
                                 file: StaticString = #filePath, line: UInt = #line) throws -> OpenSheet {
        XCTAssertNil(rig.window.attachedSheet,
                     "fixture: no sheet may be open before exporting", file: file, line: line)

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bb-export-scrollback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)

        let defaults = UserDefaults.standard
        let key = "NSNavLastRootDirectory"
        let previous = defaults.object(forKey: key)
        defaults.set(dir.path, forKey: key)
        addTeardownBlock {
            if let previous { defaults.set(previous, forKey: key) } else { defaults.removeObject(forKey: key) }
        }

        rig.view.exportScrollback(nil)
        let up = pump(until: 5.0) { rig.window.attachedSheet != nil }
        XCTAssertTrue(up, "fixture: exportScrollback must present a sheet on the window within 5 s",
                      file: file, line: line)
        let panel = try XCTUnwrap(rig.window.attachedSheet as? NSSavePanel,
                                  "fixture: the attached sheet must be an NSSavePanel; got \(String(describing: rig.window.attachedSheet))",
                                  file: file, line: line)
        return OpenSheet(panel: panel, saveDir: dir)
    }

    /// Click Save: end the sheet with `.OK` (what the Save button does),
    /// then wait for the sheet to dismiss and the file to land. Returns the
    /// saved file URL. Refuses (cancels the sheet and throws) if the panel's
    /// destination is not inside the test's temp directory.
    private func commitSave(_ rig: Rig, sheet: OpenSheet,
                            file: StaticString = #filePath, line: UInt = #line) throws -> URL {
        let panel = sheet.panel
        let target = try XCTUnwrap(panel.url, "fixture: the panel must have a destination URL",
                                   file: file, line: line)
        let targetDir = target.deletingLastPathComponent().resolvingSymlinksInPath().path
        let wantDir = sheet.saveDir.resolvingSymlinksInPath().path
        guard targetDir == wantDir else {
            rig.window.endSheet(panel, returnCode: .cancel)
            XCTFail("fixture: refusing to save outside the temp dir; panel destination is \(target.path), want a file in \(wantDir)",
                    file: file, line: line)
            throw FixtureError(description: "panel destination outside temp dir")
        }

        rig.window.endSheet(panel, returnCode: .OK)

        let dismissed = pump(until: 5.0) { rig.window.attachedSheet == nil }
        XCTAssertTrue(dismissed, "fixture: ending the sheet with OK must dismiss it within 5 s",
                      file: file, line: line)
        let written = pump(until: 5.0) { FileManager.default.fileExists(atPath: target.path) }
        XCTAssertTrue(written,
                      "fixture: Save must write \(target.path) within 5 s (dir contents: "
                      + "\((try? FileManager.default.contentsOfDirectory(atPath: sheet.saveDir.path)) ?? []))",
                      file: file, line: line)
        guard written else { throw FixtureError(description: "no file written") }
        // Atomic write: once the file exists it is complete, but give the
        // runloop one more turn in case the completion handler is mid-flight.
        settle(0.1)
        return target
    }

    /// The numbered lines (`L` + 4 digits) in the exported file, in file
    /// order, trailing whitespace stripped.
    private func numberedLines(in url: URL,
                               file: StaticString = #filePath, line: UInt = #line) throws -> [String] {
        let data = try Data(contentsOf: url)
        let text = String(decoding: data, as: UTF8.self)
        return text
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count == 5 && $0.hasPrefix("L") && $0.dropFirst().allSatisfy(\.isNumber) }
    }

    /// Human-readable diff between what was printed and what was exported:
    /// "none" when identical, otherwise the missing / unexpected / misordered
    /// summary with the first and last labels, so a failure message shows
    /// the measured values.
    private func describeDifference(printed: ClosedRange<Int>, exported: [String]) -> String {
        let expected = printed.map { Self.label($0) }
        if exported == expected { return "none" }
        let exportedSet = Set(exported)
        let missing = expected.filter { !exportedSet.contains($0) }
        let extra = exported.filter { !Set(expected).contains($0) }
        var parts: [String] = []
        parts.append("printed \(expected.count) lines \(expected.first ?? "-")...\(expected.last ?? "-")")
        parts.append("exported \(exported.count) lines \(exported.first ?? "-")...\(exported.last ?? "-")")
        if !missing.isEmpty {
            parts.append("MISSING \(missing.count) lines \(missing.first ?? "-")...\(missing.last ?? "-")")
        }
        if !extra.isEmpty { parts.append("UNEXPECTED \(extra.prefix(5))") }
        if missing.isEmpty && extra.isEmpty { parts.append("same lines but wrong order or duplicates") }
        return parts.joined(separator: "; ")
    }

    // MARK: - Control: nothing printed while the sheet is open

    /// With no output during the sheet the export is the whole buffer. This
    /// is the harness check: panel, save action, file read-back and oracle
    /// all work. It passes before and after the fix.
    func test_control_noOutputWhileSheetOpen_exportContainsEveryLine() throws {
        let rig = try makeRig()
        feedLines(rig, lines: 1...100)
        XCTAssertGreaterThan(historySize(rig), 50,
                             "precondition: 100 lines on a 12-row grid must have pushed most of them into history; historySize=\(historySize(rig))")

        let sheet = try openExportSheet(rig)
        settle(0.2)
        let url = try commitSave(rig, sheet: sheet)

        let exported = try numberedLines(in: url)
        XCTAssertEqual(describeDifference(printed: 1...100, exported: exported), "none",
                       "with no output during the sheet the file must hold exactly L0001...L0100 in order")
    }

    // MARK: - The bug: output while the sheet is open

    /// The headline scenario: a build log keeps printing while the user
    /// takes their time in the save sheet. 100 lines were in the buffer when
    /// the sheet opened; 100 more arrive before Save. The file must start at
    /// the very first line ever printed and end at the last one.
    func test_outputWhileSheetOpen_exportKeepsOldestLines() throws {
        let rig = try makeRig()
        feedLines(rig, lines: 1...100)
        let historyAtOpen = historySize(rig)
        XCTAssertGreaterThan(historyAtOpen, 50,
                             "precondition: history must exist when the sheet opens; historySize=\(historyAtOpen)")

        let sheet = try openExportSheet(rig)

        // The process keeps producing output while the sheet is up.
        feedLines(rig, lines: 101...200)
        let historyAtSave = historySize(rig)
        XCTAssertGreaterThan(historyAtSave, historyAtOpen + 50,
                             "precondition: output during the sheet must have scrolled into history (opened with \(historyAtOpen), now \(historyAtSave))")
        XCTAssertLessThan(historyAtSave, 100_000,
                          "precondition: history is far below the scrollback cap, so no line may legitimately be discarded")
        XCTAssertTrue(rig.window.attachedSheet === sheet.panel,
                      "precondition: the sheet must still be up when output arrives")

        let url = try commitSave(rig, sheet: sheet)

        let exported = try numberedLines(in: url)
        XCTAssertEqual(exported.first, "L0001",
                       "the export must begin with the very first line printed; it begins with \(exported.first ?? "<empty file>") "
                       + "(history was \(historyAtOpen) when the sheet opened, \(historyAtSave) at Save)")
        XCTAssertEqual(exported.last, "L0200",
                       "the export must end with the last line printed; it ends with \(exported.last ?? "<empty file>")")
        XCTAssertEqual(describeDifference(printed: 1...200, exported: exported), "none",
                       "the file must hold exactly L0001...L0200 in order; lines that scrolled into history while the sheet was open must not cut the head")
    }

    /// The smallest possible trigger: ONE line scrolls into history while
    /// the sheet is open. The head of the file must still be line 1.
    func test_singleLineScrollsWhileSheetOpen_exportStillStartsAtFirstLine() throws {
        let rig = try makeRig()
        feedLines(rig, lines: 1...40)
        let historyAtOpen = historySize(rig)
        XCTAssertGreaterThan(historyAtOpen, 10,
                             "precondition: history must exist when the sheet opens; historySize=\(historyAtOpen)")

        let sheet = try openExportSheet(rig)

        feedLines(rig, lines: 41...41)
        let historyAtSave = historySize(rig)
        XCTAssertGreaterThan(historyAtSave, historyAtOpen,
                             "precondition: the one extra line must have scrolled into history (opened with \(historyAtOpen), now \(historyAtSave))")

        let url = try commitSave(rig, sheet: sheet)

        let exported = try numberedLines(in: url)
        XCTAssertEqual(exported.first, "L0001",
                       "one line of output during the sheet must not cost the file its first line; it begins with \(exported.first ?? "<empty file>")")
        XCTAssertEqual(describeDifference(printed: 1...41, exported: exported), "none",
                       "the file must hold exactly L0001...L0041 in order")
    }

    /// Output that arrives in several bursts while the user dawdles in the
    /// sheet (each burst publishes its own snapshot) is all kept, and the
    /// head is still intact.
    func test_multipleBurstsWhileSheetOpen_exportHasEveryLineInOrder() throws {
        let rig = try makeRig()
        feedLines(rig, lines: 1...60)
        let historyAtOpen = historySize(rig)
        XCTAssertGreaterThan(historyAtOpen, 30,
                             "precondition: history must exist when the sheet opens; historySize=\(historyAtOpen)")

        let sheet = try openExportSheet(rig)

        feedLines(rig, lines: 61...90)
        settle(0.15)
        feedLines(rig, lines: 91...150)
        settle(0.15)
        feedLines(rig, lines: 151...180)
        let historyAtSave = historySize(rig)
        XCTAssertGreaterThan(historyAtSave, historyAtOpen + 90,
                             "precondition: three bursts must have scrolled into history (opened with \(historyAtOpen), now \(historyAtSave))")

        let url = try commitSave(rig, sheet: sheet)

        let exported = try numberedLines(in: url)
        XCTAssertEqual(describeDifference(printed: 1...180, exported: exported), "none",
                       "the file must hold exactly L0001...L0180 in order after three bursts during the sheet")
    }
}
