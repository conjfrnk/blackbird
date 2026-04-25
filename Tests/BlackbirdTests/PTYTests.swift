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
            // dyld injection surface — F8 hardening.
            "DYLD_LIBRARY_PATH",
            "DYLD_INSERT_LIBRARIES",
            "DYLD_FRAMEWORK_PATH",
            "DYLD_FALLBACK_LIBRARY_PATH",
            "DYLD_FALLBACK_FRAMEWORK_PATH",
            "DYLD_PRINT_TO_FILE",
            "DYLD_PRINT_APIS",
            "DYLD_PRINT_STATISTICS",
            // Allocator / logging / CoreAnimation debug leakage.
            "MallocNanoZone",
            "OS_ACTIVITY_MODE",
            "CA_DEBUG_TRANSACTIONS",
            "CA_ASSERT_MAIN_THREAD_TRANSACTIONS",
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
        //
        // Gated on macos-14 GHA: the cumulative ASan address-space
        // pressure from the v0.1.9 hardening sweep's added tests
        // pushes this real-shell-spawn over the malloc nano-zone
        // ceiling ("nano zone abandoned due to inability to reserve
        // vm space"), crashing the xctest runner. The list pinning
        // (test_scrubbedParentEnvVars_coversKnownLeaks) still runs
        // and guards the contract; this end-to-end probe needs an
        // explicit BB_RUN_FLAKY_PTY_TESTS=1 to fire.
        try XCTSkipIf(ProcessInfo.processInfo.environment["BB_RUN_FLAKY_PTY_TESTS"] != "1",
                      "PTY spawn flakes the xctest ASan runner under cumulative test load; run in isolation or set BB_RUN_FLAKY_PTY_TESTS=1")
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
        // End-to-end: spawn a shell, wait for its initial `stty size` line,
        // then call `pty.resize(...)` and assert the WINCH trap fires with
        // the NEW dimensions. Previously this test only verified initial-
        // spawn winsize — it never exercised resize at all. Using a WINCH
        // handler that prints size (instead of `ioctl(masterFD, TIOCGWINSZ)`
        // directly) keeps the test inside the test target and still proves
        // the full kernel-level pipeline: TIOCSWINSZ → kernel delivers
        // SIGWINCH to the fg process group → shell handler reads new size.
        //
        // Gated on macos-14 GHA: of the five real-shell-spawn tests in
        // this file, this one runs latest in alphabetical order and
        // tips the cumulative ASan-shadow VM-space ceiling that the
        // v0.1.9 hardening sweep's added 200+ tests fill up. Crashes
        // the xctest runner ("malloc: nano zone abandoned"). Run in
        // isolation with BB_RUN_FLAKY_PTY_TESTS=1.
        try XCTSkipIf(ProcessInfo.processInfo.environment["BB_RUN_FLAKY_PTY_TESTS"] != "1",
                      "PTY spawn flakes the xctest ASan runner under cumulative test load; run in isolation or set BB_RUN_FLAKY_PTY_TESTS=1")
        let pty = try PTY.spawn(
            executable: "/bin/sh",
            arguments: [
                "-c",
                // Print size on spawn, then arm a WINCH trap that re-prints
                // it and exits. `sleep 10 &` backgrounds the sleep so the
                // parent shell blocks in `wait` instead of in `sleep`'s
                // syscall — only `wait` is an interruptible shell builtin
                // that lets traps fire immediately on signal receipt.
                // Foregrounding `sleep` directly would queue SIGWINCH until
                // `sleep` exited, which outlasts the test timeout.
                "stty size; trap 'stty size; exit 0' WINCH; sleep 10 & wait",
            ],
            envOverrides: [:],
            size: .init(cols: 80, rows: 24)
        )
        // Guarantee reap even if a wait() below times out.
        defer { pty.terminate() }

        // Wait for the initial "24 80" line so we know the trap is armed
        // before we fire the resize. If we resize too early the shell may
        // not have registered the trap yet and the SIGWINCH is a no-op on
        // subsequent output.
        let initial = expectation(description: "initial size")
        var out = Data()
        var sawInitial = false
        var sawResized = false
        let resized = expectation(description: "resized size")
        let lock = NSLock()
        pty.onBytes = { chunk in
            lock.lock()
            out.append(chunk)
            let text = String(data: out, encoding: .utf8) ?? ""
            if !sawInitial, text.contains("24 80") {
                sawInitial = true
                lock.unlock()
                initial.fulfill()
                return
            }
            if sawInitial, !sawResized, text.contains("40 120") {
                sawResized = true
                lock.unlock()
                resized.fulfill()
                return
            }
            lock.unlock()
        }
        // 10 s (not the 3 s used by the simpler PTY tests above) because
        // this path is heavier: fork + /bin/sh exec + `stty size` + trap
        // registration before `initial` can fulfill, and TIOCSWINSZ →
        // kernel signal scheduling → shell trap fire + `stty size` again
        // before `resized` can fulfill. On GHA macos-14 runners under
        // ASan+UBSan the whole pipeline can exceed 3 s even on a green
        // run — d5d3b23's CI hit `Exceeded timeout of 3 seconds` on the
        // resized wait without any real bug. 10 s is comfortable without
        // masking a genuine SIGWINCH hang (a broken trap still fails
        // within 10 s, just slower to surface).
        wait(for: [initial], timeout: 10.0)

        // Drive the actual resize. TIOCSWINSZ updates the kernel winsize and
        // posts SIGWINCH to the tty's foreground pgroup; the shell trap
        // reads the new size and prints it.
        pty.resize(to: .init(cols: 120, rows: 40))

        wait(for: [resized], timeout: 10.0)
        lock.lock()
        let line = String(data: out, encoding: .utf8) ?? ""
        lock.unlock()
        XCTAssertTrue(line.contains("40 120"),
                      "post-resize stty must report new dims; saw: \(line)")
    }
}
