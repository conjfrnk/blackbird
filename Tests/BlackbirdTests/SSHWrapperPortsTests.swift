import XCTest

/// Behavioral tests for the bash and fish ports of the Blackbird `ssh`
/// terminfo-propagation wrapper:
///
/// - `Sources/Blackbird/Resources/shell/ssh.bash`
/// - `Sources/Blackbird/Resources/shell/ssh.fish`
///
/// These are the non-zsh siblings of the primary zsh wrapper. Sourcing the
/// file defines an `ssh` function that wraps `command ssh`; the wrapper's job
/// is to make Kitty's `xterm-kitty` terminfo available on remote hosts so
/// full-featured remote sessions render correctly, WITHOUT ever breaking a
/// plain `ssh` (wrong TERM, an extra hop, a swallowed exit code, or a
/// shadowed user function would each be a silent, user-visible regression
/// that never fails in CI). This file spawns a real `/bin/bash` (or `fish`)
/// sourcing the shipped script against a hermetic stub `ssh`/`infocmp` and
/// asserts on how the wrapper drove those stubs.
///
/// Blind-authored from the contract only: the test author did not read the
/// script implementations. The scripts are located from the repo tree at
/// runtime (walk up from `#filePath` to the dir containing `project.yml`),
/// mirroring `ShellIntegrationScriptTests`.
///
/// ## Contract under test
///
/// 1. `TERM != "xterm-kitty"` → exactly one real `ssh` call, argv untouched
///    (no canonicalization, no pre-flight).
/// 2. `TERM == "xterm-kitty"`:
///    - Destination canonicalized via `ssh -G <argv>`; the `user`/`hostname`/
///      `port` lines form the cache key `"user@hostname:port"`.
///    - Cache file `$XDG_STATE_HOME/blackbird/ssh-terminfo-hosts`, one key per
///      line. Cache hit → single connection, TERM stays kitty, no `tic`.
///    - Cache miss + plain destination (no remote command; `-p 2222 host` and
///      `-o X=y host` are still plain) → pre-flight: local `infocmp -x
///      xterm-kitty` piped into an `ssh` invocation carrying a remote `tic`.
///      Success → cache line appended (mode 0600), connection with kitty TERM.
///      Failure → no cache line, connection with `TERM="xterm-256color"`.
///    - Remote-command argv (`ssh host ls`) → no pre-flight, connection
///      downgraded to `TERM="xterm-256color"`.
///    - `ssh -G` failure → downgrade, no pre-flight.
///    - The wrapper preserves the real connection's exit code.
/// 3. Sourcing must not shadow a pre-existing user `ssh` function/alias.
///    Double-sourcing is idempotent.
/// 4. Diagnostics may go to stderr; stderr text is not asserted.
///
/// ## Cost
///
/// Each test creates a private temp tree (~a handful of tiny files) and spawns
/// one short-lived shell that itself forks a couple of `/bin/sh` stub
/// processes. No PTY, no GUI, no network, no real `ssh`. Well under the
/// per-test budget.
final class SSHWrapperPortsTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        // Register the host-termination observer once (idempotent) so a
        // filtered `-only-testing` run doesn't leave a zombie SwiftUI host.
        TestHostTermination.shared.register()
    }

    // MARK: - Fixed values

    /// The canonical destination the stub `ssh -G` always reports. The wrapper
    /// composes these three fields into the cache key.
    private static let kittyTERM = "xterm-kitty"
    private static let downgradeTERM = "xterm-256color"
    private static let expectedKey = "testuser@testhost:22"

    // MARK: - Errors

    private struct MissingFile: Error, CustomStringConvertible {
        let path: String
        var description: String { "required file not found: \(path)" }
    }

    // MARK: - Repo layout

    /// Walk up from this source file to the directory containing `project.yml`
    /// (the repo root). xcodebuild's CWD lives inside DerivedData, so `#filePath`
    /// is the only stable anchor.
    private func repoRoot(file: String = #filePath) throws -> URL {
        let fm = FileManager.default
        var dir = URL(fileURLWithPath: file).deletingLastPathComponent()
        while dir.path != "/" {
            if fm.fileExists(atPath: dir.appendingPathComponent("project.yml").path) {
                return dir
            }
            dir = dir.deletingLastPathComponent()
        }
        throw MissingFile(path: "project.yml (searched upward from \(file))")
    }

    /// Resolve a shipped shell script. Throws (→ test failure, not skip) when
    /// the script is absent: during TDD the impl is expected to exist by the
    /// time these run, and a missing file must go red rather than let a bare
    /// stub `ssh` on `$PATH` masquerade as a passing wrapper.
    private func shellFile(_ name: String) throws -> URL {
        let url = try repoRoot()
            .appendingPathComponent("Sources/Blackbird/Resources/shell")
            .appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MissingFile(path: url.path)
        }
        return url
    }

    // MARK: - fish location

    /// Resolved once per process. `nil` → fish is not installed (the common
    /// case on macOS and on CI); fish tests skip.
    private static let fishPath: String? = locateFish()

    private static func locateFish() -> String? {
        // 1. `which fish` honoring the ambient PATH.
        if let p = whichFish(), FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
        // 2. Known Homebrew install locations.
        for p in ["/opt/homebrew/bin/fish", "/usr/local/bin/fish"] {
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    private static func whichFish() -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        proc.arguments = ["fish"]
        proc.environment = ProcessInfo.processInfo.environment  // real PATH
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let s = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    private func requireFish() throws -> String {
        guard let f = Self.fishPath else {
            throw XCTSkip("fish not installed (CI has no fish) — skipping fish port tests")
        }
        return f
    }

    // MARK: - Stub scripts

    /// Stub `ssh`. Records how the wrapper invoked it into `$STUB_LOG` and
    /// mimics the three real behaviors the wrapper depends on:
    ///  - `-G <argv>`  → canonicalization; prints fixed `user/hostname/port`
    ///                   (or exits 1 under `STUB_SSH_G_FAIL=1`).
    ///  - any arg containing `tic` → the remote terminfo-install pre-flight;
    ///                   drains stdin (the piped `infocmp`) and honors
    ///                   `STUB_SSH_TIC_EXIT`.
    ///  - otherwise    → the real connection; logs the inherited `$TERM` and
    ///                   argv, honors `STUB_SSH_EXIT`.
    private let stubSSH = """
    #!/bin/sh
    _log() { printf '%s\\n' "$1" >> "$STUB_LOG"; }

    if [ "$1" = "-G" ]; then
        if [ "${STUB_SSH_G_FAIL:-0}" = "1" ]; then
            exit 1
        fi
        _log "G ARGS=$*"
        echo 'user testuser'
        echo 'hostname testhost'
        echo 'port 22'
        exit 0
    fi

    for _a in "$@"; do
        case "$_a" in
            *tic*)
                _log "TIC TERM=${TERM} ARGS=$*"
                cat >/dev/null 2>&1
                exit "${STUB_SSH_TIC_EXIT:-0}"
                ;;
        esac
    done

    _log "CONNECT TERM=${TERM} ARGS=$*"
    exit "${STUB_SSH_EXIT:-0}"
    """

    /// Stub `infocmp`. Logs a marker and emits a dummy terminfo blob to stdout
    /// (which the wrapper pipes into the pre-flight `ssh 'tic ...'`).
    private let stubInfocmp = """
    #!/bin/sh
    printf '%s\\n' "INFOCMP" >> "$STUB_LOG"
    echo 'dummy|xterm-kitty|blackbird stub'
    exit 0
    """

    // MARK: - Harness

    private struct Harness {
        let root: URL
        let binDir: URL
        let home: URL
        let xdgState: URL
        let xdgConfig: URL
        let xdgData: URL
        let stubLog: URL
        var cacheFile: URL {
            xdgState.appendingPathComponent("blackbird")
                .appendingPathComponent("ssh-terminfo-hosts")
        }
    }

    private func makeHarness() throws -> Harness {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("bb-sshwrap-\(UUID().uuidString)")
        let binDir = root.appendingPathComponent("bin")
        let home = root.appendingPathComponent("home")
        let xdgState = root.appendingPathComponent("state")
        let xdgConfig = root.appendingPathComponent("config")
        let xdgData = root.appendingPathComponent("data")
        for d in [root, binDir, home, xdgState, xdgConfig, xdgData] {
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
        }
        let stubLog = root.appendingPathComponent("stub.log")
        fm.createFile(atPath: stubLog.path, contents: Data())

        try writeExecutable(stubSSH, to: binDir.appendingPathComponent("ssh"))
        try writeExecutable(stubInfocmp, to: binDir.appendingPathComponent("infocmp"))

        addTeardownBlock { try? fm.removeItem(at: root) }
        return Harness(
            root: root, binDir: binDir, home: home, xdgState: xdgState,
            xdgConfig: xdgConfig, xdgData: xdgData, stubLog: stubLog
        )
    }

    private func writeExecutable(_ contents: String, to url: URL) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path
        )
    }

    /// Pre-seed the cache file with the canonical key (for cache-hit paths).
    private func prepopulateCache(_ h: Harness) throws {
        let dir = h.cacheFile.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        try "\(Self.expectedKey)\n".write(
            to: h.cacheFile, atomically: true, encoding: .utf8
        )
    }

    /// Hermetic environment: the stub bin dir shadows the real `ssh`/`infocmp`,
    /// HOME/XDG point at the temp tree so no user config or cache is touched.
    private func env(_ h: Harness, term: String, extra: [String: String]) -> [String: String] {
        var e: [String: String] = [
            "PATH": "\(h.binDir.path):/usr/bin:/bin",
            "HOME": h.home.path,
            "TERM": term,
            "XDG_STATE_HOME": h.xdgState.path,
            "XDG_CONFIG_HOME": h.xdgConfig.path,
            "XDG_DATA_HOME": h.xdgData.path,
            "STUB_LOG": h.stubLog.path,
            // v0.6.1: the terminfo-install machinery moved behind this
            // opt-in (the DEFAULT is a plain TERM=xterm-256color
            // downgrade — VS Code parity; the default-path tests override
            // this with ""). Machinery tests exercise the opted-in
            // behavior, unchanged from v0.6.0.
            "BB_SSH_REMOTE_TERM": "kitty",
        ]
        for (k, v) in extra { e[k] = v }
        return e
    }

    // MARK: - Runner

    private struct Run {
        let stdout: String
        let stderr: String
        let exit: Int?
        let log: [String]
    }

    private func runShell(
        _ executable: URL, _ arguments: [String],
        _ environment: [String: String], _ h: Harness
    ) throws -> Run {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice
        try process.run()

        // Poll rather than block so a hung wrapper (infinite loop) is killed
        // and fails loudly instead of wedging the suite. Outputs are tiny, so
        // there is no pipe-buffer deadlock risk.
        let deadline = Date().addingTimeInterval(5.0)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.1)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            XCTFail("shell hung: \(executable.lastPathComponent) \(arguments)")
        }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(decoding: outData, as: UTF8.self)
        let stderr = String(decoding: errData, as: UTF8.self)
        return Run(
            stdout: stdout, stderr: stderr,
            exit: parseExit(stdout), log: readLog(h)
        )
    }

    @discardableResult
    private func runBash(
        _ h: Harness, term: String, extra: [String: String] = [:], driver: String
    ) throws -> Run {
        let driverURL = h.root.appendingPathComponent("driver.sh")
        try driver.write(to: driverURL, atomically: true, encoding: .utf8)
        return try runShell(
            URL(fileURLWithPath: "/bin/bash"),
            ["--noprofile", "--norc", driverURL.path],
            env(h, term: term, extra: extra), h
        )
    }

    @discardableResult
    private func runFish(
        _ h: Harness, fish: String, term: String,
        extra: [String: String] = [:], body: String
    ) throws -> Run {
        return try runShell(
            URL(fileURLWithPath: fish), ["-c", body],
            env(h, term: term, extra: extra), h
        )
    }

    // MARK: - Driver bodies

    private func bashDriver(
        _ sshFile: URL, invoke argline: String,
        prelude: String = "", doubleSource: Bool = false
    ) -> String {
        var lines: [String] = []
        if !prelude.isEmpty { lines.append(prelude) }
        lines.append("source '\(sshFile.path)'")
        if doubleSource { lines.append("source '\(sshFile.path)'") }
        lines.append("ssh \(argline)")
        lines.append("echo \"EXIT=$?\"")
        return lines.joined(separator: "\n") + "\n"
    }

    private func fishBody(
        _ sshFile: URL, invoke argline: String, doubleSource: Bool = false
    ) -> String {
        var lines: [String] = []
        lines.append("source '\(sshFile.path)'")
        if doubleSource { lines.append("source '\(sshFile.path)'") }
        lines.append("ssh \(argline)")
        lines.append("echo EXIT=$status")
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Parsing helpers

    private func parseExit(_ stdout: String) -> Int? {
        for line in stdout.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            if line.hasPrefix("EXIT=") {
                return Int(line.dropFirst("EXIT=".count)
                    .trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }

    private func readLog(_ h: Harness) -> [String] {
        guard let s = try? String(contentsOf: h.stubLog, encoding: .utf8) else { return [] }
        return s.split(separator: "\n").map(String.init)
    }

    private func readCache(_ h: Harness) -> [String] {
        guard let s = try? String(contentsOf: h.cacheFile, encoding: .utf8) else { return [] }
        return s.split(separator: "\n").map(String.init)
    }

    private func connectLines(_ log: [String]) -> [String] { log.filter { $0.hasPrefix("CONNECT ") } }
    private func ticLines(_ log: [String]) -> [String] { log.filter { $0.hasPrefix("TIC ") } }
    private func gLines(_ log: [String]) -> [String] { log.filter { $0.hasPrefix("G ARGS") } }
    private func infocmpLines(_ log: [String]) -> [String] { log.filter { $0 == "INFOCMP" } }

    private func termField(_ line: String) -> String? {
        guard let r = line.range(of: "TERM=") else { return nil }
        let rest = line[r.upperBound...]
        if let a = rest.range(of: " ARGS=") { return String(rest[..<a.lowerBound]) }
        return String(rest)
    }

    private func argsField(_ line: String) -> String? {
        guard let r = line.range(of: "ARGS=") else { return nil }
        return String(line[r.upperBound...])
    }

    // MARK: - bash: non-kitty passthrough

    /// TERM != kitty must short-circuit: no canonicalization, no pre-flight,
    /// exactly one real ssh call with argv byte-for-byte untouched.
    func test_bash_nonKittyTERM_passesThroughUntouched() throws {
        let ssh = try shellFile("ssh.bash")
        let h = try makeHarness()
        let run = try runBash(h, term: Self.downgradeTERM,
                              driver: bashDriver(ssh, invoke: "host"))

        XCTAssertEqual(run.exit, 0, "wrapper should return the connection's exit (0). stdout=\(run.stdout)")
        XCTAssertTrue(gLines(run.log).isEmpty,
            "non-kitty must not canonicalize via `ssh -G`. log=\(run.log)")
        XCTAssertTrue(ticLines(run.log).isEmpty && infocmpLines(run.log).isEmpty,
            "non-kitty must not run the terminfo pre-flight. log=\(run.log)")
        let connects = connectLines(run.log)
        XCTAssertEqual(connects.count, 1, "expected exactly one real ssh call. log=\(run.log)")
        let c = try XCTUnwrap(connects.first)
        XCTAssertEqual(termField(c), Self.downgradeTERM, "TERM must pass through untouched. line=\(c)")
        XCTAssertEqual(argsField(c), "host", "argv must be untouched. line=\(c)")
    }

    // MARK: - bash: cache hit

    /// Cache hit: canonicalize, find the key already cached, connect with kitty
    /// TERM and NO pre-flight.
    func test_bash_cacheHit_connectsWithKittyNoPreflight() throws {
        let ssh = try shellFile("ssh.bash")
        let h = try makeHarness()
        try prepopulateCache(h)
        let run = try runBash(h, term: Self.kittyTERM,
                              driver: bashDriver(ssh, invoke: "host"))

        XCTAssertEqual(run.exit, 0, "stdout=\(run.stdout)")
        XCTAssertFalse(gLines(run.log).isEmpty,
            "cache lookup still requires canonicalizing the destination first. log=\(run.log)")
        XCTAssertTrue(ticLines(run.log).isEmpty && infocmpLines(run.log).isEmpty,
            "a cache hit must not run the pre-flight. log=\(run.log)")
        let connects = connectLines(run.log)
        XCTAssertEqual(connects.count, 1, "log=\(run.log)")
        let c = try XCTUnwrap(connects.first)
        XCTAssertEqual(termField(c), Self.kittyTERM, "cache hit keeps kitty TERM. line=\(c)")
        XCTAssertEqual(argsField(c), "host", "argv untouched. line=\(c)")
    }

    // MARK: - bash: install (cache miss, pre-flight success)

    /// Cache miss on a plain destination: local `infocmp` piped into a remote
    /// `tic` pre-flight; on success the key is appended (mode 0600) and the
    /// connection keeps kitty TERM.
    func test_bash_cacheMiss_installsTerminfoAndCachesHost() throws {
        let ssh = try shellFile("ssh.bash")
        let h = try makeHarness()  // cache dir intentionally absent
        let run = try runBash(h, term: Self.kittyTERM,
                              driver: bashDriver(ssh, invoke: "host"))

        XCTAssertEqual(run.exit, 0, "stdout=\(run.stdout)")
        XCTAssertFalse(infocmpLines(run.log).isEmpty,
            "pre-flight must run local `infocmp`. log=\(run.log)")
        XCTAssertFalse(ticLines(run.log).isEmpty,
            "pre-flight must invoke a remote `tic` over ssh. log=\(run.log)")
        let connects = connectLines(run.log)
        XCTAssertEqual(connects.count, 1, "log=\(run.log)")
        XCTAssertEqual(termField(try XCTUnwrap(connects.first)), Self.kittyTERM,
            "successful install connects with kitty TERM. log=\(run.log)")

        XCTAssertTrue(readCache(h).contains(Self.expectedKey),
            "the canonical key must be cached after a successful install. cache=\(readCache(h))")
        let perms = try FileManager.default
            .attributesOfItem(atPath: h.cacheFile.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual((perms?.intValue ?? -1) & 0o777, 0o600,
            "cache file must be mode 0600, got \(String(perms?.intValue ?? -1, radix: 8))")
    }

    // MARK: - bash: pre-flight failure fallback

    /// Pre-flight `tic` failure: no cache line is written and the connection
    /// downgrades to xterm-256color.
    func test_bash_preflightTicFailure_downgradesTERM_noCacheLine() throws {
        let ssh = try shellFile("ssh.bash")
        let h = try makeHarness()
        let run = try runBash(h, term: Self.kittyTERM,
                              extra: ["STUB_SSH_TIC_EXIT": "1"],
                              driver: bashDriver(ssh, invoke: "host"))

        XCTAssertFalse(infocmpLines(run.log).isEmpty && ticLines(run.log).isEmpty,
            "the pre-flight must actually be attempted before falling back. log=\(run.log)")
        let connects = connectLines(run.log)
        XCTAssertEqual(connects.count, 1, "log=\(run.log)")
        XCTAssertEqual(termField(try XCTUnwrap(connects.first)), Self.downgradeTERM,
            "a failed pre-flight must downgrade TERM. log=\(run.log)")
        XCTAssertFalse(readCache(h).contains(Self.expectedKey),
            "a failed install must NOT cache the host. cache=\(readCache(h))")
    }

    // MARK: - bash: remote-command downgrade

    /// A remote command (`ssh host ls`) skips the pre-flight entirely and
    /// downgrades TERM, but still forwards the argv.
    func test_bash_remoteCommand_downgradesTERM_noPreflight() throws {
        let ssh = try shellFile("ssh.bash")
        let h = try makeHarness()
        let run = try runBash(h, term: Self.kittyTERM,
                              driver: bashDriver(ssh, invoke: "host ls"))

        XCTAssertTrue(ticLines(run.log).isEmpty && infocmpLines(run.log).isEmpty,
            "a remote command must not trigger the terminfo pre-flight. log=\(run.log)")
        let connects = connectLines(run.log)
        XCTAssertEqual(connects.count, 1, "log=\(run.log)")
        let c = try XCTUnwrap(connects.first)
        XCTAssertEqual(termField(c), Self.downgradeTERM,
            "remote-command sessions downgrade TERM. line=\(c)")
        XCTAssertEqual(argsField(c), "host ls", "argv must be forwarded intact. line=\(c)")
    }

    // MARK: - bash: default path (v0.6.1) — plain downgrade, zero machinery

    /// v0.6.1 default (no BB_SSH_REMOTE_TERM opt-in): one real connection,
    /// TERM=xterm-256color, argv byte-identical, no -G/infocmp/tic/cache.
    /// Measured rationale: remote xterm-kitty breaks string-sniffing
    /// color-depth detection (codex composer, npm supports-color) since
    /// COLORTERM doesn't survive ssh; xterm-256color is VS Code parity.
    func test_bash_default_downgradesEveryShape_zeroMachinery() throws {
        let ssh = try shellFile("ssh.bash")
        for invoke in ["host", "-p 2222 host", "host ls -la"] {
            let h = try makeHarness()
            let run = try runBash(h, term: Self.kittyTERM,
                                  extra: ["BB_SSH_REMOTE_TERM": ""],
                                  driver: bashDriver(ssh, invoke: invoke))
            XCTAssertTrue(ticLines(run.log).isEmpty && infocmpLines(run.log).isEmpty,
                "`ssh \(invoke)` default path must never pre-flight. log=\(run.log)")
            XCTAssertTrue(run.log.filter { $0.hasPrefix("G ") }.isEmpty,
                "default path must not run ssh -G. log=\(run.log)")
            let connects = connectLines(run.log)
            XCTAssertEqual(connects.count, 1, "log=\(run.log)")
            let c = try XCTUnwrap(connects.first)
            XCTAssertEqual(termField(c), Self.downgradeTERM,
                "default path always downgrades TERM. line=\(c)")
            XCTAssertEqual(argsField(c), invoke,
                "argv must be forwarded byte-identically. line=\(c)")
            XCTAssertEqual(readCache(h), [],
                "default path must not touch the cache")
        }
    }

    // MARK: - bash: attached option args (panel finding #1 regression)

    /// ATTACHED-form option values ending in an arg-taking letter
    /// (`-oX=no`, `-i/path/keyfoo`) fooled the old last-char parser into
    /// swallowing the destination, so a trailing remote command was
    /// misclassified as interactive and the pre-flight appended
    /// `tic -x -` to the user's remote command. Attached + remote command
    /// must downgrade; attached without one must still pre-flight.
    /// Expected classifications from ssh(1) semantics per the reviewing
    /// agent, independent of the fix.
    func test_bash_attachedOptionArgs_classifyCorrectly() throws {
        let ssh = try shellFile("ssh.bash")
        for invoke in ["-oStrictHostKeyChecking=no host run-backup",
                       "-i/tmp/keyfoo host deploy"] {
            let h = try makeHarness()
            let run = try runBash(h, term: Self.kittyTERM,
                                  driver: bashDriver(ssh, invoke: invoke))
            XCTAssertTrue(ticLines(run.log).isEmpty,
                "`ssh \(invoke)` carries a remote command; must not pre-flight. log=\(run.log)")
            let c = try XCTUnwrap(connectLines(run.log).first)
            XCTAssertEqual(termField(c), Self.downgradeTERM,
                "`ssh \(invoke)` must downgrade TERM. line=\(c)")
        }
        for invoke in ["-oStrictHostKeyChecking=no host", "-p2222 host"] {
            let h = try makeHarness()
            let run = try runBash(h, term: Self.kittyTERM,
                                  driver: bashDriver(ssh, invoke: invoke))
            XCTAssertFalse(ticLines(run.log).isEmpty,
                "`ssh \(invoke)` is interactive and must pre-flight. log=\(run.log)")
            let c = try XCTUnwrap(connectLines(run.log).first)
            XCTAssertEqual(termField(c), Self.kittyTERM,
                "`ssh \(invoke)` keeps the kitty TERM. line=\(c)")
        }
    }

    /// Panel finding #4 regression: `-N` (no remote command, no terminal)
    /// must take the quiet downgrade, not the install pre-flight.
    func test_bash_nonInteractiveMode_dashN_downgrades() throws {
        let ssh = try shellFile("ssh.bash")
        let h = try makeHarness()
        let run = try runBash(h, term: Self.kittyTERM,
                              driver: bashDriver(ssh, invoke: "-N host"))
        XCTAssertTrue(ticLines(run.log).isEmpty,
            "`ssh -N host` has no interactive terminal; must not pre-flight. log=\(run.log)")
        let c = try XCTUnwrap(connectLines(run.log).first)
        XCTAssertEqual(termField(c), Self.downgradeTERM,
            "`ssh -N host` must downgrade TERM. line=\(c)")
    }

    // MARK: - bash: option args are still a plain destination

    /// `-p 2222 host` (and `-o X=y host`) carry no remote command, so the
    /// wrapper must treat them as plain destinations and run the install
    /// pre-flight — not misread the option value as a command.
    func test_bash_plainDestinationWithPortOption_installs() throws {
        let ssh = try shellFile("ssh.bash")
        let h = try makeHarness()
        let run = try runBash(h, term: Self.kittyTERM,
                              driver: bashDriver(ssh, invoke: "-p 2222 host"))

        XCTAssertFalse(ticLines(run.log).isEmpty,
            "`-p 2222 host` is a plain destination and must run the pre-flight. log=\(run.log)")
        let connects = connectLines(run.log)
        XCTAssertEqual(connects.count, 1, "log=\(run.log)")
        let c = try XCTUnwrap(connects.first)
        XCTAssertEqual(termField(c), Self.kittyTERM,
            "a plain destination with options still installs + keeps kitty TERM. line=\(c)")
        XCTAssertEqual(argsField(c), "-p 2222 host", "argv untouched. line=\(c)")
        XCTAssertTrue(readCache(h).contains(Self.expectedKey), "cache=\(readCache(h))")
    }

    // MARK: - bash: ssh -G failure

    /// If canonicalization (`ssh -G`) fails, the wrapper cannot form a cache
    /// key, so it must skip the pre-flight and downgrade.
    func test_bash_sshGCanonicalizationFailure_downgradesNoPreflight() throws {
        let ssh = try shellFile("ssh.bash")
        let h = try makeHarness()
        let run = try runBash(h, term: Self.kittyTERM,
                              extra: ["STUB_SSH_G_FAIL": "1"],
                              driver: bashDriver(ssh, invoke: "host"))

        XCTAssertTrue(ticLines(run.log).isEmpty && infocmpLines(run.log).isEmpty,
            "a failed `ssh -G` must not proceed to the pre-flight. log=\(run.log)")
        let connects = connectLines(run.log)
        XCTAssertEqual(connects.count, 1, "log=\(run.log)")
        XCTAssertEqual(termField(try XCTUnwrap(connects.first)), Self.downgradeTERM,
            "an unresolvable destination downgrades TERM. log=\(run.log)")
    }

    // MARK: - bash: exit-code propagation

    /// The wrapper must surface the real connection's exit status verbatim.
    func test_bash_preservesConnectionExitCode() throws {
        let ssh = try shellFile("ssh.bash")
        let h = try makeHarness()
        let run = try runBash(h, term: Self.downgradeTERM,
                              extra: ["STUB_SSH_EXIT": "7"],
                              driver: bashDriver(ssh, invoke: "host"))

        XCTAssertEqual(connectLines(run.log).count, 1,
            "the real connection must have run. log=\(run.log)")
        XCTAssertEqual(run.exit, 7,
            "wrapper must propagate the connection's exit code (7). stdout=\(run.stdout)")
    }

    // MARK: - bash: double-source idempotence

    /// Sourcing twice must leave a single working wrapper: still exactly one
    /// real connection, still active (canonicalizes on the kitty path).
    func test_bash_doubleSource_isIdempotent() throws {
        let ssh = try shellFile("ssh.bash")
        let h = try makeHarness()
        try prepopulateCache(h)
        let run = try runBash(h, term: Self.kittyTERM,
                              driver: bashDriver(ssh, invoke: "host", doubleSource: true))

        XCTAssertEqual(run.exit, 0, "stdout=\(run.stdout)")
        XCTAssertFalse(gLines(run.log).isEmpty,
            "the wrapper must still be active after a re-source (it canonicalizes). log=\(run.log)")
        XCTAssertEqual(connectLines(run.log).count, 1,
            "double-sourcing must not double the connection. log=\(run.log)")
        XCTAssertTrue(ticLines(run.log).isEmpty, "cache hit — no pre-flight. log=\(run.log)")
        XCTAssertEqual(termField(try XCTUnwrap(connectLines(run.log).first)), Self.kittyTERM,
            "log=\(run.log)")
    }

    // MARK: - bash: pre-existing user function not shadowed

    /// A user who already defined their own `ssh` function must keep it —
    /// sourcing the wrapper must not clobber it. The user's function runs
    /// (its marker + exit code surface) and the wrapper's stub `ssh` is never
    /// touched.
    func test_bash_preexistingSshFunction_notShadowed() throws {
        let ssh = try shellFile("ssh.bash")
        let h = try makeHarness()
        let prelude = "ssh() { printf 'USERFUNC\\n'; return 3; }"
        let run = try runBash(h, term: Self.kittyTERM,
                              driver: bashDriver(ssh, invoke: "somehost", prelude: prelude))

        XCTAssertTrue(run.stdout.contains("USERFUNC"),
            "the pre-existing user `ssh` function must still run. stdout=\(run.stdout)")
        XCTAssertEqual(run.exit, 3,
            "the user function's exit code must surface (not the wrapper's). stdout=\(run.stdout)")
        XCTAssertTrue(connectLines(run.log).isEmpty && gLines(run.log).isEmpty,
            "the wrapper must not have taken over — no stub ssh calls. log=\(run.log)")
    }

    // MARK: - fish: non-kitty passthrough

    func test_fish_nonKittyTERM_passesThroughUntouched() throws {
        let fish = try requireFish()
        let ssh = try shellFile("ssh.fish")
        let h = try makeHarness()
        let run = try runFish(h, fish: fish, term: Self.downgradeTERM,
                              body: fishBody(ssh, invoke: "host"))

        XCTAssertEqual(run.exit, 0, "stdout=\(run.stdout) stderr=\(run.stderr)")
        XCTAssertTrue(gLines(run.log).isEmpty,
            "non-kitty must not canonicalize. log=\(run.log)")
        XCTAssertTrue(ticLines(run.log).isEmpty && infocmpLines(run.log).isEmpty,
            "non-kitty must not run the pre-flight. log=\(run.log)")
        let connects = connectLines(run.log)
        XCTAssertEqual(connects.count, 1, "log=\(run.log)")
        let c = try XCTUnwrap(connects.first)
        XCTAssertEqual(termField(c), Self.downgradeTERM, "line=\(c)")
        XCTAssertEqual(argsField(c), "host", "argv untouched. line=\(c)")
    }

    // MARK: - fish: cache hit

    func test_fish_cacheHit_connectsWithKittyNoPreflight() throws {
        let fish = try requireFish()
        let ssh = try shellFile("ssh.fish")
        let h = try makeHarness()
        try prepopulateCache(h)
        let run = try runFish(h, fish: fish, term: Self.kittyTERM,
                              body: fishBody(ssh, invoke: "host"))

        XCTAssertEqual(run.exit, 0, "stdout=\(run.stdout) stderr=\(run.stderr)")
        XCTAssertFalse(gLines(run.log).isEmpty, "log=\(run.log)")
        XCTAssertTrue(ticLines(run.log).isEmpty && infocmpLines(run.log).isEmpty,
            "cache hit must not run the pre-flight. log=\(run.log)")
        let connects = connectLines(run.log)
        XCTAssertEqual(connects.count, 1, "log=\(run.log)")
        XCTAssertEqual(termField(try XCTUnwrap(connects.first)), Self.kittyTERM, "log=\(run.log)")
    }

    // MARK: - fish: install

    func test_fish_cacheMiss_installsTerminfoAndCachesHost() throws {
        let fish = try requireFish()
        let ssh = try shellFile("ssh.fish")
        let h = try makeHarness()
        let run = try runFish(h, fish: fish, term: Self.kittyTERM,
                              body: fishBody(ssh, invoke: "host"))

        XCTAssertEqual(run.exit, 0, "stdout=\(run.stdout) stderr=\(run.stderr)")
        XCTAssertFalse(infocmpLines(run.log).isEmpty, "log=\(run.log)")
        XCTAssertFalse(ticLines(run.log).isEmpty, "log=\(run.log)")
        let connects = connectLines(run.log)
        XCTAssertEqual(connects.count, 1, "log=\(run.log)")
        XCTAssertEqual(termField(try XCTUnwrap(connects.first)), Self.kittyTERM, "log=\(run.log)")

        XCTAssertTrue(readCache(h).contains(Self.expectedKey), "cache=\(readCache(h))")
        let perms = try FileManager.default
            .attributesOfItem(atPath: h.cacheFile.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual((perms?.intValue ?? -1) & 0o777, 0o600,
            "cache file must be mode 0600, got \(String(perms?.intValue ?? -1, radix: 8))")
    }

    // MARK: - fish: pre-flight failure fallback

    func test_fish_preflightTicFailure_downgradesTERM_noCacheLine() throws {
        let fish = try requireFish()
        let ssh = try shellFile("ssh.fish")
        let h = try makeHarness()
        let run = try runFish(h, fish: fish, term: Self.kittyTERM,
                              extra: ["STUB_SSH_TIC_EXIT": "1"],
                              body: fishBody(ssh, invoke: "host"))

        XCTAssertFalse(infocmpLines(run.log).isEmpty && ticLines(run.log).isEmpty,
            "the pre-flight must be attempted before falling back. log=\(run.log)")
        let connects = connectLines(run.log)
        XCTAssertEqual(connects.count, 1, "log=\(run.log)")
        XCTAssertEqual(termField(try XCTUnwrap(connects.first)), Self.downgradeTERM, "log=\(run.log)")
        XCTAssertFalse(readCache(h).contains(Self.expectedKey), "cache=\(readCache(h))")
    }

    // MARK: - fish: remote-command downgrade

    func test_fish_remoteCommand_downgradesTERM_noPreflight() throws {
        let fish = try requireFish()
        let ssh = try shellFile("ssh.fish")
        let h = try makeHarness()
        let run = try runFish(h, fish: fish, term: Self.kittyTERM,
                              body: fishBody(ssh, invoke: "host ls"))

        XCTAssertTrue(ticLines(run.log).isEmpty && infocmpLines(run.log).isEmpty,
            "a remote command must not trigger the pre-flight. log=\(run.log)")
        let connects = connectLines(run.log)
        XCTAssertEqual(connects.count, 1, "log=\(run.log)")
        let c = try XCTUnwrap(connects.first)
        XCTAssertEqual(termField(c), Self.downgradeTERM, "line=\(c)")
        XCTAssertEqual(argsField(c), "host ls", "argv forwarded intact. line=\(c)")
    }

    // MARK: - fish: exit-code propagation

    func test_fish_preservesConnectionExitCode() throws {
        let fish = try requireFish()
        let ssh = try shellFile("ssh.fish")
        let h = try makeHarness()
        let run = try runFish(h, fish: fish, term: Self.downgradeTERM,
                              extra: ["STUB_SSH_EXIT": "7"],
                              body: fishBody(ssh, invoke: "host"))

        XCTAssertEqual(connectLines(run.log).count, 1, "log=\(run.log)")
        XCTAssertEqual(run.exit, 7,
            "wrapper must propagate the connection's exit code (7). stdout=\(run.stdout) stderr=\(run.stderr)")
    }

    // MARK: - fish: double-source idempotence

    func test_fish_doubleSource_isIdempotent() throws {
        let fish = try requireFish()
        let ssh = try shellFile("ssh.fish")
        let h = try makeHarness()
        try prepopulateCache(h)
        let run = try runFish(h, fish: fish, term: Self.kittyTERM,
                              body: fishBody(ssh, invoke: "host", doubleSource: true))

        XCTAssertEqual(run.exit, 0, "stdout=\(run.stdout) stderr=\(run.stderr)")
        XCTAssertFalse(gLines(run.log).isEmpty,
            "the wrapper must still be active after a re-source. log=\(run.log)")
        XCTAssertEqual(connectLines(run.log).count, 1,
            "double-sourcing must not double the connection. log=\(run.log)")
        XCTAssertTrue(ticLines(run.log).isEmpty, "cache hit — no pre-flight. log=\(run.log)")
        XCTAssertEqual(termField(try XCTUnwrap(connectLines(run.log).first)), Self.kittyTERM,
            "log=\(run.log)")
    }
}
