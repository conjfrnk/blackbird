import XCTest

/// Tests the shipped zsh `ssh` wrapper in
/// `Sources/Blackbird/Resources/shell/ssh.zsh`.
///
/// Blackbird advertises `xterm-kitty` as its `$TERM`. When a user `ssh`s
/// into a remote host that doesn't have the `xterm-kitty` terminfo entry,
/// full-screen programs there misbehave (garbled keys, wrong colours). The
/// shipped `ssh.zsh` wraps `ssh` so that — only inside Blackbird
/// (`TERM == xterm-kitty`) — it transparently installs the terminfo entry
/// on first connection and remembers which hosts already have it, so the
/// remote side understands `xterm-kitty`. Outside Blackbird it must be a
/// perfectly transparent passthrough.
///
/// This wrapper is pure shell that never runs in CI's normal Swift paths,
/// so a regression (wrong option parsing, a broken cache, an accidental
/// double-wrap, shadowing a user's own `ssh`) would ship silently and only
/// surface as "ssh feels weird inside Blackbird" bug reports. These tests
/// pin the behavioural contract by sourcing the real script into a real
/// `/bin/zsh` with `ssh`/`infocmp` replaced by logging stubs, then
/// asserting on what the wrapper *did* (the ordered stub call log, the
/// cache file, the exit status) rather than on any diagnostic text.
///
/// Pre-flight cost: each test spawns one `/bin/zsh -f` driver that in turn
/// forks at most three tiny `/bin/sh` stub processes (a few KB RSS each),
/// all finishing in well under a second. No PTY, no TerminalSession, no
/// network, no GUI — comfortably inside the per-test budget. Every scenario
/// is hermetic: a per-test temp tree holds the stub `bin`, the
/// `XDG_STATE_HOME`, and `HOME`, so nothing touches the developer's real
/// ssh config, terminfo, or state.
final class SSHWrapperZshTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        // Same as every suite in this bundle: register the host-termination
        // observer once so a filtered run doesn't leave a zombie SwiftUI host.
        TestHostTermination.shared.register()
    }

    // MARK: - Per-test hermetic environment

    /// Root of the per-test temp tree; removed in teardown.
    private var tmpRoot: URL!
    /// Directory placed FIRST on `PATH` holding the `ssh`/`infocmp` stubs.
    private var binDir: URL!
    /// `XDG_STATE_HOME` for the run (cache lives under `blackbird/` here).
    private var stateDir: URL!
    /// `HOME` for the run (fallback cache lives under `.local/state/` here).
    private var homeDir: URL!
    /// The ordered call log every stub appends to.
    private var logURL: URL!
    /// The real script under test, resolved from the repo tree.
    private var sshScriptURL: URL!
    /// Resolved `/bin/zsh`.
    private var zshURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()

        // Resolve the script under test from the repo tree (NOT an app
        // bundle). Skip — rather than fail — if it's absent, matching the
        // sibling ShellIntegrationScriptTests: keeps the suite green on a
        // checkout where the file legitimately doesn't exist yet, while a
        // real run against a shipped script exercises everything below.
        let root = try repoRoot()
        let script = root
            .appendingPathComponent("Sources/Blackbird/Resources/shell")
            .appendingPathComponent("ssh.zsh")
        guard FileManager.default.fileExists(atPath: script.path) else {
            throw XCTSkip("ssh.zsh not found at \(script.path) — nothing to test yet")
        }
        sshScriptURL = script

        guard let zsh = locateShell("zsh") else {
            throw XCTSkip("/bin/zsh not present — cannot exercise the zsh wrapper")
        }
        zshURL = zsh

        let fm = FileManager.default
        tmpRoot = fm.temporaryDirectory
            .appendingPathComponent("bb-ssh-wrapper-\(UUID().uuidString)")
        binDir = tmpRoot.appendingPathComponent("bin")
        stateDir = tmpRoot.appendingPathComponent("state")
        homeDir = tmpRoot.appendingPathComponent("home")
        logURL = tmpRoot.appendingPathComponent("stub-calls.log")
        for dir in [binDir!, stateDir!, homeDir!] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        fm.createFile(atPath: logURL.path, contents: Data())

        try writeStubs()
    }

    override func tearDownWithError() throws {
        if let tmpRoot { try? FileManager.default.removeItem(at: tmpRoot) }
        try super.tearDownWithError()
    }

    // MARK: - Repo / shell location

    /// Walk up from the compiled test file until we find the directory that
    /// holds `project.yml` (the canonical repo root marker per CLAUDE.md).
    private func repoRoot(file: String = #filePath) throws -> URL {
        var dir = URL(fileURLWithPath: file).deletingLastPathComponent()
        for _ in 0..<12 {
            if FileManager.default.fileExists(
                atPath: dir.appendingPathComponent("project.yml").path) {
                return dir
            }
            dir = dir.deletingLastPathComponent()
        }
        throw XCTSkip("repo root (dir with project.yml) not found above \(file)")
    }

    private func locateShell(_ name: String) -> URL? {
        for path in ["/bin/\(name)", "/usr/bin/\(name)",
                     "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"] {
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    // MARK: - Stubs
    //
    // Both stubs are `/bin/sh` scripts placed first on `PATH` so they shadow
    // the real tools, while `awk`/`grep`/`mkdir`/`chmod`/`cat` (used by the
    // wrapper and by the stubs themselves) still resolve from /usr/bin:/bin.
    //
    // The `ssh` stub has three modes, in the same precedence the wrapper
    // drives them:
    //   * `-G …`  → canonical-destination resolution. Logs `G ARGS=…` FIRST
    //     (so even the failure path is recorded), then either fails (when
    //     STUB_SSH_G_FAIL=1) or prints the canned user/hostname/port block
    //     the wrapper parses into the cache key `testuser@testhost:22`.
    //   * any arg containing `tic` → the remote terminfo install pre-flight.
    //     Logs `TIC TERM=… ARGS=…`, drains stdin (the piped `infocmp`
    //     output) so the writer never takes SIGPIPE, then exits
    //     STUB_SSH_TIC_EXIT.
    //   * otherwise → the real connection. Logs `CONNECT TERM=… ARGS=…`
    //     and exits STUB_SSH_EXIT, so tests can pin the TERM the wrapper
    //     chose and propagate an arbitrary connection exit status.
    private func writeStubs() throws {
        // NOTE: `\\n` in this Swift string becomes a literal `\n` in the
        // shell file so `printf` renders a newline; a bare Swift `\n` would
        // put the newline in the source instead of the format string.
        let sshStub = """
        #!/bin/sh
        log="$STUB_LOG"
        if [ "$1" = "-G" ]; then
            printf 'G ARGS=%s\\n' "$*" >> "$log"
            if [ "${STUB_SSH_G_FAIL:-0}" = "1" ]; then
                exit 1
            fi
            printf 'user testuser\\nhostname testhost\\nport 22\\n'
            exit 0
        fi
        for a in "$@"; do
            case "$a" in
                *tic*)
                    printf 'TIC TERM=%s ARGS=%s\\n' "$TERM" "$*" >> "$log"
                    cat >/dev/null 2>&1
                    exit "${STUB_SSH_TIC_EXIT:-0}"
                    ;;
            esac
        done
        printf 'CONNECT TERM=%s ARGS=%s\\n' "$TERM" "$*" >> "$log"
        exit "${STUB_SSH_EXIT:-0}"
        """
        let infocmpStub = """
        #!/bin/sh
        printf 'INFOCMP ARGS=%s\\n' "$*" >> "$STUB_LOG"
        if [ "${STUB_INFOCMP_SILENT:-0}" != "1" ]; then
          printf 'blackbird-dummy-terminfo-source\\n'
        fi
        exit "${STUB_INFOCMP_EXIT:-0}"
        """
        try write(sshStub, to: binDir.appendingPathComponent("ssh"))
        try write(infocmpStub, to: binDir.appendingPathComponent("infocmp"))
    }

    private func write(_ contents: String, to url: URL) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    // MARK: - Driver

    /// Default driver body: source the script, run the wrapper with the
    /// driver's positional args, and echo the wrapper's exit status. When
    /// the wrapper `exec`s the real ssh (the passthrough contract) the final
    /// `print` is replaced away and the code surfaces via the process exit
    /// status instead — `RunResult.effectiveExit` reconciles both.
    private static let defaultBody = """
    emulate -L zsh
    source "$BB_SSH_SCRIPT"
    ssh "$@"
    print -r -- "EXIT=$?"
    """

    /// The cache file the wrapper is expected to use for this configuration.
    private func cacheURL(setXDG: Bool) -> URL {
        let base = setXDG
            ? stateDir!
            : homeDir.appendingPathComponent(".local/state")
        return base
            .appendingPathComponent("blackbird")
            .appendingPathComponent("ssh-terminfo-hosts")
    }

    /// Run one scenario. `args` become the driver's positional parameters
    /// (byte-preserved into `ssh "$@"`); pass a custom `body` for scenarios
    /// that need setup before sourcing (pre-existing alias/function) or that
    /// source twice.
    @discardableResult
    private func run(term: String,
                     args: [String] = [],
                     body: String? = nil,
                     setXDG: Bool = true,
                     env extra: [String: String?] = [:],
                     cacheLines: [String]? = nil) throws -> RunResult {
        // Fresh log per run for deterministic ordering assertions.
        try Data().write(to: logURL)

        let cache = cacheURL(setXDG: setXDG)
        if let cacheLines {
            try FileManager.default.createDirectory(
                at: cache.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let body = cacheLines.isEmpty ? "" : cacheLines.joined(separator: "\n") + "\n"
            try body.write(to: cache, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: cache.path)
        }

        let driverURL = tmpRoot.appendingPathComponent("driver-\(UUID().uuidString).zsh")
        try (body ?? Self.defaultBody).write(to: driverURL, atomically: true, encoding: .utf8)

        var env: [String: String] = [
            "PATH": "\(binDir.path):/usr/bin:/bin",
            "TERM": term,
            "HOME": homeDir.path,
            "STUB_LOG": logURL.path,
            "BB_SSH_SCRIPT": sshScriptURL.path,
            // v0.6.1: the terminfo-install machinery moved behind this
            // opt-in (the DEFAULT is a plain TERM=xterm-256color
            // downgrade — VS Code parity; see the default-path tests,
            // which override this with ""). The machinery tests below
            // exercise the opted-in behavior, unchanged from v0.6.0.
            "BB_SSH_REMOTE_TERM": "kitty",
        ]
        if setXDG { env["XDG_STATE_HOME"] = stateDir.path }
        // nil value = REMOVE the key entirely (truly-unset coverage —
        // the state ~100% of real users are in for BB_* knobs; an
        // empty-string override is not the same thing in shell).
        for (k, v) in extra {
            if let v { env[k] = v } else { env.removeValue(forKey: k) }
        }

        let (stdout, stderr, status) = try launch(
            driver: driverURL, args: args, env: env)
        let log = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        return RunResult(stdout: stdout, stderr: stderr, status: status,
                         rawLog: log, cacheURL: cache)
    }

    /// Spawn `/bin/zsh -f <driver> <args…>`, capture stdout/stderr, and
    /// enforce a hard wall-clock ceiling so a hung wrapper fails loudly
    /// instead of wedging the suite.
    private func launch(driver: URL, args: [String],
                        env: [String: String]) throws -> (String, String, Int32) {
        let process = Process()
        process.executableURL = zshURL
        process.arguments = ["-f", driver.path] + args
        process.environment = env

        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        // Read the pipes on background threads so a stub that writes more
        // than a pipe buffer's worth can't deadlock against our wait.
        var outData = Data(), errData = Data()
        let outHandle = outPipe.fileHandleForReading
        let errHandle = errPipe.fileHandleForReading
        let group = DispatchGroup()
        let q = DispatchQueue(label: "bb-ssh-pipe", attributes: .concurrent)
        group.enter(); q.async { outData = outHandle.readDataToEndOfFile(); group.leave() }
        group.enter(); q.async { errData = errHandle.readDataToEndOfFile(); group.leave() }

        try process.run()
        let deadline = Date().addingTimeInterval(15.0)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.1)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            XCTFail("zsh wrapper driver hung — likely an infinite loop in ssh.zsh")
        }
        group.wait()
        return (String(decoding: outData, as: UTF8.self),
                String(decoding: errData, as: UTF8.self),
                process.terminationStatus)
    }

    // MARK: - Result

    private struct RunResult {
        let stdout: String
        let stderr: String
        let status: Int32
        let rawLog: String
        let cacheURL: URL

        /// Ordered, non-empty lines the stubs logged.
        var logLines: [String] {
            rawLog.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        }
        func count(prefix: String) -> Int { logLines.filter { $0.hasPrefix(prefix) }.count }
        func firstIndex(prefix: String) -> Int? {
            logLines.firstIndex { $0.hasPrefix(prefix) }
        }
        /// The `TERM=` value recorded on the first line with `prefix`.
        func term(prefix: String) -> String? {
            guard let line = logLines.first(where: { $0.hasPrefix(prefix) }) else { return nil }
            return field(line, "TERM=")
        }
        /// The `ARGS=` value recorded on the first line with `prefix`.
        func args(prefix: String) -> String? {
            guard let line = logLines.first(where: { $0.hasPrefix(prefix) }) else { return nil }
            return field(line, "ARGS=")
        }
        private func field(_ line: String, _ key: String) -> String? {
            guard let r = line.range(of: key) else { return nil }
            var rest = String(line[r.upperBound...])
            // TERM=<v> is followed by " ARGS="; ARGS=<v> runs to end of line.
            if key == "TERM=", let a = rest.range(of: " ARGS=") {
                rest = String(rest[..<a.lowerBound])
            }
            return rest
        }

        /// Exit status parsed from the driver's `EXIT=` line if it printed,
        /// else the process exit status (the wrapper `exec`ed the real ssh).
        var effectiveExit: Int32 {
            if let line = stdout.split(separator: "\n").first(where: { $0.hasPrefix("EXIT=") }),
               let n = Int32(String(line.dropFirst("EXIT=".count))
                   .trimmingCharacters(in: .whitespaces)) {
                return n
            }
            return status
        }

        /// Cache file contents as non-empty lines ([] when the file is
        /// absent — the "nothing was cached" case).
        var cacheLines: [String] {
            guard let s = try? String(contentsOf: cacheURL, encoding: .utf8) else { return [] }
            return s.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        }
        var cacheMode: Int? {
            guard let a = try? FileManager.default
                .attributesOfItem(atPath: cacheURL.path),
                  let p = a[.posixPermissions] as? NSNumber else { return nil }
            return p.intValue & 0o777
        }
    }

    private func hex(_ s: String) -> String {
        s.unicodeScalars.map { $0.value < 0x20 || $0.value > 0x7E
            ? String(format: "<%02X>", $0.value) : String($0) }.joined()
    }

    // MARK: - Non-kitty passthrough

    /// Outside Blackbird (`TERM != xterm-kitty`) the wrapper must be a pure
    /// passthrough: it execs the real ssh with argv byte-identical, exactly
    /// one ssh invocation, and calls no other tool. A regression that ran
    /// the kitty machinery (resolve/pre-flight) for every ssh everywhere
    /// would slow down and mangle normal ssh use.
    ///
    /// Cost: 1 driver + 1 stub, ~50 ms.
    func test_nonKitty_passthrough_execsRealSshByteIdenticalOnce() throws {
        // Distinctive non-kitty TERM ("vt100") so the assertion proves the
        // original TERM was passed THROUGH, not silently downgraded to
        // xterm-256color (which the kitty-failure paths also produce).
        let r = try run(term: "vt100", args: ["-4", "testhost", "uptime"])

        XCTAssertEqual(r.logLines.count, 1,
            "passthrough must invoke ssh exactly once and no other tool; got: \(r.logLines)")
        XCTAssertEqual(r.count(prefix: "CONNECT"), 1, "expected one real connection")
        XCTAssertEqual(r.count(prefix: "G "), 0, "passthrough must not resolve via ssh -G")
        XCTAssertEqual(r.count(prefix: "INFOCMP"), 0, "passthrough must not run infocmp")
        XCTAssertEqual(r.count(prefix: "TIC"), 0, "passthrough must not pre-flight tic")
        XCTAssertEqual(r.term(prefix: "CONNECT"), "vt100",
            "passthrough must preserve the caller's TERM verbatim")
        XCTAssertEqual(r.args(prefix: "CONNECT"), "-4 testhost uptime",
            "passthrough must forward argv byte-identical")
    }

    // MARK: - Cache hit

    /// Inside Blackbird with the host already recorded in the cache, the
    /// wrapper connects immediately with `xterm-kitty` and does NO terminfo
    /// work — no infocmp, no remote tic. (It still runs `ssh -G` to derive
    /// the canonical key it looks up.)
    ///
    /// Cost: 1 driver + 2 stubs, ~60 ms.
    func test_kitty_cacheHit_connectsKittyWithoutPreflight() throws {
        let r = try run(term: "xterm-kitty", args: ["testhost"],
                        cacheLines: ["testuser@testhost:22"])

        XCTAssertEqual(r.count(prefix: "INFOCMP"), 0, "cache hit must not run infocmp")
        XCTAssertEqual(r.count(prefix: "TIC"), 0, "cache hit must not pre-flight tic")
        XCTAssertEqual(r.count(prefix: "CONNECT"), 1, "cache hit must connect exactly once")
        XCTAssertGreaterThanOrEqual(r.count(prefix: "G "), 1,
            "cache hit still resolves the canonical key via ssh -G")
        XCTAssertEqual(r.term(prefix: "CONNECT"), "xterm-kitty",
            "cache hit keeps TERM=xterm-kitty (remote already has the entry)")
    }

    /// The wrapper's exit status must be the real connection's exit status.
    /// Exercised on the cache-hit path (a single, deterministic CONNECT) so
    /// nothing but the connection can influence the code. 42 is arbitrary
    /// and distinctive.
    ///
    /// Cost: 1 driver + 2 stubs, ~60 ms.
    func test_kitty_cacheHit_propagatesConnectionExitStatus() throws {
        let r = try run(term: "xterm-kitty", args: ["testhost"],
                        env: ["STUB_SSH_EXIT": "42"],
                        cacheLines: ["testuser@testhost:22"])
        XCTAssertEqual(r.effectiveExit, 42,
            "wrapper must return the ssh connection's exit status (42). "
            + "stdout=\(hex(r.stdout)) status=\(r.status) log=\(r.logLines)")
    }

    // MARK: - Cache miss → install → cache → connect

    /// The headline path. First contact with a plain interactive
    /// destination inside Blackbird: resolve the canonical key, pre-flight
    /// the remote terminfo install (local `infocmp` piped into a remote
    /// `tic`), and on success record the key and connect with
    /// `xterm-kitty`.
    ///
    /// Pins: (1) call ORDER — resolve (`G`) precedes the install
    /// (`INFOCMP`/`TIC`), which precedes the `CONNECT`; (2) the cache gains
    /// exactly the canonical key line; (3) the cache file is mode 0600 with
    /// its parent directory freshly created; (4) the connection uses
    /// `xterm-kitty`.
    ///
    /// Cost: 1 driver + 3 stubs, ~80 ms.
    func test_kitty_cacheMiss_interactive_installsCachesAndConnectsKitty() throws {
        let r = try run(term: "xterm-kitty", args: ["testhost"])

        // All three phases happened.
        let gIdx = try XCTUnwrap(r.firstIndex(prefix: "G "), "expected ssh -G resolution")
        let infoIdx = try XCTUnwrap(r.firstIndex(prefix: "INFOCMP"),
            "expected local infocmp during pre-flight")
        let ticIdx = try XCTUnwrap(r.firstIndex(prefix: "TIC"),
            "expected remote tic during pre-flight")
        let connIdx = try XCTUnwrap(r.firstIndex(prefix: "CONNECT"),
            "expected the real connection")

        // Order: resolve before install; install before connect. (infocmp
        // and tic race inside one pipeline, so their relative order is not
        // pinned — only that both fall between resolve and connect.)
        XCTAssertLessThan(gIdx, infoIdx, "resolve must precede infocmp. log=\(r.logLines)")
        XCTAssertLessThan(gIdx, ticIdx, "resolve must precede tic. log=\(r.logLines)")
        XCTAssertGreaterThan(connIdx, infoIdx, "connect must follow infocmp. log=\(r.logLines)")
        XCTAssertGreaterThan(connIdx, ticIdx, "connect must follow tic. log=\(r.logLines)")

        XCTAssertEqual(r.term(prefix: "CONNECT"), "xterm-kitty",
            "successful install must connect with TERM=xterm-kitty")

        // Cache now holds exactly the canonical key, mode 0600, parent made.
        XCTAssertEqual(r.cacheLines, ["testuser@testhost:22"],
            "cache must contain exactly the canonical key after a successful install")
        XCTAssertEqual(r.cacheMode, 0o600,
            "cache file must be created mode 0600 (got \(r.cacheMode.map { String($0, radix: 8) } ?? "nil"))")
    }

    /// The cache root's parent (`blackbird/`) must be created by the wrapper
    /// even when only the `XDG_STATE_HOME` root exists. Covered implicitly
    /// above (setUp never creates `blackbird/`), asserted explicitly here so
    /// a regression that assumed a pre-existing directory is caught.
    ///
    /// Cost: 1 driver + 3 stubs, ~80 ms.
    func test_kitty_cacheMiss_createsCacheParentDirectory() throws {
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: stateDir.appendingPathComponent("blackbird").path),
            "precondition: blackbird/ must not exist before the run")
        let r = try run(term: "xterm-kitty", args: ["testhost"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: r.cacheURL.path),
            "wrapper must create the cache (and its parent dir) on first install")
        XCTAssertEqual(r.cacheLines, ["testuser@testhost:22"])
    }

    /// When `XDG_STATE_HOME` is unset the cache must fall back to
    /// `~/.local/state/blackbird/ssh-terminfo-hosts`.
    ///
    /// Cost: 1 driver + 3 stubs, ~80 ms.
    func test_kitty_cacheMiss_xdgUnset_usesHomeLocalStateFallback() throws {
        let r = try run(term: "xterm-kitty", args: ["testhost"], setXDG: false)
        let expected = homeDir
            .appendingPathComponent(".local/state/blackbird/ssh-terminfo-hosts")
        XCTAssertTrue(FileManager.default.fileExists(atPath: expected.path),
            "with XDG_STATE_HOME unset, cache must live at ~/.local/state/blackbird/…")
        XCTAssertEqual(r.cacheLines, ["testuser@testhost:22"],
            "fallback cache must hold the canonical key")
        XCTAssertEqual(r.cacheMode, 0o600, "fallback cache must also be mode 0600")
    }

    // MARK: - Pre-flight failure

    /// If the remote `tic` fails (no `tic`, read-only home, whatever), the
    /// wrapper must NOT record the host and must connect with a downgraded
    /// `xterm-256color` so the session still works — just without the kitty
    /// extras. Recording the key here would permanently strand the host on
    /// a broken terminfo.
    ///
    /// Cost: 1 driver + 3 stubs, ~80 ms.
    func test_kitty_cacheMiss_ticFailure_downgradesAndDoesNotCache() throws {
        let r = try run(term: "xterm-kitty", args: ["testhost"],
                        env: ["STUB_SSH_TIC_EXIT": "1"])

        XCTAssertEqual(r.count(prefix: "TIC"), 1,
            "the wrapper must have attempted the tic pre-flight")
        XCTAssertEqual(r.count(prefix: "CONNECT"), 1, "it must still connect")
        XCTAssertEqual(r.term(prefix: "CONNECT"), "xterm-256color",
            "a failed install must downgrade the connection to xterm-256color")
        XCTAssertFalse(r.cacheLines.contains("testuser@testhost:22"),
            "a failed install must NOT record the host. cache=\(r.cacheLines)")
    }

    // MARK: - Remote-command downgrade + option parsing

    /// A remote command (`ssh host cmd`) means there's no interactive login
    /// shell to benefit from kitty terminfo, so the wrapper must NEVER
    /// pre-flight and must connect with `xterm-256color`.
    ///
    /// Cost: 1 driver + ≤2 stubs, ~60 ms.
    func test_kitty_remoteCommand_neverPreflights_downgrades() throws {
        let r = try run(term: "xterm-kitty", args: ["testhost", "ls"])
        XCTAssertEqual(r.count(prefix: "INFOCMP"), 0, "remote command must not run infocmp")
        XCTAssertEqual(r.count(prefix: "TIC"), 0, "remote command must not pre-flight tic")
        XCTAssertEqual(r.count(prefix: "CONNECT"), 1, "it must still connect once")
        XCTAssertEqual(r.term(prefix: "CONNECT"), "xterm-256color",
            "a remote command connects with xterm-256color, not kitty")
        XCTAssertFalse(r.cacheLines.contains("testuser@testhost:22"),
            "a remote-command connection must not cache the host")
    }

    /// Option parsing: `-p 2222 testhost` is interactive — `2222` is `-p`'s
    /// argument, not a remote command. A naive parser that treated the first
    /// non-flag token after a flag as the command would wrongly downgrade.
    /// This is the explicitly-named case in the contract.
    ///
    /// Cost: 1 driver + 3 stubs, ~80 ms.
    func test_kitty_dashP_flagArgumentIsNotRemoteCommand_preflights() throws {
        let r = try run(term: "xterm-kitty", args: ["-p", "2222", "testhost"])
        XCTAssertEqual(r.count(prefix: "TIC"), 1,
            "`-p 2222 testhost` is interactive and must pre-flight. log=\(r.logLines)")
        XCTAssertEqual(r.term(prefix: "CONNECT"), "xterm-kitty",
            "interactive connection must use xterm-kitty")
        XCTAssertEqual(r.cacheLines, ["testuser@testhost:22"],
            "successful interactive install must cache the canonical key")
    }

    /// More interactive shapes the option parser must get right: an option
    /// that takes an argument (`-o Compression=yes`), clustered argument-less
    /// flags (`-Cv`), and an explicit end-of-options (`--`). Each has no
    /// remote command, so each must pre-flight and connect with kitty.
    ///
    /// Cost: 3 drivers + 3 stubs each, ~0.25 s total.
    func test_kitty_optionParsing_interactiveShapes_preflight() throws {
        let cases: [[String]] = [
            ["-o", "Compression=yes", "testhost"],
            ["-Cv", "testhost"],
            ["--", "testhost"],
        ]
        for args in cases {
            // Each shape must exercise the cache-MISS path: the previous
            // iteration's successful install cached testuser@testhost:22,
            // and a cache hit correctly skips the pre-flight (that is the
            // wrapper's contract, covered by the cache-hit tests) — so
            // reset the cache between shapes.
            try? FileManager.default.removeItem(
                at: stateDir.appendingPathComponent("blackbird"))
            let r = try run(term: "xterm-kitty", args: args)
            XCTAssertEqual(r.count(prefix: "TIC"), 1,
                "`ssh \(args.joined(separator: " "))` is interactive and must pre-flight. "
                + "log=\(r.logLines)")
            XCTAssertEqual(r.term(prefix: "CONNECT"), "xterm-kitty",
                "`ssh \(args.joined(separator: " "))` must connect with xterm-kitty")
        }
    }

    /// The mirror image: option shapes that DO carry a remote command must
    /// all downgrade and never pre-flight, including when flags precede the
    /// destination.
    ///
    /// Cost: 2 drivers + ≤2 stubs each, ~0.15 s total.
    func test_kitty_remoteCommandShapes_downgrade() throws {
        let cases: [[String]] = [
            ["-p", "2222", "testhost", "ls", "-la"],
            ["testhost", "echo", "hi"],
        ]
        for args in cases {
            let r = try run(term: "xterm-kitty", args: args)
            XCTAssertEqual(r.count(prefix: "TIC"), 0,
                "`ssh \(args.joined(separator: " "))` carries a remote command; must not pre-flight. "
                + "log=\(r.logLines)")
            XCTAssertEqual(r.term(prefix: "CONNECT"), "xterm-256color",
                "`ssh \(args.joined(separator: " "))` must connect with xterm-256color")
        }
    }

    /// Panel finding #1 regression (2026-07-06 review): ATTACHED-form
    /// option arguments (`-oX=y`, `-i/path`, value inside the same token)
    /// whose value ends in an arg-taking letter fooled the old last-char
    /// parser into swallowing the destination — so `ssh -oX=no host cmd`
    /// looked interactive and the pre-flight appended `tic -x -` to the
    /// user's remote command (corrupting it, then running it twice).
    /// Attached forms with a trailing remote command must downgrade;
    /// attached forms without one must still pre-flight. Expected
    /// classifications specified by the reviewing agent from ssh(1)
    /// semantics, independent of the fix.
    ///
    /// Cost: 5 drivers + stubs, ~0.4 s total.
    func test_kitty_attachedOptionArgs_classifyCorrectly() throws {
        // Attached value + remote command → downgrade, never pre-flight.
        let remoteCmd: [[String]] = [
            ["-oStrictHostKeyChecking=no", "testhost", "ls"],
            ["-oControlMaster=auto", "testhost", "run-backup"],
            ["-i/tmp/keyfoo", "testhost", "deploy"],
        ]
        for args in remoteCmd {
            try? FileManager.default.removeItem(
                at: stateDir.appendingPathComponent("blackbird"))
            let r = try run(term: "xterm-kitty", args: args)
            XCTAssertEqual(r.count(prefix: "TIC"), 0,
                "`ssh \(args.joined(separator: " "))` carries a remote command; "
                + "must not pre-flight. log=\(r.logLines)")
            XCTAssertEqual(r.term(prefix: "CONNECT"), "xterm-256color",
                "`ssh \(args.joined(separator: " "))` must connect with xterm-256color")
        }
        // Attached value, NO remote command → still interactive: pre-flight.
        let interactive: [[String]] = [
            ["-oStrictHostKeyChecking=no", "testhost"],
            ["-p2222", "testhost"],
        ]
        for args in interactive {
            try? FileManager.default.removeItem(
                at: stateDir.appendingPathComponent("blackbird"))
            let r = try run(term: "xterm-kitty", args: args)
            XCTAssertEqual(r.count(prefix: "TIC"), 1,
                "`ssh \(args.joined(separator: " "))` is interactive and must pre-flight. "
                + "log=\(r.logLines)")
            XCTAssertEqual(r.term(prefix: "CONNECT"), "xterm-kitty",
                "`ssh \(args.joined(separator: " "))` must connect with xterm-kitty")
        }
    }

    /// Panel finding #4 regression: session modes with no interactive
    /// terminal (-N port-forward, -f background, -W stdio-forward, -O
    /// control ops) must never pre-flight an install over their
    /// non-interactive channel — they take the quiet downgrade.
    ///
    /// Cost: 3 drivers + stubs, ~0.25 s total.
    func test_kitty_nonInteractiveSessionModes_downgrade() throws {
        let cases: [[String]] = [
            ["-N", "testhost"],
            ["-fN", "testhost"],
            ["-W", "host:22", "testhost"],
        ]
        for args in cases {
            try? FileManager.default.removeItem(
                at: stateDir.appendingPathComponent("blackbird"))
            let r = try run(term: "xterm-kitty", args: args)
            XCTAssertEqual(r.count(prefix: "TIC"), 0,
                "`ssh \(args.joined(separator: " "))` has no interactive terminal; "
                + "must not pre-flight. log=\(r.logLines)")
            XCTAssertEqual(r.term(prefix: "CONNECT"), "xterm-256color",
                "`ssh \(args.joined(separator: " "))` must connect with xterm-256color")
        }
    }

    // MARK: - Default path (v0.6.1): plain TERM downgrade, zero machinery

    /// v0.6.1 default (no BB_SSH_REMOTE_TERM opt-in): every kitty-TERM
    /// ssh gets exactly one real connection with TERM=xterm-256color and
    /// byte-identical argv — no `ssh -G`, no infocmp/tic, no cache I/O.
    /// Rationale (measured, 2026-07-07): remote TERM=xterm-kitty breaks
    /// string-sniffing color-depth detection (codex composer bar,
    /// npm supports-color) because COLORTERM doesn't survive ssh; VS Code
    /// works because its remote TERM is xterm-256color. Parity restored.
    ///
    /// Cost: 3 drivers + 1 stub each, ~0.25 s total.
    func test_default_kitty_downgradesEveryShape_zeroMachinery() throws {
        let shapes: [[String]] = [
            ["testhost"],
            ["-p", "2222", "testhost"],
            ["testhost", "ls", "-la"],
        ]
        for args in shapes {
            let r = try run(term: "xterm-kitty", args: args,
                            env: ["BB_SSH_REMOTE_TERM": ""])
            XCTAssertEqual(r.count(prefix: "CONNECT"), 1,
                "`ssh \(args.joined(separator: " "))` must connect exactly once. log=\(r.logLines)")
            XCTAssertEqual(r.term(prefix: "CONNECT"), "xterm-256color",
                "default path always downgrades TERM")
            XCTAssertEqual(r.count(prefix: "G"), 0,
                "default path must not canonicalize via ssh -G. log=\(r.logLines)")
            XCTAssertEqual(r.count(prefix: "TIC"), 0,
                "default path must never pre-flight. log=\(r.logLines)")
            XCTAssertEqual(r.count(prefix: "INFOCMP"), 0,
                "default path must never consult infocmp. log=\(r.logLines)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: r.cacheURL.path),
                "default path must not create the cache file")
        }
    }

    /// Panel blocker-B regression: the harness injects the opt-in for
    /// machinery tests, so without this test a `${VAR-}` → `${VAR-kitty}`
    /// typo (defaulting UNSET users into the machinery) would keep every
    /// suite green while flipping behavior for ~100% of real users, who
    /// have the variable truly UNSET — not set-to-empty.
    func test_default_kitty_trulyUnsetVariable_downgradesZeroMachinery() throws {
        let r = try run(term: "xterm-kitty", args: ["testhost"],
                        env: ["BB_SSH_REMOTE_TERM": nil])
        XCTAssertEqual(r.count(prefix: "CONNECT"), 1, "log=\(r.logLines)")
        XCTAssertEqual(r.term(prefix: "CONNECT"), "xterm-256color",
            "an UNSET BB_SSH_REMOTE_TERM must take the default downgrade")
        XCTAssertEqual(r.count(prefix: "G"), 0, "log=\(r.logLines)")
        XCTAssertEqual(r.count(prefix: "TIC"), 0, "log=\(r.logLines)")
        XCTAssertEqual(r.count(prefix: "INFOCMP"), 0, "log=\(r.logLines)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: r.cacheURL.path),
            "unset variable must not activate the cache machinery")
    }

    /// Default-path argv fidelity + exit-code propagation in one shot.
    func test_default_kitty_forwardsArgvAndExitCode() throws {
        let r = try run(term: "xterm-kitty",
                        args: ["-oStrictHostKeyChecking=no", "testhost", "deploy"],
                        env: ["BB_SSH_REMOTE_TERM": "", "STUB_SSH_EXIT": "42"])
        XCTAssertTrue(r.logLines.contains(
            "CONNECT TERM=xterm-256color ARGS=-oStrictHostKeyChecking=no testhost deploy"),
            "argv must be forwarded byte-identically. log=\(r.logLines)")
        XCTAssertEqual(r.effectiveExit, 42, "the real ssh exit code must pass through")
    }

    /// Panel silent-failure finding #1 regression: `tic -x -` exits 0 on
    /// EMPTY stdin, so a failing local infocmp piped straight into the
    /// remote would "succeed", cache the host, and permanently pin a
    /// broken kitty TERM there. The wrapper must capture the source
    /// first: empty ⇒ downgrade this connection, cache NOTHING, never
    /// run the remote tic.
    ///
    /// Cost: 1 driver + 2 stubs, ~80 ms.
    func test_kitty_emptyInfocmpSource_downgradesUncached_neverRunsTic() throws {
        let r = try run(term: "xterm-kitty", args: ["testhost"],
                        env: ["STUB_INFOCMP_SILENT": "1", "STUB_INFOCMP_EXIT": "1"])
        XCTAssertEqual(r.count(prefix: "INFOCMP"), 1,
            "the wrapper must have consulted infocmp. log=\(r.logLines)")
        XCTAssertEqual(r.count(prefix: "TIC"), 0,
            "an empty terminfo source must never reach the remote tic — "
            + "tic exits 0 on empty stdin and would poison the cache. log=\(r.logLines)")
        XCTAssertEqual(r.term(prefix: "CONNECT"), "xterm-256color",
            "empty local source downgrades this connection")
        XCTAssertFalse(r.cacheLines.contains("testuser@testhost:22"),
            "an empty-source failure must NOT be cached — the next connect retries")
    }

    // MARK: - ssh -G failure

    /// If `ssh -G` itself fails (bad config, unknown host alias), the
    /// wrapper can't derive a canonical key. It must fall back to a plain
    /// `xterm-256color` connection and must NOT pre-flight (there's nothing
    /// reliable to key the cache on).
    ///
    /// Cost: 1 driver + 2 stubs, ~60 ms.
    func test_kitty_sshGFailure_downgradesAndDoesNotPreflight() throws {
        let r = try run(term: "xterm-kitty", args: ["testhost"],
                        env: ["STUB_SSH_G_FAIL": "1"])
        XCTAssertEqual(r.count(prefix: "TIC"), 0,
            "a failed ssh -G must not pre-flight. log=\(r.logLines)")
        XCTAssertEqual(r.count(prefix: "INFOCMP"), 0,
            "a failed ssh -G must not run infocmp. log=\(r.logLines)")
        XCTAssertEqual(r.count(prefix: "CONNECT"), 1, "it must still connect")
        XCTAssertEqual(r.term(prefix: "CONNECT"), "xterm-256color",
            "a failed ssh -G downgrades to xterm-256color")
        XCTAssertFalse(r.cacheLines.contains("testuser@testhost:22"),
            "a failed ssh -G must not cache anything")
    }

    // MARK: - Not shadowing a user's own ssh

    /// If the user already defined an `ssh` ALIAS before sourcing, the
    /// script must leave it untouched. In zsh you cannot even parse a
    /// `ssh() { … }` definition while an `ssh` alias is active (it's a hard
    /// parse error), so a guard that failed to detect the alias would make
    /// `source` fail. We assert both that sourcing succeeded cleanly
    /// (`SRC=0`, i.e. no parse error) and that `whence -w ssh` still reports
    /// the alias.
    ///
    /// Cost: 1 driver, no stubs invoked, ~50 ms.
    func test_preExistingAlias_isNotShadowed() throws {
        let body = """
        emulate -L zsh
        alias ssh='print BB_PREEXISTING_ALIAS'
        source "$BB_SSH_SCRIPT"
        print -r -- "SRC=$?"
        whence -w ssh
        """
        let r = try run(term: "xterm-kitty", body: body)
        XCTAssertTrue(r.stdout.contains("SRC=0"),
            "sourcing over a pre-existing `ssh` alias must succeed with no error "
            + "(a broken guard triggers a zsh parse error). stdout=\(hex(r.stdout)) "
            + "stderr=\(hex(r.stderr))")
        XCTAssertTrue(r.stdout.contains("ssh: alias"),
            "the user's `ssh` alias must survive sourcing. stdout=\(hex(r.stdout))")
        XCTAssertFalse(r.stdout.contains("ssh: function"),
            "the wrapper must not replace the user's alias with a function")
    }

    /// If the user already defined an `ssh` FUNCTION before sourcing, the
    /// script must leave it in place. Both the user function and the wrapper
    /// are "functions", so `whence` can't tell them apart — instead we call
    /// `ssh` and prove the USER's function ran (its marker) and that the
    /// wrapper's real-ssh machinery did not (empty stub log).
    ///
    /// Cost: 1 driver, no stubs expected, ~50 ms.
    func test_preExistingFunction_isNotShadowed() throws {
        let body = """
        emulate -L zsh
        ssh() { print -r -- "BB_PREEXISTING_FUNC $*"; }
        source "$BB_SSH_SCRIPT"
        print -r -- "SRC=$?"
        ssh sentinel-arg
        """
        let r = try run(term: "xterm-kitty", body: body)
        XCTAssertTrue(r.stdout.contains("SRC=0"),
            "sourcing over a pre-existing `ssh` function must succeed cleanly. "
            + "stdout=\(hex(r.stdout))")
        XCTAssertTrue(r.stdout.contains("BB_PREEXISTING_FUNC sentinel-arg"),
            "the user's own `ssh` function must still handle the call. "
            + "stdout=\(hex(r.stdout))")
        XCTAssertTrue(r.logLines.isEmpty,
            "the wrapper must not run (no ssh -G / connect) when the user already "
            + "has an `ssh` function. log=\(r.logLines)")
    }

    // MARK: - Idempotent double-source

    /// Sourcing the script twice (a common rc-reload situation) must be
    /// safe: no errors, and still exactly one wrapper — not a wrapper that
    /// wraps itself and connects twice. We source twice, assert both
    /// sources returned 0, then drive one passthrough `ssh` and assert
    /// exactly one connection reached the stub.
    ///
    /// Cost: 1 driver + 1 stub, ~60 ms.
    func test_doubleSource_isIdempotent_singleWrapperNoErrors() throws {
        let body = """
        emulate -L zsh
        source "$BB_SSH_SCRIPT"
        print -r -- "SRC1=$?"
        source "$BB_SSH_SCRIPT"
        print -r -- "SRC2=$?"
        ssh testhost
        print -r -- "EXIT=$?"
        """
        // Non-kitty so the driven call is a simple passthrough — one CONNECT
        // and nothing else, making "wrapped itself" show up as a 2nd CONNECT.
        let r = try run(term: "vt100", body: body)
        XCTAssertTrue(r.stdout.contains("SRC1=0"),
            "first source must succeed. stdout=\(hex(r.stdout)) stderr=\(hex(r.stderr))")
        XCTAssertTrue(r.stdout.contains("SRC2=0"),
            "second source must also succeed (idempotent, no errors). "
            + "stdout=\(hex(r.stdout)) stderr=\(hex(r.stderr))")
        XCTAssertEqual(r.count(prefix: "CONNECT"), 1,
            "after double-sourcing, one `ssh` call must reach the real ssh exactly "
            + "once — a self-wrapping regression would connect twice. log=\(r.logLines)")
    }
}
