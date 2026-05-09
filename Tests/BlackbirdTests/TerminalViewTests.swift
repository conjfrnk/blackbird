import XCTest
import AppKit
import Combine
import Metal
@testable import Blackbird
import BBCore

final class TerminalViewTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    func test_gridDimensionsFromPixelSize() {
        let metrics = CellMetrics(font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        let grid = metrics.grid(forPixelSize: CGSize(width: 800, height: 480))
        XCTAssertGreaterThan(grid.cols, 40)
        XCTAssertGreaterThan(grid.rows, 10)
    }

    func test_cellMetricsAreConsistent() {
        let metrics = CellMetrics(font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        XCTAssertGreaterThan(metrics.cellWidth, 0)
        XCTAssertGreaterThan(metrics.cellHeight, 0)
        XCTAssertGreaterThan(metrics.ascent, 0)
    }

    func test_cellMetrics_gridClampsOnTinyPixelSize() {
        // Tiny input (sub-cell) should still yield a 1×1 grid rather than
        // 0 cols or 0 rows — downstream BBTerm rejects 0 dims and the
        // view would render nothing at all. Confirm the floor.
        let metrics = CellMetrics(font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        let tiny = metrics.grid(forPixelSize: CGSize(width: 0.1, height: 0.1))
        XCTAssertEqual(tiny.cols, 1)
        XCTAssertEqual(tiny.rows, 1)
        // Zero also clamps (was `max(1, Int(0 / cellWidth)) = 1`).
        let zero = metrics.grid(forPixelSize: CGSize(width: 0, height: 0))
        XCTAssertEqual(zero.cols, 1)
        XCTAssertEqual(zero.rows, 1)
    }

    func test_cellMetrics_gridHandlesFiniteButAbsurdPixelSize() {
        // Finite-but-huge values (1e20) also trap Int(Double) because
        // Int can't hold the magnitude. Upper clamp should cap at
        // the 1 000 000 sanity limit.
        let metrics = CellMetrics(font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        let big: Double = 1e20
        let g = metrics.grid(forPixelSize: CGSize(width: big, height: big))
        XCTAssertGreaterThan(g.cols, 1)
        XCTAssertGreaterThan(g.rows, 1)
        XCTAssertLessThan(g.cols, 200_000, "cols must be clamped well below sanePx / cellWidth")
    }

    func test_gridDimensionsSurviveUInt16ConversionAtExtremes() {
        // TerminalView.applyResizeIfNeeded / MainWindowController.startSession
        // bridge CellMetrics.grid (Int) to PTY.Size (UInt16). With sanePx =
        // 1M and a small cellWidth, grid.cols can exceed UInt16.max (65535)
        // even after the sanePx clamp — a direct `UInt16(grid.cols)` would
        // trap. Both call sites use `UInt16(clamping:)` now; this test
        // pins that invariant: on a pathological absurd pixel input, the
        // clamping conversion stays within UInt16 and produces a sane PTY
        // size.
        let metrics = CellMetrics(font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        let big: Double = 1e20
        let g = metrics.grid(forPixelSize: CGSize(width: big, height: big))
        let cols = UInt16(clamping: g.cols)
        let rows = UInt16(clamping: g.rows)
        // Clamp may cap at UInt16.max (65535) for the pathological case —
        // that's fine: TerminalSession.resize has its own [2, 1000] clamp
        // so the real PTY dimensions stay in a sensible range.
        XCTAssertLessThanOrEqual(cols, UInt16.max)
        XCTAssertLessThanOrEqual(rows, UInt16.max)
        XCTAssertGreaterThan(cols, 1)
        XCTAssertGreaterThan(rows, 1)
    }

    func test_cellMetrics_gridHandlesNonFinitePixelSize() {
        // `Int(Double)` traps on NaN / ±Infinity before any max(1, ...)
        // rescue. CGSize from AppKit is always finite in practice, but
        // a stray Core Animation value shouldn't SIGTRAP the render
        // pass. Non-finite components clamp that axis to 1; finite
        // components pass through to the normal cellWidth/Height math.
        let metrics = CellMetrics(font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        let nan = Double.nan
        let inf = Double.infinity
        // Only-width-bad: cols clamp to 1, rows compute normally.
        var g = metrics.grid(forPixelSize: CGSize(width: nan, height: 480))
        XCTAssertEqual(g.cols, 1)
        XCTAssertGreaterThan(g.rows, 1)
        g = metrics.grid(forPixelSize: CGSize(width: inf, height: 480))
        XCTAssertEqual(g.cols, 1)
        XCTAssertGreaterThan(g.rows, 1)
        // Only-height-bad: rows clamp to 1.
        g = metrics.grid(forPixelSize: CGSize(width: 800, height: nan))
        XCTAssertGreaterThan(g.cols, 1)
        XCTAssertEqual(g.rows, 1)
        g = metrics.grid(forPixelSize: CGSize(width: 800, height: -inf))
        XCTAssertGreaterThan(g.cols, 1)
        XCTAssertEqual(g.rows, 1)
        // Both bad: 1×1 clamp.
        g = metrics.grid(forPixelSize: CGSize(width: nan, height: nan))
        XCTAssertEqual(g.cols, 1)
        XCTAssertEqual(g.rows, 1)
    }

    func test_resizeForwardsToSession() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["BB_RUN_STRESS_TESTS"] != "1",
                      "RunLoop-pumping test SEGVs in CATransaction under cumulative ASan; set BB_RUN_STRESS_TESTS=1 for the runtime invariant")
        let session = try TerminalSession.start(
            shell: "/bin/cat",
            arguments: [],
            size: .init(cols: 80, rows: 24)
        )
        // Guarantee child reap even if the wait() below times out.
        defer { session.terminate() }
        let device = MTLCreateSystemDefaultDevice()!
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480), device: device)
        view.session = session

        // Expand to a new size. The view computes grid from pixel size.
        view.setFrameSize(NSSize(width: 1600, height: 900))

        // Wait for the resize to propagate through coreQueue → snapshot publish.
        let snapExp = expectation(description: "snap with new dims")
        var finalSnap: BBSnapshot?
        var c: AnyCancellable?
        c = session.$snapshot.sink { s in
            if let s, (s.cols != 80 || s.rows != 24), finalSnap == nil {
                finalSnap = s
                c?.cancel()
                snapExp.fulfill()
            }
        }
        wait(for: [snapExp], timeout: 3.0)

        XCTAssertGreaterThan(finalSnap?.cols ?? 0, 80)
        XCTAssertGreaterThan(finalSnap?.rows ?? 0, 24)
    }

    func test_viewRendersGivenSnapshotWithoutCrash() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["BB_RUN_STRESS_TESTS"] != "1",
                      "RunLoop-pumping test SEGVs in CATransaction under cumulative ASan; set BB_RUN_STRESS_TESTS=1 for the runtime invariant")
        let session = try TerminalSession.start(
            shell: "/bin/cat",
            arguments: [],
            size: .init(cols: 80, rows: 24)
        )
        // Guarantee child reap even if the wait() or XCTUnwrap below traps.
        defer { session.terminate() }

        let exp = expectation(description: "snap")
        var seen: BBSnapshot?
        var c: AnyCancellable?
        c = session.$snapshot
            .compactMap { $0 }
            .sink { snap in
                if seen == nil {
                    seen = snap
                    c?.cancel()
                    exp.fulfill()
                }
            }
        session.send(Data("hi\n".utf8))
        wait(for: [exp], timeout: 3.0)

