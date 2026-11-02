import XCTest
import Foundation

/// Blind regression tests for BUG SCI-2: with Blackbird's bash shell
/// integration (`Resources/shell/osc133.bash`, sourced from `~/.bashrc` -- the
/// documented manual path, bash is deliberately not auto-injected) loaded, a
/// user's own `PROMPT_COMMAND` always sees `$? == 0` and a reset `PIPESTATUS`
/// instead of the result of the command line that just ran.
///
/// Contract (bash convention, not Blackbird-specific): bash runs
/// `PROMPT_COMMAND` right before it paints the primary prompt, with `$?`
/// still holding the exit status of the LAST command line and `PIPESTATUS`
/// still holding that line's per-stage statuses. Prompt frameworks and
/// hand-rolled `PS1` helpers read them on entry to print a red `[1]`, a
/// `[0|1|3]` pipeline summary, or to colour the prompt. Shell integration may
/// add marks around the prompt, but it must be transparent to those values --
/// a failed command must still look failed to the user's hook.
///
/// Why a real interactive bash fed on stdin (and not `eval "$PROMPT_COMMAND"`
/// from a `-c` script): the only authoritative oracle for "what does the
/// user's hook see" is bash's own prompt cycle. `bash -i` with a non-tty
/// stdin runs `PROMPT_COMMAND` before every prompt it prints (to stderr),
/// exactly as in a terminal, and is agnostic to HOW the integration chains
/// itself (scalar string, bash >= 5.1 array, wrapper function), which an
/// `eval` of `$PROMPT_COMMAND` would not be.
///
/// Every scenario runs a CONTROL first (same bash, same user hook, same
/// commands, integration NOT sourced) and asserts the control reports the true
/// values, so a rig that cannot observe `$?` / `PIPESTATUS` at all can't make
/// these pass or fail vacuously. The integrated run additionally asserts that
/// the integration really engaged (OSC 133;A and the right OSC 133;D;<n> are
/// on stdout), so "integration silently didn't load" -- or a "fix" that just
/// stops reporting the exit status -- can't masquerade as a pass.
///
/// Memory + time pre-flight: each scenario spawns two short-lived bash
/// processes per installed bash (~2 MB RSS, ~20-50 ms each) with three small
/// pipes; the captured output is well under 1 KB. One throwaway HOME dir
/// (empty). No PTY, no GUI, no network, no other shell.
final class BashPromptCommandStatusBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        // Same host-termination guard every suite in this bundle registers.
        TestHostTermination.shared.register()
    }

    // MARK: - Rig

    private var homeDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        homeDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("BBBashPromptStatus-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: homeDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let homeDir { try? FileManager.default.removeItem(at: homeDir) }
        homeDir = nil
        try super.tearDownWithError()
    }

    private static let escD = "\u{1B}]133;D;"
    private static let escA = "\u{1B}]133;A"

    /// Locate the shipped bash snippet via `#filePath` arithmetic (xcodebuild's
    /// CWD is inside DerivedData).
    private func locateScript(file: String = #filePath) throws -> URL {
        let url = URL(fileURLWithPath: file)
            .deletingLastPathComponent()  // Tests/BlackbirdTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("Sources/Blackbird/Resources/shell/osc133.bash")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("osc133.bash not found at \(url.path) -- repo layout changed?")
        }
        return url
    }

    /// Every distinct installed bash (stock macOS 3.2 plus Homebrew's 5.x when
    /// present): the bug is in the script, not the shell version, so each
    /// available version is exercised. Deduped by resolved path.
    private func installedBashes() -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for path in ["/bin/bash", "/opt/homebrew/bin/bash", "/usr/local/bin/bash", "/usr/bin/bash"]
        where FileManager.default.isExecutableFile(atPath: path) {
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            if seen.insert(resolved).inserted { result.append(URL(fileURLWithPath: path)) }
        }
        return result
    }

    /// One observed run of the user's `PROMPT_COMMAND` hook.
    private struct HookObservation {
        let stage: String
        let status: String
        let pipe: String
    }

    private struct Run {
        let stdout: String
        let observations: [HookObservation]
        /// True when the shell ended through `exit` with status 0 (not killed
        /// by a signal, not by errexit, not by a runaway/hung prompt cycle).
        var exitedCleanly = true

        /// Every observation labelled `stage`. The hook fires once per prompt
        /// and each stage label covers exactly one prompt, so a healthy run
        /// has exactly one entry; the tests assert that count explicitly.
        func observation(_ stage: String) -> [HookObservation] {
            observations.filter { $0.stage == stage }
        }
    }

    /// Drive a real interactive bash through: a user hook installed as a
    /// plain STRING `PROMPT_COMMAND`, optionally the shipped integration
    /// sourced AFTER it (the `.bashrc` ordering that the Trigger describes),
    /// then one command line per `triggers` entry, then `exit`.
    ///
    /// The user's hook is the canonical "reads `$?` and `PIPESTATUS` on
    /// entry" shape. Both are captured in ONE `local` command so the second
    /// expansion is not poisoned by the first assignment's own status.
    /// `__stage` is assigned on the SAME line as the command under test, so
    /// it labels the prompt cycle that follows that command (and no other).
    ///
    /// `promptCommand` is the user's string (default: just the hook; it must
    /// call `__pc` first when it wants the real `$?`). `exportPromptCommand`
    /// exports it, and `afterIntegration` lines run right after the source
    /// line -- together they model a nested shell inheriting the parent's
    /// (possibly already wrapped) exported `PROMPT_COMMAND`.
    private func runInteractiveBash(
        _ bash: URL, integration: URL?, triggers: [(stage: String, command: String)],
        promptCommand: String = "__pc", exportPromptCommand: Bool = false,
        afterIntegration: [String] = []
    ) throws -> Run {
        var lines: [String] = [
            "unset HISTFILE",
            Self.hookDefinition,
            "PROMPT_COMMAND=\(Self.shellQuoted(promptCommand))",
        ]
        if exportPromptCommand { lines.append("export PROMPT_COMMAND") }
        if let integration { lines.append("source '\(integration.path)'") }
        lines += afterIntegration
        for t in triggers { lines.append("__stage=\(t.stage); \(t.command)") }
        lines.append("exit")
        let stdinText = lines.joined(separator: "\n") + "\n"

        var env = ProcessInfo.processInfo.environment
        for key in ["PROMPT_COMMAND", "PS0", "PS1", "PS2", "BASH_ENV", "ENV", "HISTFILE", "HISTCONTROL"] {
            env.removeValue(forKey: key)
        }
        env["HOME"] = homeDir.path
        env["TERM"] = "xterm-256color"
        env["BASH_SILENCE_DEPRECATION_WARNING"] = "1"

        let process = Process()
        process.executableURL = bash
        // --norc/--noprofile: hermetic. -i: a real interactive prompt cycle.
        process.arguments = ["--norc", "--noprofile", "-i"]
        process.environment = env
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        stdin.fileHandleForWriting.write(Data(stdinText.utf8))
        try stdin.fileHandleForWriting.close()

        // 5-second wall budget, polled so a hung shell is killed and fails
        // loudly instead of wedging the suite.
        let deadline = Date().addingTimeInterval(5.0)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.1)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            XCTFail("\(bash.path) hung driving an interactive prompt cycle")
            return Run(stdout: "", observations: [], exitedCleanly: false)
        }
        let exitedCleanly = process.terminationReason == .exit && process.terminationStatus == 0

        let out = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let err = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let observations = try Self.parseObservations(out)
        // Rig precondition: the hook must have fired for EVERY trigger plus
        // the pre-trigger prompts; zero observations means the rig (not the
        // integration) is broken.
        XCTAssertFalse(observations.isEmpty,
            "rig precondition: the user's PROMPT_COMMAND never ran under `\(bash.path) -i`. "
            + "stdout=\(Self.debugEscape(out)) stderr=\(Self.debugEscape(err))")
        return Run(stdout: out, observations: observations, exitedCleanly: exitedCleanly)
    }

    /// The user's hook: reads `$?` and `PIPESTATUS` on entry, in ONE `local`
    /// so the second expansion is not poisoned by the first assignment.
    private static let hookDefinition =
        #"__pc() { local e=$? p="${PIPESTATUS[*]}"; printf 'PCSAW stage=%s status=%s pipe=%s\n' "${__stage:-before}" "$e" "$p"; }"#

    private static func shellQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func parseObservations(_ out: String) throws -> [HookObservation] {
        let regex = try NSRegularExpression(
            pattern: #"PCSAW stage=([A-Za-z0-9_]+) status=([0-9]+) pipe=([0-9 ]*)\n"#)
        let ns = out as NSString
        return regex.matches(in: out, range: NSRange(location: 0, length: ns.length)).map { m in
            HookObservation(
                stage: ns.substring(with: m.range(at: 1)),
                status: ns.substring(with: m.range(at: 2)),
                pipe: ns.substring(with: m.range(at: 3)))
        }
    }

    private static func debugEscape(_ s: String) -> String {
        var out = ""
        for b in s.utf8 {
            if b == 0x1B {
                out += "<ESC>"
            } else if b == 0x0A {
                out += "<LF>"
            } else if b < 0x20 || b > 0x7E {
                out += String(format: "<%02X>", b)
            } else {
                out.append(Character(UnicodeScalar(b)))
            }
        }
        return out
    }

    private func bashVersion(_ bash: URL) -> String {
        let p = Process()
        p.executableURL = bash
        p.arguments = ["--norc", "--noprofile", "-c", #"printf '%s' "$BASH_VERSION""#]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "unknown" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - $? (the Trigger's `false` and `(exit 3)`)

    /// A string `PROMPT_COMMAND='__pc'` whose hook reads `$?` on entry must be
    /// told 1 after `false`, 3 after `(exit 3)` and 0 after `true` -- exactly
    /// what it is told when the integration is absent.
    func test_userPromptCommand_seesTheRealExitStatus_whenOsc133BashIsSourced() throws {
        let script = try locateScript()
        let bashes = installedBashes()
        guard !bashes.isEmpty else { throw XCTSkip("no bash installed at a known path") }

        let triggers: [(stage: String, command: String)] = [
            ("fail1", "false"),
            ("exit3", "(exit 3)"),
            ("okay0", "true"),
        ]
        let expected = ["fail1": "1", "exit3": "3", "okay0": "0"]

        for bash in bashes {
            let label = "\(bash.path) (bash \(bashVersion(bash)))"

            // CONTROL: no integration. Proves the rig observes `$?` faithfully.
            let control = try runInteractiveBash(bash, integration: nil, triggers: triggers)
            for t in triggers {
                let seen = control.observation(t.stage)
                XCTAssertEqual(seen.count, 1,
                    "\(label) CONTROL: hook must fire exactly once for stage \(t.stage); got \(seen). "
                    + "stdout=\(Self.debugEscape(control.stdout))")
                XCTAssertEqual(seen.first?.status, expected[t.stage],
                    "\(label) CONTROL (integration absent): hook after `\(t.command)` must see $?=\(expected[t.stage] ?? "?"); "
                    + "got \(seen.first?.status ?? "nil"). The rig cannot observe $? -- test would be vacuous.")
            }

            // INTEGRATED: osc133.bash sourced after PROMPT_COMMAND was set.
            let integrated = try runInteractiveBash(bash, integration: script, triggers: triggers)

            // Precondition: the integration really engaged and still reports
            // the real exit status to the terminal in its D mark. Guards
            // against a "fix" that merely stops hooking, and against one that
            // restores the user's `$?` by corrupting the D mark.
            XCTAssertTrue(integrated.stdout.contains(Self.escA),
                "\(label): OSC 133;A absent -- the integration did not engage, so the "
                + "assertions below would be vacuous. stdout=\(Self.debugEscape(integrated.stdout))")
            XCTAssertTrue(integrated.stdout.contains(Self.escD + "1"),
                "\(label): OSC 133;D;1 absent after `false` -- the integration must keep reporting the "
                + "real exit status to the terminal. stdout=\(Self.debugEscape(integrated.stdout))")
            XCTAssertTrue(integrated.stdout.contains(Self.escD + "3"),
                "\(label): OSC 133;D;3 absent after `(exit 3)` -- the integration must keep reporting the "
                + "real exit status to the terminal. stdout=\(Self.debugEscape(integrated.stdout))")

            // The bug: the user's hook runs AFTER the integration's own hook
            // and sees that hook's status (0), not the command's.
            for t in triggers {
                let seen = integrated.observation(t.stage)
                XCTAssertEqual(seen.count, 1,
                    "\(label): user's PROMPT_COMMAND must still run exactly once for stage \(t.stage); got \(seen). "
                    + "stdout=\(Self.debugEscape(integrated.stdout))")
                XCTAssertEqual(seen.first?.status, expected[t.stage],
                    "\(label): with osc133.bash sourced, the user's PROMPT_COMMAND after `\(t.command)` must see "
                    + "$?=\(expected[t.stage] ?? "?") (as it does without the integration); "
                    + "it saw \(seen.first?.status ?? "nil"). stdout=\(Self.debugEscape(integrated.stdout))")
            }
        }
    }

    // MARK: - PIPESTATUS

    /// The same hook reading `PIPESTATUS` on entry must see the per-stage
    /// statuses of the last pipeline (`0 1 3` for `true | false | (exit 3)`,
    /// `1 0` for `false | true`), not a single reset element.
    func test_userPromptCommand_seesThePipeStatus_whenOsc133BashIsSourced() throws {
        let script = try locateScript()
        let bashes = installedBashes()
        guard !bashes.isEmpty else { throw XCTSkip("no bash installed at a known path") }

        let triggers: [(stage: String, command: String)] = [
            ("pipeA", "true | false | (exit 3)"),
            ("pipeB", "false | true"),
        ]
        let expectedPipe = ["pipeA": "0 1 3", "pipeB": "1 0"]
        let expectedStatus = ["pipeA": "3", "pipeB": "0"]

        for bash in bashes {
            let label = "\(bash.path) (bash \(bashVersion(bash)))"

            // CONTROL: no integration.
            let control = try runInteractiveBash(bash, integration: nil, triggers: triggers)
            for t in triggers {
                let seen = control.observation(t.stage)
                XCTAssertEqual(seen.count, 1,
                    "\(label) CONTROL: hook must fire exactly once for stage \(t.stage); got \(seen). "
                    + "stdout=\(Self.debugEscape(control.stdout))")
                XCTAssertEqual(seen.first?.pipe, expectedPipe[t.stage],
                    "\(label) CONTROL (integration absent): hook after `\(t.command)` must see "
                    + "PIPESTATUS=(\(expectedPipe[t.stage] ?? "?")); got (\(seen.first?.pipe ?? "nil")). "
                    + "The rig cannot observe PIPESTATUS -- test would be vacuous.")
                XCTAssertEqual(seen.first?.status, expectedStatus[t.stage],
                    "\(label) CONTROL: hook after `\(t.command)` must see $?=\(expectedStatus[t.stage] ?? "?"); "
                    + "got \(seen.first?.status ?? "nil").")
            }

            // INTEGRATED.
            let integrated = try runInteractiveBash(bash, integration: script, triggers: triggers)
            XCTAssertTrue(integrated.stdout.contains(Self.escA),
                "\(label): OSC 133;A absent -- the integration did not engage, so the "
                + "assertions below would be vacuous. stdout=\(Self.debugEscape(integrated.stdout))")
            XCTAssertTrue(integrated.stdout.contains(Self.escD + "3"),
                "\(label): OSC 133;D;3 absent after a pipeline ending in `(exit 3)` -- the integration must keep "
                + "reporting the real exit status to the terminal. stdout=\(Self.debugEscape(integrated.stdout))")

            for t in triggers {
                let seen = integrated.observation(t.stage)
                XCTAssertEqual(seen.count, 1,
                    "\(label): user's PROMPT_COMMAND must still run exactly once for stage \(t.stage); got \(seen). "
                    + "stdout=\(Self.debugEscape(integrated.stdout))")
                XCTAssertEqual(seen.first?.pipe, expectedPipe[t.stage],
                    "\(label): with osc133.bash sourced, the user's PROMPT_COMMAND after `\(t.command)` must see "
                    + "PIPESTATUS=(\(expectedPipe[t.stage] ?? "?")) (as it does without the integration); "
                    + "it saw (\(seen.first?.pipe ?? "nil")). stdout=\(Self.debugEscape(integrated.stdout))")
            }
        }
    }

    // MARK: - set -e, ERR trap, nested shells, quoting
    //
    // Added with the fix for the review findings on the first SCI-2 patch
    // (written by the fixer, not by the blind author): restoring a failed
    // status must not itself behave like a failed command, the wrapped chain
    // must survive a nested shell, and the user's text must round-trip.

    /// An errexit shell must stay alive across the prompt that follows a
    /// failed command. `false && true` is the stock leak: it returns 1 but
    /// errexit exempts it, so the shell lives -- until a prompt hook that
    /// re-raises the status as a real failing command kills it.
    func test_errexitShell_survivesThePrompt_afterAFailedCommand_whenOsc133BashIsSourced() throws {
        let script = try locateScript()
        let bashes = installedBashes()
        guard !bashes.isEmpty else { throw XCTSkip("no bash installed at a known path") }

        let triggers: [(stage: String, command: String)] = [
            ("errexitOn", "set -e"),
            ("andFail", "false && true"),
            ("aliveA", "true"),
            ("aliveB", "true"),
        ]
        let afterFailure = ["andFail", "aliveA", "aliveB"]

        for bash in bashes {
            let label = "\(bash.path) (bash \(bashVersion(bash)))"

            // CONTROL: no integration -- the shell must survive in this rig.
            let control = try runInteractiveBash(bash, integration: nil, triggers: triggers)
            XCTAssertTrue(control.exitedCleanly, "\(label) CONTROL: shell did not exit cleanly via `exit`. "
                + "stdout=\(Self.debugEscape(control.stdout))")
            for stage in afterFailure {
                XCTAssertEqual(control.observation(stage).count, 1,
                    "\(label) CONTROL: hook must fire exactly once for stage \(stage). "
                    + "stdout=\(Self.debugEscape(control.stdout))")
            }

            let integrated = try runInteractiveBash(bash, integration: script, triggers: triggers)
            XCTAssertTrue(integrated.stdout.contains(Self.escA),
                "\(label): OSC 133;A absent -- the integration did not engage. "
                + "stdout=\(Self.debugEscape(integrated.stdout))")
            XCTAssertTrue(integrated.stdout.contains(Self.escD + "1"),
                "\(label): OSC 133;D;1 absent after `false && true`. "
                + "stdout=\(Self.debugEscape(integrated.stdout))")
            XCTAssertTrue(integrated.exitedCleanly,
                "\(label): with osc133.bash sourced the errexit shell did not reach its own `exit` "
                + "(it was killed at a prompt). stdout=\(Self.debugEscape(integrated.stdout))")
            for stage in afterFailure {
                XCTAssertEqual(integrated.observation(stage).count, 1,
                    "\(label): user's PROMPT_COMMAND must still run exactly once for stage \(stage) "
                    + "under `set -e`. stdout=\(Self.debugEscape(integrated.stdout))")
            }
            XCTAssertEqual(integrated.observation("andFail").first?.status, "1",
                "\(label): under `set -e` the user's hook after `false && true` must still see $?=1. "
                + "stdout=\(Self.debugEscape(integrated.stdout))")
        }
    }

    /// A user's ERR trap fires for the failing command itself and nothing
    /// else: the integration must not add firings of its own at the prompt.
    func test_errTrap_firesOnlyForTheFailedCommands_whenOsc133BashIsSourced() throws {
        let script = try locateScript()
        let bashes = installedBashes()
        guard !bashes.isEmpty else { throw XCTSkip("no bash installed at a known path") }

        let triggers: [(stage: String, command: String)] = [
            ("trapOn", #"trap 'printf "ERRTRAP\n"' ERR"#),
            ("failA", "false"),
            ("failB", "false"),
            ("failPipe", "true | false"),
            ("okay", "true"),
        ]
        func firings(_ out: String) -> Int { out.components(separatedBy: "ERRTRAP\n").count - 1 }

        for bash in bashes {
            let label = "\(bash.path) (bash \(bashVersion(bash)))"

            let control = try runInteractiveBash(bash, integration: nil, triggers: triggers)
            let expected = firings(control.stdout)
            XCTAssertEqual(expected, 3,
                "\(label) CONTROL: the ERR trap must fire once per failed command (false, false, true | false). "
                + "The rig cannot observe the trap -- test would be vacuous. stdout=\(Self.debugEscape(control.stdout))")

            let integrated = try runInteractiveBash(bash, integration: script, triggers: triggers)
            XCTAssertTrue(integrated.stdout.contains(Self.escA),
                "\(label): OSC 133;A absent -- the integration did not engage. "
                + "stdout=\(Self.debugEscape(integrated.stdout))")
            XCTAssertEqual(firings(integrated.stdout), expected,
                "\(label): with osc133.bash sourced the ERR trap must fire exactly as often as without it "
                + "(\(expected)); the prompt hook added firings. stdout=\(Self.debugEscape(integrated.stdout))")
            XCTAssertEqual(integrated.observation("failA").first?.status, "1",
                "\(label): user's hook after `false` must still see $?=1. "
                + "stdout=\(Self.debugEscape(integrated.stdout))")
        }
    }

    /// `PROMPT_COMMAND` is usually exported, so a nested interactive bash
    /// (`bash`, `exec bash`, a tmux window) inherits the parent's already
    /// wrapped chain, and its own rc sources the integration again. That must
    /// not wrap the wrapper (an endless eval that once crashed bash 3.2), and
    /// the user's hook must still run, once per prompt, with the real status.
    func test_nestedShell_inheritingTheExportedPromptCommand_keepsTheUsersHookWorking() throws {
        let script = try locateScript()
        let bashes = installedBashes()
        guard !bashes.isEmpty else { throw XCTSkip("no bash installed at a known path") }

        let rcPlain = homeDir.appendingPathComponent("nested-plain.rc")
        let rcIntegrated = homeDir.appendingPathComponent("nested-integrated.rc")
        let rcHead = "unset HISTFILE\n" + Self.hookDefinition + "\n"
        try rcHead.write(to: rcPlain, atomically: true, encoding: .utf8)
        try (rcHead + "source '\(script.path)'\n").write(to: rcIntegrated, atomically: true, encoding: .utf8)

        let triggers: [(stage: String, command: String)] = [
            ("nestFail", "false"),
            ("nestPipe", "true | false | (exit 3)"),
            ("nestOkay", "true"),
        ]
        let expectedStatus = ["nestFail": "1", "nestPipe": "3", "nestOkay": "0"]

        for bash in bashes {
            let label = "\(bash.path) (bash \(bashVersion(bash)))"
            func nested(_ rc: URL) -> [String] { ["exec '\(bash.path)' --rcfile '\(rc.path)' -i"] }

            // CONTROL: exported PROMPT_COMMAND inherited by a nested shell,
            // integration never sourced anywhere.
            let control = try runInteractiveBash(
                bash, integration: nil, triggers: triggers,
                exportPromptCommand: true, afterIntegration: nested(rcPlain))
            XCTAssertTrue(control.exitedCleanly, "\(label) CONTROL: nested shell did not exit cleanly. "
                + "stdout=\(Self.debugEscape(control.stdout))")
            for t in triggers {
                XCTAssertEqual(control.observation(t.stage).first?.status, expectedStatus[t.stage],
                    "\(label) CONTROL: nested hook after `\(t.command)` must see $?=\(expectedStatus[t.stage] ?? "?"). "
                    + "stdout=\(Self.debugEscape(control.stdout))")
            }

            // INTEGRATED: sourced in the parent AND again by the nested rc.
            let integrated = try runInteractiveBash(
                bash, integration: script, triggers: triggers,
                exportPromptCommand: true, afterIntegration: nested(rcIntegrated))
            XCTAssertTrue(integrated.exitedCleanly,
                "\(label): nested shell did not exit cleanly (crash or runaway chain?). "
                + "stdout.count=\(integrated.stdout.utf8.count) "
                + "stdout=\(Self.debugEscape(String(integrated.stdout.prefix(600))))")
            XCTAssertLessThan(integrated.stdout.utf8.count, 16 * 1024,
                "\(label): runaway output from the nested shell's prompt chain.")
            XCTAssertTrue(integrated.stdout.contains(Self.escD + "1"),
                "\(label): OSC 133;D;1 absent after `false` in the nested shell. "
                + "stdout=\(Self.debugEscape(String(integrated.stdout.prefix(600))))")
            for t in triggers {
                let seen = integrated.observation(t.stage)
                XCTAssertEqual(seen.count, 1,
                    "\(label): the user's hook must run exactly once for stage \(t.stage) in the nested shell; got \(seen). "
                    + "stdout=\(Self.debugEscape(String(integrated.stdout.prefix(600))))")
                XCTAssertEqual(seen.first?.status, expectedStatus[t.stage],
                    "\(label): nested hook after `\(t.command)` must see $?=\(expectedStatus[t.stage] ?? "?"); "
                    + "saw \(seen.first?.status ?? "nil").")
            }
            XCTAssertEqual(integrated.observation("nestPipe").first?.pipe, "0 1 3",
                "\(label): nested hook after `true | false | (exit 3)` must see PIPESTATUS=(0 1 3).")
        }
    }

    /// The user's `PROMPT_COMMAND` text is embedded in the chain, so quotes,
    /// `$` and newlines must come back out of it verbatim: it behaves as it
    /// does without the integration.
    func test_userPromptCommand_withQuotesDollarsAndNewlines_runsVerbatim_whenOsc133BashIsSourced() throws {
        let script = try locateScript()
        let bashes = installedBashes()
        guard !bashes.isEmpty else { throw XCTSkip("no bash installed at a known path") }

        // `__pc` first so it still reads the real $?; the second line must
        // print its quoted words untouched. It names the stage so each prompt
        // cycle is counted on its own (sourcing the script adds a prompt
        // cycle that the control run does not have).
        let promptCommand = "__pc\n"
            + #"printf 'QUOTE %s <%s> <%s> <%s>\n' "$__stage" "it's" '$x' "$(echo sub)""#
        let triggers: [(stage: String, command: String)] = [
            ("quoteFail", "false"),
            ("quoteOkay", "true"),
        ]
        func lineCount(_ out: String, stage: String) -> Int {
            out.components(separatedBy: "QUOTE \(stage) <it's> <$x> <sub>\n").count - 1
        }

        for bash in bashes {
            let label = "\(bash.path) (bash \(bashVersion(bash)))"

            let control = try runInteractiveBash(
                bash, integration: nil, triggers: triggers, promptCommand: promptCommand)
            for t in triggers {
                XCTAssertEqual(lineCount(control.stdout, stage: t.stage), 1,
                    "\(label) CONTROL: the second PROMPT_COMMAND line must print once for stage \(t.stage). "
                    + "stdout=\(Self.debugEscape(control.stdout))")
            }

            let integrated = try runInteractiveBash(
                bash, integration: script, triggers: triggers, promptCommand: promptCommand)
            XCTAssertTrue(integrated.stdout.contains(Self.escA),
                "\(label): OSC 133;A absent -- the integration did not engage. "
                + "stdout=\(Self.debugEscape(integrated.stdout))")
            for t in triggers {
                XCTAssertEqual(lineCount(integrated.stdout, stage: t.stage), 1,
                    "\(label): the user's multi-line, quoted PROMPT_COMMAND must run unchanged under the "
                    + "integration (stage \(t.stage)). stdout=\(Self.debugEscape(integrated.stdout))")
            }
            XCTAssertEqual(integrated.observation("quoteFail").first?.status, "1",
                "\(label): hook after `false` must see $?=1. stdout=\(Self.debugEscape(integrated.stdout))")
            XCTAssertEqual(integrated.observation("quoteOkay").first?.status, "0",
                "\(label): hook after `true` must see $?=0. stdout=\(Self.debugEscape(integrated.stdout))")
        }
    }
}
