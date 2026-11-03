import XCTest
import AppKit
import Metal
@testable import Blackbird
import BBCore

/// DEC 1005 (UTF-8 mouse coordinates) must change the wire encoding.
///
/// **The bug this suite exists for.** A TUI that sends `CSI ? 1000 h` and then
/// `CSI ? 1005 h` (and no `?1006`) is telling the terminal "report mouse
/// events in the legacy `ESC [ M Cb Cx Cy` shape, but encode the two
/// coordinates as UTF-8". The core already tracks the mode (`BBTermMode
/// .utf8Mouse`, bit 18) and `DECRQM` answers that it is supported, so programs
/// that probe for it turn it on. But a click at 0-based column >= 95 (1-based
/// >= 96) or row >= 96 is then reported as a LONE byte 0x80-0xFF: the plain
/// X10 `32 + n` value. A UTF-8 consumer decodes that as invalid UTF-8, so
/// every click right of column ~95 (or below row ~95) is misparsed or
/// dropped. Past column 223 the legacy encoder cannot even represent the
/// position, so the click is not reported at all.
///
/// **The contract pinned here** (decided from xterm's `ctlseqs` documentation
/// of mode 1005 and from how xterm itself behaves, not from Blackbird's code):
///
///  1. Under `?1000h` + `?1005h` a report is `ESC [ M`, then ONE plain byte
///     `Cb = 32 + button` (always < 128), then the column and the row, each
///     the UTF-8 encoding of the code point `32 + n` with `n` the 1-based
///     position. Values below 128 are therefore one byte (identical to the
///     legacy encoding) and values 128...2047 are two bytes
///     (`0xC2 0x80` for n = 96, `0xC3 0xBF` for n = 223, `0xC4 0x80` for
///     n = 224). Position 95 is the last single-byte value (0x7F).
///  2. The 223-position ceiling of the legacy encoding does not apply: a
///     click in column 223, 230 or 240 is reported, not dropped.
///  3. Release is `Cb = 3` as in the legacy encoding; drag motion carries the
///     motion bit (32) and the same UTF-8 coordinates.
///  4. The core makes 1005 and 1006 mutually exclusive, last one set wins (as
///     in xterm), so `?1006h` followed by `?1005h` is UTF-8 mode; `?1005h`
///     followed by `?1006h` stays SGR. `?1005l` returns to the legacy raw
///     bytes.
///
/// Controls (they pass today and must keep passing): the geometry of the big
/// rig under SGR, UTF-8 mode below the 2-byte threshold (identical to legacy),
/// SGR set after 1005, and the legacy raw-byte encoding after `?1005l`. The
/// last one is what stops a "just always UTF-8 encode" over-fix from passing.
///
/// **Geometry.** The view is sized like a real 240 x 100 window (titlebar
/// inset + 100 rows of cells + the bottom inset + 0.5 pt slack; width likewise
/// with the two 8 pt side insets). The grid the view would compute from that
/// frame is asserted to be exactly 240 x 100 and the headless session and its
/// snapshot are resized to the same size. All clicks land on the CENTRE of an
/// interior cell, so edge-clamping behaviour is not involved. The view is
/// never added to a window, so its frame origin is (0, 0) and
/// `locationInWindow` equals the view-local point.
///
/// **Event synthesis.** `NSEvent.mouseEvent(with:...)` handed straight to the
/// view's `mouseDown` / `mouseDragged` / `mouseUp`. Nothing is posted to the
/// window server, so this is not event injection and nothing can route back
/// to the outer terminal. Every event's type and `locationInWindow` are
/// asserted before use.
///
/// **Oracle.** The expected bytes are built with Swift's standard-library
/// UTF-8 encoder (`Unicode.Scalar` -> `String.utf8`), independent of anything
/// in the app, and are checked against hand-computed vectors from the xterm
/// spec in `test_oracle_knownVectors_matchHandComputedUTF8`. The report parser
/// is a strict decoder (no overlong forms, no lone continuation or lead
/// bytes), so a raw 0x85 is rejected rather than quietly accepted.
///
/// **Memory / time pre-flight** (per `feedback_test_memory_safety`):
///  - One PTY-less headless `TerminalSession` resized to 240 x 100 = 24 000
///    cells (well under 1 MB including the snapshot) per rig; one rig per
///    test.
///  - One headless `TerminalView`, about 1 900 x 1 700 pt; never added to a
///    window, never shown, never drawn, so no drawable texture is ever
///    allocated. No `NSWindow`, no `MainWindowController`, no real shell, no
///    runloop pumping, no timers.
///  - Each test sends at most three mouse events. Wall time is dominated by
///    `MTLCreateSystemDefaultDevice()`.
final class MouseUTF8EncodingBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Fixture constants

    private let gridCols = 240
    private let gridRows = 100

    /// Click reporting (DEC 1000) + UTF-8 coordinates (DEC 1005), no SGR.
    private let click1000UTF8 = "\u{1B}[?1000h\u{1B}[?1005h"
    /// Button-event tracking (DEC 1002) + UTF-8 coordinates.
    private let drag1002UTF8 = "\u{1B}[?1002h\u{1B}[?1005h"
    /// SGR first, then UTF-8: the later mode must win.
    private let click1000SGRThenUTF8 = "\u{1B}[?1000h\u{1B}[?1006h\u{1B}[?1005h"
    /// UTF-8 first, then SGR: the later mode must win.
    private let click1000UTF8ThenSGR = "\u{1B}[?1000h\u{1B}[?1005h\u{1B}[?1006h"
    /// Click reporting + SGR only.
    private let click1000SGR = "\u{1B}[?1000h\u{1B}[?1006h"
    /// UTF-8 switched on and straight back off: plain legacy encoding.
    private let click1000UTF8ThenOff = "\u{1B}[?1000h\u{1B}[?1005h\u{1B}[?1005l"

    /// Monotonic synthetic event clock; one second apart so successive clicks
    /// can never be folded into a double click.
    private var clock: TimeInterval = 1.0
    private func nextTimestamp() -> TimeInterval {
        clock += 1.0
        return clock
    }

    // MARK: - Rig

    /// Held together so nothing is deallocated mid-test. `TerminalView.session`
    /// is `weak`, so the strong `session` here is load-bearing.
    private struct Rig {
        let view: TerminalView
        let session: TerminalSession
        let recorder: RecordingPTY
    }

    private func makeRig(
        decset: String,
        expectSGR: Bool,
        expectUTF8: Bool,
        expectedProtocol: BBTermMode,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Rig {
        let device = try requireMetalDevice(file: file, line: line)
        let view = TerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 480),
            device: device
        )

        // Size the frame like a real 240 x 100 window.
        let cw = view.metrics.cellWidth
        let ch = view.metrics.cellHeight
        let top = view.titlebarOnlyTopInset
        let inset = TerminalView.horizontalContentInsetPoints
        let width = 2 * inset + CGFloat(gridCols) * cw + 0.5
        let height = top + CGFloat(gridRows) * ch + TerminalView.bottomContentInsetPoints + 0.5
        view.setFrameSize(NSSize(width: width, height: height))
        let usable = TerminalView.usableViewSize(
            forBounds: view.bounds.size, titlebarTopInset: top, metrics: view.metrics
        )
        let grid = view.metrics.grid(forPixelSize: usable)
        XCTAssertEqual(
            grid.cols, gridCols,
            "precondition: the view frame must model a real \(gridCols)-column window "
            + "(measured \(grid.cols) cols; bounds \(view.bounds.size), cellWidth \(cw))",
            file: file, line: line
        )
        XCTAssertEqual(
            grid.rows, gridRows,
            "precondition: the view frame must model a real \(gridRows)-row window "
            + "(measured \(grid.rows) rows; bounds \(view.bounds.size), cellHeight \(ch))",
            file: file, line: line
        )

        let session = TerminalSession.makeHeadlessForTests()
        addTeardownBlock { session.terminate() }
        let applied = session.coreQueue.sync {
            session.bbterm.resize(to: .init(cols: UInt16(gridCols), rows: UInt16(gridRows)))
        }
        XCTAssertEqual(
            Int(applied?.cols ?? 0), gridCols,
            "precondition: headless grid resized to \(gridCols) cols",
            file: file, line: line
        )
        XCTAssertEqual(
            Int(applied?.rows ?? 0), gridRows,
            "precondition: headless grid resized to \(gridRows) rows",
            file: file, line: line
        )
        session.feedBytesForTests(Data(decset.utf8))

        // Attach the session BEFORE installing the snapshot (the setter may
        // seed its own), same order as the other headless rigs.
        view.session = session
        let snapshot = try XCTUnwrap(
            session.coreQueue.sync { session.bbterm.snapshot() },
            "snapshot() returned nil", file: file, line: line
        )
        view.currentSnapshot = snapshot

        let recorder = RecordingPTY()
        view.ptyRecorderForTests = recorder

        // Preconditions: without these a mistyped DECSET would leave the
        // wrong encoding selected and every assertion below would fail (or
        // pass) for the wrong reason.
        XCTAssertEqual(snapshot.cols, gridCols, "precondition: snapshot cols",
                       file: file, line: line)
        XCTAssertEqual(snapshot.rows, gridRows, "precondition: snapshot rows",
                       file: file, line: line)
        XCTAssertTrue(
            snapshot.termMode.contains(expectedProtocol),
            "precondition: \(decset.debugDescription) must select the expected mouse protocol; "
            + "termMode.rawValue = \(snapshot.termMode.rawValue)",
            file: file, line: line
        )
        XCTAssertEqual(
            snapshot.termMode.contains(.sgrMouse), expectSGR,
            "precondition: SGR (?1006) encoding must be \(expectSGR ? "on" : "off"); "
            + "termMode.rawValue = \(snapshot.termMode.rawValue)",
            file: file, line: line
        )
        XCTAssertEqual(
            snapshot.termMode.contains(.utf8Mouse), expectUTF8,
            "precondition: UTF-8 (?1005) encoding must be \(expectUTF8 ? "on" : "off"); "
            + "termMode.rawValue = \(snapshot.termMode.rawValue)",
            file: file, line: line
        )
        XCTAssertTrue(
            view.mouseReportingEnabled(),
            "precondition: the view must agree the TUI has mouse reporting on",
            file: file, line: line
        )
        XCTAssertEqual(
            snapshot.displayOffset, 0,
            "precondition: fixture must not be scrolled, so display row == buffer line",
            file: file, line: line
        )
        return Rig(view: view, session: session, recorder: recorder)
    }

    // MARK: - Geometry + event synthesis

    /// View-local point at the centre of grid cell (`row`, `col`), zero-based.
    private func centre(row: Int, col: Int, in view: TerminalView) -> NSPoint {
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
        timestamp: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> NSEvent {
        let ev: NSEvent = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: type,
                location: p,
                modifierFlags: [],
                timestamp: timestamp,
                windowNumber: 0,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1.0
            ),
            "NSEvent.mouseEvent returned nil", file: file, line: line
        )
        XCTAssertEqual(
            ev.type, type,
            "precondition: event type must be what the test asked for",
            file: file, line: line
        )
        XCTAssertEqual(
            Double(ev.locationInWindow.x), Double(p.x), accuracy: 0.001,
            "precondition: locationInWindow.x must equal the requested point",
            file: file, line: line
        )
        XCTAssertEqual(
            Double(ev.locationInWindow.y), Double(p.y), accuracy: 0.001,
            "precondition: locationInWindow.y must equal the requested point",
            file: file, line: line
        )
        return ev
    }

    /// Left press + release at the centre of the zero-based cell (`col0`,
    /// `row0`); returns every byte the TUI would have received.
    private func clickAndCapture(
        _ rig: Rig,
        col0: Int,
        row0: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [UInt8] {
        rig.recorder.sent = Data()
        let p = centre(row: row0, col: col0, in: rig.view)
        let t = nextTimestamp()
        rig.view.mouseDown(with: try mouseEvent(.leftMouseDown, at: p, timestamp: t, file: file, line: line))
        rig.view.mouseUp(with: try mouseEvent(.leftMouseUp, at: p, timestamp: t + 0.01, file: file, line: line))
        return Array(rig.recorder.sent)
    }

    // MARK: - Byte oracle

    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { (b: UInt8) -> String in String(format: "%02X", b) }.joined(separator: " ")
    }

    /// Standard-library UTF-8 encoding of code point `cp`: the independent
    /// oracle for "the UTF-8 encoding of 32 + n".
    private func utf8Bytes(ofCodePoint cp: Int, file: StaticString = #filePath, line: UInt = #line) throws -> [UInt8] {
        let scalar: Unicode.Scalar = try XCTUnwrap(
            Unicode.Scalar(UInt32(cp)),
            "code point \(cp) is not a valid Unicode scalar", file: file, line: line
        )
        return Array(String(Character(scalar)).utf8)
    }

    /// One expected DEC 1005 report: `ESC [ M`, plain `Cb`, UTF-8 column,
    /// UTF-8 row. `col` and `row` are 1-based.
    private func expectedReport(
        cb: Int, col: Int, row: Int,
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> [UInt8] {
        var out: [UInt8] = [0x1B, 0x5B, 0x4D, UInt8(cb + 32)]
        out += try utf8Bytes(ofCodePoint: col + 32, file: file, line: line)
        out += try utf8Bytes(ofCodePoint: row + 32, file: file, line: line)
        return out
    }

    /// Expected press-then-release stream for a left click on the 1-based
    /// cell (`col`, `row`).
    private func expectedClick(
        col: Int, row: Int,
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> [UInt8] {
        try expectedReport(cb: 0, col: col, row: row, file: file, line: line)
            + expectedReport(cb: 3, col: col, row: row, file: file, line: line)
    }

    private struct WireReport: Equatable, CustomStringConvertible {
        /// `Cb - 32`.
        let cb: Int
        /// 1-based, decoded from the UTF-8 coordinate.
        let col: Int
        let row: Int
        var description: String { "report(cb: \(cb), col: \(col), row: \(row))" }
    }

    /// Strictly decode one code point of 1 or 2 bytes at `i` (coordinates top
    /// out at 2047). Overlong forms, lone continuation bytes and truncated
    /// sequences are rejected (`nil`).
    private func decodeCodePoint(_ bytes: [UInt8], at i: Int) -> (value: Int, length: Int)? {
        guard i < bytes.count else { return nil }
        let b0 = Int(bytes[i])
        if b0 < 0x80 { return (b0, 1) }
        guard b0 >= 0xC2, b0 <= 0xDF, i + 1 < bytes.count else { return nil }
        let b1 = Int(bytes[i + 1])
        guard b1 >= 0x80, b1 <= 0xBF else { return nil }
        return (((b0 & 0x1F) << 6) | (b1 & 0x3F), 2)
    }

    /// Parse `bytes` as back-to-back DEC 1005 reports. `consumed` is how many
    /// bytes parsed cleanly; anything short of `bytes.count` is malformed.
    private func parseReports(_ bytes: [UInt8]) -> (reports: [WireReport], consumed: Int) {
        var out: [WireReport] = []
        var i = 0
        while i + 4 <= bytes.count {
            guard bytes[i] == 0x1B, bytes[i + 1] == 0x5B, bytes[i + 2] == 0x4D, bytes[i + 3] < 0x80 else {
                break
            }
            guard let cx = decodeCodePoint(bytes, at: i + 4),
                  let cy = decodeCodePoint(bytes, at: i + 4 + cx.length) else {
                break
            }
            out.append(WireReport(
                cb: Int(bytes[i + 3]) - 32, col: cx.value - 32, row: cy.value - 32
            ))
            i += 4 + cx.length + cy.length
        }
        return (out, i)
    }

    private func isValidUTF8(_ bytes: [UInt8]) -> Bool {
        String(bytes: bytes, encoding: .utf8) != nil
    }

    // MARK: - Assertion helpers

    /// A left click on the zero-based cell (`col0`, `row0`) under DEC 1005
    /// must produce exactly the press + release the xterm spec describes.
    private func assertUTF8Click(
        _ rig: Rig,
        col0: Int,
        row0: Int,
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let got = try clickAndCapture(rig, col0: col0, row0: row0, file: file, line: line)
        let want = try expectedClick(col: col0 + 1, row: row0 + 1, file: file, line: line)
        let parsed = parseReports(got)
        XCTAssertEqual(
            hex(got), hex(want),
            "\(label): a left click on 0-based (col \(col0), row \(row0)) under ?1000h/?1005h must be "
            + "ESC [ M, plain Cb, then the UTF-8 encoding of 32 + 1-based col and 32 + 1-based row, for "
            + "press and for release. Got [\(hex(got))] (\(got.count) bytes, "
            + "valid UTF-8: \(isValidUTF8(got)), strict parse: \(parsed.reports), "
            + "\(parsed.consumed) bytes parsed cleanly); want [\(hex(want))]",
            file: file, line: line
        )
    }

    // MARK: - Oracle self-check

    /// The oracle must agree with vectors worked out by hand from the xterm
    /// description (value = 32 + n; below 128 one byte, else
    /// `0xC0 | v >> 6`, `0x80 | v & 0x3F`). Proves the expectations in the
    /// bug tests are not themselves wrong.
    func test_oracle_knownVectors_matchHandComputedUTF8() throws {
        let v95 = try utf8Bytes(ofCodePoint: 32 + 95)
        let v96 = try utf8Bytes(ofCodePoint: 32 + 96)
        let v101 = try utf8Bytes(ofCodePoint: 32 + 101)
        let v223 = try utf8Bytes(ofCodePoint: 32 + 223)
        let v224 = try utf8Bytes(ofCodePoint: 32 + 224)
        let v240 = try utf8Bytes(ofCodePoint: 32 + 240)
        let click = try expectedClick(col: 101, row: 4)
        XCTAssertEqual(hex(v95), "7F", "n = 95 is the last single-byte position (0x7F)")
        XCTAssertEqual(hex(v96), "C2 80", "n = 96 is the first two-byte position (U+0080)")
        XCTAssertEqual(hex(v101), "C2 85", "n = 101 -> U+0085")
        XCTAssertEqual(hex(v223), "C3 BF",
                       "n = 223 -> U+00FF, the largest value the legacy byte encoding can hold")
        XCTAssertEqual(hex(v224), "C4 80",
                       "n = 224 -> U+0100, the first position the legacy encoding cannot represent")
        XCTAssertEqual(hex(v240), "C4 90", "n = 240 -> U+0110")
        XCTAssertEqual(
            hex(click), "1B 5B 4D 20 C2 85 24 1B 5B 4D 23 C2 85 24",
            "full expected press+release for 1-based (101, 4)"
        )
    }

    // MARK: - Controls (pass today; prove the rig and that a fix must not over-reach)

    /// Geometry control for the whole file: under plain SGR the centre of
    /// 0-based (col 100, row 50) is reported as the 1-based cell (101, 51).
    /// If this ever fails, the click coordinates in the UTF-8 tests below are
    /// not landing on the cells they claim to.
    func test_control_sgrClickAtHighCell_reportsThatCell() throws {
        let rig = try makeRig(
            decset: click1000SGR, expectSGR: true, expectUTF8: false,
            expectedProtocol: .mouseReportClick
        )
        let got = try clickAndCapture(rig, col0: 100, row0: 50)
        let text = String(decoding: got, as: UTF8.self).replacingOccurrences(of: "\u{1B}", with: "<ESC>")
        XCTAssertEqual(
            text, "<ESC>[<0;101;51M<ESC>[<0;101;51m",
            "SGR click on 0-based (col 100, row 50) must report 1-based (101, 51) in a "
            + "\(gridCols) x \(gridRows) grid; TUI received: \(text)"
        )
    }

    /// Below the 2-byte threshold UTF-8 mode and the legacy encoding are
    /// byte-identical; a click on 0-based (col 10, row 3) is `32 + 11`,
    /// `32 + 4`. Proves the rig delivers clicks under ?1005h and that the
    /// mode is not rejected outright.
    func test_control_utf8_smallCoordinates_areSingleBytes() throws {
        let rig = try makeRig(
            decset: click1000UTF8, expectSGR: false, expectUTF8: true,
            expectedProtocol: .mouseReportClick
        )
        let got = try clickAndCapture(rig, col0: 10, row0: 3)
        XCTAssertEqual(
            hex(got), "1B 5B 4D 20 2B 24 1B 5B 4D 23 2B 24",
            "a click on 0-based (col 10, row 3) under ?1005h must be press(Cb 0x20) and "
            + "release(Cb 0x23) with single-byte coordinates 0x2B 0x24; got [\(hex(got))]"
        )
    }

    /// 1-based position 95 -> 32 + 95 = 127 = 0x7F is the LAST single-byte
    /// value, in column and row alike; both encodings agree there.
    func test_control_utf8_lastSingleByteCoordinate_is0x7F() throws {
        let rig = try makeRig(
            decset: click1000UTF8, expectSGR: false, expectUTF8: true,
            expectedProtocol: .mouseReportClick
        )
        let got = try clickAndCapture(rig, col0: 94, row0: 94)
        XCTAssertEqual(
            hex(got), "1B 5B 4D 20 7F 7F 1B 5B 4D 23 7F 7F",
            "a click on 0-based (col 94, row 94) = 1-based (95, 95) under ?1005h must use the "
            + "single byte 0x7F for both coordinates; got [\(hex(got))]"
        )
    }

    /// `?1005h` then `?1006h`: the later (SGR) mode wins, so the report is
    /// the SGR text form even at a high column. A fix keyed off 1005 must
    /// not turn this into UTF-8.
    func test_control_sgrSetAfterUTF8_staysSGR() throws {
        let rig = try makeRig(
            decset: click1000UTF8ThenSGR, expectSGR: true, expectUTF8: false,
            expectedProtocol: .mouseReportClick
        )
        let got = try clickAndCapture(rig, col0: 100, row0: 50)
        let text = String(decoding: got, as: UTF8.self).replacingOccurrences(of: "\u{1B}", with: "<ESC>")
        XCTAssertEqual(
            text, "<ESC>[<0;101;51M<ESC>[<0;101;51m",
            "after ?1005h then ?1006h the encoding is SGR; TUI received: \(text)"
        )
    }

    /// `?1005h` then `?1005l`: back to the legacy encoding, whose coordinate
    /// bytes are the raw `32 + n` values. Column 101 -> a lone 0x85, row 51 ->
    /// 0x53. Stops an over-fix that UTF-8 encodes regardless of the mode.
    func test_control_afterUTF8Reset_legacyRawBytesReturn() throws {
        let rig = try makeRig(
            decset: click1000UTF8ThenOff, expectSGR: false, expectUTF8: false,
            expectedProtocol: .mouseReportClick
        )
        let got = try clickAndCapture(rig, col0: 100, row0: 50)
        XCTAssertEqual(
            hex(got), "1B 5B 4D 20 85 53 1B 5B 4D 23 85 53",
            "with ?1005 switched off again the legacy raw-byte encoding must return "
            + "(col 101 -> 0x85, row 51 -> 0x53); got [\(hex(got))]"
        )
    }

    // MARK: - The bug: columns

    /// The very first column whose `32 + n` leaves the 7-bit range:
    /// 0-based 95 = 1-based 96 -> U+0080 -> `C2 80`. Today a lone `80`.
    func test_utf8_column95_firstTwoByteColumn() throws {
        let rig = try makeRig(
            decset: click1000UTF8, expectSGR: false, expectUTF8: true,
            expectedProtocol: .mouseReportClick
        )
        try assertUTF8Click(rig, col0: 95, row0: 3, label: "first two-byte column")
    }

    /// A typical wide-terminal column: 0-based 100 = 1-based 101 -> `C2 85`.
    func test_utf8_column100_isTwoByteUTF8() throws {
        let rig = try makeRig(
            decset: click1000UTF8, expectSGR: false, expectUTF8: true,
            expectedProtocol: .mouseReportClick
        )
        try assertUTF8Click(rig, col0: 100, row0: 3, label: "column 100")
    }

    /// 0-based 222 = 1-based 223 -> U+00FF -> `C3 BF`. The legacy encoder
    /// emits a lone `FF` here, which is not UTF-8 either.
    func test_utf8_column222_lastLegacyAddressableColumn() throws {
        let rig = try makeRig(
            decset: click1000UTF8, expectSGR: false, expectUTF8: true,
            expectedProtocol: .mouseReportClick
        )
        try assertUTF8Click(rig, col0: 222, row0: 3, label: "column 222 (legacy limit)")
    }

    /// 0-based 223 = 1-based 224 -> U+0100 -> `C4 80`. The legacy encoding
    /// cannot represent this position and drops the click entirely; UTF-8
    /// mode has no such ceiling.
    func test_utf8_column223_isNotDroppedPastLegacyCeiling() throws {
        let rig = try makeRig(
            decset: click1000UTF8, expectSGR: false, expectUTF8: true,
            expectedProtocol: .mouseReportClick
        )
        try assertUTF8Click(rig, col0: 223, row0: 3, label: "column 223 (past the legacy ceiling)")
    }

    /// The last column of the 240-column grid: 1-based 240 -> U+0110 -> `C4 90`.
    func test_utf8_lastColumnOfWideGrid_isReported() throws {
        let rig = try makeRig(
            decset: click1000UTF8, expectSGR: false, expectUTF8: true,
            expectedProtocol: .mouseReportClick
        )
        try assertUTF8Click(rig, col0: gridCols - 1, row0: 3, label: "last column of the grid")
    }

    // MARK: - The bug: rows

    /// The first row whose `32 + n` leaves the 7-bit range: 0-based 95 =
    /// 1-based 96 -> `C2 80`. Column stays single-byte so only the row can
    /// be at fault.
    func test_utf8_row95_firstTwoByteRow() throws {
        let rig = try makeRig(
            decset: click1000UTF8, expectSGR: false, expectUTF8: true,
            expectedProtocol: .mouseReportClick
        )
        try assertUTF8Click(rig, col0: 3, row0: 95, label: "first two-byte row")
    }

    /// The bottom row of the 100-row grid: 1-based 100 -> U+0084 -> `C2 84`.
    func test_utf8_lastRowOfTallGrid_isTwoByteUTF8() throws {
        let rig = try makeRig(
            decset: click1000UTF8, expectSGR: false, expectUTF8: true,
            expectedProtocol: .mouseReportClick
        )
        try assertUTF8Click(rig, col0: 3, row0: gridRows - 1, label: "last row of the grid")
    }

    /// Column and row both past the threshold in one report.
    func test_utf8_bothCoordinatesTwoByte() throws {
        let rig = try makeRig(
            decset: click1000UTF8, expectSGR: false, expectUTF8: true,
            expectedProtocol: .mouseReportClick
        )
        try assertUTF8Click(rig, col0: 150, row0: 80, label: "column 150 and row 80 together")
    }

    // MARK: - The bug: mode sequencing

    /// `?1006h` followed by `?1005h`: the core makes the two modes mutually
    /// exclusive with the last one set winning (as xterm does), so this is
    /// UTF-8 mode with SGR off. The report must be UTF-8 encoded. Today the
    /// view sees "no SGR" and falls into the legacy raw-byte path.
    func test_utf8_afterSGR_lastModeWins() throws {
        let rig = try makeRig(
            decset: click1000SGRThenUTF8, expectSGR: false, expectUTF8: true,
            expectedProtocol: .mouseReportClick
        )
        try assertUTF8Click(rig, col0: 100, row0: 50, label: "?1006h then ?1005h")
    }

    // MARK: - The bug: drag motion

    /// Button-event tracking (`?1002h`) + `?1005h`: a drag from 0-based
    /// (col 100, row 10) to (col 130, row 60) is a press, motion report(s)
    /// carrying the motion bit (Cb - 32 == 32) at the target cell, and a
    /// release (Cb - 32 == 3) at the target cell, every coordinate UTF-8
    /// encoded. The number of motion reports is not pinned.
    func test_utf8_dragReportsStrictUTF8Throughout() throws {
        let rig = try makeRig(
            decset: drag1002UTF8, expectSGR: false, expectUTF8: true,
            expectedProtocol: .mouseDrag
        )
        rig.recorder.sent = Data()
        let down = centre(row: 10, col: 100, in: rig.view)
        let moved = centre(row: 60, col: 130, in: rig.view)
        let t = nextTimestamp()
        rig.view.mouseDown(with: try mouseEvent(.leftMouseDown, at: down, timestamp: t))
        rig.view.mouseDragged(with: try mouseEvent(.leftMouseDragged, at: moved, timestamp: t + 0.01))
        rig.view.mouseUp(with: try mouseEvent(.leftMouseUp, at: moved, timestamp: t + 0.02))

        let got = Array(rig.recorder.sent)
        let parsed = parseReports(got)
        let context = "full stream [\(hex(got))] (\(got.count) bytes, valid UTF-8: \(isValidUTF8(got)), "
            + "\(parsed.consumed) bytes parsed cleanly as strict DEC 1005 reports)"

        XCTAssertEqual(
            parsed.consumed, got.count,
            "every byte of a drag under ?1002h/?1005h must belong to a well-formed report whose "
            + "coordinates are valid UTF-8; \(context)"
        )
        XCTAssertEqual(
            parsed.reports.first?.description,
            WireReport(cb: 0, col: 101, row: 11).description,
            "the first report must be the left press on 1-based (101, 11); \(context)"
        )
        XCTAssertEqual(
            parsed.reports.last?.description,
            WireReport(cb: 3, col: 131, row: 61).description,
            "the last report must be the release on 1-based (131, 61); \(context)"
        )
        let middle: [String] = parsed.reports.dropFirst().dropLast().map {
            (r: WireReport) -> String in r.description
        }
        let wantMiddle: [String] = Array(
            repeating: WireReport(cb: 32, col: 131, row: 61).description,
            count: middle.count
        )
        XCTAssertEqual(
            middle, wantMiddle,
            "every report between press and release must be left-button motion (Cb - 32 == 32) at "
            + "the drag target 1-based (131, 61); \(context)"
        )
    }
}
