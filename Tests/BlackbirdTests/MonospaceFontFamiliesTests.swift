import XCTest
import AppKit
@testable import Blackbird

/// Pins `MonospaceFontFamilies` (CoreText, off-main prewarm) to the legacy
/// NSFontManager + `isFixedPitch` result the Settings Family picker used to
/// compute on the main thread. One font lookup per installed family (a few
/// hundred) — a few hundred ms, no meaningful memory.
final class MonospaceFontFamiliesTests: XCTestCase {
    private func legacy() -> [String] {
        NSFontManager.shared.availableFontFamilies
            .filter { name in
                guard let font = NSFont(name: name, size: 12) else { return false }
                return font.isFixedPitch
            }
            .sorted()
    }

    func testMatchesNSFontManagerFixedPitchSet() {
        XCTAssertEqual(MonospaceFontFamilies.compute(), legacy())
    }

    func testSortedAndContainsMenlo() {
        let all = MonospaceFontFamilies.all
        XCTAssertEqual(all, all.sorted())
        XCTAssertTrue(all.contains("Menlo"))
    }

    func testPrewarmOffMainDoesNotChangeResult() {
        MonospaceFontFamilies.prewarm()
        XCTAssertEqual(MonospaceFontFamilies.all, MonospaceFontFamilies.compute())
    }
}
