import XCTest
@testable import Blackbird

final class TabRenameTests: XCTestCase {
    func testOverrideBeatsOscTitle() {
        let s = TerminalSession.makeHeadlessForTests()
        s.titleState.applyOscTitle("shell-says-this")
        XCTAssertEqual(s.titleState.displayTitle, "shell-says-this")

        s.titleState.titleOverride = "My Tab"
        XCTAssertEqual(s.titleState.displayTitle, "My Tab")

        s.titleState.applyOscTitle("shell-changed")
        XCTAssertEqual(s.titleState.displayTitle, "My Tab")
    }

    func testResetToAutoResumesOscTitle() {
        let s = TerminalSession.makeHeadlessForTests()
        s.titleState.applyOscTitle("from-shell")
        s.titleState.titleOverride = "Override"
        s.titleState.titleOverride = nil
        XCTAssertEqual(s.titleState.displayTitle, "from-shell")
    }

    func testEmptyOverrideTreatedAsNil() {
        let s = TerminalSession.makeHeadlessForTests()
        s.titleState.applyOscTitle("from-shell")
        s.titleState.titleOverride = ""
        XCTAssertEqual(s.titleState.displayTitle, "from-shell")
    }

    /// Hostile shells can emit `\e]0;` + KBs of payload + `\e\\` to
    /// force the tab strip's per-pill `truncatedString` to chew CPU on
    /// every redraw. `applyOscTitle` caps the retained string at
    /// `oscTitleMaxGraphemes` graphemes and appends an ellipsis so
    /// downstream layout can never see an unbounded title.
    func testOscTitleIsCappedAtMaxGraphemes() {
        let s = TerminalSession.makeHeadlessForTests()
        let cap = SessionTitleState.oscTitleMaxGraphemes
        let payload = String(repeating: "x", count: cap * 8)
        s.titleState.applyOscTitle(payload)
        let title = s.titleState.displayTitle ?? ""
        XCTAssertEqual(title.count, cap + 1,
            "oversize title must be truncated to cap + 1 grapheme (the appended ellipsis)")
        XCTAssertTrue(title.hasSuffix("…"),
            "truncation must mark the cap with an ellipsis")
    }

    /// Titles at or under the cap must round-trip unchanged — the
    /// truncation only fires above the threshold so legitimate shell
    /// titles aren't visibly altered.
    func testOscTitleAtOrBelowCapPassesThrough() {
        let s = TerminalSession.makeHeadlessForTests()
        let cap = SessionTitleState.oscTitleMaxGraphemes
        let payload = String(repeating: "y", count: cap)
        s.titleState.applyOscTitle(payload)
        XCTAssertEqual(s.titleState.displayTitle, payload)
        XCTAssertFalse(s.titleState.displayTitle?.hasSuffix("…") ?? true,
            "an exact-cap title must NOT pick up the truncation marker")
    }
}
