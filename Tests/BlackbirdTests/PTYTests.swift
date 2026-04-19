import XCTest
@testable import Blackbird

final class PTYTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    func test_spawnEchoAndReadBack() throws {
        let pty = try PTY.spawn(
            executable: "/bin/sh",
            arguments: ["-c", "printf hello"],
            envOverrides: [:],
            size: .init(cols: 80, rows: 24)
        )

        let exp = expectation(description: "got bytes")
        var collected = Data()
        var fulfilled = false
        pty.onBytes = { [weak pty] chunk in
            collected.append(chunk)
            if collected.count >= 5, !fulfilled {
                fulfilled = true
                pty?.onBytes = nil
                exp.fulfill()
            }
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
        var seen = Data()
        var fulfilled = false
        pty.onBytes = { [weak pty] chunk in
            seen.append(chunk)
            // sh echoes the command before running it.
            if seen.contains("exit".data(using: .utf8)!), !fulfilled {
                fulfilled = true
                pty?.onBytes = nil
                exp.fulfill()
            }
        }

        pty.write("exit\n".data(using: .utf8)!)
        wait(for: [exp], timeout: 3.0)

        pty.terminate()
    }

    func test_scrubbedParentEnvVars_coversKnownLeaks() {
        // Pin the env-scrub list. These launchd / XPC / CoreFoundation
        // variables leak from the GUI app's context into the child shell
        // if the post-fork path drops them. A "simplify this env
        // cleanup" refactor that silently shrinks the list would
        // re-open the leak; this test surfaces that at CI time.
        let expected: Set<String> = [
            "XPC_SERVICE_NAME",
            "XPC_FLAGS",
            "__CF_USER_TEXT_ENCODING",
            "OS_ACTIVITY_DT_MODE",
            "__XCODE_BUILT_PRODUCTS_DIR_PATHS",
            "__XPC_DYLD_LIBRARY_PATH",
            "LaunchInstanceID",
            "SECURITYSESSIONID",
        ]
        let actual = Set(PTY.scrubbedParentEnvVars)
        XCTAssertTrue(
            expected.isSubset(of: actual),
            "env scrub list missing required keys: \(expected.subtracting(actual))"
        )
    }

    func test_childShellSeesNoXpcServiceName() throws {
        // End-to-end check: spawn /bin/sh, have it echo $XPC_SERVICE_NAME.
        // After the post-fork scrub the value must be empty regardless
        // of whether the XCTest host itself inherited one. Belt-and-
        // braces on top of test_scrubbedParentEnvVars_coversKnownLeaks —
        // that one pins the list; this one verifies the list is
        // actually applied in the child.
        let pty = try PTY.spawn(
            executable: "/bin/sh",
            arguments: ["-c", "printf '[%s]' \"$XPC_SERVICE_NAME\""],
            envOverrides: [:],
            size: .init(cols: 80, rows: 24)
        )
        let exp = expectation(description: "child env")
        var out = Data()
        var fulfilled = false
        pty.onBytes = { [weak pty] chunk in
            out.append(chunk)
            if out.contains(Data("]".utf8)), !fulfilled {
                fulfilled = true
                pty?.onBytes = nil
                exp.fulfill()
            }
        }
        wait(for: [exp], timeout: 3.0)
        let line = String(data: out, encoding: .utf8) ?? ""
        XCTAssertTrue(
            line.contains("[]"),
            "child shell saw XPC_SERVICE_NAME='\(line)' — scrub must have dropped it"
        )
        pty.terminate()
    }

    func test_concurrentWriteAndWriteImmediate_doesNotDeadlock() throws {
        // Regression guard for the writeImmediate / write lock-order
        // deadlock fixed in bac607f. Fire many writes + writeImmediates
        // from different queues concurrently; if the old `stateQueue →
        // writeQueue` order ever comes back, this test times out.
        let pty = try PTY.spawn(
            executable: "/bin/sh",
            arguments: ["-c", "cat > /dev/null; exit"],
            envOverrides: [:],
            size: .init(cols: 80, rows: 24)
        )
        let group = DispatchGroup()
        let concurrentQ = DispatchQueue(
            label: "test.concurrent", attributes: .concurrent
        )
        // 50 writes + 50 writeImmediates scheduled concurrently.
        for _ in 0..<50 {
            group.enter()
            concurrentQ.async {
                pty.write(Data("a".utf8))
                group.leave()
            }
            group.enter()
            concurrentQ.async {
                pty.writeImmediate(Data([0x03]))  // Ctrl+C equivalent
                group.leave()
            }
        }
        // 3-second wait is generous; the old deadlock hung forever.
        let timedOut = group.wait(timeout: .now() + 3.0)
        XCTAssertEqual(timedOut, .success, "concurrent writes must not deadlock")
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

        let exp = expectation(description: "size")
        var out = Data()
        var fulfilled = false
        pty.onBytes = { [weak pty] chunk in
            out.append(chunk)
            if out.contains("\n".data(using: .utf8)!), !fulfilled {
                fulfilled = true
                pty?.onBytes = nil
                exp.fulfill()
            }
        }

        wait(for: [exp], timeout: 3.0)
        let line = String(data: out, encoding: .utf8) ?? ""
        XCTAssertTrue(line.contains("24 80"), "stty reported: \(line)")

        pty.terminate()
    }
}
