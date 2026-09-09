import XCTest
@testable import Blackbird
import BBCore

/// Cross-language pins for the two `BBTermMode` bits added in v0.8.1:
/// `.alternateScroll` (DEC 1007, bit 17) and `.utf8Mouse` (DEC 1005,
/// bit 18). Same shape as `FFIContractTests`: each Swift raw value is
/// compared against the cbindgen-emitted C constant so a Rust renumber
/// either fails to compile here (constant gone) or trips the assertion
/// (constant moved).
///
/// The second half of the file checks the bits through a real `BBTerm`
/// so the Swift constant, the C constant, and the Rust producer all agree
/// on the same bit at runtime — a Swift-only pin could still pass if the
/// header and the Rust `bb_mode` module disagreed.
///
/// Memory / time pre-flight: the runtime tests own one 10 × 3 `BBTerm`
/// with a 16-line scrollback each (a few KB). No snapshot allocation —
/// `currentMode` is a plain getter. <50 KB, <10 ms per test.
final class FFIContractAltScrollModeBitsTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Header pins

    func testAlternateScroll_rawValueMatchesExportedC() {
        XCTAssertEqual(BBTermMode.alternateScroll.rawValue, UInt32(ALTERNATE_SCROLL),
                       "Swift .alternateScroll must equal C ALTERNATE_SCROLL")
        XCTAssertEqual(BBTermMode.alternateScroll.rawValue, 1 << 17,
                       "spec: .alternateScroll is bit 17")
    }

    func testUtf8Mouse_rawValueMatchesExportedC() {
        XCTAssertEqual(BBTermMode.utf8Mouse.rawValue, UInt32(UTF8_MOUSE),
                       "Swift .utf8Mouse must equal C UTF8_MOUSE")
        XCTAssertEqual(BBTermMode.utf8Mouse.rawValue, 1 << 18,
                       "spec: .utf8Mouse is bit 18")
    }

    func testNewBits_areDisjointFromEveryExistingBit() {
        let existing: [BBTermMode] = [
            .altScreen, .appCursor, .appKeypad, .bracketedPaste,
            .mouseReportClick, .mouseMotion, .mouseDrag, .sgrMouse,
            .focusInOut, .showCursor, .lineWrap,
            .disambiguateEscCodes, .reportEventTypes, .reportAlternateKeys,
            .reportAllKeysAsEsc, .reportAssociatedText, .modifyOtherKeys,
        ]
        for bit in existing {
            XCTAssertTrue(bit.isDisjoint(with: .alternateScroll),
                          "bit \(bit.rawValue) collides with .alternateScroll")
            XCTAssertTrue(bit.isDisjoint(with: .utf8Mouse),
                          "bit \(bit.rawValue) collides with .utf8Mouse")
        }
        XCTAssertTrue(BBTermMode.alternateScroll.isDisjoint(with: .utf8Mouse))
    }

    // MARK: - Runtime agreement with the Rust producer

    func testAlternateScroll_isOnByDefault_andFollowsDECSET1007() throws {
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 10, rows: 3), scrollback: 16))
        XCTAssertTrue(term.currentMode.contains(.alternateScroll),
                      "alacritty enables DEC 1007 by default; the bit must be set on a fresh term")
        term.input("\u{1B}[?1007l")
        XCTAssertFalse(term.currentMode.contains(.alternateScroll),
                       "CSI ? 1007 l must clear .alternateScroll")
        term.input("\u{1B}[?1007h")
        XCTAssertTrue(term.currentMode.contains(.alternateScroll),
                      "CSI ? 1007 h must set .alternateScroll again")
    }

    func testUtf8Mouse_isOffByDefault_andFollowsDECSET1005() throws {
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 10, rows: 3), scrollback: 16))
        XCTAssertFalse(term.currentMode.contains(.utf8Mouse),
                       ".utf8Mouse must be clear on a fresh term")
        term.input("\u{1B}[?1005h")
        XCTAssertTrue(term.currentMode.contains(.utf8Mouse),
                      "CSI ? 1005 h must set .utf8Mouse")
        term.input("\u{1B}[?1005l")
        XCTAssertFalse(term.currentMode.contains(.utf8Mouse),
                       "CSI ? 1005 l must clear .utf8Mouse")
    }

    func testAlternateScroll_survivesAltScreenEntry_andSnapshotAgreesWithCurrentMode() throws {
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 10, rows: 3), scrollback: 16))
        term.input("\u{1B}[?1049h")
        let mode = term.currentMode
        XCTAssertTrue(mode.contains(.altScreen))
        XCTAssertTrue(mode.contains(.alternateScroll),
                      "entering the alt screen must not disturb the 1007 default")
        let snap = try XCTUnwrap(term.snapshot())
        XCTAssertEqual(snap.termMode.rawValue & (1 << 17 | 1 << 18),
                       mode.rawValue & (1 << 17 | 1 << 18),
                       "snapshot.termMode and currentMode must report the same 1007/1005 bits")
    }
}
