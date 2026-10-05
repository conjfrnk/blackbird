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

    /// Read-loop coalescing guard. A child that emits a known number of
    /// bytes and exits immediately must have EVERY byte delivered through
    /// `onBytes` before `onExit` fires (EOF/EIO must not drop a partially
    /// accumulated batch), and no single chunk may exceed the coalescing cap
    /// (32 KiB) or a user-action yield point would wait on an oversized
    /// parse. 200 000 bytes of non-newline output (no ONLCR expansion) is
    /// ~6 full buffers plus a tail; memory cost is under 1 MiB.
    func test_floodOutputDeliveredCompletelyInBoundedChunks() throws {
        try Self.skipIfFlakyOnCI()
        let total = 200_000
        let pty = try PTY.spawn(
            executable: "/bin/sh",
            arguments: ["-c", "head -c \(total) /dev/zero | tr '\\0' x"],
            envOverrides: [:],
            size: .init(cols: 80, rows: 24)
        )
        let lock = NSLock()
        var received = 0
        var maxChunk = 0
        var allX = true
        pty.setOnBytes { chunk in
            lock.lock(); defer { lock.unlock() }
            received += chunk.count
            maxChunk = max(maxChunk, chunk.count)
            if chunk.contains(where: { $0 != UInt8(ascii: "x") }) { allX = false }
        }
        let exited = expectation(description: "child exited")
        pty.setOnExit { _ in exited.fulfill() }
        pty.startReading()
        wait(for: [exited], timeout: 10.0)

        lock.lock(); defer { lock.unlock() }
        XCTAssertEqual(received, total, "every byte written before exit must be delivered")
        XCTAssertTrue(allX, "payload must arrive intact")
        XCTAssertLessThanOrEqual(maxChunk, 32 * 1024, "coalesced chunk must respect the cap")
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

    // MARK: - validatedEnvOverrides
    //
    // Pin the contract of the pure `PTY.validatedEnvOverrides` helper:
    // it returns exactly the subset of caller-supplied env overrides
    // that are SAFE to hand to POSIX `setenv` in the child. An entry is
    // dropped iff the key is empty, the key contains NUL, the key
    // contains "=", or the value contains NUL. Empty values and "=" in
    // values are legitimate and must survive. The result order derives
    // from Dictionary iteration and is unspecified, so every comparison
    // below is order-independent (collapse to a Dictionary first).

    /// Order-independent view of the result. Surviving keys are a subset
    /// of the (unique) input keys, so collapsing the returned pairs to a
    /// Dictionary never collides and frees the assertions from depending
    /// on the unspecified Dictionary-iteration order.
    private func asDict(_ pairs: [(key: String, value: String)]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: pairs.map { ($0.key, $0.value) })
    }

    func test_validatedEnvOverrides_validEntrySurvives() {
        let input = ["TERM": "xterm-256color"]
        XCTAssertEqual(
            asDict(PTY.validatedEnvOverrides(input)),
            input,
            "a normal KEY=VALUE-style override must survive validation unchanged"
        )
    }

    func test_validatedEnvOverrides_emptyValueSurvives() {
        let input = ["PS1": ""]
        XCTAssertEqual(
            asDict(PTY.validatedEnvOverrides(input)),
            input,
            "an empty value is a legitimate env override (e.g. PS1=\"\") and must survive"
        )
    }

    func test_validatedEnvOverrides_valueWithEqualsSurvives() {
        let input = ["FOO": "a=b"]
        XCTAssertEqual(
            asDict(PTY.validatedEnvOverrides(input)),
            input,
            "'=' is only forbidden in the key; a value containing '=' must survive"
        )
    }

    func test_validatedEnvOverrides_emptyKeyDropped() {
        let result = PTY.validatedEnvOverrides(["": "x"])
        XCTAssertTrue(
            result.isEmpty,
            "an empty key is invalid for setenv and must be dropped; got \(asDict(result))"
        )
    }

    func test_validatedEnvOverrides_keyWithEqualsDropped() {
        let result = PTY.validatedEnvOverrides(["A=B": "x"])
        XCTAssertTrue(
            result.isEmpty,
            "a key containing '=' is invalid for setenv and must be dropped; got \(asDict(result))"
        )
    }

    func test_validatedEnvOverrides_keyWithNulDropped() {
        let result = PTY.validatedEnvOverrides(["A\u{0}B": "x"])
        XCTAssertTrue(
            result.isEmpty,
            "a key containing NUL is invalid for setenv and must be dropped; got \(asDict(result))"
        )
    }

    func test_validatedEnvOverrides_valueWithNulDropped() {
        let result = PTY.validatedEnvOverrides(["FOO": "a\u{0}b"])
        XCTAssertTrue(
            result.isEmpty,
            "a value containing NUL is invalid for setenv and must be dropped; got \(asDict(result))"
        )
    }

    func test_validatedEnvOverrides_mixedDictionaryKeepsOnlyValid() {
        let input: [String: String] = [
            "TERM": "xterm-256color",  // valid
            "PS1": "",                 // valid: empty value
            "FOO": "a=b",              // valid: '=' allowed in value
            "LANG": "en_US.UTF-8",     // valid
            "": "empty-key",           // invalid: empty key
            "BAD=KEY": "x",            // invalid: '=' in key
            "NUL\u{0}KEY": "y",        // invalid: NUL in key
            "GOOD": "has\u{0}nul",     // invalid: NUL in value
        ]
        let expected: [String: String] = [
            "TERM": "xterm-256color",
            "PS1": "",
            "FOO": "a=b",
            "LANG": "en_US.UTF-8",
        ]
        let result = PTY.validatedEnvOverrides(input)
        XCTAssertEqual(
            result.count,
            expected.count,
            "exactly the 4 valid entries must survive; got \(asDict(result))"
        )
        XCTAssertEqual(
            asDict(result),
            expected,
            "mixed input must yield exactly the valid (key, value) pairs, unchanged"
        )
    }

    func test_validatedEnvOverrides_emptyInputReturnsEmpty() {
        XCTAssertTrue(
            PTY.validatedEnvOverrides([:]).isEmpty,
            "empty input must yield an empty result"
        )
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
                // Arm the WINCH trap FIRST, then print initial size. The
                // test fires resize as soon as it reads "24 80" — if
                // `stty size` ran before `trap`, a SIGWINCH delivered in
                // the gap between the two would hit the default
                // disposition (POSIX: ignore) and be silently dropped,
                // leaving the trap permanently un-fired. Installing
                // `trap` first means the bytes the test waits for are
                // produced AFTER the handler is registered, so any
                // SIGWINCH the test triggers necessarily invokes it.
                // `sleep 10 &` backgrounds the sleep so the parent
                // shell blocks in `wait` instead of in `sleep`'s
                // syscall — only `wait` is an interruptible shell
                // builtin that lets traps fire immediately on signal
                // receipt. Foregrounding `sleep` directly would queue
                // SIGWINCH until `sleep` exited, which outlasts the
                // test timeout.
                "trap 'stty size; exit 0' WINCH; stty size; sleep 10 & wait",
            ],
            envOverrides: [:],
            size: .init(cols: 80, rows: 24)
        )
        // Guarantee reap even if a wait() below times out.
        defer { pty.terminate() }

        // Wait for the initial "24 80" line. Because `trap` ran before
        // `stty size`, observing this output proves the handler is
        // already armed; the subsequent `pty.resize()` SIGWINCH is
        // guaranteed to invoke it.
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
        let result = KittyTerminfo.decideAvailability(ticExit: 1, probe: probe)
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
        let result = KittyTerminfo.decideAvailability(ticExit: 0, probe: { true })
        XCTAssertTrue(result, "tic=0 + probe=true should return true")
    }

    /// Audit L1: tic exit 0 + probe failure also yields fallback. The
    /// probe is the load-bearing check when tic succeeded — without it
    /// we'd advertise xterm-kitty to a child whose ncurses can't find
    /// the entry.
    func test_kittyTerminfoDecision_ticSuccessButProbeFails_returnsFalse() {
        let result = KittyTerminfo.decideAvailability(ticExit: 0, probe: { false })
        XCTAssertFalse(result, "tic=0 + probe=false should return false (fallback)")
    }

    /// Audit S1-001: writes against a child that NEVER reads its stdin
    /// must not wedge the writer. `/bin/sh -c 'sleep 30'` is a
    /// deterministic non-reader — the kernel tty input buffer fills
    /// after ~1 KiB and stays full for the child's lifetime. Pre-fix,
    /// a `writeImmediate` issued after the buffer filled parked inside
    /// the kernel `write(2)` indefinitely — i.e. Ctrl+C against a
    /// stuck child was exactly the keystroke that could never be
    /// delivered.
    ///
    /// Contract pinned here:
    ///  (a) `pty.write(64 KiB)` RETURNS without blocking on the full
    ///      kernel buffer (the flush may proceed asynchronously);
    ///  (b) a subsequent `writeImmediate(0x03)` — the Ctrl+C shape —
    ///      returns in well under a second instead of wedging;
    ///  (c) `pty.terminate()` (the deferred teardown) still completes.
    ///
    /// Pre-flight cost (project rule): one 64 KiB Data + one /bin/sh
    /// child; < 1 s wall on the green path. One live shell, gated like
    /// every other real-spawn test in this file.
    func test_writeAgainstNonReadingChild_doesNotWedgeWriteImmediate() throws {
        try Self.skipIfFlakyOnCI()
        let pty = try PTY.spawn(
            executable: "/bin/sh",
            arguments: ["-c", "sleep 30"],
            envOverrides: [:],
            size: .init(cols: 80, rows: 24)
        )
        // Contract (c): teardown still completes — the defer runs
        // before the test method returns; a terminate() hang would
        // surface as a suite-level timeout, loudly.
        defer { pty.terminate() }
        // Drain the master side so tty ECHO of our 64 KiB can't add a
        // second, unrelated blocking dimension on the read path.
        pty.setOnBytes { _ in }
        pty.startReading()

        // (a) The 64 KiB write call must return promptly even though
        // the child will never drain it.
        let payload = Data(repeating: 0x61, count: 64 * 1024)
        let writeStart = Date()
        pty.write(payload)
        let writeReturned = Date().timeIntervalSince(writeStart)
        XCTAssertLessThan(
            writeReturned, 1.0,
            "pty.write(64 KiB) blocked \(writeReturned)s against a non-reading child (S1-001)"
        )

        // (b) writeImmediate must complete in bounded time. Issue it
        // off the test thread so a regression fails this expectation's
        // timeout instead of parking the whole xctest host in the
        // kernel with no failure report.
        var immediateElapsed: TimeInterval = -1
        let returned = expectation(description: "writeImmediate returned")
        DispatchQueue.global().async {
            let t0 = Date()
            pty.writeImmediate(Data([0x03]))  // the Ctrl+C shape
            immediateElapsed = Date().timeIntervalSince(t0)
            returned.fulfill()
        }
        wait(for: [returned], timeout: 5.0)
        XCTAssertGreaterThanOrEqual(
            immediateElapsed, 0,
            "writeImmediate never returned — parked in the kernel (S1-001 pre-fix shape)"
        )
        XCTAssertLessThan(
            immediateElapsed, 1.0,
            "writeImmediate took \(immediateElapsed)s against a full kernel tty buffer — "
            + "must stay well under 1 s (S1-001)"
        )
    }

    /// Audit S2-001: `setOnBytes` called mid-session (after
    /// `startReading()`) must swap the live read loop's consumer —
    /// bytes produced after the swap go to the NEW closure and never
    /// to the old one. A consumer that rebinds its handler (view
    /// re-attach, session adoption) must not keep feeding a dead
    /// closure. The strict "A gets nothing after the swap" check holds
    /// because the test quiesces the producer first; `setOnBytes` itself
    /// only promises that at most one already-loaded chunk can still
    /// reach the old closure.
    ///
    /// Pre-flight cost: one /bin/zsh -f child, a few hundred bytes of
    /// prompt + echo traffic, < 6 s typical, ~20 s worst case (15 s fence deadline + 5 s
    /// nonce wait). One live shell,
    /// gated like the file's other real-spawn tests.
    func test_setOnBytes_swapMidSession_routesPostSwapBytesToNewClosureOnly() throws {
        try Self.skipIfFlakyOnCI()
        try runSwapMidSessionScenario(executable: "/bin/zsh", arguments: ["-f"])
    }

    /// The swap must wait for the shell's WHOLE startup output. The nightly
    /// TSAN flake (2026-09-29) was a startup write landing in the gap between
    /// the test's snapshot of A and its swap to B; the fix is to swap only once
    /// startup has gone quiet, so nothing is left to race. That gap is
    /// microseconds wide and cannot be hit on demand, but its precondition can
    /// be pinned: here the child emits a second startup write 0.8 s after the
    /// first (longer than the old fixed 0.3 s sleep), ending in the ESC[?2004h
    /// marker zsh uses. A test that swaps on a timer swaps before it and the
    /// write goes to B; the quiescence fence must swap after it, so A holds it.
    /// `sh` stands in for zsh so the gap is exact instead of load-dependent;
    /// tty echo is off and the child only emits the nonce after its second
    /// write (like zsh, whose ZLE echoes input only once the prompt is drawn),
    /// so the nonce wait cannot finish early. One live child, ~1.5 s.
    func test_setOnBytes_swapMidSession_waitsForSlowSecondStartupWrite() throws {
        try Self.skipIfFlakyOnCI()
        let closureA = try runSwapMidSessionScenario(
            executable: "/bin/sh",
            arguments: ["-c", "stty -echo; printf 'first\\n'; sleep 0.8; printf 'second\\033[?2004h'; read l; printf '%s\\n' \"$l\"; exec cat"]
        )
        XCTAssertTrue(
            closureA.contains(Data("second".utf8)),
            "the swap happened before the child's late startup write reached closure A "
            + "(fixed-sleep behaviour); A got \(closureA.count) byte(s)"
        )
    }

    private func runSwapMidSessionScenario(executable: String, arguments: [String]) throws -> Data {
        let pty = try PTY.spawn(
            executable: executable,
            arguments: arguments,
            envOverrides: [:],
            size: .init(cols: 80, rows: 24)
        )
        defer { pty.terminate() }

        let lock = NSLock()
        var bytesA = Data()
        var bytesB = Data()

        // Closure A: the initial consumer. Collects zsh's startup
        // output (prompt etc.).
        pty.setOnBytes { chunk in
            lock.lock()
            bytesA.append(chunk)
            lock.unlock()
        }
        pty.startReading()

        // Quiescence fence. zsh -f emits its startup as TWO pty writes
        // (a PROMPT_EOL_MARK burst, then the prompt ending in
        // ESC[?2004h) and then sits in read(2) until we send input. A
        // fixed 0.3 s sleep let a loaded TSAN runner snapshot A between
        // the two writes (nightly 2026-10-01: snapshot == first write
        // == 104 B, 92 B of prompt then landed in A). The strict
        // "A receives nothing after the swap" check below is only
        // meaningful when no startup chunk is pending or already
        // loaded-but-undelivered at the swap instant, so wait for the
        // terminal marker at the END of A plus a quiet window. If the
        // marker never shows (different zsh/TERM), fall back to a long (3 s)
        // pure quiet window, well past any loaded-runner gap between zsh's
        // two startup writes, rather than hard-failing.
        let readyMarker = Data([0x1b]) + Data("[?2004h".utf8)
        let deadline = Date().addingTimeInterval(15)
        var lastCount = -1
        var lastChange = Date()
        var quiescent = false
        while Date() < deadline {
            lock.lock()
            let snap = bytesA
            lock.unlock()
            if snap.count != lastCount {
                lastCount = snap.count
                lastChange = Date()
            }
            let quiet = Date().timeIntervalSince(lastChange)
            if !snap.isEmpty,
               (snap.suffix(readyMarker.count) == readyMarker && quiet >= 0.15) || quiet >= 3.0 {
                quiescent = true
                break
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        lock.lock()
        let startup = bytesA
        lock.unlock()
        XCTAssertTrue(
            quiescent,
            "zsh never reached a quiescent prompt within 15 s; got \(startup.count) byte(s): "
            + "\(startup.map { String(format: "%02x", $0) }.joined().prefix(400))"
        )
        guard quiescent else { return startup }

        // Determinism comes from the quiescence above: zsh is blocked
        // in read(2) and emits nothing until the write below, so no
        // chunk can be in flight to A when the swap lands.
        lock.lock()
        let aCountAtSwap = bytesA.count
        lock.unlock()

        // Swap to closure B mid-session, then produce fresh output
        // carrying a nonce. The nonce bytes did not exist anywhere
        // before the swap, so EITHER closure seeing them is an
        // unambiguous post-swap delivery.
        let nonce = "nonce-zz123"
        let sawNonce = expectation(description: "closure B saw the nonce")
        var fulfilled = false
        pty.setOnBytes { chunk in
            lock.lock()
            bytesB.append(chunk)
            let hit = bytesB.contains(Data(nonce.utf8))
            lock.unlock()
            if hit, !fulfilled {
                fulfilled = true
                sawNonce.fulfill()
            }
        }
        pty.write(Data("echo \(nonce)\r".utf8))
        wait(for: [sawNonce], timeout: 5.0)

        lock.lock()
        let aFinal = bytesA
        let bFinal = bytesB
        lock.unlock()
        XCTAssertTrue(
            bFinal.contains(Data(nonce.utf8)),
            "post-swap output must reach closure B (S2-001)"
        )
        XCTAssertFalse(
            aFinal.contains(Data(nonce.utf8)),
            "closure A saw the post-swap nonce — setOnBytes swap did not apply mid-session (S2-001)"
        )
        XCTAssertEqual(
            aFinal.count, aCountAtSwap,
            "closure A must receive nothing after the swap point — got "
            + "\(aFinal.count - aCountAtSwap) extra byte(s) (S2-001): "
            + "\(aFinal.dropFirst(aCountAtSwap).map { String(format: "%02x", $0) }.joined().prefix(400))"
        )
        return aFinal
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
