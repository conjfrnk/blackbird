import XCTest
import Foundation
@testable import Blackbird

/// Blind regression tests for BUG SCI-1: with Blackbird's fish shell
/// integration loaded, every fish prompt sees `$status == 0` and
/// `$pipestatus == 0` instead of the exit status of the command that just
/// ran.
///
/// Contract (fish convention, not Blackbird-specific): when fish paints a
/// prompt it calls the `fish_prompt` function with `$status` / `$pipestatus`
/// still holding the result of the LAST command line. The stock prompt reads
/// them on entry to print `[1]` (or `[0|3|0]` for a pipeline); themes such as
/// tide, starship and pure read them to colour the prompt red. Shell
/// integration may add marks around the prompt, but it must be transparent to
/// those variables — a failed command must still look failed in the prompt.
///
/// Two entry points are covered, because they are the two ways the bug is
/// reachable:
///
///  1. Auto-injection (the default for every Blackbird fish user): the
///     shipped `fish-vendor-conf.fish` is materialised under an
///     `XDG_DATA_DIRS` root exactly as `PTY.spawn` does it
///     (`ShellIntegration.materialize` + `ShellIntegration.envOverrides`),
///     then a real `fish -i -c` starts, the first `fish_prompt` event fires
///     (that is when the vendor conf loads the integration), a command
///     fails, and the next prompt is rendered.
///  2. Hand-sourced: a pre-existing `fish_prompt` is defined, the shipped
///     `osc133.fish` is `source`d, a command fails, the prompt is rendered.
///
/// Every scenario also runs a CONTROL (same fish, same prompt, integration
/// absent) and asserts the control reports the true status, so a harness that
/// cannot observe `$status` at all can't make these pass or fail vacuously.
/// The integrated run additionally asserts that the integration really
/// engaged (the OSC 133;B mark is present), so "integration silently didn't
/// load" can't masquerade as a pass.
///
/// Status through event handlers needs no test here: real fish saves and
/// restores `$status` around `--on-event` handlers (verified against an
/// interactive fish on a PTY), so the only place a prompt's status can be
/// lost is in the code that runs as part of rendering the prompt itself.
///
/// Memory + time pre-flight: each scenario spawns two short-lived fish
/// processes (~10 MB RSS, ~100-300 ms each) with a nil stdin and two small
/// pipes; the output is a few hundred bytes. No PTY, no GUI, no network, one
/// throwaway temp tree (< 10 KB). Skips cleanly when fish is not installed.
final class FishPromptStatusBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        // Same host-termination guard every suite in this bundle registers.
        TestHostTermination.shared.register()
    }

    // MARK: - Rig

    private var tempBase: URL!
    private var homeDir: URL!
    private var materializedRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempBase = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("BBFishPromptStatus-\(UUID().uuidString)")
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

    /// `Sources/Blackbird/Resources/shell`, anchored on this file's
    /// compile-time path (xcodebuild's CWD is inside DerivedData).
    private func shellResourcesDir(file: String = #filePath) -> URL {
        URL(fileURLWithPath: file)
            .deletingLastPathComponent()  // Tests/BlackbirdTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("Sources/Blackbird/Resources/shell", isDirectory: true)
    }

    private func requireFish() throws -> URL {
        for path in ["/opt/homebrew/bin/fish", "/usr/local/bin/fish", "/usr/bin/fish", "/bin/fish"]
        where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        throw XCTSkip("fish not installed (not a regression — fish is optional on macOS)")
    }

    /// Hermetic environment: the real process env minus anything that could
    /// steer fish or Blackbird's integration (`BB_*` is scrubbed by the PTY
    /// child setup in production too), with HOME / XDG_CONFIG_HOME pointed at
    /// the temp tree so no real user config is read or written.
    private func baseEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for key in Array(env.keys)
        where key.hasPrefix("BB_") || key.hasPrefix("XDG_") || key.hasPrefix("__fish") || key.hasPrefix("fish_") {
            env.removeValue(forKey: key)
        }
        env["HOME"] = homeDir.path
        env["XDG_CONFIG_HOME"] = homeDir.appendingPathComponent(".config").path
        // What `PTY`'s child setup exports to every shell it spawns; the
        // vendor conf can legitimately key off these, so omitting them would
        // test a session Blackbird never creates.
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "Blackbird"
        env["TERM_PROGRAM_VERSION"] = "0.0.0"
        return env
    }

    /// The environment Blackbird's PTY hands a fish child when Settings >
    /// Automatic shell integration is on (the default): the SHIPPED vendor
    /// conf materialised into a root, and the SHIPPED `envOverrides` result.
    private func autoInjectedEnvironment(fish: URL) -> [String: String] {
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
        var env = baseEnvironment()
        env.merge(overrides) { _, injected in injected }
        return env
    }

    /// Install a user `fish_prompt` the way a user's `config.fish` would:
    /// defined BEFORE the integration loads. It reads `$status` and
    /// `$pipestatus` as its very first action (one `set`, so both are
    /// captured before `set` itself overwrites them) and prints them
    /// comma-joined: status first, then every pipestatus element.
    private func installUserPrompt() throws {
        let config = """
        function fish_prompt
            set -l saved $status $pipestatus
            printf 'PS<%s>' (string join , $saved)
        end
        """
        try config.write(
            to: homeDir.appendingPathComponent(".config/fish/config.fish"),
            atomically: true, encoding: .utf8)
    }

    // MARK: - Running fish

    private struct FishRun {
        let stdout: String
        let stderr: String
        let exitStatus: Int32
    }

    /// Run fish with `args`, stdin = /dev/null, 20 s wall budget (other
    /// builds may be running on the host; a real hang is still a failure).
    private func runFish(_ fish: URL, args: [String], env: [String: String]) throws -> FishRun {
        let process = Process()
        process.executableURL = fish
        process.arguments = args
        process.environment = env
        process.currentDirectoryURL = homeDir
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()

        let deadline = Date().addingTimeInterval(20.0)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.1)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            XCTFail("fish \(args) hung — expected a sub-second run")
        }
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        let err = stderr.fileHandleForReading.readDataToEndOfFile()
        return FishRun(
            stdout: String(decoding: out, as: UTF8.self),
            stderr: String(decoding: err, as: UTF8.self),
            exitStatus: process.terminationStatus)
    }

    // MARK: - Scenario

    private enum Integration {
        /// No integration at all — fish exactly as the user has it.
        case control
        /// Vendor conf on XDG_DATA_DIRS, interactive fish, first prompt
        /// event fired before the command (how a real session loads it).
        case autoInjected
        /// `source osc133.fish` after the prompt is already defined.
        case handSourced
    }

    private struct Rendered {
        /// Raw bytes fish wrote between the markers (escapes intact).
        let raw: String
        /// `raw` with OSC / CSI sequences removed.
        let text: String
        /// Did the OSC 133;B mark appear (i.e. was the integration engaged)?
        let hasBMark: Bool
        /// First `[...]` pipestatus token in `text` (stock prompt), or
        /// "<none>" — a printable value so a failing assert shows it.
        let statusToken: String
        let run: FishRun
    }

    private static let bMark = "\u{1B}]133;B\u{1B}\\"
    private static let beginMarker = "BBPROMPTBEGIN\n"
    private static let endMarker = "\nBBPROMPTEND"

    /// Run `command` (a failing or succeeding command line) and render the
    /// very next prompt by calling `fish_prompt` DIRECTLY after it — no
    /// intervening command, so `$status` / `$pipestatus` are exactly what the
    /// reader would hand the prompt. Output is bracketed by markers printed
    /// BEFORE the command so the markers themselves can't clobber status.
    private func render(
        _ integration: Integration, after command: String, fish: URL
    ) throws -> Rendered {
        let measured = """
        printf 'BBPROMPTBEGIN\\n'
        \(command)
        fish_prompt
        printf '\\nBBPROMPTEND\\n'
        """
        let run: FishRun
        switch integration {
        case .control:
            // `emit fish_prompt` mirrors the first-prompt event a real
            // interactive session fires; with no integration it is a no-op.
            run = try runFish(fish, args: ["-ic", "emit fish_prompt\n" + measured], env: baseEnvironment())
        case .autoInjected:
            run = try runFish(
                fish, args: ["-ic", "emit fish_prompt\n" + measured],
                env: autoInjectedEnvironment(fish: fish))
        case .handSourced:
            let script = shellResourcesDir().appendingPathComponent("osc133.fish").path
            run = try runFish(fish, args: ["-c", "source '\(script)'\n" + measured], env: baseEnvironment())
        }

        let out = run.stdout
        guard let begin = out.range(of: Self.beginMarker),
              let end = out.range(of: Self.endMarker, range: begin.upperBound..<out.endIndex)
        else {
            XCTFail("""
                \(integration): prompt markers not found — fish did not run the scenario.
                stdout: \(debugHex(out))
                stderr: \(debugHex(run.stderr)) (exit \(run.exitStatus))
                """)
            return Rendered(raw: "", text: "", hasBMark: false, statusToken: "<none>", run: run)
        }
        let raw = String(out[begin.upperBound..<end.lowerBound])
        let text = Self.stripEscapes(raw)
        return Rendered(
            raw: raw, text: text, hasBMark: raw.contains(Self.bMark),
            statusToken: Self.firstMatch(of: "\\[[0-9|]+\\]", in: text) ?? "<none>",
            run: run)
    }

    // MARK: - Assertion driver

    /// Drive one scenario: (1) CONTROL must report `expected` and carry no
    /// integration; (2) the integrated run must have engaged the integration
    /// (B mark) and report the SAME `expected`. `observe` picks the facet of
    /// the prompt under test (its full text for the custom prompt, the
    /// `[...]` status token for the stock prompt).
    private func assertPromptSees(
        expected: String,
        after command: String,
        via integration: Integration,
        fish: URL,
        facet: String,
        observe: (Rendered) -> String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let control = try render(.control, after: command, fish: fish)
        XCTAssertEqual(
            observe(control), expected,
            "harness sanity: WITHOUT integration, the prompt after `\(command)` must show the true \(facet) \(expected). Raw: \(debugHex(control.raw)); stderr: \(debugHex(control.run.stderr))",
            file: file, line: line)
        XCTAssertFalse(
            control.hasBMark,
            "harness sanity: the control run must not carry Blackbird's OSC 133;B mark. Raw: \(debugHex(control.raw))",
            file: file, line: line)

        let integrated = try render(integration, after: command, fish: fish)
        XCTAssertTrue(
            integrated.hasBMark,
            "precondition: with the integration loaded (\(integration)) the prompt must carry OSC 133;B, otherwise this run measures nothing. Raw: \(debugHex(integrated.raw)); stderr: \(debugHex(integrated.run.stderr))",
            file: file, line: line)
        XCTAssertEqual(
            observe(integrated), expected,
            "fish integration (\(integration)) must be transparent to the prompt's \(facet): after `\(command)` the prompt must see \(expected) exactly as the control did, but saw \(observe(integrated)). Raw: \(debugHex(integrated.raw)); stderr: \(debugHex(integrated.run.stderr))",
            file: file, line: line)
    }

    // MARK: - Auto-injected (default Settings) — user's own prompt

    /// The headline: a user prompt reading `$status` on entry sees the failed
    /// command's code (7), not 0.
    func test_autoInjected_userPrompt_seesStatusOfFailedCommand() throws {
        let fish = try requireFish()
        try installUserPrompt()
        try assertPromptSees(
            expected: "PS<7,7>", after: "sh -c 'exit 7'", via: .autoInjected,
            fish: fish, facet: "$status/$pipestatus", observe: { $0.text })
    }

    /// `$pipestatus` must survive too — a pipeline whose LAST stage succeeds
    /// has `$status == 0` but `$pipestatus == 0 3 0`; one whose last stage
    /// fails has `$status == 3`, `$pipestatus == 0 3`.
    func test_autoInjected_userPrompt_seesPipestatusOfFailedPipeline() throws {
        let fish = try requireFish()
        try installUserPrompt()
        try assertPromptSees(
            expected: "PS<0,0,3,0>", after: "true | sh -c 'exit 3' | true", via: .autoInjected,
            fish: fish, facet: "$status/$pipestatus", observe: { $0.text })
        try assertPromptSees(
            expected: "PS<3,0,3>", after: "true | sh -c 'exit 3'", via: .autoInjected,
            fish: fish, facet: "$status/$pipestatus", observe: { $0.text })
    }

    /// Guard against an over-correction (e.g. a fix that pins a non-zero
    /// status): after a successful command the prompt must still see 0.
    func test_autoInjected_userPrompt_afterSuccessfulCommand_seesZero() throws {
        let fish = try requireFish()
        try installUserPrompt()
        try assertPromptSees(
            expected: "PS<0,0>", after: "true", via: .autoInjected,
            fish: fish, facet: "$status/$pipestatus", observe: { $0.text })
    }

    // MARK: - Auto-injected — fish's stock prompt (what most users have)

    /// The user-visible symptom from the bug report: the stock prompt must
    /// still print `[7]` after a failed command.
    func test_autoInjected_stockPrompt_showsStatusBracketAfterFailedCommand() throws {
        let fish = try requireFish()
        try assertPromptSees(
            expected: "[7]", after: "sh -c 'exit 7'", via: .autoInjected,
            fish: fish, facet: "status indicator", observe: { $0.statusToken })
    }

    func test_autoInjected_stockPrompt_showsPipestatusBracketAfterFailedPipeline() throws {
        let fish = try requireFish()
        try assertPromptSees(
            expected: "[3|0|5]", after: "sh -c 'exit 3' | true | sh -c 'exit 5'", via: .autoInjected,
            fish: fish, facet: "pipestatus indicator", observe: { $0.statusToken })
    }

    // MARK: - Hand-sourced osc133.fish over a pre-existing prompt

    func test_handSourced_userPrompt_seesStatusOfFailedCommand() throws {
        let fish = try requireFish()
        try installUserPrompt()
        try assertPromptSees(
            expected: "PS<7,7>", after: "sh -c 'exit 7'", via: .handSourced,
            fish: fish, facet: "$status/$pipestatus", observe: { $0.text })
    }

    func test_handSourced_stockPrompt_showsStatusBracketAfterFailedCommand() throws {
        let fish = try requireFish()
        try assertPromptSees(
            expected: "[7]", after: "sh -c 'exit 7'", via: .handSourced,
            fish: fish, facet: "status indicator", observe: { $0.statusToken })
    }

    // MARK: - Helpers

    /// Remove OSC (`ESC ] … BEL|ST`), CSI (`ESC [ … final`) and the two
    /// single-char keypad-mode escapes so only printable prompt text remains.
    private static func stripEscapes(_ s: String) -> String {
        let pattern = "\u{1B}\\][^\u{07}\u{1B}]*(?:\u{07}|\u{1B}\\\\)|\u{1B}\\[[0-9;?]*[ -/]*[@-~]|\u{1B}[=>]"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            XCTFail("escape-stripping regex failed to compile — test bug")
            return s
        }
        let range = NSRange(s.startIndex..., in: s)
        return regex.stringByReplacingMatches(in: s, range: range, withTemplate: "")
    }

    private static func firstMatch(of pattern: String, in s: String) -> String? {
        guard let range = s.range(of: pattern, options: .regularExpression) else { return nil }
        return String(s[range])
    }

    /// Render captured output with escapes spelled out so an assertion
    /// failure shows the exact bytes.
    private func debugHex(_ s: String) -> String {
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
}
