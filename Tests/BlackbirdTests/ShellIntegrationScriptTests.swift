import XCTest

/// Tests the shipped shell-integration snippets in
/// `Sources/Blackbird/Resources/shell/osc133.{zsh,bash,fish}`.
///
/// These snippets ship inside the Blackbird app bundle and are sourced by
/// users from their rc files to enable OSC 133 prompt-mark integration.
/// They were previously untested: a regression that broke the emit path
/// (e.g. wrong escape, missing hook registration, double-loading) would
/// silently degrade prompt jump for every user who sourced them and never
/// fail in CI.
///
/// What this layer tests vs. what `OSC133Tests.swift` tests:
///
/// - `OSC133Tests` exercises BBTerm's Swift wrapper around the Rust scanner
///   for OSC 133 sequences — given canned bytes, does Swift see the right
///   `PromptMarkKind`?
/// - This file tests the *script content*: given a real `/bin/zsh` (or
///   `/bin/bash`, or `fish`) sourcing the shipped snippet and going through
///   one prompt cycle, does the shell actually emit the OSC 133 A/B/C/D
///   byte sequences we promise?
///
/// Pre-flight: each test spawns one shell process (~few KB RSS) for ~50–
/// 200 ms. Three shells × one process each = trivially under the per-test
/// budget. No PTY, no TerminalSession — just `Process()` with a captured
/// stdout pipe. Resilient to missing shells: any shell binary not present
/// triggers `XCTSkip` so the suite stays green on machines without fish
/// (the common case on macOS) or with bash from Homebrew at a non-standard
/// path.
final class ShellIntegrationScriptTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        // Same pattern as every other test in this bundle — register the
        // termination observer once so a `--filter ShellIntegrationScript…`
        // run doesn't leave a zombie SwiftUI test host. Idempotent.
        TestHostTermination.shared.register()
    }

    // MARK: - OSC 133 byte sequences

    /// Each of these is the exact byte sequence the script-side functions
    /// promise to emit. Substring-matching against captured stdout is the
    /// whole assertion — we deliberately do not parse OSC structure here
    /// because the script's job is to emit literal bytes; if a future
    /// snippet rewrite changes the form (BEL terminator instead of ST,
    /// for example) the test should fail loudly and force the maintainer
    /// to either update the assertion or revert the rewrite.
    private static let oscPromptStart  = "\u{1B}]133;A\u{1B}\\"
    private static let oscCommandStart = "\u{1B}]133;B\u{1B}\\"
    private static let oscCommandOutput = "\u{1B}]133;C\u{1B}\\"
    /// D is parameterised with `;<exit>`. We only assert the prefix.
    private static let oscCommandEndPrefix = "\u{1B}]133;D"

    // MARK: - Script location

    /// Locate a shipped script snippet via `#filePath` arithmetic.
    /// xcodebuild's CWD is inside DerivedData, so we anchor on the test
    /// file's compile-time path. Identical to `PasteboardSourceTypePinTests`
    /// and `PreferencesTests` — three `deletingLastPathComponent()` walks
    /// us back to the repo root.
    private func locateScript(named name: String, file: String = #filePath) throws -> URL {
        let url = URL(fileURLWithPath: file)
            .deletingLastPathComponent()  // Tests/BlackbirdTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("Sources/Blackbird/Resources/shell")
            .appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("Script \(name) not found at \(url.path) — repo layout changed?")
        }
        return url
    }

    // MARK: - Shell location

    /// Resolve a shell executable, preferring the canonical macOS path
    /// (`/bin/zsh`, `/bin/bash`) and falling back to Homebrew locations.
    /// Returns nil if no executable is found — caller skips the test.
    private func locateShell(_ name: String) -> URL? {
        let candidates = [
            "/bin/\(name)",
            "/usr/bin/\(name)",
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    // MARK: - Process runner

    /// Run `shellPath` with the given inline script body, capturing stdout
    /// as a UTF-8 string. Times out after 5 seconds — generous since each
    /// invocation is a single shell sourcing one tiny snippet. A real
    /// hang means the snippet is stuck in an infinite loop, which is the
    /// kind of regression we explicitly want to fail rather than ignore.
    ///
    /// `leadingArgs` are inserted before `-c` — e.g. `["-f"]` to run zsh
    /// with startup files skipped (stock options), which the PS1
    /// prompt-expansion contract tests rely on. Defaults to empty so all
    /// existing call sites keep their prior behaviour.
    private func runShell(at shellPath: URL, leadingArgs: [String] = [], scriptBody: String) throws -> String {
        let process = Process()
        process.executableURL = shellPath
        process.arguments = leadingArgs + ["-c", scriptBody]
        // Drop user's rc — we want a hermetic environment. Otherwise a
        // local ~/.zshrc that already sources the snippet would emit
        // sequences twice and confuse the assertions. `env -i` semantics.
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"  // generic TTY stub for completeness
        env["HOME"] = NSTemporaryDirectory()  // avoid touching real ~/.zshrc
        process.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()

        // 5-second wall budget. Polling rather than `waitUntilExit()` so
        // we never deadlock if the shell hangs — kill and fail loudly.
        let deadline = Date().addingTimeInterval(5.0)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.1)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            XCTFail("\(shellPath.lastPathComponent) hung sourcing the snippet — likely an infinite loop in the script")
            return ""
        }

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: outData, as: UTF8.self)
    }

    // MARK: - zsh

    /// zsh integration: source the snippet, then manually drive its hook
    /// chains to simulate a prompt cycle.
    ///
    /// Why not `-i` (interactive)? Interactive zsh requires a controlling
    /// terminal to actually render PS1. With `-c` and no TTY, zsh skips
    /// the prompt rendering entirely — even `setopt prompt_subst` won't
    /// help because the prompt is only painted between commands in an
    /// interactive line editor session. Testing through a real PTY is a
    /// separate concern (TerminalSession / PTY tests own it). Here we
    /// directly invoke the registered hook arrays the snippet adds to
    /// `precmd_functions` / `preexec_functions`, which is what zsh would
    /// have called itself in interactive mode. If the snippet stops
    /// registering those hooks, the test fails because the manually-
    /// invoked loop produces no output.
    func test_osc133_zsh_emitsExpectedSequences() throws {
        let scriptURL = try locateScript(named: "osc133.zsh")
        guard let zsh = locateShell("zsh") else {
            throw XCTSkip("/bin/zsh not present — skipping zsh script test")
        }

        // The body sources the snippet, then fires the hook chains that
        // zsh would normally fire in an interactive session.
        //
        // Sequence:
        //   1. precmd hooks fire  → __bb_osc133_d (D;0) + __bb_osc133_a (A)
        //      Note: $? = 0 here because nothing has run yet.
        //   2. echo MARK_PROMPT_RENDERED — proxy for "prompt printed"
        //   3. preexec hooks fire → __bb_osc133_c (C)
        //   4. echo MARK_CMD_OUTPUT — proxy for "command running"
        //   5. precmd hooks fire again → D;0 + A (next prompt)
        //
        // We assert all four marks (A, B, C, D) appear, plus that the
        // markers are interleaved correctly relative to the marks.
        let body = """
        emulate -L zsh
        source '\(scriptURL.path)'
        # PS1 emits B via $(__bb_osc133_b), but evaluating PS1 requires
        # an interactive prompt + setopt prompt_subst. We can't do that in
        # -c mode, so directly call __bb_osc133_b to verify it's defined
        # and emits the right bytes — a missing or renamed function would
        # fail loudly here.
        # Pre-prompt cycle 1: D + A.
        for f in $precmd_functions; do "$f"; done
        print -n MARK_PROMPT_RENDERED
        # B emitted via PS1 (would fire here in a real session).
        __bb_osc133_b
        # Pre-command: C.
        for f in $preexec_functions; do "$f"; done
        print -n MARK_CMD_OUTPUT
        # Pre-prompt cycle 2: D + A.
        for f in $precmd_functions; do "$f"; done
        """
        let out = try runShell(at: zsh, scriptBody: body)

        XCTAssertTrue(out.contains(Self.oscPromptStart),
            "zsh: missing OSC 133 A. Captured: \(debugHex(out))")
        XCTAssertTrue(out.contains(Self.oscCommandStart),
            "zsh: missing OSC 133 B. Captured: \(debugHex(out))")
        XCTAssertTrue(out.contains(Self.oscCommandOutput),
            "zsh: missing OSC 133 C. Captured: \(debugHex(out))")
        XCTAssertTrue(out.contains(Self.oscCommandEndPrefix),
            "zsh: missing OSC 133 D. Captured: \(debugHex(out))")

        // Ordering pin: the first A must appear before MARK_PROMPT_RENDERED,
        // and C must appear after MARK_PROMPT_RENDERED but before
        // MARK_CMD_OUTPUT. A regression that swapped precmd/preexec hooks
        // would scramble this and silently break prompt jump.
        let aIdx = try XCTUnwrap(out.range(of: Self.oscPromptStart)?.lowerBound,
            "zsh: A not found, ordering pin can't run")
        let promptIdx = try XCTUnwrap(out.range(of: "MARK_PROMPT_RENDERED")?.lowerBound,
            "zsh: prompt marker not found")
        let cIdx = try XCTUnwrap(out.range(of: Self.oscCommandOutput)?.lowerBound,
            "zsh: C not found, ordering pin can't run")
        let cmdIdx = try XCTUnwrap(out.range(of: "MARK_CMD_OUTPUT")?.lowerBound,
            "zsh: command-output marker not found")
        XCTAssertLessThan(aIdx, promptIdx, "zsh: A must precede prompt-rendered marker")
        XCTAssertGreaterThan(cIdx, promptIdx, "zsh: C must follow prompt-rendered marker")
        XCTAssertLessThan(cIdx, cmdIdx, "zsh: C must precede command-output marker")
    }

    // MARK: - bash

    /// bash integration: source the snippet, then manually drive
    /// PROMPT_COMMAND + PS0 expansion. Skips on bash 3.2 (the macOS
    /// stock shell) for the PS0-driven C mark only — the rest of the
    /// snippet (PROMPT_COMMAND-driven D + A, and the C function itself)
    /// works fine on 3.2. PS0 was added in bash 4.4 (2016).
    ///
    /// macOS ships bash 3.2 from ancient GPLv2 days. Users who installed
    /// bash via Homebrew (`/opt/homebrew/bin/bash`) get bash 5+ where
    /// PS0 expands. We probe `BASH_VERSINFO[0]` and assert C only when
    /// the bash major version is 4 or higher.
    func test_osc133_bash_emitsExpectedSequences() throws {
        let scriptURL = try locateScript(named: "osc133.bash")
        guard let bash = locateShell("bash") else {
            throw XCTSkip("bash not present — skipping bash script test")
        }

        // Probe the bash major version up-front. We can't easily branch
        // assertions on shell behaviour from inside Swift without it.
        let versionProbe = try runShell(at: bash, scriptBody: "echo \"${BASH_VERSINFO[0]}\"")
        let majorVersion = Int(versionProbe.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0

        let body = """
        source '\(scriptURL.path)'
        # Force PROMPT_COMMAND to fire once. The function emits D + A and
        # captures __BB_LAST_EXIT from $? at entry — set $? = 0 explicitly.
        true
        __bb_osc133_prompt
        echo -n MARK_PROMPT_RENDERED
        # B is emitted via PS1's `\\[$(__bb_osc133_b)\\]` wrapper, which
        # only fires when bash renders a real prompt. We can't drive that
        # from -c, so call __bb_osc133_b directly to verify it's defined.
        __bb_osc133_b
        # C is emitted via PS0 in bash 4+. On bash 3.2, PS0 is silently
        # ignored. Either way, calling __bb_osc133_c directly proves the
        # function is wired up — the version-specific PS0 expansion test
        # below is the bash-4+ regression catcher.
        __bb_osc133_c
        echo -n MARK_CMD_OUTPUT
        __bb_osc133_prompt
        """
        let out = try runShell(at: bash, scriptBody: body)

        XCTAssertTrue(out.contains(Self.oscPromptStart),
            "bash: missing OSC 133 A. Captured: \(debugHex(out))")
        XCTAssertTrue(out.contains(Self.oscCommandStart),
            "bash: missing OSC 133 B. Captured: \(debugHex(out))")
        XCTAssertTrue(out.contains(Self.oscCommandOutput),
            "bash: missing OSC 133 C. Captured: \(debugHex(out))")
        XCTAssertTrue(out.contains(Self.oscCommandEndPrefix),
            "bash: missing OSC 133 D. Captured: \(debugHex(out))")

        // PS0 expansion check — only on bash 4+. macOS stock bash 3.2
        // ignores PS0 entirely, so the PS0-driven C mark wouldn't fire
        // even with a real interactive prompt. Document the gap by
        // skipping rather than asserting false.
        if majorVersion >= 4 {
            // Verify PS0 contains the call to __bb_osc133_c. Echo the
            // current PS0 verbatim (no expansion) so we can substring-
            // match it.
            let ps0Probe = try runShell(at: bash, scriptBody: """
            source '\(scriptURL.path)'
            printf '%s' "$PS0"
            """)
            XCTAssertTrue(ps0Probe.contains("__bb_osc133_c"),
                "bash 4+: PS0 must reference __bb_osc133_c so C fires before commands. PS0 = \(ps0Probe)")
        }
    }

    // MARK: - fish

    /// fish integration: source the snippet, then manually fire the
    /// `fish_preexec` and `fish_prompt` events that the snippet listens
    /// for. fish's event system supports manual emission via
    /// `emit fish_prompt`.
    ///
    /// fish is not part of the macOS base install. CI runners typically
    /// don't have it either. We skip when the binary is absent — that's
    /// not a product regression, just an unavailable test fixture.
    func test_osc133_fish_emitsExpectedSequences() throws {
        let scriptURL = try locateScript(named: "osc133.fish")
        guard let fish = locateShell("fish") else {
            throw XCTSkip("fish not installed (not a regression — fish is optional on macOS)")
        }

        // fish syntax: emit events to fire the registered handlers.
        // We pass the script via -C (sources before -c) so the handlers
        // are registered, then fire events. fish's printf accepts the
        // same `\e` escapes as bash.
        let body = """
        source '\(scriptURL.path)'
        emit fish_prompt
        printf MARK_PROMPT_RENDERED
        __bb_osc133_b
        emit fish_preexec
        printf MARK_CMD_OUTPUT
        emit fish_prompt
        """
        let out = try runShell(at: fish, scriptBody: body)

        XCTAssertTrue(out.contains(Self.oscPromptStart),
            "fish: missing OSC 133 A. Captured: \(debugHex(out))")
        XCTAssertTrue(out.contains(Self.oscCommandStart),
            "fish: missing OSC 133 B. Captured: \(debugHex(out))")
        XCTAssertTrue(out.contains(Self.oscCommandOutput),
            "fish: missing OSC 133 C. Captured: \(debugHex(out))")
        XCTAssertTrue(out.contains(Self.oscCommandEndPrefix),
            "fish: missing OSC 133 D. Captured: \(debugHex(out))")
    }

    // MARK: - Double-source guards

    /// All three snippets guard against double-sourcing (the "if loaded,
    /// return" idiom at the top). Without it, every reload of the user's
    /// rc file would stack PROMPT_COMMAND / precmd_functions and emit
    /// each mark N+1 times after N reloads.
    ///
    /// Test by sourcing twice and counting A occurrences after a single
    /// fired precmd. A regression that broke the guard would emit A
    /// twice (once from each registered hook).
    func test_osc133_zsh_doubleSourceGuard_preventsDuplicateHooks() throws {
        let scriptURL = try locateScript(named: "osc133.zsh")
        guard let zsh = locateShell("zsh") else {
            throw XCTSkip("/bin/zsh not present — skipping zsh double-source guard test")
        }
        let body = """
        emulate -L zsh
        source '\(scriptURL.path)'
        source '\(scriptURL.path)'
        # Fire precmd once. If the guard works, hook list contains one
        # entry; A appears once. If it broke, hook list contains two,
        # A appears twice.
        for f in $precmd_functions; do "$f"; done
        """
        let out = try runShell(at: zsh, scriptBody: body)
        let aCount = out.components(separatedBy: Self.oscPromptStart).count - 1
        XCTAssertEqual(aCount, 1,
            "zsh: double-source guard broken — A emitted \(aCount) times after sourcing twice. " +
            "Should be 1 (each hook registered once). Captured: \(debugHex(out))")
    }

    /// The bash guard's job is to prevent `PROMPT_COMMAND` and `PS0`
    /// from gaining duplicate `__bb_osc133_prompt` / `__bb_osc133_c`
    /// entries when the snippet is sourced more than once (a common
    /// case: an rc reload, an `.bashrc` chain that already sources
    /// it, etc.). Calling `__bb_osc133_prompt` once after a double-
    /// source DOES NOT exercise the guard — the function is the same
    /// function regardless of whether PROMPT_COMMAND lists it once or
    /// twice. The defensive contract is the *registration* shape, so
    /// the test must inspect `PROMPT_COMMAND` and `PS0` directly and
    /// count occurrences of the registered tokens.
    func test_osc133_bash_doubleSourceGuard_preventsDuplicateHooks() throws {
        let scriptURL = try locateScript(named: "osc133.bash")
        guard let bash = locateShell("bash") else {
            throw XCTSkip("bash not present — skipping bash double-source guard test")
        }
        // Probe the bash major version up-front: PS0 was added in bash
        // 4.4 (2016). On bash 3.2 (macOS stock) PS0 is silently ignored
        // — we still assert it for completeness because the snippet's
        // PS0 assignment runs on every version, but the runtime effect
        // only fires on bash 4+.
        let versionProbe = try runShell(at: bash, scriptBody: "echo \"${BASH_VERSINFO[0]}\"")
        let majorVersion = Int(versionProbe.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0

        // Source the snippet TWICE then echo the resulting PROMPT_COMMAND
        // and PS0 so we can substring-count the registered tokens.
        // A working guard yields exactly ONE occurrence of
        // `__bb_osc133_prompt` in PROMPT_COMMAND and exactly ONE of
        // `__bb_osc133_c` in PS0; a broken guard yields two.
        //
        // Use distinctive `PROMPT_COMMAND_OUT=[…]` / `PS0_OUT=[…]`
        // wrappers so the bracket-matched extraction is unambiguous —
        // PROMPT_COMMAND on bash 5.1+ may legitimately render as a
        // bash-array (`declare -a`) and we want to catch BOTH the
        // string and array forms via a single substring search.
        let body = """
        source '\(scriptURL.path)'
        source '\(scriptURL.path)'
        # `${PROMPT_COMMAND[*]}` joins array elements with the first
        # character of IFS (a space by default) on bash 5.1+ where
        # PROMPT_COMMAND can be an array; on older bash it harmlessly
        # echoes the string. Either way, every registered hook
        # appears once in the output.
        printf 'PROMPT_COMMAND_OUT=[%s]\\n' "${PROMPT_COMMAND[*]:-}"
        printf 'PS0_OUT=[%s]\\n' "${PS0:-}"
        """
        let out = try runShell(at: bash, scriptBody: body)

        // Count occurrences of the registered tokens. Splitting on
        // the token gives `count + 1` chunks; `count = chunks - 1`.
        let promptCount = out.components(separatedBy: "__bb_osc133_prompt").count - 1
        XCTAssertEqual(
            promptCount, 1,
            "bash: double-source guard broken — `__bb_osc133_prompt` appears " +
            "\(promptCount) time(s) in PROMPT_COMMAND after sourcing the snippet " +
            "twice. The guard's job is to prevent PROMPT_COMMAND from gaining a " +
            "duplicate entry; a count of 2 means every prompt cycle would emit " +
            "D + A twice. Captured: \(debugHex(out))"
        )

        if majorVersion >= 4 {
            let cCount = out.components(separatedBy: "__bb_osc133_c").count - 1
            XCTAssertEqual(
                cCount, 1,
                "bash 4+: double-source guard broken — `__bb_osc133_c` appears " +
                "\(cCount) time(s) in PS0 after sourcing the snippet twice. " +
                "PS0 is expanded once per command read; a duplicate entry would " +
                "emit C twice per command. Captured: \(debugHex(out))"
            )
        }
    }

    // MARK: - PS1 prompt-expansion contract
    //
    // The direct-call tests above prove the OSC 133 emit FUNCTIONS work:
    // given a call to `__bb_osc133_b`, the right bytes appear on stdout.
    // What they CANNOT catch is a regression that defines the function
    // but fails to wire it into the prompt so B actually fires when the
    // shell renders PS1 — under the shell's STOCK configuration.
    //
    // The real contract is behavioral, not textual. Pinning "$PS1 contains
    // the substring __bb_osc133_b" would pass even for a snippet that emits
    // B via `$(__bb_osc133_b)` — which under stock zsh (no `prompt_subst`)
    // does NOTHING useful: the command substitution never runs at prompt
    // time, so B never fires AND the user sees raw `$(...)` text in their
    // prompt. So these tests prompt-EXPAND the resulting PS1 the way the
    // shell does every time it paints a prompt, and assert on the bytes:
    //   1. the raw OSC 133;B sequence is present,
    //   2. no un-expanded `$(` garbage is left behind,
    //   3. B lands AFTER the prompt text (B = "user input begins"),
    //   4. sourcing twice does not stack a second B.

    /// Contract 1 — B fires under STOCK zsh options. `zsh -f` skips all
    /// startup files; `emulate -L zsh` restores default options; and we
    /// explicitly `unsetopt prompt_subst` so the snippet cannot lean on
    /// command substitution (which stock zsh does not perform in prompts).
    /// Prompt-expanding PS1 must then emit the raw OSC 133;B bytes.
    ///
    /// (Replaces the former `test_osc133_zsh_PS1_referencesPromptFunction`,
    /// which pinned the implementation detail `$PS1 contains __bb_osc133_b`
    /// rather than the behavioral wiring contract.)
    func test_osc133_zsh_PS1_expansion_emitsB_underStockOptions() throws {
        let scriptURL = try locateScript(named: "osc133.zsh")
        guard let zsh = locateShell("zsh") else {
            throw XCTSkip("/bin/zsh not present — skipping zsh PS1 expansion test")
        }
        let body = """
        emulate -L zsh
        source '\(scriptURL.path)'
        unsetopt prompt_subst
        print -rP -- "$PS1"
        """
        let out = try runShell(at: zsh, leadingArgs: ["-f"], scriptBody: body)
        XCTAssertTrue(
            out.contains(Self.oscCommandStart),
            "zsh: prompt-expanding PS1 under stock options (prompt_subst OFF) must "
            + "emit the raw OSC 133;B bytes. A snippet that wires B via `$(...)` needs "
            + "prompt_subst; under stock zsh that never expands, so B never fires. "
            + "Got: \(debugHex(out))"
        )
    }

    /// Contract 2 — no visible garbage. Under stock zsh (prompt_subst OFF)
    /// a `$(...)` embedded in the prompt is printed VERBATIM, so the user
    /// would literally see `$(__bb_osc133_b)` in their prompt. The
    /// prompt-expanded PS1 must contain no literal `$(`.
    func test_osc133_zsh_PS1_expansion_noUnexpandedCommandSubstitution() throws {
        let scriptURL = try locateScript(named: "osc133.zsh")
        guard let zsh = locateShell("zsh") else {
            throw XCTSkip("/bin/zsh not present — skipping zsh PS1 garbage test")
        }
        let body = """
        emulate -L zsh
        source '\(scriptURL.path)'
        unsetopt prompt_subst
        print -rP -- "$PS1"
        """
        let out = try runShell(at: zsh, leadingArgs: ["-f"], scriptBody: body)
        XCTAssertFalse(
            out.contains("$("),
            "zsh: prompt-expanded PS1 contains literal `$(` — under stock options the "
            + "shell does not run command substitution in prompts, so the user sees raw "
            + "`$(...)` text. The snippet must embed literal escape bytes, not a command "
            + "substitution. Got: \(debugHex(out))"
        )
    }

    /// Contract 3 — B marks the START of user input, so it must land AFTER
    /// the prompt text. With a known `PS1='XYZPROMPT%% '` (the `%%` expands
    /// to a single `%`, proving -P expansion is live) the OSC 133;B bytes
    /// must appear after the "XYZPROMPT" substring.
    func test_osc133_zsh_PS1_expansion_bMarkComesAfterPromptText() throws {
        let scriptURL = try locateScript(named: "osc133.zsh")
        guard let zsh = locateShell("zsh") else {
            throw XCTSkip("/bin/zsh not present — skipping zsh B-position test")
        }
        let body = """
        emulate -L zsh
        PS1='XYZPROMPT%% '
        source '\(scriptURL.path)'
        unsetopt prompt_subst
        print -rP -- "$PS1"
        """
        let out = try runShell(at: zsh, leadingArgs: ["-f"], scriptBody: body)
        let bRange = try XCTUnwrap(
            out.range(of: Self.oscCommandStart),
            "zsh: B bytes not found in expanded PS1; cannot check position. Got: \(debugHex(out))"
        )
        let pRange = try XCTUnwrap(
            out.range(of: "XYZPROMPT"),
            "zsh: prompt text 'XYZPROMPT' not found in expanded PS1. Got: \(debugHex(out))"
        )
        XCTAssertGreaterThanOrEqual(
            bRange.lowerBound, pRange.upperBound,
            "zsh: OSC 133;B must appear AFTER the prompt text — B marks where the user "
            + "begins typing, so it belongs at the END of the prompt, not the start. "
            + "Got: \(debugHex(out))"
        )
    }

    /// Contract 4 — double-source stays safe. Sourcing the snippet twice
    /// must not stack the PS1 wrap: the prompt-expanded PS1 must contain
    /// exactly ONE OSC 133;B.
    func test_osc133_zsh_PS1_expansion_doubleSourceEmitsSingleB() throws {
        let scriptURL = try locateScript(named: "osc133.zsh")
        guard let zsh = locateShell("zsh") else {
            throw XCTSkip("/bin/zsh not present — skipping zsh double-source B test")
        }
        let body = """
        emulate -L zsh
        source '\(scriptURL.path)'
        source '\(scriptURL.path)'
        unsetopt prompt_subst
        print -rP -- "$PS1"
        """
        let out = try runShell(at: zsh, leadingArgs: ["-f"], scriptBody: body)
        let bCount = out.components(separatedBy: Self.oscCommandStart).count - 1
        XCTAssertEqual(
            bCount, 1,
            "zsh: after sourcing the snippet twice, the prompt-expanded PS1 must contain "
            + "exactly ONE OSC 133;B (got \(bCount)). More than one means the PS1 wrap "
            + "stacked on re-source and every prompt would emit B repeatedly. "
            + "Got: \(debugHex(out))"
        )
    }

    /// bash counterpart of Contracts 1+2+3 — behavioral, via `${PS1@P}`
    /// prompt expansion (bash 4.4+). bash's `promptvars` is ON by default,
    /// so a `$(...)` in PS1 legitimately expands at prompt time; we test
    /// under those DEFAULT settings (never turning promptvars off). The
    /// expanded PS1 must contain the raw OSC 133;B bytes, with no literal
    /// `$(` residue, positioned AFTER the prompt text.
    ///
    /// Skips when no bash >= 4.4 is available (macOS ships bash 3.2, which
    /// lacks `@P`). `test_osc133_bash_emitsExpectedSequences` still pins
    /// that B fires on every bash version, so the wiring can't silently
    /// vanish on a bash-3.2-only host.
    ///
    /// (Replaces the former `test_osc133_bash_PS1_referencesPromptFunction`,
    /// which pinned the implementation detail `$PS1 contains __bb_osc133_b`
    /// rather than the behavioral wiring contract.)
    func test_osc133_bash_PS1_expansion_emitsBAfterPromptText() throws {
        let scriptURL = try locateScript(named: "osc133.bash")
        guard let bash = locateModernBash() else {
            throw XCTSkip("no bash >= 4.4 found (macOS stock bash is 3.2; `${PS1@P}` "
                + "prompt expansion needs 4.4+) — behavioral PS1-expansion contract can't "
                + "be exercised here. test_osc133_bash_emitsExpectedSequences still covers "
                + "that B fires.")
        }
        // DEFAULT settings: do NOT touch `promptvars`. Set a known prompt
        // BEFORE sourcing so we can assert B lands AFTER the prompt text.
        let body = """
        PS1='XYZPROMPT '
        source '\(scriptURL.path)'
        printf '%s' "${PS1@P}"
        """
        let out = try runShell(at: bash, scriptBody: body)
        XCTAssertTrue(
            out.contains(Self.oscCommandStart),
            "bash: prompt-expanded PS1 (`${PS1@P}`) must contain the raw OSC 133;B "
            + "bytes so B fires on every rendered prompt. Got: \(debugHex(out))"
        )
        XCTAssertFalse(
            out.contains("$("),
            "bash: prompt-expanded PS1 still contains literal `$(` — the command "
            + "substitution that should emit B did not expand. Got: \(debugHex(out))"
        )
        let bRange = try XCTUnwrap(
            out.range(of: Self.oscCommandStart),
            "bash: B bytes not found in expanded PS1; cannot check position. Got: \(debugHex(out))"
        )
        let pRange = try XCTUnwrap(
            out.range(of: "XYZPROMPT"),
            "bash: prompt text 'XYZPROMPT' not found in expanded PS1. Got: \(debugHex(out))"
        )
        XCTAssertGreaterThanOrEqual(
            bRange.lowerBound, pRange.upperBound,
            "bash: OSC 133;B must appear AFTER the prompt text — B marks where the user "
            + "begins typing, so it belongs at the END of the prompt, not the start. "
            + "Got: \(debugHex(out))"
        )
        // Nothing PRINTABLE may follow the mark: the ST terminator ends in
        // a literal backslash, and an embed that lets it collapse with
        // `\]`'s backslash during prompt decode eats the non-print marker
        // and leaks a visible `]` after every prompt (review-panel find).
        // `${PS1@P}` keeps `\[`/`\]` as \001/\002, so the only legal
        // follower is the \002 end-marker (or end-of-string).
        let after = out[bRange.upperBound...]
        XCTAssertTrue(
            after.isEmpty || after.first == "\u{02}",
            "bash: stray character(s) after the B mark — the `\\]` non-print marker "
            + "was consumed during prompt decode (ST's trailing backslash must be "
            + "doubled in the embed). Got: \(debugHex(out))"
        )
    }

    /// Locate a bash whose version is >= 4.4 (the release that added
    /// `${PARAM@P}` prompt expansion). Prefers the canonical `/bin/bash`
    /// but falls back to Homebrew locations, because macOS ships bash 3.2
    /// at `/bin/bash` and the `@P`-based behavioral contract can only be
    /// exercised on a modern bash. Returns nil if none qualifies.
    private func locateModernBash() -> URL? {
        let candidates = [
            "/bin/bash",
            "/opt/homebrew/bin/bash",
            "/usr/local/bin/bash",
            "/usr/bin/bash",
        ]
        for path in candidates {
            guard FileManager.default.isExecutableFile(atPath: path) else { continue }
            let url = URL(fileURLWithPath: path)
            guard let version = try? bashMajorMinor(at: url) else { continue }
            if version.major > 4 || (version.major == 4 && version.minor >= 4) {
                return url
            }
        }
        return nil
    }

    /// Probe a bash binary's major.minor version via `BASH_VERSINFO`.
    private func bashMajorMinor(at bash: URL) throws -> (major: Int, minor: Int) {
        let probe = try runShell(
            at: bash,
            scriptBody: #"printf '%s %s' "${BASH_VERSINFO[0]}" "${BASH_VERSINFO[1]}""#
        )
        let parts = probe.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
        let major = parts.count > 0 ? (Int(parts[0]) ?? 0) : 0
        let minor = parts.count > 1 ? (Int(parts[1]) ?? 0) : 0
        return (major, minor)
    }

    /// Static-content check for fish's double-source guard — runs without
    /// requiring a fish installation, so CI machines without fish still
    /// catch the regression. The fish `exit` builtin terminates the
    /// interactive shell process; a sourced file using `exit 0` as its
    /// guard kills the user's session on re-source. The bash and zsh
    /// siblings correctly use `return 0`. Audit S4-001.
    func test_osc133_fish_doubleSourceGuard_scriptSourceUsesReturnNotExit() throws {
        let scriptURL = try locateScript(named: "osc133.fish")
        let content = try String(contentsOf: scriptURL, encoding: .utf8)
        // The guard block has the shape:
        //   if set -q __bb_osc133_loaded
        //       <bail>
        //   end
        // Locate the guard line and assert the next non-blank, non-comment
        // line bails via `return`, not `exit`.
        let lines = content.components(separatedBy: "\n")
        guard let guardIdx = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "if set -q __bb_osc133_loaded"
        }) else {
            XCTFail("osc133.fish: expected guard `if set -q __bb_osc133_loaded` not found — script shape changed; re-check the audit assumption.")
            return
        }
        // Next non-blank, non-comment line is the bail.
        var bailLine: String?
        for i in (guardIdx + 1)..<lines.count {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix("#") { continue }
            bailLine = t
            break
        }
        guard let bail = bailLine else {
            XCTFail("osc133.fish: guard `if set -q __bb_osc133_loaded` found but no body.")
            return
        }
        XCTAssertFalse(
            bail.hasPrefix("exit"),
            "osc133.fish: double-source guard bails via `\(bail)` — fish's `exit` " +
            "terminates the calling shell, killing user sessions on re-source. Use " +
            "`return` instead (matches bash/zsh siblings). Audit S4-001."
        )
        XCTAssertTrue(
            bail == "return" || bail.hasPrefix("return "),
            "osc133.fish: expected `return` as the guard bail, got `\(bail)`."
        )
    }

    /// fish's double-source guard. The bash sibling uses `return 0`, but
    /// fish's `exit` builtin terminates the entire interactive shell
    /// process — including a `source`-calling parent. A guard that uses
    /// `exit 0` therefore kills the user's shell on re-source (e.g.
    /// reloading `config.fish`). The guard must use `return` instead.
    ///
    /// Test shape: source the fish snippet twice, then emit a marker.
    /// If the second source `exit`s the shell, the marker never appears
    /// in captured stdout. If the second source `return`s, the marker
    /// appears. We use a non-noisy marker so any future debug-print
    /// regression in the snippet itself doesn't accidentally satisfy the
    /// assertion. Audit S4-001.
    func test_osc133_fish_doubleSourceGuard_doesNotKillCallingShell() throws {
        let scriptURL = try locateScript(named: "osc133.fish")
        guard let fish = locateShell("fish") else {
            throw XCTSkip("fish not installed (not a regression — fish is optional on macOS)")
        }
        let body = """
        source '\(scriptURL.path)'
        source '\(scriptURL.path)'
        printf 'BB_FISH_SURVIVED_RE_SOURCE\\n'
        """
        let out = try runShell(at: fish, scriptBody: body)
        XCTAssertTrue(
            out.contains("BB_FISH_SURVIVED_RE_SOURCE"),
            "fish: double-sourcing the snippet terminated the calling shell — the " +
            "double-source guard must use `return`, not `exit`. The bash and zsh " +
            "siblings already use the correct primitive. Captured: \(debugHex(out))"
        )
    }

    /// Pin the fish wiring. fish doesn't use PS1; the snippet documents
    /// that users append `__bb_osc133_b` to their `fish_prompt` function
    /// manually. The function `__bb_osc133_b` MUST be defined post-
    /// source — that's the precondition for any user-side wiring to
    /// work. A regression that dropped the function definition (while
    /// leaving the event handlers in place) would silently break B.
    func test_osc133_fish_promptFunctionDefined() throws {
        let scriptURL = try locateScript(named: "osc133.fish")
        guard let fish = locateShell("fish") else {
            throw XCTSkip("fish not installed (not a regression — fish is optional on macOS)")
        }
        // `functions -q __bb_osc133_b` exits 0 if the function is
        // defined, 1 otherwise. Print a marker so we can substring-
        // match the result regardless of fish's own output noise.
        let body = """
        source '\(scriptURL.path)'
        if functions -q __bb_osc133_b
            printf 'BB_FN_DEFINED\\n'
        else
            printf 'BB_FN_MISSING\\n'
        end
        """
        let out = try runShell(at: fish, scriptBody: body)
        XCTAssertTrue(
            out.contains("BB_FN_DEFINED"),
            "fish: __bb_osc133_b must be defined after sourcing the snippet — users " +
            "wire it into fish_prompt themselves; without the function, no wiring is " +
            "possible. Got: \(debugHex(out))"
        )
    }

    // MARK: - Debug helpers

    /// Render the captured output as `[ASCII]<HEX>[ASCII]` so an assertion
    /// failure surfaces the exact byte sequence — escapes don't print
    /// usefully via plain interpolation.
    private func debugHex(_ s: String) -> String {
        let bytes = Array(s.utf8)
        var out = ""
        for b in bytes {
            if b == 0x1B {
                out += "<ESC>"
            } else if b < 0x20 || b > 0x7E {
                out += String(format: "<%02X>", b)
            } else {
                out.append(Character(UnicodeScalar(b)))
            }
        }
        return out
    }
}
