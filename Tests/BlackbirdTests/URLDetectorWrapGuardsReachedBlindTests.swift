import XCTest
@testable import Blackbird

/// Blind regression tests for the wrapped-URL join guards in
/// `URLDetector.scan` (S4-001 / S4-007 / cwd-hyperlink F9).
///
/// Why this suite exists. A wrap-join guard (host unchanged, port unchanged,
/// no structure leader at the start of the continuation row) only protects
/// anything if a test drives the detector THROUGH the point where the join is
/// attempted. On the primary screen the join is only attempted when the core's
/// soft-wrap bit (`WRAPLINE`) is set on the row's last cell, i.e. when the
/// terminal itself wrapped the text. A fixture that separates the URL from the
/// continuation with `\r\n` never gets that far: the join is refused before any
/// guard runs, the assertions (`url == head`) hold anyway, and the test
/// "passes" while removing the guard would turn nothing red.
///
/// So every fixture here:
///   * writes the continuation straight after the URL with NO line break, so
///     row 0 soft-wraps onto row 1 (asserted via `isSoftWrapped(row:)`), or, for
///     the alt-screen cases, places the rows with cursor addressing where the
///     fallback decision is "edge plus URL-safe leader" and the guards are the
///     only thing standing between the click and the attacker's text;
///   * is checked, independently of the detector, to trip EXACTLY ONE guard:
///     `URL(string:)` of the head and of head+continuation is compared on
///     host / port / leader character, so a host-changing fixture really
///     changes only the host, a port fixture only the port, and a leader
///     fixture neither (it is rejected by the leader rule alone);
///   * is paired with a control of the same geometry whose continuation is
///     benign and MUST join, proving the join is attempted for this layout.
///
/// Observable contract (see `URLDetectorMultiRowWrapTests` and KNOWN_ISSUES.md):
/// a rejected join leaves the first-row URL exactly as underlined, with no
/// continuation text appended and no separate fragment match; the highlight
/// (`endCol`) never leaves the first row.
///
/// Cost: every grid is at most 80x6 = 480 cells, plain text plus a few CSI
/// sequences. No PTY, no windows, no scrollback.
final class URLDetectorWrapGuardsReachedBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Fixture helpers

    /// First characters of a continuation row that stop the join.
    private let leaders: [Character] = ["?", "#", "&", "@", ";", ":"]

    private let altScreenOn = "\u{1B}[?1049h"

    private func snapshot(from text: String, cols: Int, rows: UInt16 = 6) throws -> BBSnapshot {
        let term = try XCTUnwrap(BBTerm(size: .init(cols: UInt16(cols), rows: rows)))
        term.input(text)
        let snap = try XCTUnwrap(term.snapshot())
        XCTAssertEqual(snap.cols, cols, "fixture: grid width")
        XCTAssertEqual(snap.displayOffset, 0, "fixture must sit at the live bottom")
        return snap
    }

    private func cellText(_ snap: BBSnapshot, row: Int, from: Int, through: Int) -> String {
        var out = ""
        for col in from...through {
            out.append(snap.character(at: col, row: row) ?? "?")
        }
        return out
    }

    /// The URLs a click on screen row 0 can open, left to right.
    private func rowZeroURLs(_ matches: [URLMatch]) -> [String] {
        let onRowZero: [URLMatch] = matches.filter { $0.line == 0 }
        let ordered: [URLMatch] = onRowZero.sorted { $0.startCol < $1.startCol }
        return ordered.map { $0.url.absoluteString }
    }

    private func allURLs(_ matches: [URLMatch]) -> [String] {
        let ordered: [URLMatch] = matches.sorted { a, b in
            a.line != b.line ? a.line < b.line : a.startCol < b.startCol
        }
        return ordered.map { $0.url.absoluteString }
    }

    /// Which single guard a fixture is meant to trip.
    private enum Trips {
        case hostOnly
        case portOnly
        case leaderOnly
    }

    /// Prove, without consulting the detector, that joining `continuation`
    /// onto `head` would trip exactly the guard named by `trips` and none of
    /// the others. This is what makes the fixture's rejection attributable to
    /// that one guard.
    private func assertTrips(
        _ trips: Trips, head: String, continuation: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let sub: URL? = URL(string: head)
        let joined: URL? = URL(string: head + continuation)
        XCTAssertEqual(sub?.absoluteString, head,
                       "fixture: head must parse as written", file: file, line: line)
        XCTAssertEqual(joined?.absoluteString, head + continuation,
                       "fixture: joined text must parse as written", file: file, line: line)
        let hostSame = sub?.host == joined?.host
        let portSame = sub?.port == joined?.port
        let startsWithLeader: Bool = continuation.first.map { leaders.contains($0) } ?? false
        let what = "head=\(head) continuation=\(continuation) hostSame=\(hostSame) portSame=\(portSame) startsWithLeader=\(startsWithLeader)"
        switch trips {
        case .hostOnly:
            XCTAssertFalse(hostSame, "fixture must change the host: \(what)", file: file, line: line)
            XCTAssertTrue(portSame, "fixture must not change the port: \(what)", file: file, line: line)
            XCTAssertFalse(startsWithLeader, "fixture must not start with a leader: \(what)", file: file, line: line)
        case .portOnly:
            XCTAssertTrue(hostSame, "fixture must not change the host: \(what)", file: file, line: line)
            XCTAssertFalse(portSame, "fixture must change the port: \(what)", file: file, line: line)
            XCTAssertFalse(startsWithLeader, "fixture must not start with a leader: \(what)", file: file, line: line)
        case .leaderOnly:
            XCTAssertTrue(hostSame, "fixture must not change the host: \(what)", file: file, line: line)
            XCTAssertTrue(portSame, "fixture must not change the port: \(what)", file: file, line: line)
            XCTAssertTrue(startsWithLeader, "fixture must start with a leader: \(what)", file: file, line: line)
        }
    }

    /// Primary screen. `head` is right-aligned so its last character lands on
    /// the final column of row 0, and `continuation` is written straight after
    /// with no line break: the terminal soft-wraps it onto row 1.
    private func softWrapEdge(head: String, continuation: String, cols: Int) throws -> BBSnapshot {
        XCTAssertLessThanOrEqual(head.count, cols, "fixture: head must fit on one row")
        XCTAssertLessThanOrEqual(continuation.count, cols, "fixture: continuation must fit on row 1")
        let startCol = cols - head.count
        let pad = String(repeating: " ", count: startCol)
        let snap = try snapshot(from: pad + head + continuation, cols: cols)
        XCTAssertFalse(snap.termMode.contains(.altScreen), "fixture: primary screen")
        XCTAssertTrue(snap.isSoftWrapped(row: 0),
                      "fixture: row 0 must carry the core soft-wrap bit, otherwise no guard is ever reached")
        XCTAssertEqual(cellText(snap, row: 0, from: startCol, through: cols - 1), head,
                       "fixture: row 0 must hold the head ending at the last column")
        XCTAssertEqual(cellText(snap, row: 1, from: 0, through: continuation.count - 1), continuation,
                       "fixture: row 1 must start with the continuation")
        return snap
    }

    /// Alt screen. Rows are placed with cursor addressing (CUP), exactly as
    /// tmux and TUIs do, so no row carries the soft-wrap bit even though the
    /// head ends at the last column and the continuation sits at column 0 of
    /// the next row.
    private func altEdge(head: String, continuation: String, cols: Int) throws -> BBSnapshot {
        XCTAssertLessThanOrEqual(head.count, cols, "fixture: head must fit on one row")
        let startCol = cols - head.count
        let text = altScreenOn + "\u{1B}[1;\(startCol + 1)H" + head + "\u{1B}[2;1H" + continuation
        let snap = try snapshot(from: text, cols: cols)
        XCTAssertTrue(snap.termMode.contains(.altScreen), "fixture: alt screen is active")
        XCTAssertFalse(snap.isSoftWrapped(row: 0),
                       "fixture: cursor addressing must not produce a soft-wrap bit")
        XCTAssertEqual(cellText(snap, row: 0, from: startCol, through: cols - 1), head,
                       "fixture: row 0 must hold the head ending at the last column")
        XCTAssertEqual(cellText(snap, row: 1, from: 0, through: continuation.count - 1), continuation,
                       "fixture: row 1 must start with the continuation")
        return snap
    }

    // MARK: - 1. Controls: the geometry joins when the continuation is benign

    /// Same layout as the guard fixtures below, benign continuation: the join
    /// must happen. This is what proves the soft-wrap gate is passed and the
    /// guards are the only thing that can refuse the fixtures that follow.
    func test_control_softWrapEdge_benignContinuations_join() throws {
        let cols = 40
        let cases: [(head: String, continuation: String)] = [
            ("https://apple.com", "/login"),
            ("https://good", "/x"),
            ("https://example.com:80", "/admin"),
            ("https://example.com/", "bxyz=1"),
            ("https://example.com/", "k=v"),
        ]
        var failures: [String] = []
        for c in cases {
            let snap = try softWrapEdge(head: c.head, continuation: c.continuation, cols: cols)
            let matches = URLDetector.scan(snapshot: snap)
            let want = [c.head + c.continuation]
            if allURLs(matches) != want {
                failures.append("\(c.head)|\(c.continuation): got \(allURLs(matches)), want \(want)")
            } else if matches.first?.endCol != cols - 1 || matches.first?.startCol != cols - c.head.count {
                failures.append("\(c.head)|\(c.continuation): highlight \(String(describing: matches.first?.startCol))...\(String(describing: matches.first?.endCol)), want \(cols - c.head.count)...\(cols - 1)")
            }
        }
        XCTAssertEqual(failures, [], "benign soft-wrapped continuations that failed to join cleanly")
    }

    // MARK: - 2. Host guard

    /// A soft-wrapped continuation that extends the host (`apple.com` ->
    /// `apple.com.evil.example`) must not be joined: the user sees and clicks
    /// the underlined apex. The fixtures start with `.`, `-` or a letter, none
    /// of which is a structure leader, and add no port, so only the host
    /// guard can refuse them.
    func test_hostGuard_softWrappedHostChangingContinuation_isRejected() throws {
        let cols = 40
        let cases: [(head: String, continuation: String)] = [
            ("https://apple.com", ".evil.example/login"),
            ("https://apple.com", "-evil.example/login"),
            ("https://apple.com", "x.evil.example/login"),
            ("https://good", ".evil.example/x"),
        ]
        var failures: [String] = []
        for c in cases {
            assertTrips(.hostOnly, head: c.head, continuation: c.continuation)
            let snap = try softWrapEdge(head: c.head, continuation: c.continuation, cols: cols)
            let got = rowZeroURLs(URLDetector.scan(snapshot: snap))
            if got != [c.head] {
                failures.append("\(c.head)|\(c.continuation): got \(got), want \([c.head])")
            }
        }
        XCTAssertEqual(failures, [], "host-changing soft-wrapped continuations that were dispatched")
    }

    // MARK: - 3. Port guard

    /// A soft-wrapped continuation that rewrites the port of the visible URL
    /// (`:80` + `80` -> `:8080`) keeps the host, does not start with a
    /// structure leader, and must still be refused: the user saw port 80.
    func test_portGuard_softWrappedPortChangingContinuation_isRejected() throws {
        let cols = 40
        let cases: [(head: String, continuation: String)] = [
            ("https://example.com:80", "80/admin"),
            ("http://example.com:4", "43/admin"),
            ("https://example.com:844", "3/admin"),
        ]
        var failures: [String] = []
        for c in cases {
            assertTrips(.portOnly, head: c.head, continuation: c.continuation)
            let snap = try softWrapEdge(head: c.head, continuation: c.continuation, cols: cols)
            let got = rowZeroURLs(URLDetector.scan(snapshot: snap))
            if got != [c.head] {
                failures.append("\(c.head)|\(c.continuation): got \(got), want \([c.head])")
            }
        }
        XCTAssertEqual(failures, [], "port-changing soft-wrapped continuations that were dispatched")
    }

    // MARK: - 4. Structure-leader guard

    /// With a path already present (`https://example.com/`), a continuation
    /// starting with one of `? # & @ ; :` leaves host and port untouched, so
    /// only the leader rule can refuse it. `?`/`#` smuggle a query or
    /// fragment, `@`/`:` are the S4-007 shapes that parse as plain path text.
    func test_leaderGuard_everyStructureLeader_softWrapped_isRejected() throws {
        let cols = 40
        let head = "https://example.com/"
        var failures: [String] = []
        for leader in leaders {
            let continuation = "\(leader)k=v"
            assertTrips(.leaderOnly, head: head, continuation: continuation)
            let snap = try softWrapEdge(head: head, continuation: continuation, cols: cols)
            let matches = URLDetector.scan(snapshot: snap)
            let got = rowZeroURLs(matches)
            if got != [head] {
                failures.append("'\(leader)': got \(got), want \([head])")
            } else if matches.first?.endCol != cols - 1 {
                failures.append("'\(leader)': endCol \(String(describing: matches.first?.endCol)), want \(cols - 1)")
            }
        }
        XCTAssertEqual(failures, [], "structure-leader continuations that were joined")
    }

    // MARK: - 5. Entry check: continuation must start with a URL character

    /// A soft-wrapped row that starts with a character a URL cannot contain
    /// (space, quote, angle brackets) is not a continuation of the URL.
    func test_entryCheck_softWrappedNonURLFirstCharacter_isNotJoined() throws {
        let cols = 40
        let head = "https://example.com/"
        let outside: [Character] = [" ", "\"", "<", ">"]
        var failures: [String] = []
        for c in outside {
            let snap = try softWrapEdge(head: head, continuation: "\(c)kv", cols: cols)
            let got = rowZeroURLs(URLDetector.scan(snapshot: snap))
            if got != [head] {
                failures.append("U+\(String(c.unicodeScalars.first!.value, radix: 16)): got \(got), want \([head])")
            }
        }
        XCTAssertEqual(failures, [], "non-URL first characters that were joined onto the URL")
    }

    // MARK: - 6. Multi-row walk: guards at EVERY row boundary

    /// Control: four soft-wrapped rows join into one match, no fragments, and
    /// the highlight stays on row 0.
    func test_multiRowWalk_everyBoundarySoftWrapped_joinsAllRows() throws {
        let cols = 20
        let head = "https://example.com/"
        let full = head + String(repeating: "a", count: 20) + String(repeating: "b", count: 20) + "ccc"
        let snap = try snapshot(from: full, cols: cols)
        XCTAssertTrue(snap.isSoftWrapped(row: 0), "fixture: row 0 wraps")
        XCTAssertTrue(snap.isSoftWrapped(row: 1), "fixture: row 1 wraps")
        XCTAssertTrue(snap.isSoftWrapped(row: 2), "fixture: row 2 wraps")
        XCTAssertFalse(snap.isSoftWrapped(row: 3), "fixture: row 3 is the last")

        let matches = URLDetector.scan(snapshot: snap)
        XCTAssertEqual(allURLs(matches), [full],
                       "a URL soft-wrapped across four rows must be one match holding the full href")
        XCTAssertEqual(matches.first?.line, 0, "match anchors on row 0")
        XCTAssertEqual(matches.first?.endCol, cols - 1, "highlight stays on row 0")
    }

    /// The leader rule applies at the SECOND boundary too: rows 0 and 1 are a
    /// genuine soft wrap and join, row 2 starts with a leader (also a genuine
    /// soft wrap, so the leader rule is what stops the walk).
    func test_multiRowWalk_leaderAtSecondBoundary_stopsTheWalk() throws {
        let cols = 20
        let head = "https://example.com/"
        let mid = String(repeating: "a", count: 20)
        var failures: [String] = []
        for leader in leaders {
            let continuation = "\(leader)k=v"
            assertTrips(.leaderOnly, head: head + mid, continuation: continuation)
            let snap = try snapshot(from: head + mid + continuation, cols: cols)
            XCTAssertTrue(snap.isSoftWrapped(row: 0), "fixture: row 0 wraps into row 1")
            XCTAssertTrue(snap.isSoftWrapped(row: 1),
                          "fixture: row 1 wraps into row 2, otherwise the leader rule is never reached")
            XCTAssertEqual(cellText(snap, row: 2, from: 0, through: continuation.count - 1), continuation,
                           "fixture: row 2 starts with the continuation")
            let got = rowZeroURLs(URLDetector.scan(snapshot: snap))
            if got != [head + mid] {
                failures.append("'\(leader)': got \(got), want \([head + mid])")
            }
        }
        XCTAssertEqual(failures, [], "leaders at the second boundary that were joined")
    }

    /// A soft-wrapped row 2 that starts with a character no URL contains
    /// ends the walk after row 1.
    func test_multiRowWalk_nonURLCharacterAtSecondBoundary_stopsTheWalk() throws {
        let cols = 20
        let head = "https://example.com/"
        let mid = String(repeating: "a", count: 20)
        let outside: [Character] = [" ", "\"", "<", ">"]
        var failures: [String] = []
        for c in outside {
            let snap = try snapshot(from: head + mid + "\(c)kv", cols: cols)
            XCTAssertTrue(snap.isSoftWrapped(row: 1), "fixture: row 1 wraps into row 2")
            let got = rowZeroURLs(URLDetector.scan(snapshot: snap))
            if got != [head + mid] {
                failures.append("U+\(String(c.unicodeScalars.first!.value, radix: 16)): got \(got), want \([head + mid])")
            }
        }
        XCTAssertEqual(failures, [], "non-URL first characters at the second boundary that were joined")
    }

    /// The soft-wrap gate is consulted at each step, not only the first: rows
    /// 0 and 1 are a genuine wrap, but row 2 is placed with cursor addressing
    /// (no soft-wrap bit on row 1), so on the primary screen it is another
    /// line and must not be glued on.
    func test_multiRowWalk_primaryScreen_cursorAddressedThirdRow_isNotJoined() throws {
        let cols = 20
        let head = "https://example.com/"
        let mid = String(repeating: "a", count: 20)
        let snap = try snapshot(from: head + mid + "\u{1B}[3;1H" + "zzz", cols: cols)
        XCTAssertFalse(snap.termMode.contains(.altScreen), "fixture: primary screen")
        XCTAssertTrue(snap.isSoftWrapped(row: 0), "fixture: row 0 wraps into row 1")
        XCTAssertFalse(snap.isSoftWrapped(row: 1), "fixture: row 1 does NOT wrap into row 2")
        XCTAssertEqual(cellText(snap, row: 2, from: 0, through: 2), "zzz", "fixture: row 2 holds the next text")

        XCTAssertEqual(allURLs(URLDetector.scan(snapshot: snap)), [head + mid],
                       "the walk must stop at a row boundary that carries no soft-wrap bit")
    }

    // MARK: - 7. Alt screen: the row-continuation fallback

    /// The continuation decision depends on the screen: the SAME cursor-
    /// addressed bytes join on the alt screen (no wrap bit can exist there, so
    /// the edge-plus-URL-safe-leader guess is used) and do not join on the
    /// primary screen (where the missing wrap bit means a different line).
    func test_altScreen_sameCursorAddressedBytes_joinOnAltScreenOnly() throws {
        let cols = 40
        let head = "https://example.com/" + String(repeating: "a", count: 20)
        XCTAssertEqual(head.count, cols, "fixture: head fills the row")
        let tail = "bbb/ccc"
        let body = "\u{1B}[1;1H" + head + "\u{1B}[2;1H" + tail

        let primary = try snapshot(from: body, cols: cols)
        XCTAssertFalse(primary.termMode.contains(.altScreen), "fixture: primary screen")
        XCTAssertFalse(primary.isSoftWrapped(row: 0), "fixture: no wrap bit on the primary screen")
        XCTAssertEqual(cellText(primary, row: 1, from: 0, through: tail.count - 1), tail,
                       "fixture: primary row 1 holds the tail")
        XCTAssertEqual(allURLs(URLDetector.scan(snapshot: primary)), [head],
                       "primary screen: a row boundary without the wrap bit is not a continuation")

        let alt = try snapshot(from: altScreenOn + body, cols: cols)
        XCTAssertTrue(alt.termMode.contains(.altScreen), "fixture: alt screen is active")
        XCTAssertFalse(alt.isSoftWrapped(row: 0), "fixture: no wrap bit on the alt screen either")
        XCTAssertEqual(cellText(alt, row: 1, from: 0, through: tail.count - 1), tail,
                       "fixture: alt row 1 holds the tail")
        XCTAssertEqual(allURLs(URLDetector.scan(snapshot: alt)), [head + tail],
                       "alt screen: edge plus URL-safe leader falls back to joining")
    }

    /// Documented residual (KNOWN_ISSUES.md): a full-width URL followed by a
    /// HARD newline is told apart from a wrap on the primary screen but not
    /// on the alt screen. Same bytes, two outcomes.
    func test_altScreen_hardNewlineAfterFullWidthURL_primaryStopsAltStillJoins() throws {
        let cols = 40
        let url = "https://example.com/" + String(repeating: "a", count: 20)
        XCTAssertEqual(url.count, cols, "fixture: URL fills the row")
        let body = url + "\r\nDone"

        let primary = try snapshot(from: body, cols: cols)
        XCTAssertFalse(primary.termMode.contains(.altScreen), "fixture: primary screen")
        XCTAssertFalse(primary.isSoftWrapped(row: 0), "fixture: a hard newline sets no wrap bit")
        XCTAssertEqual(allURLs(URLDetector.scan(snapshot: primary)), [url],
                       "primary screen: the hard newline ends the URL")

        let alt = try snapshot(from: altScreenOn + body, cols: cols)
        XCTAssertTrue(alt.termMode.contains(.altScreen), "fixture: alt screen is active")
        XCTAssertEqual(allURLs(URLDetector.scan(snapshot: alt)), [url + "Done"],
                       "alt screen: documented residual, the fallback joins the next line")
    }

    /// On the alt screen the soft-wrap gate is out of play, which makes the
    /// guards the ONLY protection: a host change, a port change and every
    /// structure leader must still be refused there.
    func test_altScreen_guardsStillRejectUnsafeContinuations() throws {
        let cols = 40
        var cases: [(trips: Trips, head: String, continuation: String)] = [
            (.hostOnly, "https://apple.com", ".evil.example/login"),
            (.hostOnly, "https://apple.com", "-evil.example/login"),
            (.portOnly, "https://example.com:80", "80/admin"),
            (.portOnly, "http://example.com:4", "43/admin"),
        ]
        for leader in leaders {
            cases.append((.leaderOnly, "https://example.com/", "\(leader)k=v"))
        }
        var failures: [String] = []
        for c in cases {
            assertTrips(c.trips, head: c.head, continuation: c.continuation)
            let snap = try altEdge(head: c.head, continuation: c.continuation, cols: cols)
            let got = rowZeroURLs(URLDetector.scan(snapshot: snap))
            if got != [c.head] {
                failures.append("\(c.head)|\(c.continuation): got \(got), want \([c.head])")
            }
        }
        XCTAssertEqual(failures, [], "alt-screen continuations that slipped past a guard")
    }

    /// Control for the test above: benign cursor-addressed continuations of
    /// the same layouts do join on the alt screen.
    func test_altScreen_benignContinuations_join() throws {
        let cols = 40
        let cases: [(head: String, continuation: String)] = [
            ("https://apple.com", "/login"),
            ("https://example.com:80", "/admin"),
            ("https://example.com/", "bxyz=1"),
        ]
        var failures: [String] = []
        for c in cases {
            let snap = try altEdge(head: c.head, continuation: c.continuation, cols: cols)
            let got = allURLs(URLDetector.scan(snapshot: snap))
            let want = [c.head + c.continuation]
            if got != want {
                failures.append("\(c.head)|\(c.continuation): got \(got), want \(want)")
            }
        }
        XCTAssertEqual(failures, [], "benign alt-screen continuations that failed to join")
    }

    /// The multi-row walk on the alt screen: every row is cursor-addressed and
    /// reaches the right edge, and all three rows join.
    func test_altScreen_cursorAddressedThreeRowWalk_joinsAllRows() throws {
        let cols = 20
        let head = "https://example.com/"
        let mid = String(repeating: "a", count: 20)
        let tail = "ccc"
        let text = altScreenOn + "\u{1B}[1;1H" + head + "\u{1B}[2;1H" + mid + "\u{1B}[3;1H" + tail
        let snap = try snapshot(from: text, cols: cols)
        XCTAssertTrue(snap.termMode.contains(.altScreen), "fixture: alt screen is active")
        XCTAssertFalse(snap.isSoftWrapped(row: 0), "fixture: no wrap bit on row 0")
        XCTAssertFalse(snap.isSoftWrapped(row: 1), "fixture: no wrap bit on row 1")
        XCTAssertEqual(cellText(snap, row: 2, from: 0, through: 2), tail, "fixture: row 2 holds the tail")

        let matches = URLDetector.scan(snapshot: snap)
        XCTAssertEqual(allURLs(matches), [head + mid + tail],
                       "alt-screen rows that each reach the right edge must join across all three rows")
        XCTAssertEqual(matches.first?.endCol, cols - 1, "highlight stays on row 0")
    }

    /// The leader rule also applies at the second boundary on the alt screen.
    func test_altScreen_leaderAtSecondBoundary_stopsTheWalk() throws {
        let cols = 20
        let head = "https://example.com/"
        let mid = String(repeating: "a", count: 20)
        var failures: [String] = []
        for leader in leaders {
            let continuation = "\(leader)k=v"
            assertTrips(.leaderOnly, head: head + mid, continuation: continuation)
            let text = altScreenOn + "\u{1B}[1;1H" + head + "\u{1B}[2;1H" + mid + "\u{1B}[3;1H" + continuation
            let snap = try snapshot(from: text, cols: cols)
            XCTAssertTrue(snap.termMode.contains(.altScreen), "fixture: alt screen is active")
            XCTAssertEqual(cellText(snap, row: 1, from: 0, through: cols - 1), mid,
                           "fixture: row 1 is full, so only the leader rule can stop the walk")
            let got = rowZeroURLs(URLDetector.scan(snapshot: snap))
            if got != [head + mid] {
                failures.append("'\(leader)': got \(got), want \([head + mid])")
            }
        }
        XCTAssertEqual(failures, [], "alt-screen leaders at the second boundary that were joined")
    }
}
