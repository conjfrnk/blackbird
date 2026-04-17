import XCTest
@testable import Blackbird

/// Pins KeyEncoder behavior under the kitty keyboard protocol, progressive
/// enhancement flag 1 (`disambiguateEscCodes`). Without this path, Shift+Enter,
/// Ctrl+i, Ctrl+m, modified Esc, and modified Backspace are indistinguishable
/// from their unmodified forms — which breaks Claude Code, nvim 0.10+, and any
/// TUI that negotiates kitty keyboard support.
///
/// Reference: https://sw.kovidgoyal.net/kitty/keyboard-protocol/#progressive-enhancement
final class KittyKeyboardProtocolTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Helpers

    /// `ESC [ <codepoint> ; <mod> u`. `mod == 1` collapses to `ESC [ <cp> u`.
    private func csiU(_ codepoint: Int, mod: Int = 1) -> Data {
        var s = "\u{1B}[\(codepoint)"
        if mod > 1 { s += ";\(mod)" }
        s += "u"
        return Data(s.utf8)
    }

    private let kittyOn: BBTermMode = [.disambiguateEscCodes]

    // MARK: - Enter

    func test_shiftEnter_emitsCsiU_whenDisambiguate() {
        // THE target bug: Shift+Enter in Claude Code must insert a newline
        // into the prompt, not submit. That requires the terminal to emit
        // `ESC[13;2u` instead of bare `\r`.
        let enc = KeyEncoder()
        XCTAssertEqual(enc.encode(chars: "\r", modifiers: [.shift], mode: kittyOn),
                       csiU(13, mod: 2))
    }

    func test_ctrlEnter_emitsCsiU_whenDisambiguate() {
        let enc = KeyEncoder()
        XCTAssertEqual(enc.encode(chars: "\r", modifiers: [.control], mode: kittyOn),
                       csiU(13, mod: 5))
    }

    func test_plainEnter_stillCR_evenWhenDisambiguate() {
        // Kitty spec: unmodified Enter stays as legacy CR so line-discipline
        // shells continue to work transparently.
        let enc = KeyEncoder()
        XCTAssertEqual(enc.encode(chars: "\r", modifiers: [], mode: kittyOn),
                       Data([0x0D]))
    }

    func test_plainEnter_legacyMode_stillCR() {
        let enc = KeyEncoder()
        XCTAssertEqual(enc.encode(chars: "\r", modifiers: [], mode: []),
                       Data([0x0D]))
    }

    func test_shiftEnter_legacyMode_stillCR() {
        // Protect the default: without the TUI asking for kitty mode, we must
        // not unilaterally start emitting CSI u — that would confuse legacy
        // TUIs that assume `\r` is the only thing an Enter can produce.
        let enc = KeyEncoder()
        XCTAssertEqual(enc.encode(chars: "\r", modifiers: [.shift], mode: []),
                       Data([0x0D]))
    }

    // MARK: - Ctrl + C0-aliasing letters

    func test_ctrlI_disambiguated_distinctFromTab() {
        // Without disambiguation, Ctrl+i and Tab both produce 0x09. The kitty
        // protocol exists specifically to fix this.
        let enc = KeyEncoder()
        XCTAssertEqual(enc.encode(chars: "i", modifiers: [.control], mode: kittyOn),
                       csiU(105, mod: 5))
    }

    func test_ctrlM_disambiguated_distinctFromEnter() {
        let enc = KeyEncoder()
        XCTAssertEqual(enc.encode(chars: "m", modifiers: [.control], mode: kittyOn),
                       csiU(109, mod: 5))
    }

    func test_ctrlOpenBracket_disambiguated_distinctFromEsc() {
        let enc = KeyEncoder()
        XCTAssertEqual(enc.encode(chars: "[", modifiers: [.control], mode: kittyOn),
                       csiU(91, mod: 5))
    }

    func test_ctrlH_disambiguated_distinctFromBackspace() {
        let enc = KeyEncoder()
        XCTAssertEqual(enc.encode(chars: "h", modifiers: [.control], mode: kittyOn),
                       csiU(104, mod: 5))
    }

    func test_ctrlC_disambiguateMode_stillSendsSigInt() {
        // Ctrl+c is NOT an ambiguous binding — 0x03 is unique to Ctrl+c. Every
        // shell in the world expects 0x03 for SIGINT. Emitting CSI u here
        // would silently break `^C`.
        let enc = KeyEncoder()
        XCTAssertEqual(enc.encode(chars: "c", modifiers: [.control], mode: kittyOn),
                       Data([0x03]))
    }

    func test_ctrlA_disambiguateMode_stillControlByte() {
        let enc = KeyEncoder()
        XCTAssertEqual(enc.encode(chars: "a", modifiers: [.control], mode: kittyOn),
                       Data([0x01]))
    }

    // MARK: - Tab

    func test_shiftTab_disambiguateMode_emitsCsiU() {
        // Matches kitty's own behavior: in disambiguate mode Shift+Tab becomes
        // CSI 9;2u rather than the legacy back-tab (CSI Z).
        let enc = KeyEncoder()
        XCTAssertEqual(enc.encode(chars: "\t", modifiers: [.shift], mode: kittyOn),
                       csiU(9, mod: 2))
    }

    func test_plainTab_disambiguateMode_stillHT() {
        let enc = KeyEncoder()
        XCTAssertEqual(enc.encode(chars: "\t", modifiers: [], mode: kittyOn),
                       Data([0x09]))
    }

    func test_shiftTab_legacyMode_stillCsiZ() {
        // Existing contract: readline's reverse-menu relies on CSI Z when the
        // TUI hasn't negotiated kitty. Preserve it.
        let enc = KeyEncoder()
        XCTAssertEqual(enc.encode(chars: "\t", modifiers: [.shift], mode: []),
                       Data([0x1B, 0x5B, 0x5A]))
    }

    // MARK: - Backspace

    func test_shiftBackspace_disambiguateMode_emitsCsiU() {
        let enc = KeyEncoder()
        XCTAssertEqual(enc.encode(chars: "\u{7F}", modifiers: [.shift], mode: kittyOn),
                       csiU(127, mod: 2))
    }

    func test_plainBackspace_disambiguateMode_stillDel() {
        let enc = KeyEncoder()
        XCTAssertEqual(enc.encode(chars: "\u{7F}", modifiers: [], mode: kittyOn),
                       Data([0x7F]))
    }

    // MARK: - Escape

    func test_shiftEsc_disambiguateMode_emitsCsiU() {
        let enc = KeyEncoder()
        XCTAssertEqual(enc.encode(chars: "\u{1B}", modifiers: [.shift], mode: kittyOn),
                       csiU(27, mod: 2))
    }

    func test_plainEsc_disambiguateMode_stillEsc() {
        let enc = KeyEncoder()
        XCTAssertEqual(enc.encode(chars: "\u{1B}", modifiers: [], mode: kittyOn),
                       Data([0x1B]))
    }

    // MARK: - ⌘ always suppressed

    func test_cmdShiftEnter_isSuppressed_evenWithKitty() {
        // Defence-in-depth: if ⌘ were ever passed in with Shift+Enter, we
        // must not leak the CSI u sequence as PTY bytes.
        let enc = KeyEncoder()
        XCTAssertEqual(enc.encode(chars: "\r", modifiers: [.command, .shift], mode: kittyOn),
                       Data())
    }

    // MARK: - End-to-end: round-trip with real BBTerm

    func test_endToEnd_kittyProtocolLightsBitAndFlipsEncoder() {
        // Round trip: feed the protocol-enable sequence into a real BBTerm,
        // read the snapshot's BBTermMode, pass it to the encoder — the encoder
        // must switch behavior.
        guard let term = BBTerm(size: .init(cols: 80, rows: 24)) else {
            XCTFail("BBTerm init")
            return
        }
        term.input("\u{1B}[>1u")
        guard let snap = term.snapshot() else {
            XCTFail("snapshot")
            return
        }
        XCTAssertTrue(snap.termMode.contains(.disambiguateEscCodes),
                      "ESC[>1u must light disambiguateEscCodes")

        let enc = KeyEncoder()
        XCTAssertEqual(enc.encode(chars: "\r", modifiers: [.shift], mode: snap.termMode),
                       csiU(13, mod: 2))
    }
}
