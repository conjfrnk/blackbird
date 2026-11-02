import XCTest
import Foundation
import BBCore
@testable import Blackbird

/// Blind regression tests for BUG SCI-4: in a Blackbird tab whose shell was
/// set up by AUTOMATIC shell integration (zsh via `ZDOTDIR`, fish via an
/// `XDG_DATA_DIRS` vendor conf), the FIRST prompt of the session is drawn
/// without an OSC 133;A (prompt-start) mark, although it does carry the
/// 133;B (command-start) mark and every LATER prompt carries both.
///
/// Contract (OSC 133 / FinalTerm "semantic prompt" convention, not
/// Blackbird-specific): a shell that reports prompts emits `A` before it
/// draws each prompt and `B` after the prompt text, once per prompt, from
/// the first prompt of the session on. Blackbird's `PromptNavigator` records
/// ONLY `A` marks into the prompt ring that backs jump-to-previous/next-
/// prompt, so a prompt without an `A` is simply not a jump target.
///
/// What is exercised (all through the SHIPPED templates, wired up exactly as
/// `PTY.spawn` wires them: `ShellIntegration.materialize` +
/// `ShellIntegration.envOverrides`, `TERM_PROGRAM=Blackbird`):
///
///  1. `test_interactiveZsh_*` - a REAL interactive `/bin/zsh -i` on a real
///     pseudo-terminal (allocated by the system `script(1)` so no pty code
///     runs inside the xctest host), driven with one command and `exit`.
///     The captured byte stream is split at the first 133;C (the command
///     starting), so "everything before it" is the first prompt.
///  2. `test_interactiveZsh_promptRingSeesEveryPrompt` - the same stream fed
///     into a `BBTerm`; the number of `.promptStart` events (what the prompt
///     ring consumes) must equal the number of prompts drawn (`.commandStart`
///     events).
///  3. `test_hookCycle_*` - tty-free variant of (1): `zsh -i -c` firing
///     `precmd_functions` / `preexec_functions` by hand, the same technique
///     `ShellIntegrationBootstrapTests` uses. Fast, and independent of
///     `script(1)` behaving.
///  4. `test_fish3_*` - the fish analogue, driven through the first
///     `fish_prompt` event. fish >= 4 emits its own native OSC 133;A at
///     every prompt, which masks the gap in a real session, so this test
///     only runs on fish 3.x and is skipped (not passed) otherwise.
///
/// Every scenario asserts its own controls: the SECOND prompt must show
/// exactly one `A` and one `B` (so a rig that cannot observe marks can't make
/// the main assertion pass or fail vacuously), and the first prompt must
/// show its `B` (so "integration never loaded" can't masquerade as the bug).
///
/// Memory + time pre-flight: each test spawns at most one `script` + one
/// short-lived shell (a few MB RSS, 100-500 ms wall) with an empty temp
/// HOME, small pipes and a captured stream well under 4 KB. No GUI, no
/// network, no `MainWindowController`, no keystroke injection into any
/// terminal other than the throwaway pty owned by the child `script`.
final class ShellIntegrationFirstPromptMarkBlindTests: XCTestCase {

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
            .appendingPathComponent("BBFirstPromptMark-\(UUID().uuidString)")
        homeDir = tempBase.appendingPathComponent("home")
        materializedRoot = tempBase.appendingPathComponent("root")
        try FileManager.default.createDirectory(
            at: homeDir.appendingPathComponent(".config/fish"), withIntermediateDirectories: true)
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

    private func requireFish() throws -> URL {
        for path in ["/opt/homebrew/bin/fish", "/usr/local/bin/fish", "/usr/bin/fish", "/bin/fish"]
        where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        throw XCTSkip("fish not installed (not a regression - fish is optional on macOS)")
    }

