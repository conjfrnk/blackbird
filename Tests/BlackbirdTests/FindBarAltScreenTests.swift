import XCTest
import AppKit
@testable import Blackbird
import BBCore

/// Regression coverage for `F-S5-014`: when the terminal is on the
/// alt-screen (vim, less, htop, etc.), `performSearch` should target the
/// VISIBLE viewport, not the scrollback buffer that belongs to the
/// primary screen. Without the fix, ⌘F over a vim session searches the
/// shell history that was on screen before vim launched — confusing
/// because the user's query is plainly visible in the vim window but
/// the find counter says "0 / 0".
///
/// We can't directly drive `performSearch` without a real find bar +
/// session wiring, but we CAN verify the upstream invariants:
///
///  - The Rust core correctly reports the alt-screen mode bit through
///    `BBSnapshot.termMode.contains(.altScreen)` after `\e[?1049h`.
///  - The same mode bit clears after `\e[?1049l`.
///  - The visibleRowsAsText path returns the alt-screen content (vim's
///    UI) — NOT scrollback — when alt-screen is active.
///
/// These pin the data the find loop must consult. A regression where
/// the find loop walks `-historySize..<rows` (covering scrollback)
/// instead of branching on alt-screen mode would surface as the
/// reviewer's user-visible bug.
final class FindBarAltScreenTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    /// pre-flight: 1 BBTerm at 20×4, no scrollback growth — < 10 KB.
    /// Wall < 50 ms.
    ///
    /// `\e[?1049h` enables the alt-screen and the mode bit must light
    /// up in the snapshot. Without this signal, the find loop has no
    /// way to branch.
    func test_altScreenMode_setsTermModeBit() throws {
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 20, rows: 4)))
        // Pre-condition: NOT in alt-screen yet.
        let pre = try XCTUnwrap(term.snapshot())
        XCTAssertFalse(
            pre.termMode.contains(.altScreen),
            "fresh BBTerm must start on the primary screen"
        )

        // Switch to alt-screen via DECSET 1049 (the modern xterm
        // sequence: saves cursor, switches to alt screen, clears it).
        term.input("\u{1B}[?1049h")
        let post = try XCTUnwrap(term.snapshot())
        XCTAssertTrue(
            post.termMode.contains(.altScreen),
            "termMode must reflect the alt-screen bit after \\e[?1049h; "
            + "F-S5-014 find-loop branch depends on this"
        )
    }

    /// pre-flight: same as above.
    ///
    /// `\e[?1049l` returns to the primary screen and clears the bit.
    /// Reviewer-flagged hazard: a stale alt-screen flag would mean find
    /// stays in viewport-only mode after vim exits.
    func test_altScreenMode_clearsAfterLeave() throws {
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 20, rows: 4)))
        term.input("\u{1B}[?1049h")
        XCTAssertTrue(try XCTUnwrap(term.snapshot()).termMode.contains(.altScreen))

        term.input("\u{1B}[?1049l")
        let final = try XCTUnwrap(term.snapshot())
        XCTAssertFalse(
            final.termMode.contains(.altScreen),
            "leaving alt-screen via \\e[?1049l must clear the mode bit; "
            + "stale flag would keep find in viewport-only mode after vim exit"
        )
    }

    /// pre-flight: 1 BBTerm at 20×4 with text on primary screen first,
    /// then alt-screen content; total cells ≈ 80, < 5 KB.
    ///
    /// On the primary screen we type "alpha" and press Enter several
    /// times to push it into scrollback. Then we enter alt-screen and
    /// type "beta" — the visible viewport. The contract: `BBSnapshot`
    /// after the alt-screen entry shows ONLY "beta" in the visible
    /// rows, not "alpha". (Find should walk these rows; if it walked
    /// scrollback instead, it would still find "alpha" — the reviewer's
    /// bug shape.)
    func test_altScreenSnapshot_visibleRowsContainAltScreenContent() throws {
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 20, rows: 4)))

        // Push "alpha" into scrollback by writing it then forcing
        // newlines (LF + cursor-down so it scrolls off the visible 4-row grid).
        term.input("alpha\r\n")
        for _ in 0..<6 { term.input("\r\n") }   // push beyond the 4-row viewport

        // Enter alt-screen, write "beta".
        term.input("\u{1B}[?1049h")
        term.input("beta")

        let snap = try XCTUnwrap(term.snapshot())
        XCTAssertTrue(
            snap.termMode.contains(.altScreen),
            "test setup must have entered alt-screen"
        )

        // Walk visible rows. "beta" must appear; "alpha" must NOT
        // (it's in primary scrollback).
        var visibleText = ""
        for r in 0..<snap.rows {
            for c in 0..<snap.cols {
                if let ch = snap.character(at: c, row: r) {
                    visibleText.append(ch)
                }
            }
            visibleText.append("\n")
        }
        XCTAssertTrue(
            visibleText.contains("beta"),
            "alt-screen viewport must contain alt-screen content 'beta'; "
            + "got: \(visibleText.debugDescription)"
        )
        XCTAssertFalse(
            visibleText.contains("alpha"),
            "alt-screen viewport must NOT contain primary-screen content 'alpha'; "
            + "F-S5-014 user-visible bug: find against the visible rows must "
            + "see only what's on screen, not scrollback content."
        )
    }

    /// pre-flight: trivial.
    ///
    /// Belt-and-braces: the historic alt-screen sequence `\e[?47h` (a
    /// pre-DECSET-1049 alternative) must also set the bit. Some legacy
    /// curses programs still use it.
    func test_altScreenMode_setsViaLegacyDECSET47() throws {
        // alacritty_terminal 0.26 doesn't wire legacy DECSET 47h to the
        // ALT_SCREEN mode bit — only 1049h is implemented. Kept as a
        // breadcrumb: if alacritty grows support, drop the XCTSkip.
        throw XCTSkip("alacritty_terminal 0.26 doesn't implement DECSET 47h; only 1049h is wired to altScreen")
    }
}
