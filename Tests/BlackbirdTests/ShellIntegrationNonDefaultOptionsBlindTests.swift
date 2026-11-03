import XCTest
import Foundation
import BBCore
@testable import Blackbird

/// Blind regression tests for BUG SCI-8: Blackbird's automatic zsh shell
/// integration (the `ZDOTDIR` bootstrap that is on by default) is not robust
/// to non-default zsh options in the user's own `.zshrc`.
///
/// Observed with a `.zshrc` whose only option line is one of
///
///  * `setopt ksh_arrays`      - an error line (`__bb_load_integration:11:
///                               bad output format specification`) is printed
///                               before the first prompt of every new tab and
///                               the first prompt has no OSC 133;A mark;
///  * `setopt ignorebraces`    - an error line on every tab, no prompt marks;
///  * `emulate sh` / `ksh`     - the same family of error lines, no marks;
///  * `setopt cshjunkiequotes` - an error line and no `ssh` wrapper;
///  * `unsetopt prompt_percent`- a literal `%{%}` junk suffix on the prompt.
///
/// Contract (terminal / shell-integration convention, not Blackbird-specific):
/// shell integration is invisible. Whatever options the user has set, opening
/// a tab must (1) print nothing but the user's own prompt, (2) announce every
/// prompt, the FIRST one included, with exactly one OSC 133;A before its
/// 133;B (Blackbird's prompt ring records only `A` marks), and (3) leave the
/// bundled `ssh` terminfo wrapper installed as a shell function.
///
/// How it is exercised: a REAL interactive `/bin/zsh -i` on a real pty
/// (allocated by the system `script(1)`, so no pty code runs inside the xctest
/// host), wired up exactly as `PTY.spawn` wires an auto-injected zsh -
/// `ShellIntegration.materialize` + `ShellIntegration.envOverrides`,
/// `TERM_PROGRAM=Blackbird`, temp `HOME`. The temp `HOME/.zshrc` holds the
/// option under test plus a fixed `PROMPT='BBPROMPT> '`, so the correct first
/// screen is known exactly.
///
/// Observation is split in two so a test is judged on what the user sees:
///  * the raw byte stream is scanned for OSC 133 marks (kind sequence per
///    prompt), and
///  * the same bytes are fed into a `BBTerm` and the resulting SCREEN text is
///    read back - an error line or `%{%}` junk is visible there, an invisible
///    OSC mark is not.
///
/// Every scenario runs the identical script, and a control scenario (no
/// non-default option) goes through it too, so a rig that cannot observe the
/// prompt or the marks cannot make the others pass or fail vacuously. Rig
/// preconditions (no prompt appeared, shell never exited, ...) throw
/// `RigError` instead of asserting, so they can't be confused with the bug.
///
/// Memory + time pre-flight: each test spawns one `script` + one short-lived
/// zsh (a few MB RSS, ~1.5 s wall: ~0.3 s shell start, two 0.3 s settles) with
/// an empty temp HOME, small pipes, a captured stream well under 4 KB, and a
/// 120x24 `BBTerm` with 100 lines of scrollback (well under 1 MB of cells). No GUI,
/// no network, no `MainWindowController`, no keystroke injection into any
/// terminal other than the throwaway pty owned by the child `script`.
final class ShellIntegrationNonDefaultOptionsBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        // Same host-termination guard every suite in this bundle registers.
        TestHostTermination.shared.register()
    }

    // MARK: - Rig state

    private var tempBase: URL!
    private var homeDir: URL!
    private var materializedRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempBase = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("BBNonDefaultOpts-\(UUID().uuidString)")
        homeDir = tempBase.appendingPathComponent("home")
        materializedRoot = tempBase.appendingPathComponent("root")
        try FileManager.default.createDirectory(at: homeDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempBase { try? FileManager.default.removeItem(at: tempBase) }
        tempBase = nil
        homeDir = nil
        materializedRoot = nil
        try super.tearDownWithError()
    }

    private struct RigError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    // MARK: - Locating things

    /// `Sources/Blackbird/Resources/shell`, anchored on this file's
    /// compile-time path (xcodebuild's CWD is inside DerivedData).
    private func shellResourcesDir(file: String = #filePath) -> URL {
        URL(fileURLWithPath: file)
            .deletingLastPathComponent()  // Tests/BlackbirdTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("Sources/Blackbird/Resources/shell", isDirectory: true)
    }

    private func requireExecutable(_ path: String, because reason: String) throws -> URL {
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw XCTSkip("\(path) not present - \(reason)")
        }
        return URL(fileURLWithPath: path)
    }

    // MARK: - Environment

    /// The environment Blackbird's PTY hands a zsh child when Settings >
    /// Automatic shell integration is on (the default): the SHIPPED bootstrap
    /// materialised into a root and the SHIPPED `envOverrides` result, on top
    /// of a minimal hermetic base (nothing from the outer test runner's shell
    /// config can leak in; temp HOME).
    private func autoInjectedZshEnvironment() -> [String: String] {
        let shellDir = shellResourcesDir()
        let root = ShellIntegration.materialize(
            into: materializedRoot,
            zshenvTemplate: shellDir.appendingPathComponent("zshenv-bootstrap.zsh"),
            fishTemplate: shellDir.appendingPathComponent("fish-vendor-conf.fish"))
        XCTAssertEqual(root, materializedRoot,
            "rig precondition: ShellIntegration.materialize must write the shipped templates under the temp root")
        let overrides = ShellIntegration.envOverrides(
            shellPath: "/bin/zsh", integrationDir: shellDir.path,
            materializedRoot: materializedRoot, parentEnv: [:], enabled: true)
        XCTAssertEqual(Set(overrides.keys), ["ZDOTDIR", "BB_SHELL_INTEGRATION_DIR"],
            "rig precondition: auto-injection for zsh with no parent ZDOTDIR must set exactly ZDOTDIR + BB_SHELL_INTEGRATION_DIR; got \(overrides)")
        var env: [String: String] = [
            "HOME": homeDir.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "TERM": "xterm-256color",
            "COLORTERM": "truecolor",
            "TERM_PROGRAM": "Blackbird",
            "TERM_PROGRAM_VERSION": "0.0.0",
            // macOS's /etc/zshrc restores per-session history through
            // $SHELL_SESSIONS_DIR unless told not to; keep the run hermetic.
            "SHELL_SESSIONS_DISABLE": "1",
        ]
        env.merge(overrides) { (_: String, injected: String) -> String in injected }
        return env
    }

    // MARK: - OSC 133 scanning

    private struct OSCMark: CustomStringConvertible {
        /// The byte after `ESC ] 133 ;` - `A`, `B`, `C` or `D`.
        let kind: Character
        let offset: Int
        var description: String { "\(kind)@\(offset)" }
    }

    /// `ESC ] 1 3 3 ;`
    private static let oscPrefix: [UInt8] = [0x1B, 0x5D, 0x31, 0x33, 0x33, 0x3B]

    /// Every OSC 133 mark in `bytes`, in stream order. Only the kind byte is
    /// read: whether a shell terminates with ST or BEL, or appends `;opts`,
    /// is not what these tests are about.
    private func oscMarks(in bytes: [UInt8]) -> [OSCMark] {
        let prefix = Self.oscPrefix
        var marks: [OSCMark] = []
        var i = 0
        while i + prefix.count < bytes.count {
            if bytes[i] == prefix[0], Array(bytes[i..<(i + prefix.count)]) == prefix {
                marks.append(OSCMark(kind: Character(UnicodeScalar(bytes[i + prefix.count])), offset: i))
                i += prefix.count
            } else {
                i += 1
            }
        }
        return marks
    }

    /// The mark kinds of `bytes` as a space-separated string (`"A B"`),
    /// optionally restricted to a subset of kinds.
    private func kindSequence(in bytes: [UInt8], only: Set<Character>? = nil) -> String {
        var kinds: [String] = []
        for mark in oscMarks(in: bytes) {
            if let only, !only.contains(mark.kind) { continue }
            kinds.append(String(mark.kind))
        }
        return kinds.joined(separator: " ")
    }

    // MARK: - Reading the screen

    /// Printable rendering of captured bytes for assertion messages.
    private func printable(_ bytes: [UInt8], limit: Int = 1600) -> String {
        var out = ""
        var spaceRun = 0
        func flushSpaces() {
            out += spaceRun >= 4 ? "<\(spaceRun) spaces>" : String(repeating: " ", count: spaceRun)
            spaceRun = 0
        }
        for b in bytes {
            if b == 0x20 { spaceRun += 1; continue }
            flushSpaces()
            switch b {
            case 0x1B: out += "\\e"
            case 0x0D: out += "\\r"
            case 0x0A: out += "\\n"
            case 0x07: out += "\\a"
            case 0x08: out += "\\b"
            case 0x00..<0x20, 0x7F: out += String(format: "\\x%02X", b)
            default: out.unicodeScalars.append(UnicodeScalar(b))
            }
        }
        flushSpaces()
        return out.count > limit ? String(out.prefix(limit)) + "..." : out
    }

    /// What the user would SEE after `bytes` were written to a 120x24
    /// terminal: the non-blank screen rows, trailing whitespace trimmed.
    /// Escape sequences (including invisible OSC 133 marks), `PROMPT_SP`'s
    /// reverse-video `%` filler and carriage-return overdraw are all resolved
    /// by a real terminal emulator rather than by string munging.
    private func screenRows(after bytes: [UInt8]) throws -> [String] {
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 120, rows: 24), scrollback: 100),
            "rig precondition: BBTerm(120x24) must construct")
        defer { term.terminate() }
        term.input(bytes)
        let snapshot = try XCTUnwrap(term.snapshot(), "rig precondition: BBTerm must produce a snapshot")
        return snapshot.visibleRowsAsText()
            .map { $0.trimmingTrailingWhitespace() }
            .filter { !$0.isEmpty }
    }

    // MARK: - Running the shell

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return condition()
    }

    private func forceStop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        Thread.sleep(forTimeInterval: 0.1)
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    /// Thread-safe growing byte buffer fed by a `readabilityHandler`.
    private final class SessionBytes: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [UInt8] = []
        private var sawEOF = false
        func append(_ data: Data) {
            lock.lock(); storage.append(contentsOf: data); lock.unlock()
        }
        func markEOF() {
            lock.lock(); sawEOF = true; lock.unlock()
        }
        var snapshot: [UInt8] {
            lock.lock(); defer { lock.unlock() }
            return storage
        }
        var reachedEOF: Bool {
            lock.lock(); defer { lock.unlock() }
            return sawEOF
        }
    }

    /// Everything one interactive session wrote, cut at the two points where
    /// the rig was idle at a prompt.
    private struct Session {
        /// Bytes written before ANYTHING was typed: the first prompt and
        /// whatever preceded it.
        let firstPrompt: [UInt8]
        /// Bytes written between the first settle and the second settle:
        /// the typed command's output and the second prompt.
        let secondPrompt: [UInt8]
        /// Whole stream up to the end of the second prompt.
        let throughSecondPrompt: [UInt8]
        /// Whole stream including the `exit`.
        let all: [UInt8]
    }

    /// The prompt every scenario's `.zshrc` installs. No `%` or `$`, so it
    /// expands to itself under any combination of prompt options.
    private static let promptText = "BBPROMPT> "
    private static let promptNeedle: [UInt8] = Array("BBPROMPT>".utf8)
    private static let sshProbeCommand = "whence -w ssh"

    private func indexOf(_ needle: [UInt8], in haystack: [UInt8], from start: Int = 0) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count, start <= haystack.count - needle.count else {
            return nil
        }
        var i = start
        while i <= haystack.count - needle.count {
            if haystack[i] == needle[0], Array(haystack[i..<(i + needle.count)]) == needle { return i }
            i += 1
        }
        return nil
    }

    /// Run an auto-injected interactive `/bin/zsh -i` whose `.zshrc` is
    /// `zshrc`, through two prompts: wait (expect-style, never by fixed
    /// delay alone) for the first prompt text, let the shell go idle, type
    /// `whence -w ssh`, wait for its output and the second prompt text, idle
    /// again, `exit`.
    private func runSession(zshrc: String) throws -> Session {
        _ = try requireExecutable("/bin/zsh", because: "cannot exercise zsh integration")
        let script = try requireExecutable("/usr/bin/script", because: "needed to give zsh a real pty")
        try zshrc.write(to: homeDir.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        let env = autoInjectedZshEnvironment()

        let process = Process()
        process.executableURL = script
        process.arguments = ["-q", "/dev/null", "/bin/zsh", "-i"]
        process.environment = env
        process.currentDirectoryURL = homeDir
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        let sink = SessionBytes()
        stdout.fileHandleForReading.readabilityHandler = { (handle: FileHandle) -> Void in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                sink.markEOF()
            } else {
                sink.append(data)
            }
        }

        // Writing to a pipe whose reader has exited must fail with EPIPE, not
        // deliver SIGPIPE to (and kill) the xctest host.
        let inputFD = stdin.fileHandleForWriting.fileDescriptor
        _ = Darwin.fcntl(inputFD, F_SETNOSIGPIPE, 1)
        func send(_ text: String) {
            let bytes = Array(text.utf8)
            bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Void in
                _ = Darwin.write(inputFD, raw.baseAddress, raw.count)
            }
        }
        func transcript() -> String { printable(sink.snapshot) }

        try process.run()
        defer {
            stdout.fileHandleForReading.readabilityHandler = nil
            forceStop(process)
        }

        // First prompt on screen <=> the fixed prompt text has been written.
        // (Not a 133;B mark: in the buggy configurations marks may be absent
        // altogether, and that must surface as an assertion, not a rig error.)
        let needle = Self.promptNeedle
        guard waitUntil(timeout: 20, { self.indexOf(needle, in: sink.snapshot) != nil }) else {
            throw RigError("rig precondition: the first prompt (\(Self.promptText)) never appeared within 20 s. Captured: \(transcript())")
        }
        Thread.sleep(forTimeInterval: 0.3)  // zle goes idle; any trailing prompt bytes land
        let firstEnd = sink.snapshot.count
        send(Self.sshProbeCommand + "\n")

        // Second prompt on screen <=> the probe's `ssh: <kind>` output has
        // been written and the prompt text follows it.
        let sshOutput = Array("ssh: ".utf8)
        guard waitUntil(timeout: 20, {
            let bytes = sink.snapshot
            guard let at = self.indexOf(sshOutput, in: bytes, from: firstEnd) else { return false }
            return self.indexOf(needle, in: bytes, from: at) != nil
        }) else {
            throw RigError("rig precondition: no `ssh: ...` output followed by a second prompt within 20 s of sending `\(Self.sshProbeCommand)`. Captured: \(transcript())")
        }
        Thread.sleep(forTimeInterval: 0.3)
        let secondEnd = sink.snapshot.count
        send("exit\n")

        guard waitUntil(timeout: 20, { !process.isRunning }) else {
            throw RigError("rig precondition: interactive zsh did not exit within 20 s after `exit`. Captured: \(transcript())")
        }
        guard waitUntil(timeout: 5, { sink.reachedEOF }) else {
            throw RigError("rig precondition: terminal output never reached EOF after the shell exited. Captured: \(transcript())")
        }
        let all = sink.snapshot
        return Session(
            firstPrompt: Array(all[..<firstEnd]),
            secondPrompt: Array(all[firstEnd..<secondEnd]),
            throughSecondPrompt: Array(all[..<secondEnd]),
            all: all)
    }

    // MARK: - The contract, shared by every scenario

    /// `optionLines` is the non-default configuration under test (empty for
    /// the control); the fixed prompt is appended after it, as a real
    /// `.zshrc` sets its prompt after its options.
    private func assertIntegrationIsInvisibleAndComplete(
        optionLines: [String], scenario: String
    ) throws {
        let zshrc = (optionLines + ["PROMPT='\(Self.promptText)'"]).joined(separator: "\n") + "\n"
        let session = try runSession(zshrc: zshrc)
        let raw = printable(session.all)
        let config = optionLines.isEmpty ? "(no non-default option)" : optionLines.joined(separator: "; ")

        // Control that the rig sees the prompt at all.
        let firstScreen = try screenRows(after: session.firstPrompt)
        XCTAssertEqual(firstScreen.filter { $0.contains("BBPROMPT>") }.count, 1,
            "rig precondition [\(scenario)]: the first screen must show the prompt exactly once. Screen: \(firstScreen). Captured: \(raw)")

        // 1. Integration prints nothing of its own: the first screen is the
        //    user's prompt and nothing else - no diagnostic line above it, no
        //    `%{%}` junk after it.
        XCTAssertEqual(firstScreen, ["BBPROMPT>"],
            "[\(scenario): \(config)] a new tab's first screen must be exactly the user's prompt - no error line before it, no junk after it. Screen rows: \(firstScreen). Captured: \(raw)")

        // 2. The first prompt is announced by one 133;A and closed by one
        //    133;B, in that order.
        XCTAssertEqual(kindSequence(in: session.firstPrompt), "A B",
            "[\(scenario): \(config)] the first prompt must carry exactly one 133;A followed by exactly one 133;B. Marks before the first command: [\(kindSequence(in: session.firstPrompt))]. Captured: \(raw)")

        // 3. Steady state: the next prompt is announced and closed the same
        //    way (C/D marks for the probe command may surround them).
        XCTAssertEqual(kindSequence(in: session.secondPrompt, only: ["A", "B"]), "A B",
            "[\(scenario): \(config)] the second prompt must carry exactly one 133;A followed by exactly one 133;B. All marks of the second cycle: [\(kindSequence(in: session.secondPrompt))]. Captured: \(raw)")

        let secondScreen = try screenRows(after: session.throughSecondPrompt)
        XCTAssertEqual(secondScreen.last, "BBPROMPT>",
            "[\(scenario): \(config)] the last screen row after the second prompt must be exactly the user's prompt (no `%{%}` junk). Screen rows: \(secondScreen). Captured: \(raw)")

        // 4. The ssh terminfo wrapper is installed as a shell function.
        let sshRows = secondScreen.filter { $0.hasPrefix("ssh: ") }
        XCTAssertEqual(sshRows, ["ssh: function"],
            "[\(scenario): \(config)] `whence -w ssh` must report the bundled wrapper as a function (not the bare /usr/bin/ssh binary). Screen rows: \(secondScreen). Captured: \(raw)")
    }

    // MARK: - Control

    /// Control: stock options go through the exact same script and must be
    /// clean. If this fails, the rig (not the option handling) is broken.
    func test_control_defaultOptions_firstScreenIsJustThePrompt_andAllPromptsAreMarked() throws {
        try assertIntegrationIsInvisibleAndComplete(optionLines: [], scenario: "control")
    }

    // MARK: - The regression and its siblings

    /// The headline regression: `setopt ksh_arrays` made the first-prompt
    /// announce print `__bb_load_integration:11: bad output format
    /// specification` before the first prompt of every new tab and dropped
    /// the first prompt's 133;A.
    func test_kshArrays_noErrorLineBeforeFirstPrompt_andFirstPromptIsMarked() throws {
        try assertIntegrationIsInvisibleAndComplete(
            optionLines: ["setopt ksh_arrays"], scenario: "ksh_arrays")
    }

    /// `setopt ignorebraces` broke parsing of the integration script: an
    /// error line on every tab and no prompt marks at all.
    func test_ignoreBraces_noErrorLine_andPromptsAreMarked() throws {
        try assertIntegrationIsInvisibleAndComplete(
            optionLines: ["setopt ignorebraces"], scenario: "ignorebraces")
    }

    /// `emulate sh` (which turns on ignorebraces, ksh_arrays and others, and
    /// turns prompt_percent off): error lines on every tab, no marks.
    func test_emulateSh_noErrorLine_andPromptsAreMarked() throws {
        try assertIntegrationIsInvisibleAndComplete(
            optionLines: ["emulate sh"], scenario: "emulate sh")
    }

    /// `emulate ksh`: same family as `emulate sh`.
    func test_emulateKsh_noErrorLine_andPromptsAreMarked() throws {
        try assertIntegrationIsInvisibleAndComplete(
            optionLines: ["emulate ksh"], scenario: "emulate ksh")
    }

    /// `setopt cshjunkiequotes` broke parsing of the ssh wrapper: an error
    /// line on the first prompt and no `ssh` function afterwards.
    func test_cshJunkieQuotes_noErrorLine_andSshWrapperIsInstalled() throws {
        try assertIntegrationIsInvisibleAndComplete(
            optionLines: ["setopt cshjunkiequotes"], scenario: "cshjunkiequotes")
    }

    /// `unsetopt prompt_percent` left a literal `%{%}` (the zero-width
    /// wrapper the integration appends to the prompt to carry the 133;B
    /// mark) visible after every prompt.
    func test_promptPercentOff_promptHasNoLiteralJunkSuffix() throws {
        try assertIntegrationIsInvisibleAndComplete(
            optionLines: ["unsetopt prompt_percent"], scenario: "prompt_percent off")
    }
}
