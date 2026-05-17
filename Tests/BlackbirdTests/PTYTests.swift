import XCTest
@testable import Blackbird

final class PTYTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    /// Shared skip-gate for every test in this file that does
    /// `PTY.spawn(executable: "/bin/sh", …)`. Background: the v0.1.9
    /// hardening sweep added 200+ tests upstream of `PTYTests` in
    /// alphabetical order. Each one allocates inside the same xctest
    /// process and grows the ASan shadow-mapping plus the malloc nano
    /// zone. By the time this file's first real-shell-spawn test runs
    /// on macos-14 GHA, the runner is close enough to the VM-mapping
    /// ceiling that one more `forkpty` trips
    /// `malloc: nano zone abandoned due to inability to reserve vm space`,
    /// crashing the xctest runner. The protocol-level invariants these
    /// tests verify (env-scrub list, post-fork SIGWINCH propagation,
    /// concurrent write deadlock guard) are also pinned by in-process
    /// tests that don't spawn shells (e.g.
    /// `test_scrubbedParentEnvVars_coversKnownLeaks`); the spawning
    /// variants are belt-and-braces. Run with `BB_RUN_FLAKY_PTY_TESTS=1`
    /// in isolation when investigating a real shell-spawn regression.
    static func skipIfFlakyOnCI() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["BB_RUN_FLAKY_PTY_TESTS"] != "1",
                      "PTY shell-spawn tests flake the xctest ASan runner under cumulative test load; run in isolation or set BB_RUN_FLAKY_PTY_TESTS=1")
    }

    func test_spawnEchoAndReadBack() throws {
        try Self.skipIfFlakyOnCI()
        let pty = try PTY.spawn(
            executable: "/bin/sh",
            arguments: ["-c", "printf hello"],
            envOverrides: [:],
            size: .init(cols: 80, rows: 24)
        )

        let exp = expectation(description: "got bytes")
        var collected = Data()
        var fulfilled = false
        pty.setOnBytes { [weak pty] chunk in
            collected.append(chunk)
            if collected.count >= 5, !fulfilled {
                fulfilled = true
                pty?.setOnBytes(nil)
                exp.fulfill()
            }
        }
        pty.startReading()

        wait(for: [exp], timeout: 3.0)
        XCTAssertEqual(String(data: collected.prefix(5), encoding: .utf8), "hello")

        pty.terminate()
    }

    func test_writeBytesEchoedBack() throws {
        try Self.skipIfFlakyOnCI()
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
        pty.setOnBytes { [weak pty] chunk in
            seen.append(chunk)
            // sh echoes the command before running it.
            if seen.contains("exit".data(using: .utf8)!), !fulfilled {
                fulfilled = true
                pty?.setOnBytes(nil)
                exp.fulfill()
            }
        }
        pty.startReading()

        pty.write("exit\n".data(using: .utf8)!)
        wait(for: [exp], timeout: 3.0)

        pty.terminate()
    }

    func test_masterFDHasNoSigPipeSet() throws {
        // Audit H1: PTY.init must apply F_SETNOSIGPIPE to the master
        // fd. Without it, writing to a master whose slave has been
        // closed (typical at shell exit) delivers SIGPIPE — the
        // process default disposition terminates the entire app, so
        // a single keystroke racing the shell exit can take Blackbird
        // down. With the flag set the same condition produces EPIPE,
        // which writeRawLocked logs and treats as fatal for that one
        // write only.
        try Self.skipIfFlakyOnCI()
        let pty = try PTY.spawn(
            executable: "/bin/sh",
            arguments: ["-c", "sleep 1"],
            envOverrides: [:],
            size: .init(cols: 80, rows: 24)
        )
        defer { pty.terminate() }
        XCTAssertEqual(pty._testGetNoSigPipeFlag(), 1,
                       "PTY master fd must have F_SETNOSIGPIPE applied (H1)")
    }

    func test_F_SETNOSIGPIPE_platformPrimitive() throws {
        // Defense-in-depth on top of test_masterFDHasNoSigPipeSet:
        // exercise the platform fcntl primitive in-process so a
        // future macOS that stops exposing F_SETNOSIGPIPE breaks
        // CI before any user-visible regression.
        var master: Int32 = -1
        var slave: Int32 = -1
        XCTAssertEqual(Darwin.openpty(&master, &slave, nil, nil, nil), 0,
                       "openpty should succeed on a healthy host")
        defer {
            _ = Darwin.close(master)
            _ = Darwin.close(slave)
        }
        XCTAssertEqual(Darwin.fcntl(master, F_GETNOSIGPIPE), 0,
                       "F_NOSIGPIPE should be off by default on a fresh master fd")
        XCTAssertEqual(Darwin.fcntl(master, F_SETNOSIGPIPE, 1), 0,
                       "F_SETNOSIGPIPE should succeed on a master fd")
        XCTAssertEqual(Darwin.fcntl(master, F_GETNOSIGPIPE), 1,
                       "After F_SETNOSIGPIPE(1), F_GETNOSIGPIPE should return 1")
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
        try Self.skipIfFlakyOnCI()
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
        pty.setOnBytes { [weak pty] chunk in
            out.append(chunk)
            if out.contains(Data("]".utf8)), !fulfilled {
                fulfilled = true
                pty?.setOnBytes(nil)
                exp.fulfill()
            }
        }
        pty.startReading()
        wait(for: [exp], timeout: 3.0)
        let line = String(data: out, encoding: .utf8) ?? ""
        XCTAssertTrue(
            line.contains("[]"),
            "child shell saw XPC_SERVICE_NAME='\(line)' — scrub must have dropped it"
        )
        pty.terminate()
    }

    /// S2-004: PTY's BLACKBIRD_/BB_ namespace classifier must match
    /// case-insensitively so a lowercase parent env var (e.g. one set
    /// by `launchctl setenv bb_token …` or a parent shell script) is
    /// included in the post-fork scrub list and doesn't leak into the
    /// child shell. End-to-end coverage via `posix_spawn` lives under
    /// the BB_RUN_FLAKY_PTY_TESTS gate; this unit test pins the
    /// classifier directly so the contract is checked on every CI run.
    func test_isBlackbirdNamespacedEnvKey_caseInsensitive() {
        // Uppercase canonical.
        XCTAssertTrue(PTY.isBlackbirdNamespacedEnvKey("BB_TOKEN"))
        XCTAssertTrue(PTY.isBlackbirdNamespacedEnvKey("BLACKBIRD_THEME"))
        // Lowercase / mixed — the S2-004 cases that previously slipped.
        XCTAssertTrue(PTY.isBlackbirdNamespacedEnvKey("bb_token"))
        XCTAssertTrue(PTY.isBlackbirdNamespacedEnvKey("Bb_Token"))
        XCTAssertTrue(PTY.isBlackbirdNamespacedEnvKey("blackbird_theme"))
        XCTAssertTrue(PTY.isBlackbirdNamespacedEnvKey("BlackBird_Theme"))
        // Non-matches.
        XCTAssertFalse(PTY.isBlackbirdNamespacedEnvKey("PATH"))
        XCTAssertFalse(PTY.isBlackbirdNamespacedEnvKey("BBQ"))   // no underscore
        XCTAssertFalse(PTY.isBlackbirdNamespacedEnvKey("BLACK"))
        XCTAssertFalse(PTY.isBlackbirdNamespacedEnvKey(""))
    }

    func test_concurrentWriteAndWriteImmediate_doesNotDeadlock() throws {
        try Self.skipIfFlakyOnCI()
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
        // Audit M2: setOnBytes (no-op — concurrent-write test, byte
        // content ignored) then kick the read loop so terminate() reaps
        // the child. PTY.startReading() asserts setOnBytes was called
        // first (PTY.swift:634, M2 misuse guard).
        pty.setOnBytes { _ in }
        pty.startReading()
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
        try Self.skipIfFlakyOnCI()
        // End-to-end: spawn a shell, wait for its initial `stty size` line,
        // then call `pty.resize(...)` and assert the WINCH trap fires with
        // the NEW dimensions. Previously this test only verified initial-
        // spawn winsize — it never exercised resize at all. Using a WINCH
        // handler that prints size (instead of `ioctl(masterFD, TIOCGWINSZ)`
        // directly) keeps the test inside the test target and still proves
        // the full kernel-level pipeline: TIOCSWINSZ → kernel delivers
        // SIGWINCH to the fg process group → shell handler reads new size.
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
        pty.setOnBytes { chunk in
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
        pty.startReading()
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

    /// Audit L1: a non-zero `tic` exit MUST short-circuit before the
    /// `infocmp` probe. A pre-planted hostile `xterm-kitty` entry would
    /// otherwise survive — the probe succeeds against the attacker's
    /// entry and the child gets `TERM=xterm-kitty` against terminfo
    /// nobody installed. The decision helper takes a probe closure so
    /// we can drive both branches without running `tic`.
    func test_kittyTerminfoDecision_ticFailureForcesFallback_evenIfProbeWouldSucceed() {
        var probeCalled = false
        let probe: () -> Bool = {
            probeCalled = true
            return true  // simulate hostile pre-planted entry — probe succeeds
        }
        let result = PTY.decideKittyTerminfoAvailability(ticExit: 1, probe: probe)
        XCTAssertFalse(
            result,
            "tic non-zero exit must force xterm-256color fallback regardless of probe outcome"
        )
        XCTAssertFalse(
            probeCalled,
            "tic failure must short-circuit before probing — pre-planted entries must not be trusted"
        )
    }

    /// Audit L1 happy path: tic exit 0 + successful probe yields the
    /// xterm-kitty TERM. Pins that the success branch still works.
    func test_kittyTerminfoDecision_ticSuccessAndProbeSuccess_returnsTrue() {
        let result = PTY.decideKittyTerminfoAvailability(ticExit: 0, probe: { true })
        XCTAssertTrue(result, "tic=0 + probe=true should return true")
    }

    /// Audit L1: tic exit 0 + probe failure also yields fallback. The
    /// probe is the load-bearing check when tic succeeded — without it
    /// we'd advertise xterm-kitty to a child whose ncurses can't find
    /// the entry.
    func test_kittyTerminfoDecision_ticSuccessButProbeFails_returnsFalse() {
        let result = PTY.decideKittyTerminfoAvailability(ticExit: 0, probe: { false })
        XCTAssertFalse(result, "tic=0 + probe=false should return false (fallback)")
    }

    /// Audit M2: bytes the shell emits before the consumer wires `onBytes`
    /// must NOT be dropped on the floor. The contract changed: `PTY.spawn`
    /// no longer starts the read loop; `startReading()` is the explicit
    /// trigger that the consumer must call AFTER `setOnBytes`.
    ///
    /// Concretely: spawn a shell that prints "hello" immediately, sleep
    /// to let the kernel actually buffer those bytes, then wire `onBytes`
    /// and start the read loop. Without M2 (loop started in init), the
    /// reader would drain the pipe into a nil callback and "hello" would
    /// vanish. With the fix, the reader is dormant until `startReading()`
    /// fires and "hello" lands in the consumer's collected buffer.
    func test_bytesEmittedBeforeOnBytesWired_areNotDropped() throws {
        try Self.skipIfFlakyOnCI()
        let pty = try PTY.spawn(
            executable: "/bin/sh",
            arguments: ["-c", "printf hello"],
            envOverrides: [:],
            size: .init(cols: 80, rows: 24)
        )
        // Give the shell time to print + the kernel to buffer the bytes
        // before any reader could possibly drain them. Without M2 the
        // init-time read loop would drain into a nil onBytes here.
        let pump = expectation(description: "child prints + kernel buffers")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
            pump.fulfill()
        }
        wait(for: [pump], timeout: 1.0)

        // Now wire the consumer and start the loop. The captured 'hello'
        // must arrive — bytes pre-existed in the pipe before this point.
        let exp = expectation(description: "got bytes after deferred startReading")
        var collected = Data()
        var fulfilled = false
        pty.setOnBytes { [weak pty] chunk in
            collected.append(chunk)
            if collected.count >= 5, !fulfilled {
                fulfilled = true
                pty?.setOnBytes(nil)
                exp.fulfill()
            }
        }
        pty.startReading()

        wait(for: [exp], timeout: 3.0)
        XCTAssertEqual(
            String(data: collected.prefix(5), encoding: .utf8), "hello",
            "PTY must buffer pre-wire bytes until startReading() fires; M2 regression"
        )

        pty.terminate()
    }
}