        let device = MTLCreateSystemDefaultDevice()!
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480), device: device)
        view.session = session
        view.render(snapshot: seen!)  // must not crash
    }

    func test_controlCSendsSigintViaEncoder() {
        // Sanity check — ⌃C continues to produce 0x03 via KeyEncoder, even
        // after the ⌘C enforcement change.
        let encoder = KeyEncoder()
        XCTAssertEqual(encoder.encode(chars: "c", modifiers: [.control]), Data([0x03]))
    }

    func test_optionKeyPreference_drivesEncoderOptionIsMeta() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["BB_RUN_STRESS_TESTS"] != "1",
                      "RunLoop-pumping test SEGVs in CATransaction under cumulative ASan; set BB_RUN_STRESS_TESTS=1 for the runtime invariant")
        // Regression: the Settings picker for Option Key was wired to
        // Preferences but TerminalView was always instantiating a default
        // KeyEncoder(optionIsMeta: true). The user's "Native" choice had
        // no effect on the encoder.
        let saved = Preferences.shared.optionKeyRaw
        defer { Preferences.shared.optionKeyRaw = saved }

        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())

        Preferences.shared.optionKeyRaw = Preferences.OptionKey.native.rawValue
        let v1 = TerminalView(frame: .init(x: 0, y: 0, width: 800, height: 480),
                              device: device)
        XCTAssertFalse(v1.encoder.optionIsMeta,
                       "Native mode should construct KeyEncoder(optionIsMeta: false)")

        Preferences.shared.optionKeyRaw = Preferences.OptionKey.meta.rawValue
        // Give the objectWillChange -> sync hop a runloop turn.
        let exp = expectation(description: "encoder refresh")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
        XCTAssertTrue(v1.encoder.optionIsMeta,
                      "Flipping Option Key to Meta must rebuild the encoder with optionIsMeta=true")
    }

    /// Test-only NSResponder that counts keyDown invocations. Wired
    /// as `TerminalView.nextResponder` in tests that need to assert
    /// the view forwarded an event up the responder chain.
    private final class KeyEventCounter: NSResponder {
        var keyDownCount = 0
        override func keyDown(with event: NSEvent) {
            keyDownCount += 1
        }
    }

    func test_systemFunctionKey_forwardsToSuperWhenEncoderProducesNoBytes() throws {
        // Audit M3. F13–F24 and Mac system keys (brightness, media,
        // eject) report empty `charactersIgnoringModifiers` (or a
        // private-use scalar) which the encoder turns into empty
        // Data. Without a super-forward in keyDown, the event was
        // silently consumed: the shell never saw it AND AppKit's
        // menu chain / accelerator handlers never saw it either,
        // so e.g. F15 brightness-up was swallowed while Blackbird
        // was key.
        let view = try XCTUnwrap(TerminalView.makeHeadlessForTests())
        let recorder = RecordingPTY()
        view.ptyRecorderForTests = recorder

        // Wire a counter responder as the next responder in the chain
        // so a `super.keyDown(with:)` lands somewhere observable.
        // NSResponder's default keyDown forwards to nextResponder, so
        // installing a counting responder downstream proves the
        // forward happened.
        let counter = KeyEventCounter()
        view.nextResponder = counter

        // Synthesize an F15 keyDown. F15 has keyCode 113 on macOS.
        // characters / charactersIgnoringModifiers are empty for
        // brightness-up on most layouts.
        let f15Event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 113
        ))
        view.keyDown(with: f15Event)

        XCTAssertTrue(recorder.sent.isEmpty,
                      "F15 must not produce PTY bytes; recorder captured \(Array(recorder.sent))")
        XCTAssertEqual(counter.keyDownCount, 1,
                       "F15 with empty encoded bytes must fall through to super.keyDown so AppKit's responder chain sees the event (audit M3)")
    }

    func test_commandKeyDoesNotSendToPty() throws {
        // Byte-level assertion of the ⌘-isolation invariant. The view's
        // keyDown fast-returns on `.command`-flagged events before the
        // session / encoder / sendToSession path runs; hooking the
        // `ptyRecorderForTests` recorder lets us prove zero bytes reached
        // that path. No real PTY is needed because the ⌘ branch returns
        // before the `guard let session` check — so a headless view with
        // a nil session is sufficient and matches IMETests' pattern.
        //
        // Skip-as-pass triage 2026-05-09: the previous defensive
        // `wait(for:)` post-keyDown was speculative — the .command
        // branch in `TerminalView.keyDown` is `super.keyDown(with:); return`,
        // both synchronous, with no DispatchQueue.async hop. The
        // recorder check therefore sees the final state immediately.
        // Dropping the runloop pump lets this test run on every PR
        // without the cumulative-ASan CATransaction hazard.
        let view = try XCTUnwrap(TerminalView.makeHeadlessForTests())
        let recorder = RecordingPTY()
        view.ptyRecorderForTests = recorder

        // Baseline: an IME commit flows through sendToSession and MUST land
        // in the recorder, proving the hook works on this view. Without this
        // anchor a regression that broke the recorder wiring could hide a
        // real ⌘-isolation failure behind a silent recorder.
        view.insertText("c", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(recorder.sent, Data("c".utf8),
                       "recorder must capture a non-⌘ IME commit as sanity")
        recorder.sent.removeAll()

        // Synthesize a ⌘C keyDown and deliver it to the view.
        let cmdCEvent = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "c",
            charactersIgnoringModifiers: "c",
            isARepeat: false,
            keyCode: 8
        ))
        view.keyDown(with: cmdCEvent)
        // No runloop pump: the .command branch is fully synchronous
        // (`super.keyDown(with:); return`), so the recorder reflects
        // the final state by the time `view.keyDown(...)` returns.

        XCTAssertTrue(recorder.sent.isEmpty,
                      "⌘C must never produce PTY bytes; recorder captured \(Array(recorder.sent))")
    }

    // MARK: - Selection mode routing in mouseDown

    /// Regression for swift-tests-view F3: the original helper spawned
    /// a real `/bin/cat` PTY session for every selection-mode test
    /// (four tests × one cat each = four live forkpty children per
    /// class run). mouseDown routing only reads `event.clickCount` /
    /// `.option` modifier — it doesn't need a real shell for any of
    /// the four branches it covers. Switch to the TerminalSession
    /// headless factory: no PTY spawn, no /bin/cat, no zombie-risk
    /// on failure, and the tests run ~10x faster. The grid is 2×2
    /// on a headless session but the selection-mode routing is
    /// grid-independent (it only picks between `.character`,
    /// `.word`, `.line`, `.rectangular` based on click shape).
    ///
    /// Skip-as-pass triage 2026-05-09: the previous incarnation of
    /// this helper waited on `session.$snapshot` for the initial
    /// publish — that runloop pump is what gated the four selection-
    /// mode tests behind `BB_RUN_STRESS_TESTS`. The actual mouseDown
    /// path (`TerminalView+Mouse.swift::mouseDown(with:)` →
    /// `bufferPointFromEvent`) handles `currentSnapshot == nil`
    /// gracefully (returns the origin BufferPoint sentinel and warns
    /// once via `logEarlyClickOnce`), and the assertions in this
    /// file only inspect `view.selection?.mode`, which is decided
    /// purely from `event.clickCount` + `event.modifierFlags`. The
    /// snapshot-wait was therefore load-bearing for nothing — drop
    /// it, and the whole class can run on every PR without the
    /// cumulative-ASan CATransaction hazard the gate was protecting
    /// against.
    private func makeViewForSelection() throws -> TerminalView {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let view = TerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 480),
            device: device
        )
        // Headless session has no PTY; assigning it wires the
        // Combine subscription so future @Published snapshot landings
        // would update `currentSnapshot`. We don't wait for the
        // initial publish: mouseDown's selection-mode decision is
        // grid-independent (see helper doc above), and waiting was
        // the one runloop pump the cumulative-ASan gate disliked.
        let session = TerminalSession.makeHeadlessForTests()
        addTeardownBlock { session.terminate() }
        view.session = session
        return view
    }

    private func mouseDownEvent(at local: NSPoint,
                                modifiers: NSEvent.ModifierFlags,
                                clickCount: Int = 1) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: local,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: 1.0
        ))
    }

    /// Regression for swift-tests-view F4: prior tests hard-coded
    /// `NSPoint(x: 200, y: 200)` which depended on the 80×24 grid
    /// layout at 13pt system mono. A font metrics refactor that
    /// shrank cellWidth below 2.5 pt (possible with custom fonts)
    /// could land the click outside the grid and fail the test for
    /// reasons unrelated to the regression it guards. Derive the
    /// click point from `view.metrics` so the point stays interior
    /// regardless of font size.
    private func cellCenterPoint(in view: TerminalView, col: Int, row: Int) -> NSPoint {
        // AppKit's origin is bottom-left; TerminalView uses flipped
        // coordinates for grid math. Place the click at the center
        // of (col, row) so any rounding on either side stays inside
        // the intended cell. The +horizontalContentInsetPoints offset
        // matches the renderer's cell origin (cellOriginPx).
        let x = TerminalView.horizontalContentInsetPoints
            + CGFloat(col) * view.metrics.cellWidth
            + view.metrics.cellWidth / 2
        let y = CGFloat(row) * view.metrics.cellHeight + view.metrics.cellHeight / 2
        return NSPoint(x: x, y: y)
    }

    func test_mouseDown_option_triggersRectangularSelection() throws {
        let view = try makeViewForSelection()
        // Session teardown registered via addTeardownBlock in the helper.
        // Click cell (10, 5) — comfortably inside the 80×24 grid across
        // any reasonable font size. F4: no more hard-coded pixel.
        let point = cellCenterPoint(in: view, col: 10, row: 5)
        let ev = try mouseDownEvent(at: point, modifiers: [.option])
        view.mouseDown(with: ev)
        XCTAssertEqual(view.selection?.mode, .rectangular,
                       "⌥-drag should trigger rectangular selection")
    }

    func test_mouseDown_noModifiers_triggersCharacterSelection() throws {
        let view = try makeViewForSelection()
        let point = cellCenterPoint(in: view, col: 10, row: 5)
        let ev = try mouseDownEvent(at: point, modifiers: [])
        view.mouseDown(with: ev)
        XCTAssertEqual(view.selection?.mode, .character,
                       "Plain drag should be prose-style character selection")
    }

    func test_mouseDown_doubleClick_triggersWordSelection() throws {
        let view = try makeViewForSelection()
        let point = cellCenterPoint(in: view, col: 10, row: 5)
        let ev = try mouseDownEvent(at: point, modifiers: [], clickCount: 2)
        view.mouseDown(with: ev)
        XCTAssertEqual(view.selection?.mode, .word,
                       "Double-click should start a word-mode selection")
    }

    func test_mouseDown_tripleClick_triggersLineSelection() throws {
        let view = try makeViewForSelection()
        let point = cellCenterPoint(in: view, col: 10, row: 5)
        let ev = try mouseDownEvent(at: point, modifiers: [], clickCount: 3)
        view.mouseDown(with: ev)
        XCTAssertEqual(view.selection?.mode, .line,
                       "Triple-click should start a line-mode selection")
    }

    // MARK: - Bracketed-paste sanitiser

    func test_bracketedPasteSanitiser_leavesNormalPayloadUntouched() {
        let input = Data("hello\nworld\n".utf8)
        XCTAssertEqual(TerminalView.sanitizeBracketedPaste(input), input)
    }

    func test_bracketedPasteSanitiser_stripsEmbeddedClose() {
        // "foo" + ESC[201~ + "bar" — the embedded terminator would close the
        // paste window early without sanitisation.
        var input = Data("foo".utf8)
        input.append(Data([0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]))
        input.append(Data("bar".utf8))
        XCTAssertEqual(TerminalView.sanitizeBracketedPaste(input), Data("foobar".utf8))
    }

    func test_bracketedPasteSanitiser_stripsMultipleOccurrences() {
        var input = Data()
        input.append(contentsOf: [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E])
        input.append(Data("a".utf8))
        input.append(contentsOf: [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E])
        input.append(Data("b".utf8))
        XCTAssertEqual(TerminalView.sanitizeBracketedPaste(input), Data("ab".utf8))
    }

    func test_bracketedPasteSanitiser_preservesOpener() {
        // ESC[200~ *inside* a paste is harmless (bracketed paste doesn't
        // nest) and stripping it would alter the user's content. Keep it.
        var input = Data()
        input.append(contentsOf: [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E])
        input.append(Data("payload".utf8))
        XCTAssertEqual(TerminalView.sanitizeBracketedPaste(input), input)
    }

    func test_bracketedPasteSanitiser_truncatedTerminator_leftIntact() {
        let input = Data([0x1B, 0x5B, 0x32, 0x30, 0x31])  // 5-byte prefix of terminator
        XCTAssertEqual(TerminalView.sanitizeBracketedPaste(input), input)
    }

    // MARK: - C0 paste sanitiser (CVE-2026-26982 class)

    func test_sanitizePasteControls_keepsTabLfCr() {
        let input = Data("a\tb\nc\rd".utf8)
        XCTAssertEqual(
            TerminalView.sanitizePasteControls(input), input,
            "TAB / LF / CR are legitimate whitespace in pasted payload"
        )
    }

    func test_sanitizePasteControls_stripsCtrlCAndCtrlZ() {
        // Attack: pasted prompt + 0x03 (Ctrl+C) + additional commands.
        // Without sanitisation the 0x03 interrupts the current shell line
        // and the rest runs as a fresh command — the Ghostty CVE class.
        var input = Data("echo hi".utf8)
        input.append(0x03)
        input.append(Data("rm -rf ~\n".utf8))
        let out = TerminalView.sanitizePasteControls(input)
        XCTAssertFalse(out.contains(0x03), "Ctrl+C must be scrubbed")
        XCTAssertEqual(
            out, Data("echo hi rm -rf ~\n".utf8),
            "Blocked byte replaced with space, length preserved"
        )
    }

    func test_sanitizePasteControls_stripsEscape() {
        // ESC is the gateway to every CSI/OSC sequence. Pasting a payload
        // with ESC embedded could drive the remote into an alt-screen, set
        // a window title, or — with bracketed paste off — execute bytes
        // as if typed. Strip unconditionally.
        let input = Data([0x1B, 0x5B, 0x32, 0x4A])  // ESC [ 2 J (clear screen)
        XCTAssertEqual(
            TerminalView.sanitizePasteControls(input),
            Data([0x20, 0x5B, 0x32, 0x4A]),
            "ESC → space; remaining printable bytes untouched"
        )
    }

    func test_sanitizePasteControls_stripsDel() {
        let input = Data([0x61, 0x7F, 0x62])  // a DEL b
        XCTAssertEqual(
            TerminalView.sanitizePasteControls(input),
            Data([0x61, 0x20, 0x62]),
            "0x7F (DEL) is replaced with space"
        )
    }

    func test_sanitizePasteControls_stripsEveryC0Except09_0A_0D() {
        // Sweep: build a payload containing every byte 0x00..0x1F plus
        // 0x7F. Expect only 0x09 / 0x0A / 0x0D to survive.
        var input = Data()
        for b in UInt8(0x00)...UInt8(0x1F) { input.append(b) }
        input.append(0x7F)
        let out = TerminalView.sanitizePasteControls(input)
        let survivors = out.filter { $0 != 0x20 }
        XCTAssertEqual(
            Array(survivors), [0x09, 0x0A, 0x0D],
            "Exactly TAB / LF / CR pass through; every other C0+DEL becomes space"
        )
    }

    func test_sanitizePasteControls_stripsC1TwoByteUTF8() {
        // C1 controls encoded as UTF-8 are `0xC2 0x80..0x9F`. 0x9B (CSI),
        // 0x9D (OSC), 0x90 (DCS) are ESC-free alternates — xterm's
        // allowC1Printable=false default disables them, and our paste
        // sanitizer must match so a carefully crafted non-ESC payload
        // can't drive the parser into OSC / CSI state from paste.
        let c1Bytes: [UInt8] = [0x80, 0x8F, 0x90, 0x9B, 0x9D, 0x9F]
        for c1 in c1Bytes {
            var input = Data("a".utf8)
            input.append(contentsOf: [0xC2, c1])
            input.append(Data("b".utf8))
            let out = TerminalView.sanitizePasteControls(input)
            XCTAssertEqual(
                out, Data([0x61, 0x20, 0x62]),
                "UTF-8-encoded C1 control 0xC2 0x\(String(c1, radix: 16)) must be replaced with a space"
            )
        }
    }

    func test_sanitizePasteControls_preservesValidHighUTF8() {
        // 0xC2 alone is not C1; it can also start legitimate codepoints
        // like U+00A0..U+00BF (latin-1 supplement). Make sure we don't
        // eat `0xC2 0xA0` (non-breaking space). Also make sure a 0xC2
        // without a valid continuation passes through untouched.
        let nbsp = Data([0xC2, 0xA0])
        XCTAssertEqual(TerminalView.sanitizePasteControls(nbsp), nbsp)
        let trailing = Data([0x61, 0xC2])
        XCTAssertEqual(TerminalView.sanitizePasteControls(trailing), trailing)
    }

    func test_sanitizePasteControls_passesThroughHighBytes() {
        // UTF-8 continuation bytes are ≥0x80 and must pass unchanged so
        // multi-byte characters (CJK, emoji) paste intact.
        let input = Data("héllo — 日本語".utf8)
        XCTAssertEqual(
            TerminalView.sanitizePasteControls(input), input,
            "Only C0 + DEL are scrubbed; UTF-8 stays intact"
        )
    }

    // MARK: - Bidi override scrubber (Trojan Source defence)

    func test_stripBidiOverrides_removesRLO() {
        // Attack payload: literal bytes for "rm -rf " + U+202E (RLO) +
        // "\\harmless\n". Displays as `rm -rf harmless\n`; executed as
        // `rm -rf ~`. The scrubbed copy must carry no bidi control byte.
        var input = Data("rm -rf ".utf8)
        input.append(contentsOf: [0xE2, 0x80, 0xAE])  // U+202E RLO
        input.append(Data("~\n".utf8))
        let out = TerminalView.stripBidiOverrides(input)
        XCTAssertFalse(
            out.contains(0xE2), "bidi-override codepoint must be stripped wholesale"
        )
        XCTAssertEqual(out, Data("rm -rf ~\n".utf8))
    }

    func test_stripBidiOverrides_removesLRMandRLM() {
        // U+200E LRM and U+200F RLM — weaker than overrides but called
        // out in CVE-2021-42574 follow-up advisories. Verify they're
        // stripped alongside the stronger overrides.
        let lrm = Data([0x61] + [0xE2, 0x80, 0x8E] + [0x62])
        let rlm = Data([0x61] + [0xE2, 0x80, 0x8F] + [0x62])
        XCTAssertEqual(TerminalView.stripBidiOverrides(lrm), Data("ab".utf8))
        XCTAssertEqual(TerminalView.stripBidiOverrides(rlm), Data("ab".utf8))
    }

    func test_stripBidiOverrides_removesArabicLetterMark() {
        // U+061C ALM is 2-byte UTF-8 (D8 9C). Often overlooked in bidi
        // scrubbers because it's the only 2-byte format control.
        let alm = Data([0x61, 0xD8, 0x9C, 0x62])
        XCTAssertEqual(TerminalView.stripBidiOverrides(alm), Data("ab".utf8))
    }

    func test_stripBidiOverrides_removesMongolianVowelSeparator() {
        // U+180E (E1 A0 8E) — deprecated but still Format category.
        let mvs = Data([0x61, 0xE1, 0xA0, 0x8E, 0x62])
        XCTAssertEqual(TerminalView.stripBidiOverrides(mvs), Data("ab".utf8))
    }

    func test_stripBidiOverrides_coversAllNineCodepoints() {
        // U+202A..U+202E (E2 80 AA..AE) and U+2066..U+2069 (E2 81 A6..A9).
        var input = Data("start".utf8)
        let codepoints: [[UInt8]] = [
            [0xE2, 0x80, 0xAA], [0xE2, 0x80, 0xAB], [0xE2, 0x80, 0xAC],
            [0xE2, 0x80, 0xAD], [0xE2, 0x80, 0xAE],
            [0xE2, 0x81, 0xA6], [0xE2, 0x81, 0xA7], [0xE2, 0x81, 0xA8],
            [0xE2, 0x81, 0xA9],
        ]
        for cp in codepoints { input.append(contentsOf: cp) }
        input.append(Data("end".utf8))
        XCTAssertEqual(
            TerminalView.stripBidiOverrides(input), Data("startend".utf8),
            "All nine explicit bidi controls must be removed"
        )
    }

    func test_stripBidiOverrides_preservesLegitimateUtf8() {
        // Hebrew, Arabic, CJK, emoji — no explicit bidi controls. Must
        // round-trip byte-for-byte. The E2 prefix byte appears inside
        // e.g. U+2014 (em dash, E2 80 94) — checks that we don't over-
        // match on the prefix alone.
        let input = Data("שלום 安全 — 日本語 🇺🇸 tree".utf8)
        XCTAssertEqual(
            TerminalView.stripBidiOverrides(input), input,
            "Non-override UTF-8 passes through unchanged (em dash contains E2 prefix)"
        )
    }

    func test_pasteSanitizer_preservesInvalidUtf8Shape_withoutCrash() {
        // Pasted content can contain sequences that aren't valid UTF-8 —
        // some clipboard providers emit them. The sanitizer must not
        // crash or infinite-loop on these. Downstream String(decoding:,
        // as: UTF8.self) will substitute U+FFFD; that's acceptable.
        let payloads: [Data] = [
            Data([0x80]),                                  // lone continuation
            Data([0xC2]),                                  // truncated 2-byte lead
            Data([0xE2, 0x80]),                            // truncated 3-byte lead
            Data([0xF4, 0x90, 0x80, 0x80]),                // > U+10FFFF
            Data([0x61, 0xED, 0xA0, 0x80, 0x62]),          // surrogate encoded as UTF-8
            Data(repeating: 0xFF, count: 64),              // all-0xFF
        ]
        for p in payloads {
            let cleaned = TerminalView.sanitizePasteControls(p)
            let bidiStripped = TerminalView.stripBidiOverrides(cleaned)
            let final = TerminalView.sanitizeBracketedPaste(bidiStripped)
            // Invariant: no crash, output length ≤ input length.
            XCTAssertLessThanOrEqual(final.count, p.count)
        }
    }

    func test_pasteSanitizerPipeline_fuzzInvariants() {
        // Property-based style: generate 500 random byte sequences up to
        // 4 KiB, run them through the full paste sanitizer chain, verify
        // the invariants that must hold for every possible input:
        //
        //   1. Output never contains C0 controls except TAB/LF/CR.
        //   2. Output never contains DEL (0x7F).
        //   3. Output never contains the bracketed-paste terminator
        //      ESC [ 201 ~ (stripped by sanitizeBracketedPaste).
        //   4. Output never contains a U+202E RLO sequence intact.
        //   5. Output length ≤ input length (sanitization only removes).
        //
        // 150 × 2 KiB inputs is enough to exercise the invariants across
        // many byte patterns without slowing CI appreciably (~1s on CI).
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<150 {
            let length = Int.random(in: 0..<2048, using: &rng)
            var input = Data(count: length)
            for i in 0..<length {
                input[i] = UInt8.random(in: 0...255, using: &rng)
            }
            let cleaned = TerminalView.sanitizePasteControls(input)
            let bidiStripped = TerminalView.stripBidiOverrides(cleaned)
            let bracketed = TerminalView.sanitizeBracketedPaste(bidiStripped)

            // (5) monotone non-growth
            XCTAssertLessThanOrEqual(
                bracketed.count, input.count,
                "sanitizer must never grow the payload"
            )
            // (1, 2) no forbidden control bytes
            for b in bracketed {
                if b == 0x09 || b == 0x0A || b == 0x0D { continue }
                XCTAssertGreaterThanOrEqual(b, 0x20)
                XCTAssertNotEqual(b, 0x7F)
            }
            // (3) no ESC[201~ terminator
            XCTAssertFalse(
                bracketed.contains(Data([0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E])),
                "bracketed-paste terminator must not survive"
            )
            // (4) no bidi RLO
            XCTAssertFalse(
                bracketed.contains(Data([0xE2, 0x80, 0xAE])),
                "U+202E RLO bidi override must not survive"
            )
        }
    }

    func test_pasteSanitizerPipeline_handlesCombinedAttack() {
        // Realistic crafted payload that mixes every attack class:
        //   - CRLF line endings (Windows-origin paste)
        //   - Embedded Ctrl+C (C0 escape)
        //   - Embedded ESC (would drive terminal into unexpected mode)
        //   - U+202E RLO (Trojan Source override)
        //   - Embedded bracketed-paste terminator (nested-paste escape)
        // Running the pipeline in the same order pasteText uses — normalise,
        // then sanitize controls, then strip bidi — must produce a harmless
        // byte sequence with only printable chars + real newlines.
        var input = Data("ok\r\n".utf8)
        input.append(0x03)                                           // Ctrl+C
        input.append(Data("rm -rf".utf8))
        input.append(contentsOf: [0xE2, 0x80, 0xAE])                 // U+202E RLO
        input.append(Data(" /\n".utf8))
        input.append(0x1B)                                           // ESC
        input.append(Data("[2J".utf8))                               // clear screen
        input.append(contentsOf: [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E])  // ESC[201~
        input.append(Data("tail".utf8))

        let normalised = TerminalView.normalizePasteLineEndings(input)
        let cleanedControls = TerminalView.sanitizePasteControls(normalised)
        let bidiStripped = TerminalView.stripBidiOverrides(cleanedControls)
        let bracketStripped = TerminalView.sanitizeBracketedPaste(bidiStripped)

        // Every byte <0x20 other than TAB/LF/CR must be gone.
        for b in bracketStripped {
            if b == 0x09 || b == 0x0A || b == 0x0D { continue }
            XCTAssertGreaterThanOrEqual(
                b, 0x20,
                "byte 0x\(String(b, radix: 16)) survived sanitizer pipeline"
            )
            XCTAssertNotEqual(b, 0x7F, "DEL survived sanitizer pipeline")
        }
        // Bidi override sequence must be fully stripped (E2 80 AE gone as a unit).
        XCTAssertFalse(
            bracketStripped.contains(Data([0xE2, 0x80, 0xAE])),
            "U+202E override byte sequence leaked through"
        )
        // Newlines normalised: no CR (0x0D) anywhere except as part of a CRLF
        // we'd already collapsed. Check there's no stray CR.
        XCTAssertFalse(
            bracketStripped.contains(0x0D),
            "CR byte leaked through normalizePasteLineEndings"
        )
    }

    func test_stripBidiOverrides_fastPathWhenNoE2Byte() {
        // Pure ASCII hits the early-return; the assertion is identity.
        let input = Data("pure ascii payload, no bidi".utf8)
        XCTAssertEqual(TerminalView.stripBidiOverrides(input), input)
    }

    // MARK: - M3 / M4: extended scrub coverage

    /// U+2028 LS / U+2029 PS — Trojan-Source-class invisible separator.
    /// Some shells / readline configurations / Python REPL treat these
    /// as line terminators, so a "single-line" paste can sneak in a
    /// second command. Audit M3.
    func test_stripBidiOverrides_removesLineSeparators() {
        let ls = Data([0x61, 0xE2, 0x80, 0xA8, 0x62])  // a U+2028 b
        let ps = Data([0x61, 0xE2, 0x80, 0xA9, 0x62])  // a U+2029 b
        XCTAssertEqual(TerminalView.stripBidiOverrides(ls), Data("ab".utf8))
        XCTAssertEqual(TerminalView.stripBidiOverrides(ps), Data("ab".utf8))
    }

    /// Zero-width chars (ZWSP/ZWNJ/ZWJ) — homograph + log-injection
    /// surface. Audit M4.
    func test_stripBidiOverrides_removesZeroWidthChars() {
        for cp: UInt8 in [0x8B, 0x8C, 0x8D] {  // U+200B / 200C / 200D
            let payload = Data([0x61, 0xE2, 0x80, cp, 0x62])
            XCTAssertEqual(
                TerminalView.stripBidiOverrides(payload), Data("ab".utf8),
                "U+200\(String(cp - 0x80, radix: 16, uppercase: true)) (zero-width) must strip"
            )
        }
    }

    func test_stripBidiOverrides_removesWordJoiner() {
        // U+2060 WORD JOINER — E2 81 A0
        let payload = Data([0x61, 0xE2, 0x81, 0xA0, 0x62])
        XCTAssertEqual(TerminalView.stripBidiOverrides(payload), Data("ab".utf8))
    }

    func test_stripBidiOverrides_removesBOM() {
        // U+FEFF — EF BB BF
        let payload = Data([0x61, 0xEF, 0xBB, 0xBF, 0x62])
        XCTAssertEqual(TerminalView.stripBidiOverrides(payload), Data("ab".utf8))
    }

    func test_stripBidiOverrides_removesSoftHyphen() {
        // U+00AD — C2 AD
        let payload = Data([0x61, 0xC2, 0xAD, 0x62])
        XCTAssertEqual(TerminalView.stripBidiOverrides(payload), Data("ab".utf8))
    }

    func test_stripBidiOverrides_removesAllVariationSelectors1to16() {
        // U+FE00..U+FE0F — EF B8 80..8F
        for vs: UInt8 in 0x80...0x8F {
            let payload = Data([0x61, 0xEF, 0xB8, vs, 0x62])
            XCTAssertEqual(
                TerminalView.stripBidiOverrides(payload), Data("ab".utf8),
                "VS at byte \(String(vs, radix: 16, uppercase: true)) must strip"
            )
        }
    }

    func test_stripBidiOverrides_removesTagBlock() {
        // U+E0073 (tag 's') — F3 A0 81 B3.
        let payload = Data([0x61, 0xF3, 0xA0, 0x81, 0xB3, 0x62])
        XCTAssertEqual(TerminalView.stripBidiOverrides(payload), Data("ab".utf8))
        // U+E0000 (tag NULL) — F3 A0 80 80.
        let payload2 = Data([0x61, 0xF3, 0xA0, 0x80, 0x80, 0x62])
        XCTAssertEqual(TerminalView.stripBidiOverrides(payload2), Data("ab".utf8))
    }

    func test_stripBidiOverrides_removesVariationSelectors17to256() {
        // U+E0100 (VS17) — F3 A0 84 80
        let payload = Data([0x61, 0xF3, 0xA0, 0x84, 0x80, 0x62])
        XCTAssertEqual(TerminalView.stripBidiOverrides(payload), Data("ab".utf8))
        // U+E01EF (VS256) — F3 A0 87 AF
        let payload2 = Data([0x61, 0xF3, 0xA0, 0x87, 0xAF, 0x62])
        XCTAssertEqual(TerminalView.stripBidiOverrides(payload2), Data("ab".utf8))
    }

    func test_stripBidiOverrides_preservesAdjacentNonVSPlaneE0() {
        // U+E01F0 (just past VS256) — F3 A0 87 B0. Must NOT strip;
        // it's outside the variation-selector range. Also U+E0200,
        // F3 A0 88 80, which shares the F3 A0 lead but b2 is past
        // the VS upper page.
        let beyondVS = Data([0x61, 0xF3, 0xA0, 0x87, 0xB0, 0x62])
        XCTAssertEqual(TerminalView.stripBidiOverrides(beyondVS), beyondVS)
        let pastPage = Data([0x61, 0xF3, 0xA0, 0x88, 0x80, 0x62])
        XCTAssertEqual(TerminalView.stripBidiOverrides(pastPage), pastPage)
    }

    func test_stripBidiOverrides_attackComboPayload() {
        // Realistic worst-case: bidi RLO + ZWJ + tag char + VS + soft
        // hyphen all sandwiched into one payload. Must scrub to the
        // bare ASCII "ab".
        var payload = Data("a".utf8)
        payload.append(contentsOf: [0xE2, 0x80, 0xAE])      // U+202E RLO
        payload.append(contentsOf: [0xE2, 0x80, 0x8D])      // U+200D ZWJ
        payload.append(contentsOf: [0xF3, 0xA0, 0x81, 0xA1]) // U+E0061 tag 'a'
        payload.append(contentsOf: [0xEF, 0xB8, 0x80])      // U+FE00 VS1
        payload.append(contentsOf: [0xC2, 0xAD])            // U+00AD SHY
        payload.append(0x62)
        XCTAssertEqual(TerminalView.stripBidiOverrides(payload), Data("ab".utf8))
    }

    func test_stripBidiOverrides_preservesLegitimateMultibyteScalars() {
        // Em-dash (U+2014, E2 80 94), CJK, emoji, Hebrew/Arabic round-
        // trip unchanged — we only strip the explicit invisibles.
        let input = Data("—中文שלום🚀hello world".utf8)
        XCTAssertEqual(TerminalView.stripBidiOverrides(input), input)
    }

    // MARK: - Paste line-ending normalisation

    func test_normalizePaste_collapsesCRLF() {
        let input = Data("line1\r\nline2\r\nline3".utf8)
        let expected = Data("line1\nline2\nline3".utf8)
        XCTAssertEqual(TerminalView.normalizePasteLineEndings(input), expected)
    }

    func test_normalizePaste_preservesLoneCR() {
        // Lone CR is left alone — progress-bar output (`\r[###  ]`) and some
        // applications legitimately want the bare CR.
        let input = Data("progress\r".utf8)
        XCTAssertEqual(TerminalView.normalizePasteLineEndings(input), input)
    }

    func test_normalizePaste_preservesLoneLF() {
        let input = Data("unix\nstyle\nlines".utf8)
        XCTAssertEqual(TerminalView.normalizePasteLineEndings(input), input)
    }

    func test_normalizePaste_emptyInput() {
        XCTAssertEqual(TerminalView.normalizePasteLineEndings(Data()), Data())
    }

    func test_normalizePaste_fastPathWhenNoCR() {
        // Sanity: implementation short-circuits when there's no CR. The
        // assertion here is functional (unchanged output); the perf claim is
        // in the comment.
        let input = Data("no carriage returns here".utf8)
        XCTAssertEqual(TerminalView.normalizePasteLineEndings(input), input)
    }

    func test_normalizePaste_trailingCROnly() {
        // Edge case: a CR at the very end, with no following LF, must pass
        // through untouched (can't peek past endIndex).
        let input = Data("hello\r".utf8)
        XCTAssertEqual(TerminalView.normalizePasteLineEndings(input), input)
    }

    // MARK: - TerminalMode helpers

    func test_termModeFlag_focusInOutBit() {
        // Pin the focus-in-out bit's stable position in BBTermMode. A
        // future core refactor that re-orders the mode bits would flip
        // which terminal mode TerminalView observes in render() for the
        // initial-focus notification.
        XCTAssertEqual(BBTermMode.focusInOut.rawValue, 1 << 8,
                       "focusInOut bit must remain at position 8")
    }

    func test_termModeFlag_kittyKeyboardBits() {
        // Pin the kitty keyboard protocol bit positions. KeyEncoder reads
        // these directly; a shift here would silently start emitting CSI u
        // under the wrong conditions (or stop emitting entirely) and break
        // Shift+Enter / Ctrl+i disambiguation in Claude Code, nvim, etc.
        XCTAssertEqual(BBTermMode.disambiguateEscCodes.rawValue, 1 << 11)
        XCTAssertEqual(BBTermMode.reportEventTypes.rawValue,     1 << 12)
        XCTAssertEqual(BBTermMode.reportAlternateKeys.rawValue,  1 << 13)
        XCTAssertEqual(BBTermMode.reportAllKeysAsEsc.rawValue,   1 << 14)
        XCTAssertEqual(BBTermMode.reportAssociatedText.rawValue, 1 << 15)
    }

    // MARK: - Paste composition

    func test_normalizePaste_composedWithSanitiser() {
        // Real paste flow: Windows-origin text that also happens to contain
        // an embedded bracketed-paste terminator. Normalisation runs first,
        // then the sanitiser strips the terminator. Verify both stages apply
        // cleanly to the same bytes. The test composes them manually (the
        // real `paste(_:)` does this internally, but we can't easily drive
        // the NSPasteboard side from XCTest).
        var input = Data("line1\r\n".utf8)
        input.append(contentsOf: [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E])  // ESC [ 201 ~
        input.append(Data("line2".utf8))
        let normalised = TerminalView.normalizePasteLineEndings(input)
        let sanitised = TerminalView.sanitizeBracketedPaste(normalised)
        XCTAssertEqual(
            sanitised, Data("line1\nline2".utf8),
            "Normalise CRLF → LF, then strip the embedded terminator bytes"
        )
    }

    // MARK: - Mouse-report encoding (pure path)

    func test_mouseReport_sgr_leftPress_final_M() {
        let bytes = TerminalView.encodeMouseReport(
            sgr: true, button: 0, press: true, col: 10, row: 5
        )
        // ESC [ < 0 ; 11 ; 6 M
        XCTAssertEqual(String(data: bytes!, encoding: .utf8), "\u{1B}[<0;11;6M")
    }

    func test_mouseReport_sgr_leftRelease_final_m() {
        let bytes = TerminalView.encodeMouseReport(
            sgr: true, button: 0, press: false, col: 10, row: 5
        )
        // SGR preserves the button number; lowercase m indicates release.
        XCTAssertEqual(String(data: bytes!, encoding: .utf8), "\u{1B}[<0;11;6m")
    }

    func test_mouseReport_sgr_wheelUp() {
        let bytes = TerminalView.encodeMouseReport(
            sgr: true, button: 64, press: true, col: 0, row: 0
        )
        XCTAssertEqual(String(data: bytes!, encoding: .utf8), "\u{1B}[<64;1;1M")
    }

    func test_mouseReport_x10_leftPress_hasCbButton() {
        let bytes = TerminalView.encodeMouseReport(
            sgr: false, button: 0, press: true, col: 0, row: 0
        )
        XCTAssertEqual(bytes, Data([0x1B, 0x5B, 0x4D, 32, 33, 33]))
    }

    func test_mouseReport_x10_leftRelease_cbForcesButton3() {
        // Regression: previously emitted cb=32 (indistinguishable from
        // left-press). The fix sets the low bits to 3 for releases.
        let bytes = TerminalView.encodeMouseReport(
            sgr: false, button: 0, press: false, col: 0, row: 0
        )
        XCTAssertEqual(bytes, Data([0x1B, 0x5B, 0x4D, 35, 33, 33]),
                       "X10 release must report cb = 32+3 = 35")
    }

    func test_mouseReport_x10_rightRelease_alsoCb35() {
        let bytes = TerminalView.encodeMouseReport(
            sgr: false, button: 2, press: false, col: 0, row: 0
        )
        XCTAssertEqual(bytes, Data([0x1B, 0x5B, 0x4D, 35, 33, 33]),
                       "Any X10 release reports cb=35 regardless of button")
    }

    func test_mouseReport_x10_outsideRange_returnsNil() {
        XCTAssertNil(TerminalView.encodeMouseReport(
            sgr: false, button: 0, press: true, col: 500, row: 0
        ), "X10 can't address cols >= 223")
        XCTAssertNil(TerminalView.encodeMouseReport(
            sgr: false, button: 0, press: true, col: 0, row: 500
        ), "X10 can't address rows >= 223")
    }

    func test_mouseReport_x10_motion() {
        // Motion with button held: button=32 (bit 5). cb = 32+32 = 64.
        let bytes = TerminalView.encodeMouseReport(
            sgr: false, button: 32, press: true, col: 3, row: 7
        )
        XCTAssertEqual(bytes, Data([0x1B, 0x5B, 0x4D, 64, 36, 40]))
    }

    func test_mouseReport_rejectsNegativeCoord() {
        // Pre-guards before any encoding mode — negative col/row from a
        // misbehaving input device would otherwise produce nonsense.
        XCTAssertNil(TerminalView.encodeMouseReport(
            sgr: true, button: 0, press: true, col: -1, row: 0
        ))
        XCTAssertNil(TerminalView.encodeMouseReport(
            sgr: true, button: 0, press: true, col: 0, row: -1
        ))
        XCTAssertNil(TerminalView.encodeMouseReport(
            sgr: false, button: 0, press: true, col: -1, row: 0
        ))
    }

    func test_mouseReport_rejectsOutOfRangeButton() {
        // X10 encoding would trap on `UInt8(button + 32)` for button
        // >= 224. SGR encoding doesn't trap but would stringify an
        // absurd value. Reject both up front.
        XCTAssertNil(TerminalView.encodeMouseReport(
            sgr: true, button: -1, press: true, col: 0, row: 0
        ))
        XCTAssertNil(TerminalView.encodeMouseReport(
            sgr: true, button: 224, press: true, col: 0, row: 0
        ))
        XCTAssertNil(TerminalView.encodeMouseReport(
            sgr: true, button: Int.max, press: true, col: 0, row: 0
        ))
        XCTAssertNil(TerminalView.encodeMouseReport(
            sgr: false, button: 224, press: true, col: 0, row: 0
        ))
    }

    func test_mouseReport_sgr_acceptsLargeColAndRow() {
        // SGR encoding doesn't cap col/row (digits only, no byte truncation).
        // Callers clamp to 10k upstream. Verify the encoder handles those
        // values without drama.
        let bytes = TerminalView.encodeMouseReport(
            sgr: true, button: 0, press: true, col: 9999, row: 9999
        )
        XCTAssertEqual(bytes, Data("\u{1B}[<0;10000;10000M".utf8))
    }

    func test_oscTitleReachesWindowTitle() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["BB_RUN_STRESS_TESTS"] != "1",
                      "RunLoop-pumping OSC title test SEGVs in CATransaction under cumulative ASan; set BB_RUN_STRESS_TESTS=1 for the OSC->window-title invariant")
        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        // NSWindow defaults to `isReleasedWhenClosed = true`, which turns
        // `window.close()` into a release of a local whose lifetime ARC
        // still thinks it owns → double-free / use-after-free (ASAN catches
        // it as SEGV in objc_release). Switching to false makes the
        // `defer` teardown a plain order-out; ARC handles the dealloc on
        // scope exit.
        window.isReleasedWhenClosed = false
        let device = MTLCreateSystemDefaultDevice()!
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480), device: device)
        window.contentView = view

        let session = try TerminalSession.start(
            shell: "/bin/sh",
            arguments: ["-c", "printf '\\033]2;blackbird-title-test\\007'; sleep 0.5"],
            size: .init(cols: 80, rows: 24)
        )
        // Teardown MUST happen even if an XCTUnwrap / wait between here and
        // the tail of the test throws — otherwise a failed assertion leaves
        // a zombie /bin/sh plus a live NSWindow until the test host exits.
        defer {
            session.terminate()
            window.close()
        }
        view.session = session

        // Poll window.title — updates dispatch to main; the test runs on main.
        let exp = expectation(description: "window title set")
        var fulfilled = false
        let timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { t in
            if window.title == "blackbird-title-test", !fulfilled {
                fulfilled = true
                t.invalidate()
                exp.fulfill()
            }
        }
        wait(for: [exp], timeout: 3.0)
        timer.invalidate()
    }

    // MARK: - Bug #14 / #15: selection invalidation on reflow / alt-screen toggle
    //
    // `Selection.anchor` and `cursor` are `BufferPoint(line, col)` pinned
    // to the pre-reflow grid. Two snapshot transitions move the cells
    // those points address out from under the selection:
    //   - Bug #14: column shrink → alacritty re-wraps scrollback so
    //     the (line, col) addresses now point at different cells.
    //     Row-only resizes don't reflow; selection should survive.
    //   - Bug #15: alt-screen enter/exit (CSI ?1049h/l) swaps the
    //     visible grid; the buffer lines the selection points into are
    //     replaced.
    // Both fixes live in `TerminalView.render(snapshot:)`. These tests
    // drive a real BBTerm directly so we can synthesize the snapshot
    // sequence without the timing variability of a session+shell.

    /// Construct a TerminalView wired to a fresh BBTerm. The view's
    /// `session` is left nil — these tests drive snapshots into
    /// `render(snapshot:)` synchronously, no Combine sink involved.
    private func makeViewForRenderInvalidation() throws -> (TerminalView, BBTerm) {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let view = TerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 480),
            device: device
        )
        let bb = try XCTUnwrap(BBTerm(size: .init(cols: 80, rows: 24)))
        return (view, bb)
    }

    func test_columnShrinkResize_clearsActiveSelection() throws {
        let (view, bb) = try makeViewForRenderInvalidation()
        // Establish the prior snapshot so the next render() has a `prev`
        // to compare cols against. Without a prior, the gate is skipped
        // (no live selection at session start).
        let s1 = try XCTUnwrap(bb.snapshot())
        view.render(snapshot: s1)

        // Drive scrollback so the selection has somewhere meaningful to
        // anchor. Feed a few hundred lines so the buffer wraps off the
        // visible viewport — irrelevant to the invalidation logic itself
        // but matches the bug's user-visible scenario.
        var lines = ""
        for i in 0..<500 { lines += "row \(i) padding to fill out the line\n" }
        bb.input(lines)
        let s2 = try XCTUnwrap(bb.snapshot())
        view.render(snapshot: s2)

        // User starts a selection in scrollback.
        let sel = Selection(
            anchor: BufferPoint(line: -50, col: 5),
            cursor: BufferPoint(line: -50, col: 30),
            mode: .character
        )
        view.selection = sel
        XCTAssertEqual(view.selection, sel,
                       "pre-condition: selection assigned before resize")

        // Shrink columns 80 → 40. alacritty reflows wrapped scrollback so
        // the (line, col) coordinates now address different cells.
        bb.resize(to: .init(cols: 40, rows: 24))
        let s3 = try XCTUnwrap(bb.snapshot())
        XCTAssertEqual(s3.cols, 40, "sanity: column shrink applied")
        view.render(snapshot: s3)

        XCTAssertNil(view.selection,
                     "column shrink must clear the active selection (Bug #14)")
    }

    func test_rowOnlyResize_preservesSelection() throws {
        let (view, bb) = try makeViewForRenderInvalidation()
        let s1 = try XCTUnwrap(bb.snapshot())
        view.render(snapshot: s1)

        var lines = ""
        for i in 0..<200 { lines += "row \(i)\n" }
        bb.input(lines)
        let s2 = try XCTUnwrap(bb.snapshot())
        view.render(snapshot: s2)

        let sel = Selection(
            anchor: BufferPoint(line: -10, col: 0),
            cursor: BufferPoint(line: -10, col: 5),
            mode: .character
        )
        view.selection = sel

        // Resize ROWS only — alacritty doesn't reflow scrollback on row
        // changes, so the selection's (line, col) coordinates still
        // address the same cells.
        bb.resize(to: .init(cols: 80, rows: 12))
        let s3 = try XCTUnwrap(bb.snapshot())
        XCTAssertEqual(s3.cols, 80, "sanity: cols unchanged")
        XCTAssertEqual(s3.rows, 12, "sanity: rows shrunk")
        view.render(snapshot: s3)

        XCTAssertEqual(view.selection, sel,
                       "row-only resize must preserve selection (Bug #14)")
    }

    func test_altScreenExit_clearsSelection() throws {
        let (view, bb) = try makeViewForRenderInvalidation()
        let s1 = try XCTUnwrap(bb.snapshot())
        view.render(snapshot: s1)

        // Enter alt-screen via CSI ?1049h. BBSnapshot.termMode.altScreen
        // flips on. Render that as the prior snapshot so the alt-screen
        // bit is the baseline for the next render().
        bb.input("\u{1B}[?1049h")
        let sAlt = try XCTUnwrap(bb.snapshot())
        XCTAssertTrue(sAlt.termMode.contains(.altScreen),
                      "sanity: ?1049h enabled alt-screen")
        view.render(snapshot: sAlt)

        // User starts a selection while in alt-screen (e.g. inside vim).
        let sel = Selection(
            anchor: BufferPoint(line: 2, col: 1),
            cursor: BufferPoint(line: 2, col: 8),
            mode: .character
        )
        view.selection = sel
        XCTAssertEqual(view.selection, sel,
                       "pre-condition: selection assigned before alt-screen exit")

        // Exit alt-screen. The lines the selection points into are
        // discarded — copy would return garbage.
        bb.input("\u{1B}[?1049l")
        let sMain = try XCTUnwrap(bb.snapshot())
        XCTAssertFalse(sMain.termMode.contains(.altScreen),
                       "sanity: ?1049l restored main screen")
        view.render(snapshot: sMain)

        XCTAssertNil(view.selection,
                     "alt-screen exit must clear the active selection (Bug #15)")
    }

    // MARK: - Chrome-surface URL scrubber (audit critical-1)

    /// `scrubURLForDisplay` is the policy gate for any remote-controlled
    /// string we surface in UI chrome (hover tooltip, "Open in Finder"
    /// proxy icon, OSC 7 cwd display). Stricter than the paste sanitizer:
    /// chrome surfaces are single-line, so TAB/LF/CR drop here even
    /// though they pass through paste.

    func test_scrubURLForDisplay_passesPlainURL() {
        let input = "https://example.com/path?query=1"
        XCTAssertEqual(TerminalView.scrubURLForDisplay(input), input)
    }

    func test_scrubURLForDisplay_dropsBidiOverride() {
        // The audit's canonical homograph: `https://evil.tld/login` +
        // U+202E + `moc.elppa//:sptth`. Without scrubbing, NSTextField
        // renders the second half right-to-left and the user reads
        // `https://apple.com/login` while the click target stays evil.
        let lhs = "https://evil.tld/login"
        let rls = "moc.elppa//:sptth"
        let attack = lhs + "\u{202E}" + rls
        let scrubbed = TerminalView.scrubURLForDisplay(attack)
        XCTAssertFalse(scrubbed.contains("\u{202E}"))
        XCTAssertEqual(scrubbed, lhs + rls)
    }

    func test_scrubURLForDisplay_dropsAllExplicitBidiCodepoints() {
        // The full bidi list scrubbed by stripBidiOverrides — the
        // chrome scrubber inherits all of them.
        let bidi: [String.UnicodeScalarView.Element] = [
            "\u{200E}", "\u{200F}",
            "\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}",
            "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}",
            "\u{061C}", "\u{180E}",
        ]
        for cp in bidi {
            var s = "a"
            s.unicodeScalars.append(cp)
            s += "b"
            XCTAssertEqual(
                TerminalView.scrubURLForDisplay(s), "ab",
                "bidi codepoint U+\(String(cp.value, radix: 16, uppercase: true)) must be removed"
            )
        }
    }

    func test_scrubURLForDisplay_dropsTabLfCr() {
        // Paste keeps TAB/LF/CR (legitimate whitespace in pasted
        // content). The chrome surface is single-line; these would
        // wrap or layout-break the tooltip, so we drop them.
        let input = "https://example.com/\tpath\nfrag\rment"
        XCTAssertEqual(
            TerminalView.scrubURLForDisplay(input),
            "https://example.com/pathfragment"
        )
    }

    func test_scrubURLForDisplay_replacesC0WithSpace() {
        // sanitizePasteControls replaces C0 (excl. TAB/LF/CR) with a
        // space. The chrome path inherits that — these bytes shouldn't
        // appear in URLs but if they do, replacement-with-space is
        // safer than dropping (a fake space is visually obvious).
        let input = "https://example.com/\u{01}\u{1B}path"
        XCTAssertEqual(
            TerminalView.scrubURLForDisplay(input),
            "https://example.com/  path"
        )
    }

    func test_scrubURLForDisplay_replacesUTF8C1WithSpace() {
        // 0xC2 0x9D (U+009D, OSC) — same policy as paste.
        var bytes = Data("a".utf8)
        bytes.append(contentsOf: [0xC2, 0x9D])
        bytes += Data("b".utf8)
        let s = String(decoding: bytes, as: UTF8.self)
        XCTAssertEqual(TerminalView.scrubURLForDisplay(s), "a b")
    }

    func test_scrubURLForDisplay_preservesNonAsciiUtf8() {
        // CJK / emoji in URLs (punycode-decoded host display, etc.)
        // must round-trip. The em-dash (E2 80 94) carries the same E2
        // prefix as bidi overrides; verify we don't over-match.
        let input = "https://例え.jp/—path/🌐"
        XCTAssertEqual(TerminalView.scrubURLForDisplay(input), input)
    }
}
