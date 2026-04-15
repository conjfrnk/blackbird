import XCTest
@testable import Blackbird

final class KeyEncoderTests: XCTestCase {

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

    func test_optionAsMeta() {
        let encoder = KeyEncoder()  // defaults to Option=Meta=ESC+
        XCTAssertEqual(encoder.encode(chars: "a", modifiers: [.option]), Data([0x1B, 0x61]))
    }

    func test_emptyStringProducesNothing() {
        let encoder = KeyEncoder()
        XCTAssertEqual(encoder.encode(chars: "", modifiers: []), Data())
    }
}
