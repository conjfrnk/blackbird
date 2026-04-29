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
        // The contract: an unrecognised rawValue must NEVER surface to
        // the renderer as something other than `.followShell`. There
        // are two layers that uphold this jointly, and we pin both:
        //
        //   (1) The pure enum bridge `CursorShape(rawValue: …)` returns
        //       `nil` for an unknown string — no silent coercion inside
        //       Swift's RawRepresentable.
        //
        //   (2) The persisted-raw → effective-shape pipeline lands on
        //       `.followShell`. Post-Batch-5 (audit H-8 / L-28,
        //       2026-04-29) this is enforced TWICE: the resolver
        //       `cursorShape` has a `?? .followShell` fallback, AND the
        //       `UserDefaults.didChangeNotification` observer repairs an
        //       unknown rawValue back to `followShell.rawValue`
        //       synchronously when it lands on disk. Either layer alone
        //       satisfies the contract; together they make it
        //       defence-in-depth.
        //
        // We can't observe layer (1) by reading `cursorShapeRaw` after
        // a write — the observer repairs it before this thread sees the
        // value — so we assert layer (1) on the literal, and assert the
        // joint contract by writing garbage and reading the resolver.
        XCTAssertNil(Preferences.CursorShape(rawValue: "garbage-not-a-case"))
        Preferences.shared.cursorShapeRaw = "garbage-not-a-case"
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
