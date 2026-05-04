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

    /// Hostile shells can emit `\e]0;` + KBs of payload + `\e\\` to
    /// force the tab strip's per-pill `truncatedString` to chew CPU on
    /// every redraw. `applyOscTitle` caps the retained string at
    /// `oscTitleMaxGraphemes` graphemes and appends an ellipsis so
    /// downstream layout can never see an unbounded title.
    func testOscTitleIsCappedAtMaxGraphemes() {
        let s = TerminalSession.makeHeadlessForTests()
        let cap = TerminalSession.oscTitleMaxGraphemes
        let payload = String(repeating: "x", count: cap * 8)
        s.applyOscTitle(payload)
        let title = s.displayTitle ?? ""
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
        let cap = TerminalSession.oscTitleMaxGraphemes
        let payload = String(repeating: "y", count: cap)
        s.applyOscTitle(payload)
        XCTAssertEqual(s.displayTitle, payload)
        XCTAssertFalse(s.displayTitle?.hasSuffix("…") ?? true,
            "an exact-cap title must NOT pick up the truncation marker")
    }
}
