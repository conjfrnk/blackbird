import XCTest

/// Blind regression tests for SCI-10: the shipped `ssh` wrapper
/// (`Sources/Blackbird/Resources/shell/ssh.{zsh,bash,fish}`) in the opt-in
/// `BB_SSH_REMOTE_TERM=kitty` mode must NOT treat `ssh -G <host>` as an
/// interactive connection worth a terminfo install.
///
/// ## Background (from the docs and the sibling suites, not the scripts)
///
/// In kitty mode, the first plain interactive `ssh host` from inside Blackbird
/// (`TERM=xterm-kitty`) installs the `xterm-kitty` terminfo entry on the
/// remote (local `infocmp` piped into a remote `tic`), records the canonical
/// `user@hostname:port` in `~/.local/state/blackbird/ssh-terminfo-hosts`, and
/// connects with `TERM=xterm-kitty`. Every later connection to a cached host
/// skips the install. (`KNOWN_ISSUES.md`: "successes are cached, failures
/// never are".)
///
/// OpenSSH's `-G` flag ("dump configuration") is NOT a connection: ssh
/// resolves the host's effective configuration, prints it to stdout, and
/// exits 0 without ever authenticating or running a remote command. So a
/// `-G` run installs nothing on the remote. If the wrapper nevertheless
/// drives its install machinery for it (and the stand-in "install" is just
/// another `-G` run that exits 0), the wrapper believes the host has been
/// provisioned and caches it. Every later real `ssh host` then skips the
/// install and connects with `TERM=xterm-kitty` to a remote that has no such
/// terminfo entry, which is exactly the `'xterm-kitty': unknown terminal
/// type` failure (issue #23) the wrapper exists to prevent. It also dumps the
/// config more than once on the user's terminal.
///
/// ## Contract under test
///
/// For `ssh -G ...` (alone or inside an option cluster such as `-vG`, `-Gv`,
/// `-Gp 2222`) in all three dialects:
///   1. the user sees the config dump exactly once on stdout;
///   2. no terminfo install is attempted (`infocmp` never runs, no remote
///      `tic` is issued);
///   3. the host is NOT recorded in the provisioned-hosts cache;
///   4. the exit status is the dump's (0);
///   5. consequently a following plain `ssh host` still does the first-contact
///      install, caches the host, and connects with `TERM=xterm-kitty`.
///
/// Over-correction guards: option arguments that merely CONTAIN the letter G
/// (`-iGkey`, `-l G`, `-oSendEnv=G`) are not `-G` and must still install.
///
/// ## Harness
///
/// The `ssh` stub models the part of OpenSSH's option parsing that matters
/// here: it scans getopt-style (option letters that take an argument consume
/// the rest of the token, or the next token), and any invocation in which `-G`
/// is a real option letter prints a config dump and exits 0 WITHOUT
/// connecting or running a remote command, like the real thing. Wrapper
/// behavior is asserted purely on observable effects: the stub call log, the
/// user-visible stdout, the cache file, and the next run's behavior. The
/// wrapper's own diagnostics (stderr) are never asserted.
///
/// Cost: each test spawns at most 2 short-lived shell drivers per shape (~3
/// shapes of one tiny `/bin/sh` stub each), a few KB of RSS, well under a
/// second total per shell. No PTY, no network, no GUI, no real `ssh`.
final class SSHWrapperDumpConfigBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        // Same as every suite in this bundle: register the host-termination
        // observer once so a filtered run doesn't leave a zombie SwiftUI host.
        TestHostTermination.shared.register()
    }

    // MARK: - Fixed values

    private static let kittyTERM = "xterm-kitty"
    /// Canonical key the stub's `-G` dump reports: `user@hostname:port`.
    private static let expectedKey = "testuser@testhost:22"
    /// Unique line the stub appends to every config dump so the test can count
    /// how many times the user actually saw a dump on stdout.
    private static let dumpMarker = "bbmarker-ssh-config-dump"

    // MARK: - Dialects

    private enum Dialect: String {
        case zsh
        case bash
        case fish

        var scriptName: String { "ssh.\(rawValue)" }

        /// Candidate absolute paths for the interpreter.
        var candidates: [String] {
            switch self {
            case .zsh:
                return ["/bin/zsh", "/usr/bin/zsh", "/opt/homebrew/bin/zsh", "/usr/local/bin/zsh"]
            case .bash:
                return ["/bin/bash"]
            case .fish:
                return ["/opt/homebrew/bin/fish", "/usr/local/bin/fish",
                        "/opt/local/bin/fish", "/usr/bin/fish"]
            }
        }

        /// Interpreter argv for running `driverPath` (zsh/bash) or the inline
        /// driver body (fish).
        func arguments(driverPath: String, body: String) -> [String] {
            switch self {
            case .zsh: return ["-f", driverPath]
            case .bash: return ["--noprofile", "--norc", driverPath]
            case .fish: return ["-c", body]
            }
        }
    }

    // MARK: - Rig (one hermetic tree per scenario)

    private struct Rig {
        let dialect: Dialect
        let interpreter: URL
        let script: URL
        let root: URL
        let binDir: URL
        let homeDir: URL
        let stateDir: URL
        let logURL: URL

        var cacheURL: URL {
            stateDir.appendingPathComponent("blackbird")
                .appendingPathComponent("ssh-terminfo-hosts")
        }
    }

    /// Everything one wrapper invocation produced.
    private struct Outcome {
        let stdout: String
        let stderr: String
        let status: Int32
        let logLines: [String]
        let cacheLines: [String]

        func count(prefix: String) -> Int {
            logLines.filter { (l: String) -> Bool in l.hasPrefix(prefix) }.count
        }

        /// `TERM=` value recorded on the first log line with `prefix`.
        func term(prefix: String) -> String? {
            guard let line = logLines.first(where: { (l: String) -> Bool in l.hasPrefix(prefix) }),
                  let r = line.range(of: "TERM=") else { return nil }
            var rest = String(line[r.upperBound...])
            if let a = rest.range(of: " ARGS=") { rest = String(rest[..<a.lowerBound]) }
            return rest
        }

        /// Number of times the config-dump marker reached the user's stdout.
        var dumpsOnStdout: Int {
            stdout.components(separatedBy: SSHWrapperDumpConfigBlindTests.dumpMarker).count - 1
        }

        /// Exit status: the driver's `EXIT=` line when it ran to completion,
        /// else the process status (wrapper `exec`ed ssh).
        var effectiveExit: Int32 {
            for line in stdout.split(whereSeparator: { (c: Character) -> Bool in c == "\n" || c == "\r" }) {
                if line.hasPrefix("EXIT="),
                   let n = Int32(line.dropFirst("EXIT=".count).trimmingCharacters(in: .whitespaces)) {
                    return n
                }
            }
            return status
        }
    }

    // MARK: - Repo / interpreter location

    private func repoRoot(file: String = #filePath) throws -> URL {
        let fm = FileManager.default
        var dir = URL(fileURLWithPath: file).deletingLastPathComponent()
        while dir.path != "/" {
            if fm.fileExists(atPath: dir.appendingPathComponent("project.yml").path) {
                return dir
            }
            dir = dir.deletingLastPathComponent()
        }
        throw XCTSkip("repo root (dir with project.yml) not found above \(file)")
    }

    private func locate(_ dialect: Dialect) -> URL? {
        for path in dialect.candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    // MARK: - Stubs

    /// `ssh` stand-in. Models OpenSSH's getopt scan: letters in
    /// `BbcDEeFIiJLlmOopQRSWw` take an argument (the rest of the token if any,
    /// else the next token); `G` anywhere else in a cluster selects
    /// config-dump mode, which prints the dump and exits 0 without connecting
    /// and without running any remote command (a trailing `tic -x -` is
    /// ignored, exactly like real ssh -G). The first non-option token ends the
    /// scan.
    private static let sshStub = #"""
    #!/bin/sh
    gmode=0
    expect_arg=0
    for a in "$@"; do
        if [ "$expect_arg" = 1 ]; then
            expect_arg=0
            continue
        fi
        case "$a" in
            --) break ;;
            -?*)
                rest="${a#-}"
                while [ -n "$rest" ]; do
                    c="${rest%"${rest#?}"}"
                    rest="${rest#?}"
                    case "$c" in
                        G) gmode=1 ;;
                        [BbcDEeFIiJLlmOopQRSWw])
                            if [ -z "$rest" ]; then expect_arg=1; fi
                            rest=""
                            ;;
                    esac
                done
                ;;
            *) break ;;
        esac
    done

    if [ "$gmode" = 1 ]; then
        printf 'GDUMP TERM=%s ARGS=%s\n' "$TERM" "$*" >> "$STUB_LOG"
        # Real ssh -G never reads stdin; drain it (stdin is /dev/null or the
        # wrapper's pipe) so an upstream writer can never take SIGPIPE and
        # make the outcome racy.
        cat >/dev/null 2>&1
        printf 'user testuser\nhostname testhost\nport 22\n'
        printf '%s\n' 'bbmarker-ssh-config-dump'
        exit 0
    fi

    for a in "$@"; do
        case "$a" in
            *tic*)
                printf 'TIC TERM=%s ARGS=%s\n' "$TERM" "$*" >> "$STUB_LOG"
                cat >/dev/null 2>&1
                exit 0
                ;;
        esac
    done
    printf 'CONNECT TERM=%s ARGS=%s\n' "$TERM" "$*" >> "$STUB_LOG"
    exit 0
    """#

    private static let infocmpStub = #"""
    #!/bin/sh
    printf 'INFOCMP ARGS=%s\n' "$*" >> "$STUB_LOG"
    printf 'blackbird-dummy-terminfo-source\n'
    exit 0
    """#

    private func writeExecutable(_ contents: String, to url: URL) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    // MARK: - Rig construction

    private func makeRig(_ dialect: Dialect) throws -> Rig {
        guard let interpreter = locate(dialect) else {
            throw XCTSkip("\(dialect.rawValue) not installed - skipping its wrapper port")
        }
        let script = try repoRoot()
            .appendingPathComponent("Sources/Blackbird/Resources/shell")
            .appendingPathComponent(dialect.scriptName)
        guard FileManager.default.fileExists(atPath: script.path) else {
            throw XCTSkip("\(dialect.scriptName) not found at \(script.path)")
        }

        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("bb-sshdump-\(UUID().uuidString)")
        let binDir = root.appendingPathComponent("bin")
        let homeDir = root.appendingPathComponent("home")
        let stateDir = root.appendingPathComponent("state")
        let logURL = root.appendingPathComponent("stub-calls.log")
        for dir in [binDir, homeDir, stateDir] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        fm.createFile(atPath: logURL.path, contents: Data())
        try writeExecutable(Self.sshStub, to: binDir.appendingPathComponent("ssh"))
        try writeExecutable(Self.infocmpStub, to: binDir.appendingPathComponent("infocmp"))
        addTeardownBlock { try? fm.removeItem(at: root) }

        return Rig(dialect: dialect, interpreter: interpreter, script: script, root: root,
                   binDir: binDir, homeDir: homeDir, stateDir: stateDir, logURL: logURL)
    }

    // MARK: - Driver / runner

    /// Single-quote each argument for the driver line. Test arguments are
    /// fixed literals that never contain a single quote.
    private func quoted(_ args: [String]) -> String {
        args.map { (a: String) -> String in "'\(a)'" }.joined(separator: " ")
    }

    private func driverBody(_ rig: Rig, args: [String]) -> String {
        let invoke = "ssh " + quoted(args)
        switch rig.dialect {
        case .zsh:
            return """
            emulate -L zsh
            source '\(rig.script.path)'
            \(invoke)
            print -r -- "EXIT=$?"

            """
        case .bash:
            return """
            source '\(rig.script.path)'
            \(invoke)
            echo "EXIT=$?"

            """
        case .fish:
            return """
            source '\(rig.script.path)'
            \(invoke)
            echo EXIT=$status

            """
        }
    }

    /// Run `ssh <args>` through the real wrapper in a fresh shell. Persistent
    /// state (the cache under `XDG_STATE_HOME`) is shared across runs of the
    /// same rig; the call log is reset per run.
    @discardableResult
    private func run(_ rig: Rig, args: [String]) throws -> Outcome {
        try Data().write(to: rig.logURL)

        let body = driverBody(rig, args: args)
        let driverURL = rig.root.appendingPathComponent("driver-\(UUID().uuidString).sh")
        try body.write(to: driverURL, atomically: true, encoding: .utf8)

        let env: [String: String] = [
            "PATH": "\(rig.binDir.path):/usr/bin:/bin",
            "TERM": Self.kittyTERM,
            "HOME": rig.homeDir.path,
            "XDG_STATE_HOME": rig.stateDir.path,
            "STUB_LOG": rig.logURL.path,
            // The install machinery is only active with this opt-in; the
            // default path is a plain TERM=xterm-256color downgrade.
            "BB_SSH_REMOTE_TERM": "kitty",
        ]

        let process = Process()
        process.executableURL = rig.interpreter
        process.arguments = rig.dialect.arguments(driverPath: driverURL.path, body: body)
        process.environment = env
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice
        try process.run()

        // Poll with a hard ceiling so a hung wrapper fails loudly instead of
        // wedging the suite. Output is a few hundred bytes (well under a pipe
        // buffer), so waiting before draining cannot deadlock.
        let deadline = Date().addingTimeInterval(15.0)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.1)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            XCTFail("\(rig.dialect.rawValue) wrapper driver hung for ssh \(args)")
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()

        let log = (try? String(contentsOf: rig.logURL, encoding: .utf8)) ?? ""
        let logLines: [String] = log
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { (s: Substring) -> String in String(s) }
        let cache = (try? String(contentsOf: rig.cacheURL, encoding: .utf8)) ?? ""
        let cacheLines: [String] = cache
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { (s: Substring) -> String in String(s) }

        return Outcome(stdout: String(decoding: outData, as: UTF8.self),
                       stderr: String(decoding: errData, as: UTF8.self),
                       status: process.terminationStatus,
                       logLines: logLines, cacheLines: cacheLines)
    }

    // MARK: - Shared scenario bodies

    /// `ssh <dumpArgs>` is a config dump, not a connection. Assert it leaves
    /// no trace of a provisioning, then prove the consequence the user
    /// cares about: a following plain `ssh testhost` still installs.
    private func assertDumpConfigIsNotAnInstall(
        _ dialect: Dialect, dumpArgs: [String],
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let rig = try makeRig(dialect)
        let shape = "ssh " + dumpArgs.joined(separator: " ")
        let tag = "[\(dialect.rawValue)] `\(shape)`"

        let dump = try run(rig, args: dumpArgs)

        // Precondition (non-vacuity): ssh really was asked for a config dump
        // and the user really saw one, so the assertions below are about the
        // wrapper's reaction to a live -G run, not an inert harness.
        XCTAssertGreaterThanOrEqual(dump.count(prefix: "GDUMP"), 1,
            "\(tag): the wrapper never reached ssh -G at all. log=\(dump.logLines) "
            + "stderr=\(dump.stderr)", file: file, line: line)

        XCTAssertEqual(dump.dumpsOnStdout, 1,
            "\(tag): the user must see the config dump exactly once. "
            + "stdout=\(dump.stdout.debugDescription) log=\(dump.logLines)",
            file: file, line: line)
        XCTAssertEqual(dump.effectiveExit, 0,
            "\(tag): a config dump exits 0. stderr=\(dump.stderr)", file: file, line: line)
        XCTAssertEqual(dump.count(prefix: "INFOCMP"), 0,
            "\(tag): -G connects nowhere, so no terminfo source may be generated for an "
            + "install. log=\(dump.logLines)", file: file, line: line)
        XCTAssertEqual(dump.count(prefix: "TIC"), 0,
            "\(tag): no remote tic may be issued. log=\(dump.logLines)",
            file: file, line: line)
        XCTAssertEqual(dump.cacheLines, [],
            "\(tag): nothing was installed, so the host must NOT be cached as "
            + "provisioned. cache=\(dump.cacheLines)", file: file, line: line)

        // The consequence: the first real connection must still provision.
        let next = try run(rig, args: ["testhost"])
        XCTAssertEqual(next.count(prefix: "TIC"), 1,
            "\(tag) then `ssh testhost`: first real contact must still pre-flight the "
            + "remote terminfo install (a cached-by-mistake host skips it and fails "
            + "with 'unknown terminal type'). log=\(next.logLines) cache=\(next.cacheLines)",
            file: file, line: line)
        XCTAssertEqual(next.term(prefix: "CONNECT"), Self.kittyTERM,
            "\(tag) then `ssh testhost`: after a successful install the connection "
            + "uses TERM=xterm-kitty. log=\(next.logLines)", file: file, line: line)
        XCTAssertEqual(next.cacheLines, [Self.expectedKey],
            "\(tag) then `ssh testhost`: the successful install is cached exactly once. "
            + "cache=\(next.cacheLines)", file: file, line: line)
    }

    /// Option arguments that merely contain the letter G are not `-G`: the
    /// first contact must still install (guards against an over-eager fix
    /// that pattern-matches `G` anywhere in argv).
    private func assertLetterGInOptionArgumentStillInstalls(
        _ dialect: Dialect, args: [String],
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let rig = try makeRig(dialect)
        let tag = "[\(dialect.rawValue)] `ssh \(args.joined(separator: " "))`"

        let r = try run(rig, args: args)
        XCTAssertEqual(r.count(prefix: "TIC"), 1,
            "\(tag): not a config dump, an ordinary interactive connect must pre-flight "
            + "the install. log=\(r.logLines)", file: file, line: line)
        XCTAssertEqual(r.term(prefix: "CONNECT"), Self.kittyTERM,
            "\(tag): must connect with TERM=xterm-kitty after the install. log=\(r.logLines)",
            file: file, line: line)
        XCTAssertEqual(r.cacheLines, [Self.expectedKey],
            "\(tag): successful install must be cached. cache=\(r.cacheLines)",
            file: file, line: line)
    }

    // MARK: - Shapes

    /// Real `ssh -G` invocations: bare, clustered with a no-arg flag on
    /// either side, and clustered with / next to an arg-taking option.
    private static let dumpShapes: [[String]] = [
        ["-G", "testhost"],
        ["-vG", "testhost"],
        ["-Gv", "testhost"],
        ["-G", "-p", "2222", "testhost"],
        ["-Gp", "2222", "testhost"],
    ]

    /// Option arguments that contain a literal `G` but are not -G.
    private static let notDumpShapes: [[String]] = [
        ["-iGkey", "testhost"],
        ["-l", "G", "testhost"],
        ["-oSendEnv=G", "testhost"],
    ]

    // MARK: - zsh

    func test_zsh_dashG_isNotAnInstall_hostNotCached() throws {
        for shape in Self.dumpShapes {
            try assertDumpConfigIsNotAnInstall(.zsh, dumpArgs: shape)
        }
    }

    func test_zsh_letterGInsideOptionArgument_stillInstalls() throws {
        for shape in Self.notDumpShapes {
            try assertLetterGInOptionArgumentStillInstalls(.zsh, args: shape)
        }
    }

    // MARK: - bash

    func test_bash_dashG_isNotAnInstall_hostNotCached() throws {
        for shape in Self.dumpShapes {
            try assertDumpConfigIsNotAnInstall(.bash, dumpArgs: shape)
        }
    }

    func test_bash_letterGInsideOptionArgument_stillInstalls() throws {
        for shape in Self.notDumpShapes {
            try assertLetterGInOptionArgumentStillInstalls(.bash, args: shape)
        }
    }

    // MARK: - fish (skipped where fish is not installed, e.g. CI)

    func test_fish_dashG_isNotAnInstall_hostNotCached() throws {
        for shape in Self.dumpShapes {
            try assertDumpConfigIsNotAnInstall(.fish, dumpArgs: shape)
        }
    }

    func test_fish_letterGInsideOptionArgument_stillInstalls() throws {
        for shape in Self.notDumpShapes {
            try assertLetterGInOptionArgumentStillInstalls(.fish, args: shape)
        }
    }
}
