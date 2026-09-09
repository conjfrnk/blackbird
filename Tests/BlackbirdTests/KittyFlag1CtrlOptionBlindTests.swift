import XCTest
@testable import Blackbird

/// Blind behaviour tests for `KeyEncoder` under kitty progressive-enhancement
/// flag 1 (`disambiguateEscCodes`) for the key classes that were previously
/// only pinned for Enter / Tab / Backspace: plain Esc, Ctrl+letter, and the
/// Option (Meta vs Native) chords.
///
/// Wire form is CSI u: `ESC [ <cp> ; <mod> u`, `mod` omitted when it is 1.
/// Modifier bits: shift 1, alt 2, ctrl 4; `mod = 1 + sum`. The code point is
/// always the *unshifted* key (`c` for Ctrl+Shift+C) with Shift carried in
/// the modifier field, per
/// https://sw.kovidgoyal.net/kitty/keyboard-protocol/#modifiers
///
/// Written without reading `KeyEncoder.swift` bodies (only the public
/// signature + doc comment).
final class KittyFlag1CtrlOptionBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Helpers

    /// `ESC [ <codepoint> ; <mod> u`, collapsing `mod == 1` to `ESC [ <cp> u`.
    private func csiU(_ codepoint: Int, mod: Int = 1) -> Data {
        var s = "\u{1B}[\(codepoint)"
        if mod > 1 { s += ";\(mod)" }
        s += "u"
        return Data(s.utf8)
    }

    private let flag1: BBTermMode = [.disambiguateEscCodes]
    private let flag1and8: BBTermMode = [.disambiguateEscCodes, .reportAllKeysAsEsc]

    private func hex(_ d: Data) -> String {
        d.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    // MARK: - Esc

    func test_plainEsc_flag1_isCsiU27() {
        let enc = KeyEncoder()
        let got = enc.encode(chars: "\u{1B}", modifiers: [], mode: flag1)
        XCTAssertEqual(got, csiU(27),
                       "plain Esc under flag 1 must be ESC[27u, got \(hex(got))")
    }

    // MARK: - Unmodified legacy keys stay legacy

    func test_plainEnterTabBackspace_flag1_stayLegacyBytes() {
        let enc = KeyEncoder()
        XCTAssertEqual(enc.encode(chars: "\r", modifiers: [], mode: flag1), Data([0x0D]),
                       "unmodified Enter must stay CR under flag 1")
        XCTAssertEqual(enc.encode(chars: "\t", modifiers: [], mode: flag1), Data([0x09]),
                       "unmodified Tab must stay HT under flag 1")
        XCTAssertEqual(enc.encode(chars: "\u{7F}", modifiers: [], mode: flag1), Data([0x7F]),
                       "unmodified Backspace must stay DEL under flag 1")
    }

    // MARK: - Ctrl + letter

    func test_ctrlC_flag1_isCsiU99Mod5() {
        let enc = KeyEncoder()
        let got = enc.encode(chars: "c", modifiers: [.control], mode: flag1)
        XCTAssertEqual(got, csiU(99, mod: 5), "Ctrl+c under flag 1, got \(hex(got))")
    }

    func test_ctrlA_flag1_isCsiU97Mod5() {
        let enc = KeyEncoder()
        let got = enc.encode(chars: "a", modifiers: [.control], mode: flag1)
        XCTAssertEqual(got, csiU(97, mod: 5), "Ctrl+a under flag 1, got \(hex(got))")
    }

    func test_ctrlZ_flag1_isCsiU122Mod5() {
        let enc = KeyEncoder()
        let got = enc.encode(chars: "z", modifiers: [.control], mode: flag1)
        XCTAssertEqual(got, csiU(122, mod: 5), "Ctrl+z under flag 1, got \(hex(got))")
    }

    func test_ctrlShiftC_flag1_usesUnshiftedCodepoint_withShiftBit() {
        // AppKit hands us "C" for Ctrl+Shift+c. The kitty wire form keeps the
        // unshifted key (99) and carries Shift in the modifier field: 1+1+4 = 6.
        let enc = KeyEncoder()
        let got = enc.encode(chars: "C", modifiers: [.control, .shift], mode: flag1)
        XCTAssertEqual(got, csiU(99, mod: 6),
                       "Ctrl+Shift+C under flag 1 must be ESC[99;6u, got \(hex(got))")
    }

    // MARK: - Option as Meta

    func test_metaOptionA_flag1_isCsiU97Mod3() {
        let enc = KeyEncoder(optionIsMeta: true)
        let got = enc.encode(chars: "a", modifiers: [.option], mode: flag1)
        XCTAssertEqual(got, csiU(97, mod: 3), "Meta Option+a under flag 1, got \(hex(got))")
    }

    func test_metaShiftOptionA_flag1_isCsiU97Mod4() {
        let enc = KeyEncoder(optionIsMeta: true)
        let got = enc.encode(chars: "A", modifiers: [.option, .shift], mode: flag1)
        XCTAssertEqual(got, csiU(97, mod: 4),
                       "Meta Shift+Option+A under flag 1 must be ESC[97;4u, got \(hex(got))")
    }

    func test_metaCtrlOptionA_flag1_isCsiU97Mod7() {
        let enc = KeyEncoder(optionIsMeta: true)
        let got = enc.encode(chars: "a", modifiers: [.option, .control], mode: flag1)
        XCTAssertEqual(got, csiU(97, mod: 7),
                       "Meta Ctrl+Option+a under flag 1 must be ESC[97;7u, got \(hex(got))")
    }

    // MARK: - Option native

    func test_nativeOptionA_flag1_emitsComposedCharacter_notCsiU() {
        // Native-Option: AppKit already resolved Option+a into "å"; the
        // terminal must pass the glyph through and never surface Option.
        let enc = KeyEncoder(optionIsMeta: false)
        let got = enc.encode(chars: "å", modifiers: [.option], mode: flag1)
        XCTAssertEqual(got, Data("å".utf8),
                       "Native Option+a must emit UTF-8 'å', got \(hex(got))")
        XCTAssertFalse(got.starts(with: [0x1B]),
                       "Native Option must not produce an escape sequence")
    }

    // MARK: - No kitty flag: legacy untouched

    func test_noFlags_ctrlC_isC0Byte() {
        let enc = KeyEncoder()
        XCTAssertEqual(enc.encode(chars: "c", modifiers: [.control], mode: []), Data([0x03]))
    }

    func test_noFlags_esc_isBare0x1B() {
        let enc = KeyEncoder()
        XCTAssertEqual(enc.encode(chars: "\u{1B}", modifiers: [], mode: []), Data([0x1B]))
    }

    func test_noFlags_metaOptionA_isEscPrefixed() {
        let enc = KeyEncoder(optionIsMeta: true)
        XCTAssertEqual(enc.encode(chars: "a", modifiers: [.option], mode: []),
                       Data([0x1B, 0x61]))
    }

    // MARK: - Flag 8 (report all keys as escapes) on top of flag 1

    func test_flag1and8_ctrlC_stillCsiU99Mod5() {
        let enc = KeyEncoder()
        let got = enc.encode(chars: "c", modifiers: [.control], mode: flag1and8)
        XCTAssertEqual(got, csiU(99, mod: 5), "Ctrl+c under flags 1+8, got \(hex(got))")
    }

    func test_flag1and8_plainA_isCsiU97() {
        let enc = KeyEncoder()
        let got = enc.encode(chars: "a", modifiers: [], mode: flag1and8)
        XCTAssertEqual(got, csiU(97), "plain 'a' under flags 1+8 must be ESC[97u, got \(hex(got))")
    }
}
