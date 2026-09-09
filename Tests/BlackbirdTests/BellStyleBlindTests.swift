import XCTest
@testable import Blackbird

/// Blind behaviour tests for `Preferences.BellStyle`, written from the
/// spec without sight of the implementation.
///
/// Contract:
///   - `allCases == [.visual, .sound, .visualAndSound, .off]`.
///   - `flashes` / `sounds` derive from the case: visual flashes only,
///     sound sounds only, visualAndSound both, off neither.
///   - Raw values "Visual", "Sound", "Visual and Sound", "Off".
///   - `Preferences.shared.bell` falls back to `.visual` for an unknown
///     stored raw value.
///
/// Pre-flight: pure enum checks plus one UserDefaults write that is
/// restored in `tearDown`. < 5 ms.
final class BellStyleBlindTests: XCTestCase {

    private var savedBellRaw: String = ""

    override func setUp() {
        super.setUp()
        savedBellRaw = Preferences.shared.bellRaw
    }

    override func tearDown() {
        Preferences.shared.bellRaw = savedBellRaw
        super.tearDown()
    }

    func test_allCases_orderAndMembership() {
        XCTAssertEqual(
            Preferences.BellStyle.allCases,
            [.visual, .sound, .visualAndSound, .off]
        )
    }

    func test_rawValues() {
        XCTAssertEqual(Preferences.BellStyle.visual.rawValue, "Visual")
        XCTAssertEqual(Preferences.BellStyle.sound.rawValue, "Sound")
        XCTAssertEqual(Preferences.BellStyle.visualAndSound.rawValue, "Visual and Sound")
        XCTAssertEqual(Preferences.BellStyle.off.rawValue, "Off")
    }

    func test_rawValues_roundTripThroughInit() {
        for style in Preferences.BellStyle.allCases {
            XCTAssertEqual(Preferences.BellStyle(rawValue: style.rawValue), style)
        }
    }

    func test_visual_flashesOnly() {
        XCTAssertTrue(Preferences.BellStyle.visual.flashes)
        XCTAssertFalse(Preferences.BellStyle.visual.sounds)
    }

    func test_sound_soundsOnly() {
        XCTAssertTrue(Preferences.BellStyle.sound.sounds)
        XCTAssertFalse(Preferences.BellStyle.sound.flashes)
    }

    func test_visualAndSound_doesBoth() {
        XCTAssertTrue(Preferences.BellStyle.visualAndSound.flashes)
        XCTAssertTrue(Preferences.BellStyle.visualAndSound.sounds)
    }

    func test_off_doesNeither() {
        XCTAssertFalse(Preferences.BellStyle.off.flashes)
        XCTAssertFalse(Preferences.BellStyle.off.sounds)
    }

    func test_bell_unknownStoredRaw_fallsBackToVisual() {
        Preferences.shared.bellRaw = "Bogus"
        XCTAssertEqual(Preferences.shared.bell, .visual,
                       "an unknown bellRaw must resolve to .visual")
    }

    func test_bell_eachValidRaw_resolves() {
        for style in Preferences.BellStyle.allCases {
            Preferences.shared.bellRaw = style.rawValue
            XCTAssertEqual(Preferences.shared.bell, style,
                           "bellRaw=\(style.rawValue) must resolve to .\(style)")
        }
    }
}
