import XCTest
import AppKit
import Metal
@testable import Blackbird
import BBCore

/// ⌘-click link opening while a TUI holds mouse reporting on.
///
/// **The bug this suite exists for.** Claude Code's REPL enables
/// `?1000h ?1002h ?1003h ?1006h` (click reporting + button-event motion +
/// any-event motion + SGR encoding) for its whole session. Blackbird used to
/// disable the ⌘-click-to-open-URL path outright whenever mouse reporting was
/// on, so a ⌘-click on a hyperlink fell straight through to the window-drag
/// gesture and the link never opened. Every clickable link in a Claude Code
/// session was dead.
///
/// **The contract now pinned here** (numbers match the behaviour spec):
///
///  1. ⌘-click opens a link even while mouse reporting is enabled — for both
///     OSC 8 attributed cells and regex-detected plain URLs.
///  2. A consumed ⌘-click opens on mouse-UP, not mouse-DOWN, and only when the
///     pointer stayed put: a `mouseDragged` more than 3 points from the
///     mousedown cancels the pending click (that gesture is a window drag).
///  3. The TUI never sees the swallowed click. No xterm mouse-report bytes are
///     written on down, drag, or up. The specific regression guarded here is
///     an **orphan release report** (`ESC [ < 0 ; col ; row m`) with no
///     matching press — a TUI that receives one thinks a button it never saw
///     pressed was just released.
///  4. Plain (unmodified) clicks are unaffected: press on down, exactly one
///     release on up, and no URL opens.
///  5. ⌥⌘-click still opens the link (the pre-existing escape hatch).
///  6. ⌘-click over a cell with no link opens nothing and emits no report.
///  7. The titlebar-inset suppression survives: a ⌘-click in the chrome band
///     must not open a row-0 URL even though that region snaps to display
///     row 0.
///  8. Blocked URL schemes stay blocked.
///
/// **Why a real `BBTerm` snapshot rather than
/// `installHyperlinkSnapshotForTests`.** The fake resolver answers URL
/// lookups but does not set `termMode`, and `termMode` is precisely the gate
/// under test here — the whole point is "reporting is ON and the link still
/// opens". Feeding the real DECSET bytes to a real `BBTerm` and letting the
/// real OSC 8 parser attribute the cells means the mouse-reporting bit and the
/// link attribution come from the same authority the product reads at runtime,
/// so the test cannot pass because a fake disagreed with reality.
///
/// **Geometry, and why it is verified rather than assumed.** Click points are
/// built with the same view-local formula `TerminalActivationClickTests` uses
/// (`x = leftInset + (col + 0.5)·cellWidth`,
/// `y = (bounds.height - titlebarOnlyTopInset) - (row + 0.5)·cellHeight`;
/// AppKit y is up and the view is not flipped). The view is never added to a
/// window, so its frame origin is (0, 0) and window coordinates — what
/// `NSEvent.location` carries — equal view coordinates. Rather than trusting
/// that, `test_control_plainClickOverLink_…` asserts the SGR report the
/// product emits for a click built at (row 2, col 2) names exactly
/// `col + 1 = 3` and `row + 1 = 3`. If the mapping ever drifts, that control
/// fails first and names the real cell, so no other test in this file can
/// silently start clicking a different cell than it claims.
///
/// **Memory / time pre-flight** (per `feedback_test_memory_safety`):
///  - One 60 × 8 `BBTerm` per rig — 480 cells, a few KB — with
///    `scrollback: 64` instead of the 100 000-line default.
///  - One 800 × 480 headless `TerminalView` per rig. Never added to a window,
///    never shown, never drawn; no `NSWindow`, no `MainWindowController`, no
///    PTY, no real shell. `TerminalSession.makeHeadlessForTests()` has no pty,
///    so `send()` is a no-op and only the recorder observes writes.
///  - Two rigs in the single test that needs a paired control; one elsewhere.
///  - No runloop pumping, no timers armed (every click lands mid-viewport, so
///    the selection autoscroll band is never entered). Wall time is dominated
///    by `MTLCreateSystemDefaultDevice()`.
final class LinkClickUnderMouseReportingBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Fixture constants

    private let gridCols: UInt16 = 60
    private let gridRows: UInt16 = 8

    /// Display row the fixtures are written on for every test except the
    /// titlebar one. Deliberately interior: row 0 abuts the titlebar-inset
    /// boundary that test 7 probes, and picking row 2 keeps the two concerns
    /// from overlapping.
    private let linkRow = 2

    /// Column clicked inside the 6-cell anchor `openme` (cols 0…5). Two cells
    /// in, so a half-cell of slack on either side absorbs any font-metric
    /// change without drifting into a neighbouring cell.
    private let linkCol = 2

    private let href = "https://example.com/docs"

    /// Anchor text is deliberately NOT URL-shaped. `resolveClickURL` runs
    /// `OSC8URLPolicy.anchorDivergesFromHost` on the rendered anchor, and a
    /// URL-shaped anchor whose host differed from the href would be blocked
    /// by the anti-phishing gate — for reasons that have nothing to do with
    /// mouse reporting. Plain text short-circuits divergence detection, so
    /// these tests isolate the one variable they mean to.
    private let anchor = "openme"

    /// What Claude Code's REPL sends on entry: click reporting, button-event
    /// motion, any-event motion, SGR encoding.
    private let mouseReportingDECSET = "\u{1B}[?1000h\u{1B}[?1002h\u{1B}[?1003h\u{1B}[?1006h"

    // MARK: - Rig

    /// Everything a test needs, held together so nothing is deallocated
    /// mid-test. `TerminalView.session` is `weak`, so the strong `session`
    /// reference here is load-bearing: without it the session would be gone
    /// before the first event and mouse reports would never be emitted.
    private struct Rig {
        let view: TerminalView
        let term: BBTerm
        let session: TerminalSession
        let opener: RecordingURLOpener
        let recorder: RecordingPTY
        let snapshot: BBSnapshot
    }

    /// Build a headless view whose snapshot has mouse reporting enabled and
    /// whose grid contains `fixture`.
    ///
    /// Ordering matters: `session` is assigned before `currentSnapshot`, so
    /// that if attaching a session installs the session's own (2 × 2, empty)
    /// snapshot, our fixture snapshot still wins.
    private func makeRig(
        feeding fixture: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Rig {
        let device = try requireMetalDevice(file: file, line: line)
        let view = TerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 480),
            device: device
        )
        let term = try XCTUnwrap(
            BBTerm(size: .init(cols: gridCols, rows: gridRows), scrollback: 64),
            "BBTerm init failed", file: file, line: line
        )
        term.input(mouseReportingDECSET)
        term.input(fixture)
        let snapshot = try XCTUnwrap(
            term.snapshot(), "snapshot() returned nil", file: file, line: line
        )

        let session = TerminalSession.makeHeadlessForTests()
        view.session = session
        view.currentSnapshot = snapshot

        let opener = RecordingURLOpener()
        view.urlOpenerForTests = opener
        let recorder = RecordingPTY()
        view.ptyRecorderForTests = recorder

        // Preconditions on the snapshot itself. Without these a fixture
        // regression (a mistyped DECSET, a scroll that shifted the grid)
        // would let every test below pass for the wrong reason: with mouse
        // reporting OFF, ⌘-click always worked, so the whole suite would be
        // green while the shipped bug was untouched.
        // The three mouse *protocols* (1000 click / 1002 button-event /
        // 1003 any-event) are mutually exclusive in the VT model — enabling
        // one clears the others (vendor/alacritty_terminal, `set_mouse_mode`).
        // Claude Code sends all four in order, so what actually survives is
        // ANY-EVENT + SGR, not click-reporting. Assert the property the
        // product reads (`mouseReportingEnabled()` = any of the three) rather
        // than one specific bit, plus the two bits that genuinely co-exist.
        XCTAssertFalse(
            snapshot.termMode.isDisjoint(with: [.mouseReportClick, .mouseMotion, .mouseDrag]),
            "precondition: the DECSET preamble must leave a mouse-reporting protocol active",
            file: file, line: line
        )
        XCTAssertTrue(
            snapshot.termMode.contains(.mouseMotion),
            "precondition: \\e[?1003h is last in Claude Code's preamble, so any-event "
            + "motion is the protocol that survives",
            file: file, line: line
        )
        XCTAssertTrue(
            snapshot.termMode.contains(.sgrMouse),
            "precondition: \\e[?1006h must select SGR mouse encoding (an encoding, not a "
            + "protocol — it co-exists with whichever protocol is active)",
            file: file, line: line
        )
        XCTAssertTrue(
            view.mouseReportingEnabled(),
            "precondition: the view must agree the TUI has mouse reporting on — this is "
            + "the exact predicate the fixed ⌘-click path must no longer be gated on",
            file: file, line: line
        )
        XCTAssertEqual(
            snapshot.displayOffset, 0,
            "precondition: fixture must not scroll — display row must equal buffer line, "
            + "otherwise the SGR row this suite asserts is not the row it clicked",
            file: file, line: line
        )
        return Rig(
            view: view, term: term, session: session,
            opener: opener, recorder: recorder, snapshot: snapshot
        )
    }

    /// Fixture text that parks the cursor on `linkRow` before emitting the
    /// payload. CR+LF `linkRow` times leaves the cursor at (linkRow, col 0);
    /// with only 3 of 8 rows used nothing scrolls.
    private func atLinkRow(_ payload: String) -> String {
        String(repeating: "\r\n", count: linkRow) + payload
    }

    /// An OSC 8 hyperlink: `ESC ] 8 ; ; <href> ESC \ <anchor> ESC ] 8 ; ; ESC \`.
    private func osc8(_ href: String, _ anchor: String) -> String {
        "\u{1B}]8;;\(href)\u{1B}\\\(anchor)\u{1B}]8;;\u{1B}\\"
    }

    // MARK: - Geometry + event synthesis

    /// View-local (== window-local, the view has no window) point at the
    /// centre of grid cell (`row`, `col`).
    private func point(row: Int, col: Int, in view: TerminalView) -> NSPoint {
        let textAreaHeight = view.bounds.height - view.titlebarOnlyTopInset
        return NSPoint(
            x: TerminalView.horizontalContentInsetPoints
                + (CGFloat(col) + 0.5) * view.metrics.cellWidth,
            y: textAreaHeight - (CGFloat(row) + 0.5) * view.metrics.cellHeight
        )
    }

    private func mouseEvent(
        _ type: NSEvent.EventType,
        at p: NSPoint,
        modifiers: NSEvent.ModifierFlags,
        timestamp: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.mouseEvent(
                with: type,
                location: p,
                modifierFlags: modifiers,
                timestamp: timestamp,
                windowNumber: 0,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1.0
            ),
            "NSEvent.mouseEvent returned nil", file: file, line: line
        )
    }

    // MARK: - PTY-byte oracle

    /// Everything written toward the PTY so far, with ESC rendered `<ESC>` so
    /// an assertion failure prints something a human can read.
    private func pty(_ recorder: RecordingPTY) -> String {
        String(decoding: recorder.sent, as: UTF8.self)
            .replacingOccurrences(of: "\u{1B}", with: "<ESC>")
    }

    /// The SGR (`?1006`) mouse report for `button` at zero-based (`row`,
    /// `col`): `ESC [ < button ; col+1 ; row+1 M` for a press, `… m` for a
    /// release. Rendered in the same `<ESC>` form as `pty(_:)` so the two
    /// compare directly.
    private func sgrReport(button: Int = 0, row: Int, col: Int, press: Bool) -> String {
        "<ESC>[<\(button);\(col + 1);\(row + 1)\(press ? "M" : "m")"
    }

    // MARK: - (4) Control: plain clicks still report, and never open a link

    /// Two jobs in one test.
    ///
    /// **Contract 4.** With mouse reporting enabled and no modifier held, the
    /// TUI owns the click: mousedown emits one SGR press and mouseup emits
    /// exactly one SGR release. No URL opens even though the click lands
    /// squarely on an OSC 8 hyperlink — un-modified clicks belong to the
    /// application, not to the link opener.
    ///
    /// **Geometry control for the whole file.** The asserted report names
    /// `col + 1 = 3` and `row + 1 = 3`, which is only true if the point built
    /// by `point(row: 2, col: 2, in:)` really maps to grid cell (2, 2). Every
    /// other test in this file clicks points built the same way; if the
    /// view-local mapping or the titlebar inset ever changes, this assertion
    /// fails first and prints the cell the product actually resolved.
    func test_control_plainClickOverLink_emitsPressAndRelease_andOpensNothing() throws {
        let rig = try makeRig(feeding: atLinkRow(osc8(href, anchor)))
        try assertFixtureHasOSC8Link(rig)

        let p = point(row: linkRow, col: linkCol, in: rig.view)

        rig.view.mouseDown(with: try mouseEvent(.leftMouseDown, at: p, modifiers: [], timestamp: 1.0))
        XCTAssertEqual(
            pty(rig.recorder),
            sgrReport(row: linkRow, col: linkCol, press: true),
            "an unmodified mousedown under \\e[?1000h/\\e[?1006h must emit exactly one SGR "
            + "press naming the clicked cell — this also proves the test's view-local "
            + "point → (row \(linkRow), col \(linkCol)) mapping is correct"
        )

        rig.view.mouseUp(with: try mouseEvent(.leftMouseUp, at: p, modifiers: [], timestamp: 1.01))
        XCTAssertEqual(
            pty(rig.recorder),
            sgrReport(row: linkRow, col: linkCol, press: true)
                + sgrReport(row: linkRow, col: linkCol, press: false),
            "the mouseup must add exactly one SGR release for the same cell — no more, no less"
        )

        XCTAssertEqual(
            rig.opener.opened, [],
            "an unmodified click must never open the hyperlink under it; the TUI owns that click"
        )
    }

    // MARK: - (1) ⌘-click opens a link while mouse reporting is enabled

    /// Contract 1 (OSC 8 flavour) — the headline regression. Pre-fix the
    /// ⌘-click path was gated off entirely while `termMode` carried the
    /// mouse-reporting bits, so this click opened nothing and became a window
    /// drag.
    func test_cmdClick_opensOsc8Href_whileMouseReportingEnabled() throws {
        let rig = try makeRig(feeding: atLinkRow(osc8(href, anchor)))
        try assertFixtureHasOSC8Link(rig)

        let p = point(row: linkRow, col: linkCol, in: rig.view)
        rig.view.mouseDown(with: try mouseEvent(.leftMouseDown, at: p, modifiers: [.command], timestamp: 1.0))
        rig.view.mouseUp(with: try mouseEvent(.leftMouseUp, at: p, modifiers: [.command], timestamp: 1.01))

        XCTAssertEqual(
            rig.opener.opened.map(\.absoluteString),
            [href],
            "⌘-click on an OSC 8 hyperlink must open exactly that href even while the "
            + "foreground TUI has mouse reporting enabled"
        )
    }

    /// Contract 1 (regex flavour). Most tools do not emit OSC 8; a bare URL in
    /// `ls` / `cat` / log output is detected by `URLDetector`. That path must
    /// survive mouse reporting too, otherwise every plain URL Claude Code
    /// prints stays unclickable.
    func test_cmdClick_opensRegexDetectedURL_whileMouseReportingEnabled() throws {
        // "see " occupies cols 0…3, so the URL runs from col 4.
        let plain = "https://foo.test/ok"
        let urlStartCol = 4
        let clickCol = urlStartCol + 5
        let rig = try makeRig(feeding: atLinkRow("see \(plain) here"))

        // Precondition: the regex detector really claims the clicked cell.
        // Without this a nil `resolveClickURL` could mean either "gated off by
        // mouse reporting" (the bug) or "fixture text never matched" (a broken
        // test), and the failure message would not distinguish them.
        let matches = URLDetector.scan(snapshot: rig.snapshot)
        XCTAssertEqual(
            URLDetector.match(
                at: BufferPoint(line: Int32(linkRow), col: clickCol), in: matches
            )?.url.absoluteString,
            plain,
            "precondition: URLDetector must claim (row \(linkRow), col \(clickCol)) for \(plain)"
        )
        XCTAssertEqual(
            rig.snapshot.linkID(row: linkRow, col: clickCol), 0,
            "precondition: the plain-text fixture must carry NO OSC 8 attribution, so this "
            + "test exercises the regex fallback rather than the OSC 8 branch"
        )

        let p = point(row: linkRow, col: clickCol, in: rig.view)
        rig.view.mouseDown(with: try mouseEvent(.leftMouseDown, at: p, modifiers: [.command], timestamp: 1.0))
        rig.view.mouseUp(with: try mouseEvent(.leftMouseUp, at: p, modifiers: [.command], timestamp: 1.01))

        XCTAssertEqual(
            rig.opener.opened.map(\.absoluteString),
            [plain],
            "⌘-click on a regex-detected plain URL must open it while mouse reporting is enabled"
        )
    }

    // MARK: - (2) Open on mouse-UP, and only if the pointer stayed put

    /// Contract 2, first half. The mousedown only *arms* a pending link click.
    /// Opening on mousedown would fire the browser before the user could
    /// abandon the gesture by dragging away, and would make ⌘-drag (window
    /// move) impossible to start over any link.
    func test_cmdMouseDown_armsPendingClick_andOpensNothingUntilMouseUp() throws {
        let rig = try makeRig(feeding: atLinkRow(osc8(href, anchor)))
        try assertFixtureHasOSC8Link(rig)

        let p = point(row: linkRow, col: linkCol, in: rig.view)
        rig.view.mouseDown(with: try mouseEvent(.leftMouseDown, at: p, modifiers: [.command], timestamp: 1.0))
        XCTAssertEqual(
            rig.opener.opened, [],
            "⌘-mousedown must only arm the pending link click — opening here would fire the "
            + "browser before the user has a chance to drag the gesture away"
        )

        rig.view.mouseUp(with: try mouseEvent(.leftMouseUp, at: p, modifiers: [.command], timestamp: 1.01))
        XCTAssertEqual(
            rig.opener.opened.map(\.absoluteString),
            [href],
            "the armed link click must be committed by the mouseup at the same point"
        )
    }

    /// Contract 2, second half. A ⌘-drag that travels more than 3 points is a
    /// window-move gesture, not a link click: the pending click is cancelled
    /// and nothing opens on the mouseup.
    func test_cmdDragBeyondThreshold_cancelsPendingLinkClick() throws {
        let rig = try makeRig(feeding: atLinkRow(osc8(href, anchor)))
        try assertFixtureHasOSC8Link(rig)

        let down = point(row: linkRow, col: linkCol, in: rig.view)
        // 10 points — comfortably past the 3-point tolerance in a single axis,
        // so the Euclidean distance is unambiguously 10 whichever way the
        // threshold is measured.
        let dragged = NSPoint(x: down.x + 10, y: down.y)

        rig.view.mouseDown(with: try mouseEvent(.leftMouseDown, at: down, modifiers: [.command], timestamp: 1.0))
        rig.view.mouseDragged(with: try mouseEvent(.leftMouseDragged, at: dragged, modifiers: [.command], timestamp: 1.01))
        rig.view.mouseUp(with: try mouseEvent(.leftMouseUp, at: dragged, modifiers: [.command], timestamp: 1.02))

        XCTAssertEqual(
            rig.opener.opened, [],
            "a ⌘-drag of 10 points must cancel the pending link click — that gesture is a "
            + "window drag, and finishing it must not launch a browser"
        )
    }

    /// Contract 2, tolerance half. Real trackpad and mouse clicks jitter by a
    /// point or two between press and release. A cancel rule that fired on ANY
    /// movement would make links feel randomly unclickable, so movement within
    /// the 3-point tolerance must still commit the click. The mouseup returns
    /// to the exact mousedown point, so the only thing under test is whether
    /// the intermediate 2-point drag cancelled the arming.
    func test_cmdDragWithinThreshold_stillOpensLink() throws {
        let rig = try makeRig(feeding: atLinkRow(osc8(href, anchor)))
        try assertFixtureHasOSC8Link(rig)

        let down = point(row: linkRow, col: linkCol, in: rig.view)
        let jitter = NSPoint(x: down.x + 2, y: down.y)   // 2 points ≤ 3-point tolerance

        rig.view.mouseDown(with: try mouseEvent(.leftMouseDown, at: down, modifiers: [.command], timestamp: 1.0))
        rig.view.mouseDragged(with: try mouseEvent(.leftMouseDragged, at: jitter, modifiers: [.command], timestamp: 1.01))
        rig.view.mouseUp(with: try mouseEvent(.leftMouseUp, at: down, modifiers: [.command], timestamp: 1.02))

        XCTAssertEqual(
            rig.opener.opened.map(\.absoluteString),
            [href],
            "a 2-point wobble is inside the 3-point tolerance and must NOT cancel the click; "
            + "cancelling on any movement would make links unclickable on a trackpad"
        )
    }

    // MARK: - (3) The TUI must never see the swallowed click

    /// Contract 3 — the regression this whole contract exists to prevent.
    ///
    /// When a ⌘-click is consumed for URL opening, the click is invisible to
    /// the foreground TUI: no press on the mousedown, no motion report on the
    /// intermediate drag (even though `?1003h` any-event motion is on), and —
    /// critically — **no release on the mouseup**. A release with no matching
    /// press is an orphan: `ESC [ < 0 ; col ; row m` arriving out of nowhere
    /// makes an application think a button it never saw pressed was released,
    /// which in Claude Code's REPL lands as a stray click on whatever is under
    /// the cursor.
    ///
    /// The gesture here is the full down → small drag → up, and the PTY stream
    /// is checked after every single event so the failure message names the
    /// event that leaked.
    func test_consumedCmdClick_writesNoMouseReportBytes_includingNoOrphanRelease() throws {
        let rig = try makeRig(feeding: atLinkRow(osc8(href, anchor)))
        try assertFixtureHasOSC8Link(rig)

        let down = point(row: linkRow, col: linkCol, in: rig.view)
        let jitter = NSPoint(x: down.x + 1, y: down.y)

        rig.view.mouseDown(with: try mouseEvent(.leftMouseDown, at: down, modifiers: [.command], timestamp: 1.0))
        XCTAssertEqual(
            pty(rig.recorder), "",
            "a consumed ⌘-mousedown must not emit an SGR press — the TUI must never learn "
            + "about a click the terminal swallowed for link opening"
        )

        rig.view.mouseDragged(with: try mouseEvent(.leftMouseDragged, at: jitter, modifiers: [.command], timestamp: 1.01))
        XCTAssertEqual(
            pty(rig.recorder), "",
            "the drag inside a consumed ⌘-click must not emit a motion report, even with "
            + "\\e[?1003h (any-event motion) enabled"
        )

        rig.view.mouseUp(with: try mouseEvent(.leftMouseUp, at: down, modifiers: [.command], timestamp: 1.02))
        XCTAssertEqual(
            pty(rig.recorder), "",
            "the mouseup of a consumed ⌘-click must not emit a release — a release with no "
            + "matching press is the orphan report (\(sgrReport(row: linkRow, col: linkCol, press: false))) "
            + "this contract exists to prevent"
        )

        // Pair the byte assertion with the behavioural one: the click really
        // was consumed for URL opening, so "no bytes" cannot be explained away
        // by "nothing happened at all".
        XCTAssertEqual(
            rig.opener.opened.map(\.absoluteString),
            [href],
            "the silent gesture must still be the one that opened the link"
        )
    }

    /// Contract 3, cancelled-drag variant. The mousedown was swallowed, so the
    /// TUI never saw a press; the fact that the gesture later turned into a
    /// window drag cannot retroactively justify emitting a release. This is the
    /// same orphan-release hazard reached down a different branch.
    func test_cancelledCmdDrag_writesNoMouseReportBytes() throws {
        let rig = try makeRig(feeding: atLinkRow(osc8(href, anchor)))
        try assertFixtureHasOSC8Link(rig)

        let down = point(row: linkRow, col: linkCol, in: rig.view)
        let dragged = NSPoint(x: down.x + 10, y: down.y)

        rig.view.mouseDown(with: try mouseEvent(.leftMouseDown, at: down, modifiers: [.command], timestamp: 1.0))
        rig.view.mouseDragged(with: try mouseEvent(.leftMouseDragged, at: dragged, modifiers: [.command], timestamp: 1.01))
        rig.view.mouseUp(with: try mouseEvent(.leftMouseUp, at: dragged, modifiers: [.command], timestamp: 1.02))

        XCTAssertEqual(
            pty(rig.recorder), "",
            "a ⌘-click whose drag cancelled the pending link click still swallowed the "
            + "mousedown, so no press was ever sent — emitting a release on the mouseup "
            + "would hand the TUI an orphan release report"
        )
        XCTAssertEqual(
            rig.opener.opened, [],
            "and the cancelled gesture must still open nothing"
        )
    }

    // MARK: - (5) ⌥⌘-click escape hatch must not regress

    /// Contract 5. Holding Option has always been the "give me the terminal's
    /// own behaviour, not the TUI's" escape hatch. Teaching plain ⌘-click to
    /// work under mouse reporting must not break it.
    ///
    /// The assertion is on the whole gesture producing exactly ONE open. If the
    /// legacy Option path fires on mousedown and the new pending-click path
    /// fires again on mouseup, the user gets two browser tabs from one click —
    /// so a duplicate here is a real defect, not a harmless overlap.
    func test_optionCmdClick_stillOpensLink_whileMouseReportingEnabled() throws {
        let rig = try makeRig(feeding: atLinkRow(osc8(href, anchor)))
        try assertFixtureHasOSC8Link(rig)

        let p = point(row: linkRow, col: linkCol, in: rig.view)
        let mods: NSEvent.ModifierFlags = [.command, .option]
        rig.view.mouseDown(with: try mouseEvent(.leftMouseDown, at: p, modifiers: mods, timestamp: 1.0))
        rig.view.mouseUp(with: try mouseEvent(.leftMouseUp, at: p, modifiers: mods, timestamp: 1.01))

        XCTAssertEqual(
            rig.opener.opened.map(\.absoluteString),
            [href],
            "⌥⌘-click must still open the link exactly once — the pre-existing escape hatch "
            + "must neither stop working nor start double-opening"
        )
    }

    // MARK: - (6) ⌘-click over a cell with no link

    /// Contract 6. Over a cell with no OSC 8 attribution and no detected URL,
    /// ⌘-click belongs to the window-drag branch: nothing opens, and nothing
    /// is reported to the TUI either (the modifier still claims the click).
    func test_cmdClickOverCellWithNoLink_opensNothingAndEmitsNoReport() throws {
        // Plain prose: no OSC 8 attribution, no scheme the URL detector matches.
        let rig = try makeRig(feeding: atLinkRow("plain text with no url"))
        let col = 3   // the 'i' of "plain"

        XCTAssertEqual(
            rig.snapshot.linkID(row: linkRow, col: col), 0,
            "precondition: the clicked cell must carry no OSC 8 link id"
        )
        XCTAssertNil(
            URLDetector.match(
                at: BufferPoint(line: Int32(linkRow), col: col),
                in: URLDetector.scan(snapshot: rig.snapshot)
            )?.url,
            "precondition: the clicked cell must not be inside a regex-detected URL"
        )

        let p = point(row: linkRow, col: col, in: rig.view)
        rig.view.mouseDown(with: try mouseEvent(.leftMouseDown, at: p, modifiers: [.command], timestamp: 1.0))
        rig.view.mouseUp(with: try mouseEvent(.leftMouseUp, at: p, modifiers: [.command], timestamp: 1.01))

        XCTAssertEqual(
            rig.opener.opened, [],
            "⌘-click over a linkless cell must open nothing"
        )
        XCTAssertEqual(
            pty(rig.recorder), "",
            "⌘-click over a linkless cell belongs to the window-drag branch and must not "
            + "report to the TUI either"
        )
    }

    // MARK: - (7) Titlebar-inset suppression survives

    /// Contract 7. `bufferPointFromEvent` snaps any click in the titlebar-inset
    /// band to display row 0. If row 0 happens to carry a hyperlink, a
    /// ⌘-drag started from the window chrome would silently open that URL
    /// instead of moving the window (audit M12). Teaching ⌘-click to work under
    /// mouse reporting must not reopen that hole.
    ///
    /// Two rigs, identical except for the click's y: the text-area click is the
    /// positive control proving the row-0 fixture really is clickable, so the
    /// titlebar assertion cannot pass merely because the fixture was broken.
    func test_cmdClickInTitlebarInset_doesNotOpenRow0Link_whileMouseReportingEnabled() throws {
        // Positive control — same fixture, click inside the text area at row 0.
        let control = try makeRig(feeding: osc8(href, anchor))
        XCTAssertNotEqual(
            control.snapshot.linkID(row: 0, col: linkCol), 0,
            "precondition: row 0 of the fixture must carry the OSC 8 link"
        )
        let textPoint = point(row: 0, col: linkCol, in: control.view)
        control.view.mouseDown(with: try mouseEvent(.leftMouseDown, at: textPoint, modifiers: [.command], timestamp: 1.0))
        control.view.mouseUp(with: try mouseEvent(.leftMouseUp, at: textPoint, modifiers: [.command], timestamp: 1.01))
        XCTAssertEqual(
            control.opener.opened.map(\.absoluteString),
            [href],
            "control: a ⌘-click on row 0 INSIDE the text area must open the link — if this "
            + "fails the titlebar assertion below proves nothing"
        )

        // The real subject — same x, y raised into the titlebar-inset band.
        let rig = try makeRig(feeding: osc8(href, anchor))
        let textAreaTop = rig.view.bounds.height - rig.view.titlebarOnlyTopInset
        let titlebarPoint = NSPoint(x: textPoint.x, y: textAreaTop + 8)
        XCTAssertLessThan(
            titlebarPoint.y, rig.view.bounds.height,
            "precondition: the titlebar probe must be inside the view's bounds, not above it"
        )

        rig.view.mouseDown(with: try mouseEvent(.leftMouseDown, at: titlebarPoint, modifiers: [.command], timestamp: 1.0))
        rig.view.mouseUp(with: try mouseEvent(.leftMouseUp, at: titlebarPoint, modifiers: [.command], timestamp: 1.01))

        XCTAssertEqual(
            rig.opener.opened, [],
            "⌘-click in the titlebar inset region must NOT open the row-0 link that region "
            + "snaps onto — chrome clicks are window drags, mouse reporting or not"
        )
    }

    // MARK: - (8) Blocked schemes stay blocked

    /// Contract 8. `OSC8URLPolicy` refuses `javascript:` (and every other
    /// non-http/https/mailto scheme) because `NSWorkspace.open` would dispatch
    /// it to whichever handler registered for it. Re-enabling ⌘-click under
    /// mouse reporting must widen *when* the click resolves, never *what* it is
    /// allowed to resolve to.
    func test_cmdClickOnDisallowedScheme_opensNothing_whileMouseReportingEnabled() throws {
        let hostile = "javascript:alert(1)"
        let rig = try makeRig(feeding: atLinkRow(osc8(hostile, anchor)))

        // Precondition: the OSC 8 attribution really is present and really does
        // carry the hostile href — so "nothing opened" means the policy gate
        // fired, not that the parser dropped the link.
        let id = rig.snapshot.linkID(row: linkRow, col: linkCol)
        XCTAssertNotEqual(id, 0, "precondition: the clicked cell must carry an OSC 8 link id")
        XCTAssertEqual(
            rig.snapshot.linkURL(id: id), hostile,
            "precondition: the link table must hold the disallowed href verbatim"
        )

        let p = point(row: linkRow, col: linkCol, in: rig.view)
        rig.view.mouseDown(with: try mouseEvent(.leftMouseDown, at: p, modifiers: [.command], timestamp: 1.0))
        rig.view.mouseUp(with: try mouseEvent(.leftMouseUp, at: p, modifiers: [.command], timestamp: 1.01))

        XCTAssertEqual(
            rig.opener.opened, [],
            "a ⌘-click on a javascript: OSC 8 href must open nothing — the scheme allowlist "
            + "is unaffected by mouse reporting"
        )
    }

    // MARK: - (9) A consumed ⌘-gesture stays consumed for its WHOLE life
    //
    // `test_cancelledCmdDrag_writesNoMouseReportBytes` above sends exactly ONE
    // `mouseDragged`, so it only pins the first drag of the gesture. A
    // per-event fall-through — "the pending link click is cancelled, therefore
    // from now on the TUI owns this drag again" — sails straight through it:
    // the single dragged event is the one that performs the cancel, and the
    // leak starts on the event after. The two tests here send a RUN of drags,
    // each landing in a DIFFERENT grid cell so a same-cell dedupe cannot mask
    // the leak either, and cover both ways a ⌘-gesture stops being a click:
    // a window drag (the configured drag modifier matches) and a text
    // selection (it does not).
    //
    // Why any leak here is worse than a cosmetic stray byte: the press was
    // swallowed, so the TUI never saw a button go down. A motion report
    // (`ESC [ < 32 ; col ; row M`) then arrives describing movement of a
    // button the application never saw pressed — and because the matching
    // mouseup is swallowed too, no release ever follows. A TUI that starts a
    // selection on that motion has no event that can ever end it.

    /// Contract 9, window-drag flavour. The configured window-drag modifier is
    /// Command (the default), so a ⌘-mousedown on a link that then travels
    /// becomes a window move. Every event of that gesture — the swallowed
    /// mousedown, all three drags, and the mouseup — must write nothing toward
    /// the PTY, and the gesture must open no URL.
    ///
    /// **What this catches that the single-drag test cannot.** An
    /// implementation that clears its "this gesture is mine" state as part of
    /// cancelling the pending click passes the one-drag test (the cancelling
    /// event is still handled) and fails here on drag #2. The drags are in
    /// three distinct cells, so a cell-dedupe cannot be the reason drags 2 and
    /// 3 are silent.
    func test_consumedCmdGesture_staysConsumed_acrossEveryDraggedEvent() throws {
        // Pinned rather than assumed: this is the "drag modifier MATCHES" half
        // and the mirror below is the "does not match" half, so the pref must
        // not depend on what an earlier test in the host process left behind.
        // Restored in `defer` (the singleton is shared process-wide).
        let saved = Preferences.shared.windowDragModifierRaw
        Preferences.shared.windowDragModifierRaw = "Command"
        defer { Preferences.shared.windowDragModifierRaw = saved }
        XCTAssertEqual(
            Preferences.shared.windowDragModifier, .command,
            "precondition: this test is the drag-modifier-MATCHES half, so the configured "
            + "window-drag modifier must be Command"
        )

        let rig = try makeRig(feeding: atLinkRow(osc8(href, anchor)))
        try assertFixtureHasOSC8Link(rig)

        let down = point(row: linkRow, col: linkCol, in: rig.view)
        // Three drags, each in a different cell and each further from the
        // mousedown than the last. Built from (row, col) rather than raw point
        // offsets so "different cell" is true by construction whatever the
        // font metrics are.
        let drags = [
            point(row: linkRow,     col: linkCol +  6, in: rig.view),
            point(row: linkRow + 1, col: linkCol + 14, in: rig.view),
            point(row: linkRow + 3, col: linkCol + 22, in: rig.view),
        ]
        XCTAssertGreaterThan(
            hypot(drags[0].x - down.x, drags[0].y - down.y), 3,
            "precondition: even the FIRST drag must clear the 3-point click tolerance — if it "
            + "did not, this gesture would still be a pending click and would prove nothing "
            + "about the cancelled path"
        )

        rig.view.mouseDown(
            with: try mouseEvent(.leftMouseDown, at: down, modifiers: [.command], timestamp: 1.0)
        )
        XCTAssertEqual(
            pty(rig.recorder), "",
            "the ⌘-mousedown is swallowed for link arming, so no SGR press may reach the TUI"
        )

        for (i, p) in drags.enumerated() {
            rig.view.mouseDragged(
                with: try mouseEvent(
                    .leftMouseDragged, at: p, modifiers: [.command],
                    timestamp: 1.01 + 0.01 * Double(i)
                )
            )
            XCTAssertEqual(
                pty(rig.recorder), "",
                "drag #\(i + 1) of a consumed ⌘-gesture leaked mouse-report bytes. The press "
                + "was never reported, so a motion report here (\(sgrReport(button: 32, row: linkRow, col: linkCol, press: true)) "
                + "and friends) reaches the TUI as movement of a button it never saw pressed — "
                + "and the swallowed mouseup means no release will ever terminate it"
            )
        }

        rig.view.mouseUp(
            with: try mouseEvent(
                .leftMouseUp, at: drags[drags.count - 1], modifiers: [.command], timestamp: 1.05
            )
        )
        XCTAssertEqual(
            pty(rig.recorder), "",
            "and the mouseup that ends the window drag must not emit the orphan release either"
        )
        XCTAssertEqual(
            rig.opener.opened, [],
            "a gesture that travelled 20+ cells is a drag, not a click — it must open nothing"
        )
    }

    /// Contract 9, text-selection flavour — the same gesture with the
    /// configured window-drag modifier deliberately NOT matching.
    ///
    /// With `windowDragModifier` set to Option-Command, a Command-only drag is
    /// not a window move; it falls through to the terminal's own drag handling
    /// (a text selection). That is a different branch from the test above, and
    /// it is the branch most likely to hand the drag back to the mouse-report
    /// encoder — "no modifier gesture claimed this, so the TUI must own it" —
    /// even though the mousedown that started it was swallowed. The contract is
    /// identical: zero PTY bytes for the whole gesture, and no URL opened.
    ///
    /// `windowDragModifierRaw` is restored in `defer`; the singleton is shared
    /// with every other test in the host process (see `PreferencesTests` for
    /// the same save/set/restore shape).
    func test_consumedCmdGesture_staysConsumed_whenDragModifierDoesNotMatch() throws {
        let saved = Preferences.shared.windowDragModifierRaw
        Preferences.shared.windowDragModifierRaw = "Option-Command"
        defer { Preferences.shared.windowDragModifierRaw = saved }
        XCTAssertEqual(
            Preferences.shared.windowDragModifier, .optionCommand,
            "precondition: the configured window-drag modifier must be Option-Command, so the "
            + "Command-only gesture below is NOT a window drag"
        )

        let rig = try makeRig(feeding: atLinkRow(osc8(href, anchor)))
        try assertFixtureHasOSC8Link(rig)

        let down = point(row: linkRow, col: linkCol, in: rig.view)
        let drags = [
            point(row: linkRow,     col: linkCol +  6, in: rig.view),
            point(row: linkRow + 1, col: linkCol + 14, in: rig.view),
            point(row: linkRow + 3, col: linkCol + 22, in: rig.view),
        ]
        XCTAssertGreaterThan(
            hypot(drags[0].x - down.x, drags[0].y - down.y), 3,
            "precondition: the first drag must clear the 3-point click tolerance"
        )

        rig.view.mouseDown(
            with: try mouseEvent(.leftMouseDown, at: down, modifiers: [.command], timestamp: 1.0)
        )
        XCTAssertEqual(
            pty(rig.recorder), "",
            "⌘ still arms a link click regardless of what the window-drag modifier is set to, "
            + "so the mousedown is still swallowed and must still report nothing"
        )

        for (i, p) in drags.enumerated() {
            rig.view.mouseDragged(
                with: try mouseEvent(
                    .leftMouseDragged, at: p, modifiers: [.command],
                    timestamp: 1.01 + 0.01 * Double(i)
                )
            )
            XCTAssertEqual(
                pty(rig.recorder), "",
                "drag #\(i + 1) leaked mouse-report bytes. With the drag modifier set to "
                + "Option-Command this gesture is a text selection, and a selection drag must "
                + "not re-route into the mouse-report encoder — the press it would belong to "
                + "was swallowed and no release will ever follow"
            )
        }

        rig.view.mouseUp(
            with: try mouseEvent(
                .leftMouseUp, at: drags[drags.count - 1], modifiers: [.command], timestamp: 1.05
            )
        )
        XCTAssertEqual(
            pty(rig.recorder), "",
            "the mouseup ending the selection drag must not emit the orphan release either"
        )
        XCTAssertEqual(
            rig.opener.opened, [],
            "and a gesture that became a selection must open nothing"
        )
    }

    // MARK: - (10) A drag past the viewport edge must keep reporting
    //
    // The mirror image of contract 9. When the TUI genuinely owns the drag (no
    // modifier held) the motion stream must not stop just because the pointer
    // left the grid: the coordinate is clamped to the edge cell, so every
    // report past the edge carries the SAME cell, and a "only report when the
    // cell changed" dedupe silently swallows all but the first. A TUI in
    // copy/visual mode autoscrolls off that continuing stream, so a swallowed
    // stream means the selection freezes at the edge and the user cannot drag
    // past the bottom of the screen.
    //
    // The two tests are a matched pair and must be read together: outside the
    // grid every event reports, inside the grid a repeat of the same cell
    // reports once. Only one of the two can be satisfied by "always dedupe" and
    // only the other by "never dedupe", so neither can pass by accident.

    /// Contract 10, outside-the-grid half. Three drags progressively further
    /// BELOW the view (increasing negative y, constant x) must each add exactly
    /// one motion report.
    ///
    /// They share an x, so they clamp to the same column, and they are all past
    /// the bottom edge, so they clamp to the same row: the three reports are
    /// byte-identical, which is asserted explicitly. That is what makes this a
    /// real test of the edge case — a cell-dedupe would emit the first and
    /// swallow the second and third, and the assertion names exactly that.
    ///
    /// The exact clamped cell is deliberately NOT asserted (it depends on
    /// whether the clamp targets the snapshot's rows or the view's), only that
    /// it is a motion report (`ESC [ < 32 ; …`) and that it does not change.
    ///
    /// The gesture is closed with a mouseup so nothing is left armed when the
    /// test returns.
    func test_dragOutsideViewport_underMouseReporting_reportsEveryEvent() throws {
        let rig = try makeRig(feeding: atLinkRow("plain text with no url"))

        let down = point(row: linkRow, col: linkCol, in: rig.view)
        rig.view.mouseDown(
            with: try mouseEvent(.leftMouseDown, at: down, modifiers: [], timestamp: 1.0)
        )
        XCTAssertEqual(
            pty(rig.recorder),
            sgrReport(row: linkRow, col: linkCol, press: true),
            "precondition: an unmodified mousedown under mouse reporting emits one SGR press — "
            + "if this fails the rig is not reporting at all and the drags below prove nothing"
        )

        // Same x (so the clamped COLUMN cannot change), progressively further
        // below the view's bottom edge (so the clamped ROW cannot change
        // either, once clamped).
        let outside = [
            NSPoint(x: down.x, y: -12),
            NSPoint(x: down.x, y: -60),
            NSPoint(x: down.x, y: -130),
        ]
        for p in outside {
            XCTAssertFalse(
                rig.view.bounds.contains(p),
                "precondition: \(p) must be OUTSIDE the view's bounds \(rig.view.bounds) — "
                + "this test is about the clamped-to-edge path"
            )
        }

        var mark = rig.recorder.sent.count
        var deltas: [String] = []
        for (i, p) in outside.enumerated() {
            rig.view.mouseDragged(
                with: try mouseEvent(
                    .leftMouseDragged, at: p, modifiers: [],
                    timestamp: 1.01 + 0.01 * Double(i)
                )
            )
            let delta = ptyDelta(rig.recorder, since: mark)
            mark = rig.recorder.sent.count
            deltas.append(delta)

            XCTAssertEqual(
                motionReportCount(in: delta), 1,
                "drag #\(i + 1) past the bottom edge must add exactly one motion report, got "
                + "\"\(delta)\". A TUI in copy/visual mode autoscrolls off this stream; if it "
                + "stops when the clamped cell stops changing, the selection freezes at the edge"
            )
        }

        XCTAssertEqual(
            deltas, Array(repeating: deltas.first ?? "", count: outside.count),
            "the three reports must be byte-identical (same clamped edge cell). That they are "
            + "identical is the point: a \"report only when the cell changed\" dedupe would "
            + "have emitted the first and swallowed the other two"
        )
        XCTAssertEqual(
            motionReportCount(in: pty(rig.recorder)), outside.count,
            "across the whole gesture there must be one motion report per dragged event"
        )

        // Close the gesture so no drag state or autoscroll survives the test.
        rig.view.mouseUp(
            with: try mouseEvent(.leftMouseUp, at: outside[outside.count - 1], modifiers: [], timestamp: 1.05)
        )
    }

    /// Contract 10, inside-the-grid half — the control that stops the test
    /// above from being satisfied by "never dedupe, report on every event".
    ///
    /// Two consecutive `mouseDragged` events at the EXACT same point inside the
    /// grid describe no movement between cells, and xterm-style motion
    /// reporting emits on cell changes: the second must add nothing. Without
    /// this, a drag that jitters within one cell floods the TUI with duplicate
    /// motion reports — the ?1003h any-event stream is already the highest-rate
    /// thing a terminal writes.
    ///
    /// The first drag lands in a different cell from the mousedown, so the
    /// assertion cannot pass by the view emitting nothing at all: the expected
    /// stream is press(2,2) + motion(2,10), and it must still be exactly that
    /// after the repeat.
    func test_repeatedDragInSameCell_underMouseReporting_reportsMotionOnce() throws {
        let rig = try makeRig(feeding: atLinkRow("plain text with no url"))
        let dragCol = linkCol + 8   // a different cell from the mousedown

        let down = point(row: linkRow, col: linkCol, in: rig.view)
        let dragged = point(row: linkRow, col: dragCol, in: rig.view)

        rig.view.mouseDown(
            with: try mouseEvent(.leftMouseDown, at: down, modifiers: [], timestamp: 1.0)
        )
        rig.view.mouseDragged(
            with: try mouseEvent(.leftMouseDragged, at: dragged, modifiers: [], timestamp: 1.01)
        )

        let afterFirstDrag = sgrReport(row: linkRow, col: linkCol, press: true)
            + sgrReport(button: 32, row: linkRow, col: dragCol, press: true)
        XCTAssertEqual(
            pty(rig.recorder), afterFirstDrag,
            "a drag into a NEW cell must add exactly one motion report for that cell — this "
            + "also proves the repeat assertion below is not passing because nothing reports"
        )

        rig.view.mouseDragged(
            with: try mouseEvent(.leftMouseDragged, at: dragged, modifiers: [], timestamp: 1.02)
        )
        XCTAssertEqual(
            pty(rig.recorder), afterFirstDrag,
            "a second dragged event at the SAME point inside the grid describes no cell change "
            + "and must add nothing. Contrast "
            + "`test_dragOutsideViewport_underMouseReporting_reportsEveryEvent`: dedupe applies "
            + "to a stationary pointer inside the grid, not to a pointer held past the edge"
        )

        rig.view.mouseUp(
            with: try mouseEvent(.leftMouseUp, at: dragged, modifiers: [], timestamp: 1.03)
        )
    }

    // MARK: - PTY-byte oracle: deltas and motion counting

    /// The `<ESC>`-rendered bytes written toward the PTY *since* `mark`, a byte
    /// count captured earlier from `recorder.sent.count`. Lets a test attribute
    /// each report to the single event that produced it instead of diffing
    /// cumulative strings by eye.
    private func ptyDelta(_ recorder: RecordingPTY, since mark: Int) -> String {
        String(decoding: recorder.sent.dropFirst(mark), as: UTF8.self)
            .replacingOccurrences(of: "\u{1B}", with: "<ESC>")
    }

    /// How many SGR motion-with-button reports (`ESC [ < 32 ; col ; row M`)
    /// `rendered` contains. Takes an already-`<ESC>`-rendered string so it works
    /// on both `pty(_:)` output and `ptyDelta(_:since:)` output.
    private func motionReportCount(in rendered: String) -> Int {
        rendered.components(separatedBy: "<ESC>[<32;").count - 1
    }

    // MARK: - Shared fixture precondition

    /// Assert the OSC 8 fixture really attributed the clicked cell with the
    /// expected href. Every ⌘-click test that expects `href` to open depends on
    /// this; without it, a parser regression would turn "the link opened" into
    /// "nothing was there to open" and the negative tests would go green for
    /// the wrong reason.
    private func assertFixtureHasOSC8Link(
        _ rig: Rig,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let id = rig.snapshot.linkID(row: linkRow, col: linkCol)
        XCTAssertNotEqual(
            id, 0,
            "precondition: cell (row \(linkRow), col \(linkCol)) must carry an OSC 8 link id",
            file: file, line: line
        )
        XCTAssertEqual(
            rig.snapshot.linkURL(id: id), href,
            "precondition: the OSC 8 link table must resolve the clicked cell to \(href)",
            file: file, line: line
        )
    }
}
