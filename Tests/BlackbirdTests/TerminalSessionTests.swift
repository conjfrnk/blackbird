import XCTest
import Combine
@testable import Blackbird

final class TerminalSessionTests: XCTestCase {

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
        let session = try TerminalSession.start(
            shell: "/bin/sh",
            arguments: [],
            size: .init(cols: 80, rows: 24)
        )

        let exp = expectation(description: "echo appears")
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

        session.send(Data("hello".utf8))
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
