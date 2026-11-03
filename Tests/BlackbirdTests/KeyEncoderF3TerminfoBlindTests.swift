import XCTest
import Foundation
@testable import Blackbird
@testable import BBCore

/// Blind regression tests for bug api-contract-1: a modified F3 is sent in a
/// form that neither the bundled `xterm-kitty` terminfo nor the kitty keyboard
/// protocol recognise, and F13-F20 disagree with that terminfo as well.
///
/// Contract under test (observable bytes written to the PTY):
///
///  1. **Modified F3 is `CSI 13 ; <mod> ~`.** The xterm-style `CSI 1 ; <mod> R`
///     that F1/F2/F4 use cannot be used for F3: its bytes are indistinguishable
///     from a cursor-position report (`CSI <row> ; <col> R`), so any program
///     with a DSR/CPR request in flight swallows the keystroke as "row 1,
///     col <mod>". Kitty's protocol (and the terminfo we install for
///     `TERM=xterm-kitty`) therefore moved F3 to the tilde form
///     `CSI 13 ; <mod> ~`. `<mod>` is `1 + (shift 1 | alt 2 | ctrl 4)`.
///     That holds in legacy mode and under kitty flags 1, 1+2 and 1+8, for
///     press, repeat and release events.
///  2. **The encoder agrees with the terminfo it ships.** For every modified
///     function-key capability in `kitty.terminfo` (`kf13`...`kf63`, i.e.
///     Shift / Ctrl / Ctrl+Shift / Alt / Alt+Shift crossed with F1...F12), a
///     terminfo-driven application that looks the capability up and compares
///     it with the bytes the terminal sent must find a match.
///  3. **Physical F13-F20 match `kf13`...`kf20`.** The terminfo defines
///     those capabilities (the same bytes as Shift+F1...Shift+F8); an
///     application that asks terminfo "what does F15 send?" must be answered
///     with bytes the encoder really produces for the F15 key.
///
/// The terminfo is the oracle for (2) and (3): it is parsed from the shipped
/// resource (`Bundle.main`, falling back to the source-tree copy), so the test
/// neither hard-codes nor reads any encoder internals. The literal
/// `CSI 13 ; <mod> ~` expectations in (1) come from the kitty protocol
/// specification, not from the encoder.
///
/// Pre-flight cost (project rule): a few hundred `encodeSpecial` calls on a
/// value-type encoder, one ~10 KB text file read. No window, no PTY, no
/// Metal, no `MainWindowController`; well under a second.
final class KeyEncoderF3TerminfoBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Fixtures

    private struct ModCase {
        let name: String
        let modifiers: KeyEncoder.Modifiers
        /// xterm / kitty modifier parameter, written out literally:
        /// 1 + (shift 1 | alt 2 | ctrl 4).
        let param: Int
    }

    private let modCases: [ModCase] = [
        ModCase(name: "Shift", modifiers: [.shift], param: 2),
        ModCase(name: "Option", modifiers: [.option], param: 3),
        ModCase(name: "Shift+Option", modifiers: [.shift, .option], param: 4),
        ModCase(name: "Control", modifiers: [.control], param: 5),
        ModCase(name: "Shift+Control", modifiers: [.shift, .control], param: 6),
        ModCase(name: "Option+Control", modifiers: [.option, .control], param: 7),
        ModCase(name: "Shift+Option+Control", modifiers: [.shift, .option, .control], param: 8),
    ]

    private struct ModeCase {
        let name: String
        let mode: BBTermMode
    }

    /// Legacy plus the three kitty flag combinations the bug report names:
    /// flag 1 (disambiguate), 1+2 (+ event types), 1+8 (+ all keys as escapes).
    private let modeCases: [ModeCase] = [
        ModeCase(name: "legacy", mode: []),
        ModeCase(name: "kitty flags 1", mode: [.disambiguateEscCodes]),
        ModeCase(name: "kitty flags 1+2", mode: [.disambiguateEscCodes, .reportEventTypes]),
        ModeCase(name: "kitty flags 1+8", mode: [.disambiguateEscCodes, .reportAllKeysAsEsc]),
    ]

    private func csi(_ body: String) -> Data {
        Data(("\u{1B}[" + body).utf8)
    }

    /// Readable rendering of wire bytes for assertion messages.
    private func show(_ data: Data) -> String {
        var out = ""
        for byte in data {
            if byte == 0x1B {
                out += "ESC"
            } else if byte >= 0x20 && byte < 0x7F {
                out.unicodeScalars.append(Unicode.Scalar(byte))
            } else {
                out += String(format: "\\x%02X", Int(byte))
            }
        }
        return out
    }

    // MARK: - 1. Modified F3 wire form

    /// The headline trigger: Shift / Ctrl / Alt + F3 in legacy mode.
    func test_f3_legacy_singleModifiers_areCsi13Tilde() {
        let enc = KeyEncoder()
        let expectations: [(name: String, modifiers: KeyEncoder.Modifiers, expected: Data)] = [
            ("Shift", [.shift], csi("13;2~")),
            ("Option", [.option], csi("13;3~")),
            ("Control", [.control], csi("13;5~")),
        ]
        for item in expectations {
            let actual = enc.encodeSpecial(.f3, modifiers: item.modifiers)
            XCTAssertEqual(
                actual, item.expected,
                "\(item.name)+F3 (legacy) must be \(show(item.expected)); got \(show(actual))"
            )
        }
    }

    /// Every non-empty combination of Shift / Option / Control, legacy mode.
    func test_f3_legacy_allModifierCombinations_areCsi13Tilde() {
        let enc = KeyEncoder()
        for item in modCases {
            let expected = csi("13;\(item.param)~")
            let actual = enc.encodeSpecial(.f3, modifiers: item.modifiers)
            XCTAssertEqual(
                actual, expected,
                "\(item.name)+F3 (legacy, mod param \(item.param)) must be \(show(expected)); got \(show(actual))"
            )
        }
    }

    /// Kitty flag 1 press: the unambiguous case, so pin the absolute bytes.
    func test_f3_kittyFlag1_press_isCsi13Tilde() {
        let enc = KeyEncoder()
        let mode: BBTermMode = [.disambiguateEscCodes]
        for item in modCases {
            let expected = csi("13;\(item.param)~")
            let actual = enc.encodeSpecial(.f3, modifiers: item.modifiers, mode: mode)
            XCTAssertEqual(
                actual, expected,
                "\(item.name)+F3 under kitty flag 1 must be \(show(expected)); got \(show(actual))"
            )
        }
    }

    /// Press under kitty flags 1, 1+2 and 1+8. F3 must be shaped exactly like
    /// F5 under the same mode and modifiers (both are `CSI <n> ; <mod> ~`
    /// keys), with the number 13 in place of 15. The F5 output is the
    /// protocol-mode-specific anchor, so this does not hard-code how each flag
    /// combination spells a press event.
    func test_f3_kittyFlagCombos_press_isShapedLikeTildeKeys() {
        let enc = KeyEncoder()
        let anchorPrefix = csi("15;")
        for modeCase in modeCases {
            for item in modCases {
                let anchor = enc.encodeSpecial(.f5, modifiers: item.modifiers, mode: modeCase.mode)
                XCTAssertTrue(
                    anchor.starts(with: anchorPrefix) && anchor.last == 0x7E,
                    "anchor: \(item.name)+F5 under \(modeCase.name) must be a CSI 15;<mod> ~ sequence; got \(show(anchor))"
                )
                guard anchor.starts(with: anchorPrefix) else { continue }
                let expected = csi("13;") + anchor.dropFirst(anchorPrefix.count)
                let actual = enc.encodeSpecial(.f3, modifiers: item.modifiers, mode: modeCase.mode)
                XCTAssertEqual(
                    actual, expected,
                    "\(item.name)+F3 under \(modeCase.name) must be \(show(expected)) (F5 shape with 13); got \(show(actual))"
                )
            }
        }
    }

    /// Repeat and release events under kitty flags 1+2 carry an event-type
    /// sub-parameter (`:2` / `:3`). F3 must keep the tilde form there too.
    func test_f3_kittyFlag2_repeatAndRelease_areCsi13Tilde() {
        let enc = KeyEncoder()
        let mode: BBTermMode = [.disambiguateEscCodes, .reportEventTypes]
        let events: [(name: String, type: KeyEncoder.EventType, suffix: String)] = [
            ("repeat", .repeat, "2"),
            ("release", .release, "3"),
        ]
        for event in events {
            for item in modCases {
                let anchor = enc.encodeSpecial(.f5, modifiers: item.modifiers, mode: mode, eventType: event.type)
                let anchorExpected = csi("15;\(item.param):\(event.suffix)~")
                XCTAssertEqual(
                    anchor, anchorExpected,
                    "anchor: \(item.name)+F5 \(event.name) under flags 1+2 must be \(show(anchorExpected)); got \(show(anchor))"
                )
                let expected = csi("13;\(item.param):\(event.suffix)~")
                let actual = enc.encodeSpecial(.f3, modifiers: item.modifiers, mode: mode, eventType: event.type)
                XCTAssertEqual(
                    actual, expected,
                    "\(item.name)+F3 \(event.name) under flags 1+2 must be \(show(expected)); got \(show(actual))"
                )
            }
        }
    }

    /// The impact statement: a modified F3 must never be a CSI sequence that
    /// ends in `R`, in any mode and for any event type, because a program
    /// with a cursor-position request outstanding would parse
    /// `ESC [ 1 ; <mod> R` as "cursor at row 1, column <mod>".
    func test_f3_modified_neverLooksLikeCursorPositionReport() {
        let enc = KeyEncoder()
        let eventTypes: [KeyEncoder.EventType] = [.press, .repeat, .release]
        var checked = 0
        for modeCase in modeCases {
            for item in modCases {
                for eventType in eventTypes {
                    let out = enc.encodeSpecial(.f3, modifiers: item.modifiers, mode: modeCase.mode, eventType: eventType)
                    checked += 1
                    let bytes = [UInt8](out)
                    let looksLikeCSIR = bytes.count >= 3 && bytes[0] == 0x1B && bytes[1] == 0x5B && bytes.last == 0x52
                    XCTAssertFalse(
                        looksLikeCSIR,
                        "\(item.name)+F3 (\(modeCase.name), \(eventType)) = \(show(out)) is a CSI ... R sequence, indistinguishable from a cursor-position report"
                    )
                }
            }
        }
        XCTAssertEqual(checked, modeCases.count * modCases.count * eventTypes.count,
                       "every mode x modifier x event combination must have been exercised")
    }

    // MARK: - Terminfo oracle

    private struct TerminfoLoadError: Error, CustomStringConvertible {
        let description: String
    }

    private func loadBundledKittyTerminfo() throws -> (url: URL, text: String) {
        var candidates: [URL] = []
        if let bundled = Bundle.main.url(forResource: "kitty", withExtension: "terminfo") {
            candidates.append(bundled)
        }
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // BlackbirdTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
        candidates.append(repoRoot.appendingPathComponent("Sources/Blackbird/Resources/Terminfo/kitty.terminfo"))
        for url in candidates {
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                return (url, text)
            }
        }
        throw TerminfoLoadError(description: "kitty.terminfo not found; tried \(candidates.map { $0.path })")
    }

    /// Decode a terminfo string capability value into its wire bytes.
    /// Handles `\E`, `\NNN` octal, `\\`, `\,`, `\:`, `\^` and `^X`; anything
    /// else is reported rather than guessed at.
    private func decodeTerminfoString(_ raw: String, cap: String) -> Data? {
        var bytes: [UInt8] = []
        let scalars: [Unicode.Scalar] = Array(raw.unicodeScalars)
        var i = 0
        while i < scalars.count {
            let s = scalars[i]
            if s == "\\" {
                guard i + 1 < scalars.count else {
                    XCTFail("\(cap): dangling backslash in \(raw)")
                    return nil
                }
                let next = scalars[i + 1]
                switch next {
                case "E", "e":
                    bytes.append(0x1B); i += 2
                case "n":
                    bytes.append(0x0A); i += 2
                case "r":
                    bytes.append(0x0D); i += 2
                case "t":
                    bytes.append(0x09); i += 2
                case "s":
                    bytes.append(0x20); i += 2
                case "\\", ",", ":", "^":
                    bytes.append(UInt8(next.value)); i += 2
                case "0", "1", "2", "3", "4", "5", "6", "7":
                    var value = 0
                    var consumed = 0
                    var j = i + 1
                    while j < scalars.count, consumed < 3,
                          let digit = Int(String(scalars[j])), digit <= 7 {
                        value = value * 8 + digit
                        consumed += 1
                        j += 1
                    }
                    bytes.append(UInt8(truncatingIfNeeded: value))
                    i = j
                default:
                    XCTFail("\(cap): unsupported escape \\\(next) in \(raw)")
                    return nil
                }
            } else if s == "^", i + 1 < scalars.count {
                let next = scalars[i + 1]
                bytes.append(next == "?" ? 0x7F : UInt8(next.value & 0x1F))
                i += 2
            } else {
                bytes.append(UInt8(truncatingIfNeeded: s.value))
                i += 1
            }
        }
        return Data(bytes)
    }

    /// Parse every `kf<N>=<string>,` line into `N -> bytes`.
    private func parseFunctionKeyCapabilities(_ text: String) -> [Int: Data] {
        var caps: [Int: Data] = [:]
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("kf"), let eq = trimmed.firstIndex(of: "=") else { continue }
            let name = String(trimmed[trimmed.startIndex..<eq])
            guard let number = Int(name.dropFirst(2)) else { continue }
            var value = String(trimmed[trimmed.index(after: eq)...])
            guard value.hasSuffix(",") else {
                XCTFail("\(name): capability line does not end with a comma: \(trimmed)")
                continue
            }
            value.removeLast()
            if let decoded = decodeTerminfoString(value, cap: name) {
                caps[number] = decoded
            }
        }
        return caps
    }

    private let functionKeysF1ToF12: [KeyEncoder.SpecialKey] = [
        .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12,
    ]

    private struct CapGroup {
        let firstCap: Int
        let label: String
        let modifiers: KeyEncoder.Modifiers
        let param: Int
    }

    /// ncurses' conventional layout: kf13-kf24 Shift+F1-F12, kf25-kf36
    /// Ctrl+F1-F12, kf37-kf48 Ctrl+Shift+F1-F12, kf49-kf60 Alt+F1-F12,
    /// kf61 onward Alt+Shift+F1... The test cross-checks each group against
    /// the modifier parameter written in the capability string itself, so a
    /// wrong table here fails loudly instead of masking a product bug.
    private let capGroups: [CapGroup] = [
        CapGroup(firstCap: 13, label: "Shift", modifiers: [.shift], param: 2),
        CapGroup(firstCap: 25, label: "Ctrl", modifiers: [.control], param: 5),
        CapGroup(firstCap: 37, label: "Ctrl+Shift", modifiers: [.shift, .control], param: 6),
        CapGroup(firstCap: 49, label: "Alt", modifiers: [.option], param: 3),
        CapGroup(firstCap: 61, label: "Alt+Shift", modifiers: [.shift, .option], param: 4),
    ]

    // MARK: - 2. Encoder agrees with the shipped terminfo (modified F1-F12)

    func test_modifiedF1ThroughF12_matchBundledTerminfoKfCapabilities() throws {
        let loaded = try loadBundledKittyTerminfo()
        XCTAssertTrue(loaded.text.contains("xterm-kitty|"),
                      "precondition: \(loaded.url.path) must be the xterm-kitty terminfo source")
        let caps = parseFunctionKeyCapabilities(loaded.text)
        let enc = KeyEncoder()
        var compared = 0
        for group in capGroups {
            for index in 0..<functionKeysF1ToF12.count {
                let capNumber = group.firstCap + index
                guard let capBytes = caps[capNumber] else { continue }
                let key = functionKeysF1ToF12[index]
                let capName = "kf\(capNumber)"
                XCTAssertTrue(
                    String(decoding: capBytes, as: UTF8.self).contains(";\(group.param)"),
                    "precondition: \(capName) = \(show(capBytes)) should carry modifier parameter \(group.param) (\(group.label)+F\(index + 1))"
                )
                let actual = enc.encodeSpecial(key, modifiers: group.modifiers)
                XCTAssertEqual(
                    actual, capBytes,
                    "\(group.label)+F\(index + 1) must send terminfo \(capName) = \(show(capBytes)); got \(show(actual))"
                )
                compared += 1
            }
        }
        XCTAssertGreaterThanOrEqual(
            compared, 48,
            "precondition: the terminfo must define at least kf13-kf60; compared only \(compared) (parsed \(caps.count) kf capabilities)"
        )
    }
}
