import XCTest
@testable import Blackbird

final class CursorShapeTests: XCTestCase {
    private var saved: String = ""

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    override func setUp() {
        super.setUp()
        saved = Preferences.shared.cursorShapeRaw
    }

    override func tearDown() {
        Preferences.shared.cursorShapeRaw = saved
        super.tearDown()
    }

    func test_resolver_returns_followShell_for_unknown_raw() {
        Preferences.shared.cursorShapeRaw = "garbage-not-a-case"
        XCTAssertNil(Preferences.CursorShape(rawValue: Preferences.shared.cursorShapeRaw))
        XCTAssertEqual(Preferences.shared.cursorShape, .followShell)
    }

    func test_roundtrip_each_case() {
        for c in Preferences.CursorShape.allCases {
            Preferences.shared.cursorShapeRaw = c.rawValue
            XCTAssertEqual(Preferences.shared.cursorShape, c)
        }
    }

    func test_rendererOverride_isNilForFollowShell() {
        Preferences.shared.cursorShapeRaw = Preferences.CursorShape.followShell.rawValue
        XCTAssertNil(Preferences.shared.cursorShape.rendererOverride)
    }

    func test_rendererOverride_mapsForFixedShapes() {
        Preferences.shared.cursorShapeRaw = Preferences.CursorShape.block.rawValue
        XCTAssertEqual(Preferences.shared.cursorShape.rendererOverride, 0)
        Preferences.shared.cursorShapeRaw = Preferences.CursorShape.bar.rawValue
        XCTAssertEqual(Preferences.shared.cursorShape.rendererOverride, 1)
        Preferences.shared.cursorShapeRaw = Preferences.CursorShape.underline.rawValue
        XCTAssertEqual(Preferences.shared.cursorShape.rendererOverride, 2)
    }
}