    // MARK: - Environments

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
        env.merge(overrides) { _, injected in injected }
        return env
    }

    private func fishBaseEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for key in Array(env.keys)
        where key.hasPrefix("BB_") || key.hasPrefix("XDG_") || key.hasPrefix("__fish") || key.hasPrefix("fish_") {
            env.removeValue(forKey: key)
        }
        env["HOME"] = homeDir.path
        env["XDG_CONFIG_HOME"] = homeDir.appendingPathComponent(".config").path
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "Blackbird"
        env["TERM_PROGRAM_VERSION"] = "0.0.0"
        return env
    }

    private func autoInjectedFishEnvironment(fish: URL) -> [String: String] {
        let shellDir = shellResourcesDir()
        let root = ShellIntegration.materialize(
            into: materializedRoot,
            zshenvTemplate: shellDir.appendingPathComponent("zshenv-bootstrap.zsh"),
            fishTemplate: shellDir.appendingPathComponent("fish-vendor-conf.fish"))
        XCTAssertEqual(root, materializedRoot,
            "rig precondition: ShellIntegration.materialize must write the shipped templates under the temp root")
        let overrides = ShellIntegration.envOverrides(
            shellPath: fish.path, integrationDir: shellDir.path,
            materializedRoot: materializedRoot, parentEnv: [:], enabled: true)
        XCTAssertEqual(Set(overrides.keys), ["XDG_DATA_DIRS", "BB_SHELL_INTEGRATION_DIR"],
            "rig precondition: auto-injection for fish must set exactly XDG_DATA_DIRS + BB_SHELL_INTEGRATION_DIR; got \(overrides)")
        var env = fishBaseEnvironment()
        env.merge(overrides) { _, injected in injected }
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

    private func kinds(_ marks: [OSCMark]) -> String {
        marks.map { String($0.kind) }.joined(separator: " ")
    }

    private func count(_ kind: Character, in marks: [OSCMark]) -> Int {
        marks.filter { $0.kind == kind }.count
    }

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

    /// OSC 133 marks printed between `BBCYCLE<n>BEGIN` and `BBCYCLE<n>END`.
    private func cycleMarks(_ n: Int, in out: String) throws -> [OSCMark] {
        let begin = "BBCYCLE\(n)BEGIN", end = "BBCYCLE\(n)END"
        guard let b = out.range(of: begin),
              let e = out.range(of: end, range: b.upperBound..<out.endIndex)
        else {
            throw RigError("rig precondition: cycle \(n) markers missing from output: \(printable(Array(out.utf8)))")
        }
        return oscMarks(in: Array(out[b.upperBound..<e.lowerBound].utf8))
    }

    // MARK: - Running processes

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

    /// Run `executable` with stdin = /dev/null and return its stdout. Output
    /// is a few hundred bytes so reading after exit cannot deadlock on a full
    /// pipe. 20 s wall budget (other builds may be running on the host; a
    /// real hang is still a failure).
    private func runToCompletion(
        _ executable: URL, args: [String], env: [String: String], timeout: TimeInterval = 20
    ) throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = args
        process.environment = env
        process.currentDirectoryURL = homeDir
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        if !waitUntil(timeout: timeout, { !process.isRunning }) {
            forceStop(process)
            throw RigError("\(executable.lastPathComponent) \(args) did not exit within \(timeout)s")
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
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

    /// Drive a REAL interactive `/bin/zsh -i` (auto-injected, as in a
    /// Blackbird tab) through two prompts and return every byte it wrote to
    /// its terminal.
    ///
    /// The pty is allocated by `/usr/bin/script -q /dev/null ...` (separate
    /// process), so zsh has a controlling terminal, a real line editor and
    /// real prompt rendering while this process only ever sees two pipes.
    /// Expect-style: input is sent only after the previous prompt's `B`
    /// mark has been SEEN, so the stream is the same on a slow host.
    private func captureInteractiveZshSession() throws -> [UInt8] {
        _ = try requireExecutable("/bin/zsh", because: "cannot exercise zsh integration")
        let script = try requireExecutable("/usr/bin/script", because: "needed to give zsh a real pty")
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
        stdout.fileHandleForReading.readabilityHandler = { handle in
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
            bytes.withUnsafeBytes { _ = Darwin.write(inputFD, $0.baseAddress, $0.count) }
        }
        func transcript() -> String { printable(sink.snapshot) }
        func bCount() -> Int { count("B", in: oscMarks(in: sink.snapshot)) }

        try process.run()
        defer {
            stdout.fileHandleForReading.readabilityHandler = nil
            forceStop(process)
        }

        // First prompt on screen <=> its B mark has arrived.
        guard waitUntil(timeout: 20, { bCount() >= 1 }) else {
            throw RigError("rig precondition: no 133;B mark (no first prompt) within 20 s. Captured: \(transcript())")
        }
        Thread.sleep(forTimeInterval: 0.15)  // let zle finish switching the tty to raw mode
        send("echo BB_FIRST_PROMPT_COMMAND\n")

        // Second prompt on screen <=> a second B mark.
        guard waitUntil(timeout: 20, { bCount() >= 2 }) else {
            throw RigError("rig precondition: no second prompt (second 133;B) within 20 s after sending a command. Captured: \(transcript())")
        }
        Thread.sleep(forTimeInterval: 0.15)
        send("exit\n")

        guard waitUntil(timeout: 20, { !process.isRunning }) else {
            throw RigError("rig precondition: interactive zsh did not exit within 20 s after `exit`. Captured: \(transcript())")
        }
        guard waitUntil(timeout: 5, { sink.reachedEOF }) else {
            throw RigError("rig precondition: terminal output never reached EOF after the shell exited. Captured: \(transcript())")
        }
        return sink.snapshot
    }

    // MARK: - 1. Real interactive zsh: the first prompt's marks

    /// The bug, observed the way a user hits it: open a Blackbird zsh tab,
    /// look at the very first prompt. It must be announced by exactly one
    /// 133;A, before its 133;B - same as every later prompt.
    func test_interactiveZsh_firstPrompt_carriesPromptStartBeforeCommandStart() throws {
        let bytes = try captureInteractiveZshSession()
        let marks = oscMarks(in: bytes)
        let transcript = printable(bytes)
        let sequence = kinds(marks)

        // Prompt boundaries: 133;C is emitted when a command starts running,
        // so everything before the first C is the first prompt, and
        // everything between the first and second C is the second prompt.
        let cIndices = marks.indices.filter { marks[$0].kind == "C" }
        XCTAssertGreaterThanOrEqual(cIndices.count, 2,
            "rig precondition: both typed commands (echo, exit) must produce a 133;C. Marks: [\(sequence)]. Captured: \(transcript)")
        guard cIndices.count >= 2 else { return }
        let firstPrompt = Array(marks[..<cIndices[0]])
        let secondPrompt = Array(marks[cIndices[0]..<cIndices[1]])

        // Controls: the integration is engaged, and in the steady state a
        // prompt is announced by exactly one A and closed by exactly one B.
        XCTAssertEqual(count("B", in: secondPrompt), 1,
            "control: the second prompt must carry exactly one 133;B. Marks: [\(sequence)]. Captured: \(transcript)")
        XCTAssertEqual(count("A", in: secondPrompt), 1,
            "control: the second prompt must carry exactly one 133;A. Marks: [\(sequence)]. Captured: \(transcript)")
        XCTAssertEqual(count("B", in: firstPrompt), 1,
            "precondition: the first prompt must carry its 133;B (otherwise the integration did not engage at all). Marks: [\(sequence)]. Captured: \(transcript)")

        // The bug.
        let beforeFirstB = firstPrompt.prefix { $0.kind != "B" }
        XCTAssertEqual(count("A", in: Array(beforeFirstB)), 1,
            "the first prompt must be announced by exactly one 133;A BEFORE its 133;B. Marks before the first command: [\(kinds(firstPrompt))]; whole session: [\(sequence)]. Captured: \(transcript)")
        XCTAssertEqual(count("A", in: firstPrompt), 1,
            "the first prompt must carry exactly one 133;A in total (no duplicates, which would register two prompt-ring entries). Marks before the first command: [\(kinds(firstPrompt))]; whole session: [\(sequence)]")
    }

    // MARK: - 2. Real interactive zsh: what the prompt ring would record

    /// Same session, judged by the consumer: feed the terminal output into a
    /// `BBTerm` and count the `.promptStart` events (the only mark kind
    /// `PromptNavigator` turns into a jump target). Every prompt that was
    /// drawn (each draws one `.commandStart`) must have produced one.
    func test_interactiveZsh_promptRingSeesEveryPrompt() throws {
        let bytes = try captureInteractiveZshSession()
        let term = try XCTUnwrap(BBTerm(size: .init(cols: 80, rows: 24)),
            "rig precondition: BBTerm(80x24) must construct")
        var events: [BBTerm.PromptMarkKind] = []
        term.onEvent { event in
            if case .promptMark(let kind, _) = event { events.append(kind) }
        }
        term.input(bytes)

        let starts = events.filter { $0 == .promptStart }.count
        let commandStarts = events.filter { $0 == .commandStart }.count
        let sequence = events.map { "\($0)" }.joined(separator: " ")

        XCTAssertEqual(commandStarts, 2,
            "rig precondition: the session drew exactly two prompts (before `echo` and before `exit`). Events: [\(sequence)]. Captured: \(printable(bytes))")
        XCTAssertEqual(starts, commandStarts,
            "every drawn prompt must be recorded as a prompt-ring entry: expected \(commandStarts) .promptStart events, got \(starts). Events: [\(sequence)]. Captured: \(printable(bytes))")
    }

    // MARK: - 3. tty-free hook cycle

    /// tty-free variant: fire the hook arrays the way zsh does around a
    /// prompt (`precmd_functions` once per prompt, `preexec_functions` before
    /// a command). zsh snapshots a hook array before calling into it, so
    /// `for f in $precmd_functions` is the faithful model of one prompt
    /// cycle. The first cycle is where the bootstrap's one-shot loader
    /// pulls the integration in.
    func test_hookCycle_firstPrecmdOfAutoInjectedZsh_emitsPromptStart() throws {
        let zsh = try requireExecutable("/bin/zsh", because: "cannot exercise zsh integration")
        let driverURL = tempBase.appendingPathComponent("driver.zsh")
        try """
        print -rn -- BBCYCLE1BEGIN
        for f in $precmd_functions; do "$f"; done
        print -rn -- BBCYCLE1END
        for f in $preexec_functions; do "$f" 'true' 'true' 'true'; done
        print -rn -- BBCYCLE2BEGIN
        for f in $precmd_functions; do "$f"; done
        print -rn -- BBCYCLE2END
        """.write(to: driverURL, atomically: true, encoding: .utf8)

        let out = try runToCompletion(
            zsh, args: ["-i", "-c", "source '\(driverURL.path)'"], env: autoInjectedZshEnvironment())

        let first = try cycleMarks(1, in: out)
        let second = try cycleMarks(2, in: out)
        let raw = printable(Array(out.utf8))

        XCTAssertEqual(count("A", in: second), 1,
            "control: a steady-state precmd cycle must emit exactly one 133;A (this also proves the integration loaded). Cycle 2 marks: [\(kinds(second))]. Captured: \(raw)")
        XCTAssertEqual(count("A", in: first), 1,
            "the very first precmd cycle (the first prompt of the session) must emit exactly one 133;A. Cycle 1 marks: [\(kinds(first))]; cycle 2 marks: [\(kinds(second))]. Captured: \(raw)")
    }

    // MARK: - 4. fish 3.x

    private func fishMajorVersion(_ fish: URL) throws -> Int {
        let out = try runToCompletion(fish, args: ["--version"], env: fishBaseEnvironment())
        guard let range = out.range(of: #"\d+"#, options: .regularExpression),
              let major = Int(out[range])
        else {
            throw XCTSkip("could not parse `fish --version` output: \(out)")
        }
        return major
    }

    /// fish analogue of (3): the first `fish_prompt` event of a session
    /// loads the integration; the prompt drawn right after it must already
    /// be announced by an `A`. Skipped on fish >= 4, whose native OSC 133
    /// marks (including `A`) mask the gap in a real session.
    func test_fish3_autoInjected_firstPromptEvent_emitsPromptStart() throws {
        let fish = try requireFish()
        let major = try fishMajorVersion(fish)
        try XCTSkipIf(major >= 4,
            "fish \(major).x emits its own native OSC 133;A at every prompt, which masks the missing first integration mark in a real session; only fish 3.x shows the bug")

        // One prompt cycle = the `fish_prompt` event (what the integration
        // hooks) followed by painting the prompt (what carries `B`).
        let script = """
        printf BBCYCLE1BEGIN
        emit fish_prompt
        fish_prompt
        printf BBCYCLE1END
        printf BBCYCLE2BEGIN
        emit fish_prompt
        fish_prompt
        printf BBCYCLE2END
        """
        let out = try runToCompletion(fish, args: ["-ic", script], env: autoInjectedFishEnvironment(fish: fish))

        let first = try cycleMarks(1, in: out)
        let second = try cycleMarks(2, in: out)
        let raw = printable(Array(out.utf8))

        XCTAssertEqual(count("A", in: second), 1,
            "control: a steady-state fish prompt cycle must emit exactly one 133;A. Cycle 2 marks: [\(kinds(second))]. Captured: \(raw)")
        XCTAssertEqual(count("B", in: first), 1,
            "precondition: the first fish prompt must carry its 133;B (integration engaged). Cycle 1 marks: [\(kinds(first))]. Captured: \(raw)")
        XCTAssertEqual(count("A", in: first), 1,
            "the first fish prompt must be announced by exactly one 133;A. Cycle 1 marks: [\(kinds(first))]; cycle 2 marks: [\(kinds(second))]. Captured: \(raw)")
    }
}
