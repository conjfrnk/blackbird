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
        XCTAssertNotNil(term.focusChangeBytes(focused: true))
        term.input("\u{1b}[?1004l")
        XCTAssertNil(term.focusChangeBytes(focused: true))
    }
}
