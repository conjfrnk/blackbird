import XCTest
import Combine
@testable import Blackbird

final class TerminalSessionTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    func test_shellOutputAppearsInSnapshot() throws {
        let session = try TerminalSession.start(
            shell: "/bin/sh",
            arguments: ["-c", "printf hello"],
            size: .init(cols: 80, rows: 24)
        )

        let exp = expectation(description: "hello in snapshot")
        var c: AnyCancellable?
        c = session.$snapshot
            .compactMap { $0 }
            .sink { snap in
                if let ch = snap.character(at: 0, row: 0), ch == "h" {
                    c?.cancel()
                    exp.fulfill()
                }
            }

        wait(for: [exp], timeout: 3.0)
        session.terminate()
    }

    func test_sendBytesReachesShell() throws {
        // Use /bin/cat: deterministic echo. Interactive /bin/sh was flaky
        // because sh's decision to echo depends on whether the kernel PTY
        // driver sees ECHO ON AND the shell has reached its read(2) — a
        // race. cat just echoes stdin after each newline, reliably.
        let session = try TerminalSession.start(
            shell: "/bin/cat",
            arguments: [],
            size: .init(cols: 80, rows: 24)
        )

        let exp = expectation(description: "cat echoed back")
        var c: AnyCancellable?
        c = session.$snapshot
            .compactMap { $0 }
            .sink { snap in
                for col in 0..<snap.cols {
                    if snap.character(at: col, row: 0) == "h" {
                        c?.cancel()
                        exp.fulfill()
                        return
                    }
                }
            }

        // cat echoes each line after newline.
        session.send(Data("hello\n".utf8))
        wait(for: [exp], timeout: 3.0)
        session.terminate()
    }

    func test_titleEventUpdatesPublishedTitle() throws {
        let session = try TerminalSession.start(
            shell: "/bin/sh",
            arguments: ["-c", "printf '\\033]2;my-title\\007'"],
            size: .init(cols: 80, rows: 24)
        )

        let exp = expectation(description: "title set")
        var c: AnyCancellable?
        c = session.$title
            .compactMap { $0 }
            .sink { title in
                if title == "my-title" {
                    c?.cancel()
                    exp.fulfill()
                }
            }

        wait(for: [exp], timeout: 3.0)
        session.terminate()
    }

    // Pin the scroll sign convention: positive delta reveals older content
    // (scrollback) by growing displayOffset. The mouseDragged autoscroll path
    // relies on this; a previous bug had the signs swapped.
    func test_scrollPositiveDeltaShowsOlderContent() throws {
        let session = try TerminalSession.start(
            shell: "/bin/sh",
            // Enough newlines to push lines into scrollback beyond the 5-row grid.
            arguments: ["-c", "for i in 1 2 3 4 5 6 7 8 9 10 11 12; do echo line$i; done; sleep 0.3"],
            size: .init(cols: 20, rows: 5)
        )

        // Wait until history has accumulated.
        let histExp = expectation(description: "history built")
        var c: AnyCancellable?
        c = session.$snapshot.sink { snap in
            if let snap, snap.historySize > 0 {
                c?.cancel()
                histExp.fulfill()
            }
        }
        wait(for: [histExp], timeout: 3.0)

        let before = session.snapshot?.displayOffset ?? 0
        session.scroll(delta: 1)
        let after = session.snapshot?.displayOffset ?? 0
        XCTAssertGreaterThan(
            after, before,
            "scroll(delta: 1) should advance displayOffset into scrollback (show older)"
        )

        // And the reverse brings us back toward the live grid.
        session.scroll(delta: -1)
        let afterBack = session.snapshot?.displayOffset ?? 0
        XCTAssertLessThan(
            afterBack, after,
            "scroll(delta: -1) should move displayOffset back toward the live grid"
        )

        session.terminate()
    }

    func test_resize_degenerateSizeClampsToMinimum() throws {
        // Caller passes a pathological 1×1. The Rust core clamps to 2×2 so
        // reflow doesn't explode; Swift must clamp before calling PTY so the
        // tty's TIOCSWINSZ matches what the grid will actually render into.
        // The snapshot's final cols/rows reflect the clamp — anything below 2
        // here would mean the PTY and grid disagree on dimensions.
        let session = try TerminalSession.start(
            shell: "/bin/cat",
            arguments: [],
            size: .init(cols: 80, rows: 24)
        )

        let exp = expectation(description: "snapshot at clamped size")
        var gotExpected = false
        var c: AnyCancellable?
        c = session.$snapshot
            .compactMap { $0 }
            .sink { snap in
                if snap.cols == 2, snap.rows == 2, !gotExpected {
                    gotExpected = true
                    c?.cancel()
                    exp.fulfill()
                }
            }

        session.resize(to: .init(cols: 1, rows: 1))

        wait(for: [exp], timeout: 3.0)
        session.terminate()
    }

    func test_resizePropagatesToCoreAndPty() throws {
        let session = try TerminalSession.start(
            shell: "/bin/sh",
            arguments: ["-c", "sleep 0.2; stty size"],
            size: .init(cols: 80, rows: 24)
        )

        session.resize(to: .init(cols: 120, rows: 40))

        let exp = expectation(description: "stty reports new size")
        var c: AnyCancellable?
        c = session.$snapshot
            .compactMap { $0 }
            .sink { snap in
                var row0 = ""
                for col in 0..<snap.cols {
                    if let ch = snap.character(at: col, row: 0) {
                        row0.append(ch)
                    }
                }
                if row0.contains("40 120") {
                    c?.cancel()
                    exp.fulfill()
                }
            }

        wait(for: [exp], timeout: 3.0)
        session.terminate()
    }
}
