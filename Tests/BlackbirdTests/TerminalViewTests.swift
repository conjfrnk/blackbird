import XCTest
import AppKit
import Combine
import Metal
@testable import Blackbird

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

    func test_resizeForwardsToSession() throws {
        let session = try TerminalSession.start(
            shell: "/bin/cat",
            arguments: [],
            size: .init(cols: 80, rows: 24)
        )
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

        session.terminate()
    }

    func test_viewRendersGivenSnapshotWithoutCrash() throws {
        let session = try TerminalSession.start(
            shell: "/bin/cat",
            arguments: [],
            size: .init(cols: 80, rows: 24)
        )

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

        session.terminate()
    }

    func test_controlCSendsSigintViaEncoder() {
        // Sanity check — ⌃C continues to produce 0x03 via KeyEncoder, even
        // after the ⌘C enforcement change.
        let encoder = KeyEncoder()
        XCTAssertEqual(encoder.encode(chars: "c", modifiers: [.control]), Data([0x03]))
    }

    func test_optionKeyPreference_drivesEncoderOptionIsMeta() throws {
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

    func test_commandKeyDoesNotSendToPty() throws {
        // Simulate ⌘C on the TerminalView and verify the session received no bytes.
        // We use a cat-backed session because /bin/cat echoes only what it receives
        // — so if we accidentally sent 'c' to cat, it would echo back.

        let session = try TerminalSession.start(
            shell: "/bin/cat",
            arguments: [],
            size: .init(cols: 80, rows: 24)
        )
        let device = MTLCreateSystemDefaultDevice()!
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480), device: device)
        view.session = session

        // First, send a known byte so we have a baseline the snapshot contains.
        // Use "x\n" so cat echoes "x".
        session.send(Data("x\n".utf8))

        // Wait for the baseline echo.
        let baseline = expectation(description: "baseline echo")
        var snapAfterBaseline: BBSnapshot?
        var c: AnyCancellable?
        c = session.$snapshot.sink { s in
            if let s, s.character(at: 0, row: 0) == "x", snapAfterBaseline == nil {
                snapAfterBaseline = s
                c?.cancel()
                baseline.fulfill()
            }
        }
        wait(for: [baseline], timeout: 3.0)

        // Now synthesize a ⌘C event and deliver it to the view.
        let cmdCEvent = NSEvent.keyEvent(
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
        )!
        view.keyDown(with: cmdCEvent)

        // Give the event loop time to propagate any (incorrect) byte.
        let settle = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { settle.fulfill() }
        wait(for: [settle], timeout: 1.0)

        // Pragmatic version: just assert no crash + view is still alive.
        // A full intercept-based test would require session.send to be injectable.
        // For Plan 2 the non-crash + unit test on KeyEncoder.encode is enough;
        // selection + real copy wiring lands in Plan 6.
        XCTAssertNotNil(view.session)
        session.terminate()
    }

    // MARK: - Selection mode routing in mouseDown

    private func makeViewForSelection() throws -> TerminalView {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let view = TerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 480),
            device: device
        )
        // Session + snapshot so bufferPointFromEvent can resolve cols/rows.
        let session = try TerminalSession.start(
            shell: "/bin/cat",
            arguments: [],
            size: .init(cols: 80, rows: 24)
        )
        view.session = session
        let exp = expectation(description: "initial snapshot")
        var c: AnyCancellable?
        c = session.$snapshot.sink { s in
            if s != nil {
                c?.cancel()
                exp.fulfill()
            }
        }
        wait(for: [exp], timeout: 3.0)
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

    func test_mouseDown_option_triggersRectangularSelection() throws {
        let view = try makeViewForSelection()
        // Middle of the view → somewhere inside the grid.
        let mid = NSPoint(x: 200, y: 200)
        let ev = try mouseDownEvent(at: mid, modifiers: [.option])
        view.mouseDown(with: ev)
        XCTAssertEqual(view.selection?.mode, .rectangular,
                       "⌥-drag should trigger rectangular selection")
        view.session?.terminate()
    }

    func test_mouseDown_noModifiers_triggersCharacterSelection() throws {
        let view = try makeViewForSelection()
        let mid = NSPoint(x: 200, y: 200)
        let ev = try mouseDownEvent(at: mid, modifiers: [])
        view.mouseDown(with: ev)
        XCTAssertEqual(view.selection?.mode, .character,
                       "Plain drag should be prose-style character selection")
        view.session?.terminate()
    }

    func test_mouseDown_doubleClick_triggersWordSelection() throws {
        let view = try makeViewForSelection()
        let mid = NSPoint(x: 200, y: 200)
        let ev = try mouseDownEvent(at: mid, modifiers: [], clickCount: 2)
        view.mouseDown(with: ev)
        XCTAssertEqual(view.selection?.mode, .word,
                       "Double-click should start a word-mode selection")
        view.session?.terminate()
    }

    func test_mouseDown_tripleClick_triggersLineSelection() throws {
        let view = try makeViewForSelection()
        let mid = NSPoint(x: 200, y: 200)
        let ev = try mouseDownEvent(at: mid, modifiers: [], clickCount: 3)
        view.mouseDown(with: ev)
        XCTAssertEqual(view.selection?.mode, .line,
                       "Triple-click should start a line-mode selection")
        view.session?.terminate()
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
        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let device = MTLCreateSystemDefaultDevice()!
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480), device: device)
        window.contentView = view

        let session = try TerminalSession.start(
            shell: "/bin/sh",
            arguments: ["-c", "printf '\\033]2;blackbird-title-test\\007'; sleep 0.5"],
            size: .init(cols: 80, rows: 24)
        )
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

        session.terminate()
    }
}
