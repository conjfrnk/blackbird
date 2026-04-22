import XCTest
@testable import Blackbird

final class KeyEncoderTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    func test_printableAscii() {
        let encoder = KeyEncoder()
        XCTAssertEqual(encoder.encode(chars: "a", modifiers: []), Data([0x61]))
        XCTAssertEqual(encoder.encode(chars: "Z", modifiers: [.shift]), Data([0x5A]))
    }

    func test_return() {
        let encoder = KeyEncoder()
        XCTAssertEqual(encoder.encode(chars: "\r", modifiers: []), Data([0x0D]))
    }

    func test_backspace() {
        let encoder = KeyEncoder()
        XCTAssertEqual(encoder.encode(chars: "\u{7F}", modifiers: []), Data([0x7F]))
    }

    func test_tab() {
        let encoder = KeyEncoder()
        XCTAssertEqual(encoder.encode(chars: "\t", modifiers: []), Data([0x09]))
    }

    func test_shiftTab_emitsCsiZ() {
        // Shift+Tab is xterm's "back-tab" (reverse tab). zsh's reverse-menu,
        // bash readline's menu-complete, and tab-cycling pickers in TUIs
        // all bind CSI Z. Delivering a plain 0x09 is indistinguishable from
        // a forward Tab and breaks those bindings.
        let encoder = KeyEncoder()
        XCTAssertEqual(encoder.encode(chars: "\t", modifiers: [.shift]),
                       Data([0x1B, 0x5B, 0x5A]))
    }

    func test_escape() {
        let encoder = KeyEncoder()
        XCTAssertEqual(encoder.encode(chars: "\u{1B}", modifiers: []), Data([0x1B]))
    }

    func test_arrows() {
        let encoder = KeyEncoder()
        XCTAssertEqual(encoder.encodeSpecial(.up, modifiers: []),    Data([0x1B, 0x5B, 0x41])) // ESC[A
        XCTAssertEqual(encoder.encodeSpecial(.down, modifiers: []),  Data([0x1B, 0x5B, 0x42])) // ESC[B
        XCTAssertEqual(encoder.encodeSpecial(.right, modifiers: []), Data([0x1B, 0x5B, 0x43])) // ESC[C
        XCTAssertEqual(encoder.encodeSpecial(.left, modifiers: []),  Data([0x1B, 0x5B, 0x44])) // ESC[D
    }

    func test_ctrlPrintable() {
        let encoder = KeyEncoder()
        // Ctrl-C -> 0x03
        XCTAssertEqual(encoder.encode(chars: "c", modifiers: [.control]), Data([0x03]))
        // Ctrl-A -> 0x01, Ctrl-Z -> 0x1A
        XCTAssertEqual(encoder.encode(chars: "a", modifiers: [.control]), Data([0x01]))
        XCTAssertEqual(encoder.encode(chars: "z", modifiers: [.control]), Data([0x1A]))
    }

    func test_ctrlBoundaryCases() {
        let encoder = KeyEncoder()
        // Ctrl-@ (0x40) -> NUL (0x00)
        XCTAssertEqual(encoder.encode(chars: "@", modifiers: [.control]), Data([0x00]))
        // Ctrl-Space (0x20) -> NUL (0x00)
        XCTAssertEqual(encoder.encode(chars: " ", modifiers: [.control]), Data([0x00]))
        // Ctrl-? (0x3F) -> DEL (0x7F)
        XCTAssertEqual(encoder.encode(chars: "?", modifiers: [.control]), Data([0x7F]))
    }

    func test_optionAsMeta() {
        let encoder = KeyEncoder()  // defaults to Option=Meta=ESC+
        XCTAssertEqual(encoder.encode(chars: "a", modifiers: [.option]), Data([0x1B, 0x61]))
    }

    func test_emptyStringProducesNothing() {
        let encoder = KeyEncoder()
        XCTAssertEqual(encoder.encode(chars: "", modifiers: []), Data())
    }

    /// Regression for swift-tests-input F7: `controlByte(for:)` has five
    /// branches — 0x40-0x5F (@...?), 0x61-0x7A (a..z), 0x20→NUL, 0x3F→DEL,
    /// default→nil. The existing tests only hit a few interior cells. This
    /// sweep pins the edges that matter for shell usability.
    func test_ctrlBoundaryCases_fullCoverage() {
        let encoder = KeyEncoder()
        // Ctrl+A uppercase — 0x41 - 0x40 = 0x01. Parallels the lowercase
        // path in `test_ctrlPrintable` but ensures the 0x41-0x5A portion
        // of the 0x40-0x5F range is pinned.
        XCTAssertEqual(encoder.encode(chars: "A", modifiers: [.control]),
                       Data([0x01]), "Ctrl+A (uppercase) → 0x01")
        // Ctrl+[ — 0x5B - 0x40 = 0x1B = ESC. Documents the intentional
        // collision with plain Escape. Kitty disambiguation, when active,
        // remaps this via `ctrlColliderCodepoint`; in legacy mode below
        // it is indistinguishable from pressing Escape — and that is the
        // documented, compatible behaviour every terminfo knows.
        XCTAssertEqual(encoder.encode(chars: "[", modifiers: [.control]),
                       Data([0x1B]), "Ctrl+[ → ESC (0x1B)")
        // Ctrl+\ — 0x5C - 0x40 = 0x1C = SIGQUIT. Critical for shell users
        // — silently mapping this to anything else would break every
        // runaway process kill.
        XCTAssertEqual(encoder.encode(chars: "\\", modifiers: [.control]),
                       Data([0x1C]), "Ctrl+\\ → 0x1C (SIGQUIT trigger)")
        // Ctrl+] — 0x5D - 0x40 = 0x1D. telnet escape, Emacs `C-]`.
        XCTAssertEqual(encoder.encode(chars: "]", modifiers: [.control]),
                       Data([0x1D]), "Ctrl+] → 0x1D")
        // Ctrl+^ — 0x5E - 0x40 = 0x1E. rare; readline's `character-
        // search-backward` bind.
        XCTAssertEqual(encoder.encode(chars: "^", modifiers: [.control]),
                       Data([0x1E]), "Ctrl+^ → 0x1E")
        // Ctrl+_ — 0x5F - 0x40 = 0x1F. Emacs undo binding.
        XCTAssertEqual(encoder.encode(chars: "_", modifiers: [.control]),
                       Data([0x1F]), "Ctrl+_ → 0x1F")
    }

    /// Regression for swift-tests-input F7: characters outside the
    /// `controlByte` ranges (digits, common prose punctuation) fall
    /// through to the Option-Meta / UTF-8 tail. With default
    /// `optionIsMeta=true` and `.control` only (no `.option`), Ctrl+digit
    /// encodes as the plain digit byte — matches every legacy terminal.
    func test_ctrlDigitsAndPunctuation_fallThroughToPlainByte() {
        let encoder = KeyEncoder()
        // Ctrl+1 — digit 0x31 has no controlByte mapping. Encoder falls
        // through and emits the plain digit so readline's undo-on-digit
        // keybindings work as expected.
        XCTAssertEqual(encoder.encode(chars: "1", modifiers: [.control]),
                       Data([0x31]), "Ctrl+1 falls through to plain '1'")
        // Ctrl+. — 0x2E also has no mapping. Emit the period unchanged.
        XCTAssertEqual(encoder.encode(chars: ".", modifiers: [.control]),
                       Data([0x2E]), "Ctrl+. falls through to plain '.'")
    }
}
