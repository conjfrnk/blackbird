import XCTest
@testable import Blackbird

final class TabRenameTests: XCTestCase {
    func testOverrideBeatsOscTitle() {
        let s = TerminalSession.makeHeadlessForTests()
        s.applyOscTitle("shell-says-this")
        XCTAssertEqual(s.displayTitle, "shell-says-this")

        s.titleOverride = "My Tab"
        XCTAssertEqual(s.displayTitle, "My Tab")

        s.applyOscTitle("shell-changed")
        XCTAssertEqual(s.displayTitle, "My Tab")
    }

    func testResetToAutoResumesOscTitle() {
        let s = TerminalSession.makeHeadlessForTests()
        s.applyOscTitle("from-shell")
        s.titleOverride = "Override"
        s.titleOverride = nil
        XCTAssertEqual(s.displayTitle, "from-shell")
    }

    func testEmptyOverrideTreatedAsNil() {
        let s = TerminalSession.makeHeadlessForTests()
        s.applyOscTitle("from-shell")
        s.titleOverride = ""
        XCTAssertEqual(s.displayTitle, "from-shell")
    }
}
