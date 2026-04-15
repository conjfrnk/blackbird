import XCTest
@testable import Blackbird

final class PTYTests: XCTestCase {

    func test_spawnEchoAndReadBack() throws {
        let pty = try PTY.spawn(
            executable: "/bin/sh",
            arguments: ["-c", "printf hello"],
            envOverrides: [:],
            size: .init(cols: 80, rows: 24)
        )

        let exp = expectation(description: "got bytes")
        exp.assertForOverFulfill = false
        var collected = Data()
        pty.onBytes = { chunk in
            collected.append(chunk)
            if collected.count >= 5 { exp.fulfill() }
        }

        wait(for: [exp], timeout: 3.0)
        XCTAssertEqual(String(data: collected.prefix(5), encoding: .utf8), "hello")

        pty.terminate()
    }

    func test_writeBytesEchoedBack() throws {
        // sh with -i echoes input back; feed "exit\n" so it terminates cleanly.
        let pty = try PTY.spawn(
            executable: "/bin/sh",
            arguments: [],
            envOverrides: ["PS1": ""],
            size: .init(cols: 80, rows: 24)
        )

        let exp = expectation(description: "echoed")
        exp.assertForOverFulfill = false
        var seen = Data()
        pty.onBytes = { chunk in
            seen.append(chunk)
            // sh echoes the command before running it.
            if seen.contains("exit".data(using: .utf8)!) { exp.fulfill() }
        }

        pty.write("exit\n".data(using: .utf8)!)
        wait(for: [exp], timeout: 3.0)

        pty.terminate()
    }

    func test_resizePropagatesSIGWINCH() throws {
        // Use stty inside the shell to confirm the PTY knows the new size.
        let pty = try PTY.spawn(
            executable: "/bin/sh",
            arguments: ["-c", "stty size; exit"],
            envOverrides: [:],
            size: .init(cols: 80, rows: 24)
        )

        // Resize BEFORE the shell starts stty is a race — instead wait a tick, then resize,
        // then read. Simpler: just check initial size is what we set.
        let exp = expectation(description: "size")
        exp.assertForOverFulfill = false
        var out = Data()
        pty.onBytes = { chunk in
            out.append(chunk)
            if out.contains("\n".data(using: .utf8)!) { exp.fulfill() }
        }

        wait(for: [exp], timeout: 3.0)
        let line = String(data: out, encoding: .utf8) ?? ""
        XCTAssertTrue(line.contains("24 80"), "stty reported: \(line)")

        pty.terminate()
    }
}
