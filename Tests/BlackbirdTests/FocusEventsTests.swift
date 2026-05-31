import XCTest
@testable import Blackbird
import BBCore

/// Pins the focus-event escape plumbing. Two surfaces being tested:
///  1. `BBTerm.currentMode` reports the FOCUS_IN_OUT bit after `\e[?1004h`.
///  2. `BBTerm.focusChangeBytes(focused:)` gates on that bit and emits the
///     right escape sequence.
///
/// Hooked to `NSWindow.didBecomeKey` / `didResignKey` in MainWindowController;
/// a UI test to exercise the window path would require NSApp, which XCTest
/// avoids. The pure-BBTerm path below covers the semantic contract.
final class FocusEventsTests: XCTestCase {

    func test_focusChangeBytes_returnsNilWhenModeDisabled() throws {
        // Mode 1004 off → no bytes emitted. Emitting `\e[I` in this state
        // would be interpreted as HPA and move the cursor, corrupting
        // non-focus-aware TUIs.
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 10, rows: 1)))
        XCTAssertNil(term.focusChangeBytes(focused: true))
        XCTAssertNil(term.focusChangeBytes(focused: false))
    }

    func test_focusChangeBytes_returnsCsiI_onFocusGain_whenModeEnabled() throws {
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 10, rows: 1)))
        term.input("\u{1b}[?1004h")
        let bytes = try XCTUnwrap(term.focusChangeBytes(focused: true))
        XCTAssertEqual(Array(bytes), [0x1b, 0x5b, 0x49])  // ESC [ I
    }

    func test_focusChangeBytes_returnsCsiO_onFocusLoss_whenModeEnabled() throws {
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 10, rows: 1)))
        term.input("\u{1b}[?1004h")
        let bytes = try XCTUnwrap(term.focusChangeBytes(focused: false))
        XCTAssertEqual(Array(bytes), [0x1b, 0x5b, 0x4f])  // ESC [ O
    }

    func test_currentMode_reflectsFocusInOutToggle() throws {
        // Pins the state transition so a future regression that caches
        // the mode at snapshot time (instead of reading live) gets caught.
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 10, rows: 1)))
        XCTAssertFalse(term.currentMode.contains(.focusInOut))
        term.input("\u{1b}[?1004h")
        XCTAssertTrue(term.currentMode.contains(.focusInOut))
        term.input("\u{1b}[?1004l")
        XCTAssertFalse(term.currentMode.contains(.focusInOut))
    }

    func test_focusChangeBytes_goesNilAgain_afterModeDisable() throws {
        // Paired with the toggle test: once the TUI leaves raw mode,
        // the host must stop sending focus escapes immediately.
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 10, rows: 1)))
        term.input("\u{1b}[?1004h")
        // Mode 1004 enabled: focus-in must emit "\x1b[I" per the xterm spec.
        XCTAssertEqual(
            term.focusChangeBytes(focused: true),
            Data([0x1b, 0x5b, 0x49]),
            "focused=true with mode 1004 active must produce \\x1b[I"
        )
        term.input("\u{1b}[?1004l")
        XCTAssertNil(term.focusChangeBytes(focused: true))
    }

    // MARK: - Session-level focus emission (DECSET 1004 gate + same-state dedup)
    //
    // These exercise `TerminalSession.focusEmissionBytesForTests(focused:)`,
    // the single consolidated owner of focus-escape emission. The contract:
    // emit only when mode 1004 is enabled, and dedup consecutive same-state
    // transitions so a TUI never sees a redundant focus-in / focus-out.
    // The helpers are DEBUG-only, so the whole block is gated to match.
    #if DEBUG

    func test_session_focusEmission_nilBothDirections_whenModeNeverEnabled() {
        // Fresh session, 1004 never enabled → both directions must stay silent.
        // A stray `\e[I` here would be read as HPA and shove the cursor.
        let session = TerminalSession.makeHeadlessForTests()
        XCTAssertNil(
            session.focusEmissionBytesForTests(focused: true),
            "focus-in with mode 1004 off must emit nothing"
        )
        XCTAssertNil(
            session.focusEmissionBytesForTests(focused: false),
            "focus-out with mode 1004 off must emit nothing"
        )
    }

    func test_session_focusEmission_firstFocusIn_emitsCsiI_whenModeEnabled() {
        let session = TerminalSession.makeHeadlessForTests()
        session.feedBytesForTests(Data("\u{1b}[?1004h".utf8))
        XCTAssertEqual(
            session.focusEmissionBytesForTests(focused: true),
            Data([0x1b, 0x5b, 0x49]),   // ESC [ I
            "first focus-in after enabling 1004 must emit \\x1b[I"
        )
    }

    func test_session_focusEmission_dedupsConsecutiveFocusIn() {
        let session = TerminalSession.makeHeadlessForTests()
        session.feedBytesForTests(Data("\u{1b}[?1004h".utf8))
        // First focus-in emits.
        XCTAssertEqual(
            session.focusEmissionBytesForTests(focused: true),
            Data([0x1b, 0x5b, 0x49]),
            "first focus-in must emit \\x1b[I"
        )
        // Second consecutive focus-in (no intervening focus-out) is deduped.
        XCTAssertNil(
            session.focusEmissionBytesForTests(focused: true),
            "a second consecutive focus-in must be deduped to nil"
        )
    }

    func test_session_focusEmission_focusOutEmitsCsiO_thenDedups() {
        let session = TerminalSession.makeHeadlessForTests()
        session.feedBytesForTests(Data("\u{1b}[?1004h".utf8))
        // Establish a focus-in baseline so focus-out is a genuine transition.
        XCTAssertEqual(
            session.focusEmissionBytesForTests(focused: true),
            Data([0x1b, 0x5b, 0x49]),
            "focus-in baseline must emit \\x1b[I"
        )
        // Focus-out after a focus-in emits CSI O.
        XCTAssertEqual(
            session.focusEmissionBytesForTests(focused: false),
            Data([0x1b, 0x5b, 0x4f]),   // ESC [ O
            "focus-out after focus-in must emit \\x1b[O"
        )
        // Second consecutive focus-out is deduped — dedup works both ways.
        XCTAssertNil(
            session.focusEmissionBytesForTests(focused: false),
            "a second consecutive focus-out must be deduped to nil"
        )
    }

    func test_session_focusEmission_alternatingStates_eachEmit() {
        // Distinct consecutive states are real transitions and must NOT dedup.
        let session = TerminalSession.makeHeadlessForTests()
        session.feedBytesForTests(Data("\u{1b}[?1004h".utf8))
        XCTAssertEqual(
            session.focusEmissionBytesForTests(focused: true),
            Data([0x1b, 0x5b, 0x49]),   // T → ESC [ I
            "focus-in (1 of alternating) must emit \\x1b[I"
        )
        XCTAssertEqual(
            session.focusEmissionBytesForTests(focused: false),
            Data([0x1b, 0x5b, 0x4f]),   // F → ESC [ O
            "focus-out (2 of alternating) must emit \\x1b[O"
        )
        XCTAssertEqual(
            session.focusEmissionBytesForTests(focused: true),
            Data([0x1b, 0x5b, 0x49]),   // T → ESC [ I again
            "focus-in (3 of alternating) must emit \\x1b[I again"
        )
    }

    func test_session_focusEmission_gatedOffCall_doesNotPoisonDedupState() {
        // CRITICAL regression guard. A focus-in that is gated off (1004 still
        // disabled) must return nil WITHOUT recording `true` as the last
        // emitted state. Otherwise the real first emit — right after the TUI
        // enables 1004 — would be wrongly deduped and the program would never
        // learn it has focus.
        let session = TerminalSession.makeHeadlessForTests()
        // Gated-off focus-in: silent, and must not record last-state = true.
        XCTAssertNil(
            session.focusEmissionBytesForTests(focused: true),
            "focus-in while 1004 is disabled must emit nothing"
        )
        // Program now enables focus reporting.
        session.feedBytesForTests(Data("\u{1b}[?1004h".utf8))
        // The first real focus-in MUST emit, not be swallowed by stale state.
        XCTAssertEqual(
            session.focusEmissionBytesForTests(focused: true),
            Data([0x1b, 0x5b, 0x49]),
            "first focus-in after enabling 1004 must emit \\x1b[I even if a "
                + "gated-off focus-in preceded it"
        )
    }

    func test_session_focusEmission_reEnabling1004WhileKey_emitsAgain() {
        // A TUI that disables then re-enables 1004 while the window stays key
        // (vim :e, tmux re-attach, alt-screen re-init) must receive a fresh
        // focus-in on the re-enable. The dedup latch must NOT survive the
        // disabled interval and swallow the 1004-enable catch-up.
        let session = TerminalSession.makeHeadlessForTests()
        session.feedBytesForTests(Data("\u{1b}[?1004h".utf8))
        XCTAssertEqual(
            session.focusEmissionBytesForTests(focused: true),
            Data([0x1b, 0x5b, 0x49]),
            "first focus-in after enabling 1004 must emit \\x1b[I"
        )
        // TUI disables focus reporting…
        session.feedBytesForTests(Data("\u{1b}[?1004l".utf8))
        XCTAssertNil(
            session.focusEmissionBytesForTests(focused: true),
            "focus-in while 1004 disabled must emit nothing"
        )
        // …then re-enables it while the window never lost key.
        session.feedBytesForTests(Data("\u{1b}[?1004h".utf8))
        XCTAssertEqual(
            session.focusEmissionBytesForTests(focused: true),
            Data([0x1b, 0x5b, 0x49]),
            "re-enabling 1004 while focused must emit a fresh \\x1b[I, not be "
                + "swallowed by the pre-disable dedup latch"
        )
    }

    #endif
}
