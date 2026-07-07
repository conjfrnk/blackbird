import XCTest
@testable import Blackbird

/// Blind-authored tests for `ShellIntegration` (the Swift side that decides
/// which env vars to inject when spawning a login shell, and that
/// materializes the shipped shell snippets into a user-writable root) and
/// for the shipped `zshenv-bootstrap.zsh` template (the zsh side that
/// re-points `$ZDOTDIR`, chains the user's real `.zshenv`, and defers the
/// integration load to the first prompt).
///
/// These were written WITHOUT sight of the implementation, from the API
/// contract alone, so a wrong-but-plausible implementation that happens to
/// pass a co-authored test can't slip through. Until `ShellIntegration`
/// and `zshenv-bootstrap.zsh` land, this file will not compile / will fail
/// — that red state is the point of TDD, not a bug in the tests.
///
/// Two suites:
///
///  1. `ShellIntegrationTests` — pure-function coverage of
///     `envOverrides(...)` and `materialize(...)`. No shell, no subprocess:
///     `envOverrides` is a total function over its inputs and `materialize`
///     only touches a throwaway temp dir. Per-test cost is a handful of
///     dictionary comparisons plus, for materialize, a few tiny file
///     writes (< 1 KB each). Trivially under the per-test budget.
///
///  2. `ShellIntegrationBootstrapTests` — behavioural coverage of the
///     shipped `zshenv-bootstrap.zsh` by copying it into a temp
///     `zdotdir/.zshenv` and launching a real `/bin/zsh -i -c` with a fully
///     specified environment and a temp `HOME` (so no real user rc leaks
///     in). Each scenario spawns exactly one short-lived zsh (< 1 s,
///     no PTY, no GUI, no network).

// MARK: - Pure functions: envOverrides / materialize

final class ShellIntegrationTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        // Same host-termination guard every suite in this bundle registers.
        TestHostTermination.shared.register()
    }

    /// A synthetic materialized-root URL. `envOverrides` never touches the
    /// filesystem, so the path need not exist — it only has to round-trip
    /// through the same URL arithmetic the contract specifies.
    private let root = URL(fileURLWithPath: "/private/tmp/bb-materialized-root")

    /// The contract: `ZDOTDIR` = `<materializedRoot>/zdotdir` as a path
    /// string. Compute the expectation the canonical URL way so we compare
    /// against the same value regardless of whether the impl appends a path
    /// component or concatenates strings (identical for a non-trailing-slash
    /// root).
    private var expectedZdotdir: String { root.appendingPathComponent("zdotdir").path }

    // MARK: enabled / nil gating

    func test_envOverrides_disabled_returnsEmpty() {
        // enabled == false wins over everything else: a fully valid zsh
        // configuration still yields no overrides.
        let result = ShellIntegration.envOverrides(
            shellPath: "/bin/zsh",
            integrationDir: "/opt/bb/integration",
            materializedRoot: root,
            parentEnv: ["ZDOTDIR": "/home/u/.zdot"],
            enabled: false
        )
        XCTAssertTrue(result.isEmpty,
            "enabled == false must short-circuit to [:] regardless of other inputs; got \(result)")
    }

    func test_envOverrides_nilIntegrationDir_returnsEmpty() {
        let result = ShellIntegration.envOverrides(
            shellPath: "/bin/zsh",
            integrationDir: nil,
            materializedRoot: root,
            parentEnv: [:],
            enabled: true
        )
        XCTAssertTrue(result.isEmpty,
            "a nil integrationDir means nothing to inject; expected [:], got \(result)")
    }

    func test_envOverrides_nilMaterializedRoot_returnsEmpty() {
        let result = ShellIntegration.envOverrides(
            shellPath: "/bin/zsh",
            integrationDir: "/opt/bb/integration",
            materializedRoot: nil,
            parentEnv: [:],
            enabled: true
        )
        XCTAssertTrue(result.isEmpty,
            "a nil materializedRoot means we have no ZDOTDIR to point at; expected [:], got \(result)")
    }

    func test_envOverrides_bothNil_returnsEmpty() {
        let result = ShellIntegration.envOverrides(
            shellPath: "/bin/zsh",
            integrationDir: nil,
            materializedRoot: nil,
            parentEnv: [:],
            enabled: true
        )
        XCTAssertTrue(result.isEmpty,
            "both prerequisites nil → [:]; got \(result)")
    }

    // MARK: zsh branch

    func test_envOverrides_zsh_withoutParentZDOTDIR_setsZdotdirAndIntegrationDir() {
        let result = ShellIntegration.envOverrides(
            shellPath: "/bin/zsh",
            integrationDir: "/opt/bb/integration",
            materializedRoot: root,
            parentEnv: [:],   // no ZDOTDIR in parent
            enabled: true
        )
        // Exactly two keys, no BB_ORIG_ZDOTDIR because the parent had none.
        XCTAssertEqual(Set(result.keys), ["ZDOTDIR", "BB_SHELL_INTEGRATION_DIR"],
            "zsh with no parent ZDOTDIR must inject exactly ZDOTDIR + BB_SHELL_INTEGRATION_DIR; got keys \(Set(result.keys))")
        XCTAssertEqual(result["ZDOTDIR"], expectedZdotdir,
            "ZDOTDIR must point at <materializedRoot>/zdotdir")
        XCTAssertEqual(result["BB_SHELL_INTEGRATION_DIR"], "/opt/bb/integration",
            "BB_SHELL_INTEGRATION_DIR must be the integrationDir verbatim")
        XCTAssertNil(result["BB_ORIG_ZDOTDIR"],
            "no BB_ORIG_ZDOTDIR when the parent env has no ZDOTDIR key")
    }

    func test_envOverrides_zsh_withParentZDOTDIR_capturesOrigZdotdir() {
        let result = ShellIntegration.envOverrides(
            shellPath: "/bin/zsh",
            integrationDir: "/opt/bb/integration",
            materializedRoot: root,
            parentEnv: ["ZDOTDIR": "/home/u/.config/zsh"],
            enabled: true
        )
        XCTAssertEqual(Set(result.keys),
            ["ZDOTDIR", "BB_SHELL_INTEGRATION_DIR", "BB_ORIG_ZDOTDIR"],
            "zsh with a parent ZDOTDIR must additionally stash BB_ORIG_ZDOTDIR; got keys \(Set(result.keys))")
        XCTAssertEqual(result["ZDOTDIR"], expectedZdotdir)
        XCTAssertEqual(result["BB_SHELL_INTEGRATION_DIR"], "/opt/bb/integration")
        XCTAssertEqual(result["BB_ORIG_ZDOTDIR"], "/home/u/.config/zsh",
            "BB_ORIG_ZDOTDIR must preserve the parent's original ZDOTDIR so the bootstrap can restore it")
    }

    func test_envOverrides_zsh_withEmptyParentZDOTDIR_capturesEmptyOrig() {
        // The contract keys BB_ORIG_ZDOTDIR on *presence* of the parent
        // ZDOTDIR key, not on it being non-empty. A parent that exported
        // ZDOTDIR="" must still round-trip an empty BB_ORIG_ZDOTDIR so the
        // bootstrap restores exactly what the user had.
        let result = ShellIntegration.envOverrides(
            shellPath: "/bin/zsh",
            integrationDir: "/opt/bb/integration",
            materializedRoot: root,
            parentEnv: ["ZDOTDIR": ""],
            enabled: true
        )
        XCTAssertEqual(result["BB_ORIG_ZDOTDIR"], "",
            "an empty-but-present parent ZDOTDIR must still produce a "
                + "BB_ORIG_ZDOTDIR key carrying the empty value the parent set")
        XCTAssertEqual(Set(result.keys),
            ["ZDOTDIR", "BB_SHELL_INTEGRATION_DIR", "BB_ORIG_ZDOTDIR"])
    }

    func test_envOverrides_zsh_selectedByLastPathComponent() {
        // Selection is by the LAST path component only. A homebrew zsh
        // resolves to the zsh branch...
        let brew = ShellIntegration.envOverrides(
            shellPath: "/opt/homebrew/bin/zsh",
            integrationDir: "/i",
            materializedRoot: root,
            parentEnv: [:],
            enabled: true
        )
        XCTAssertNotNil(brew["ZDOTDIR"],
            "/opt/homebrew/bin/zsh must select the zsh branch by last path component")

        // ...and a bare "zsh" with no directory still resolves to zsh.
        let bare = ShellIntegration.envOverrides(
            shellPath: "zsh",
            integrationDir: "/i",
            materializedRoot: root,
            parentEnv: [:],
            enabled: true
        )
        XCTAssertNotNil(bare["ZDOTDIR"],
            "a bare \"zsh\" (no slash) must select the zsh branch")

        // ...and a path with "fish" earlier in it but "zsh" as the last
        // component must select zsh, NOT fish — proving the choice is the
        // last component, not a substring search.
        let trap = ShellIntegration.envOverrides(
            shellPath: "/opt/fish/tools/zsh",
            integrationDir: "/i",
            materializedRoot: root,
            parentEnv: [:],
            enabled: true
        )
        XCTAssertNotNil(trap["ZDOTDIR"],
            "'/opt/fish/tools/zsh' must select zsh by its last component")
        XCTAssertNil(trap["XDG_DATA_DIRS"],
            "'/opt/fish/tools/zsh' must NOT trip the fish branch just because 'fish' appears mid-path")
    }

    // MARK: fish branch

    func test_envOverrides_fish_withoutParentXDG_usesDefault() {
        let result = ShellIntegration.envOverrides(
            shellPath: "/opt/homebrew/bin/fish",
            integrationDir: "/opt/bb/integration",
            materializedRoot: root,
            parentEnv: [:],   // no XDG_DATA_DIRS
            enabled: true
        )
        XCTAssertEqual(Set(result.keys), ["XDG_DATA_DIRS", "BB_SHELL_INTEGRATION_DIR"],
            "fish must inject exactly XDG_DATA_DIRS + BB_SHELL_INTEGRATION_DIR; got keys \(Set(result.keys))")
        XCTAssertEqual(result["XDG_DATA_DIRS"], root.path + ":/usr/local/share:/usr/share",
            "with no parent XDG_DATA_DIRS the fish branch must fall back to the freedesktop default tail")
        XCTAssertEqual(result["BB_SHELL_INTEGRATION_DIR"], "/opt/bb/integration")
    }

    func test_envOverrides_fish_withParentXDG_prepends() {
        let result = ShellIntegration.envOverrides(
            shellPath: "/opt/homebrew/bin/fish",
            integrationDir: "/opt/bb/integration",
            materializedRoot: root,
            parentEnv: ["XDG_DATA_DIRS": "/nix/share:/snap/share"],
            enabled: true
        )
        XCTAssertEqual(result["XDG_DATA_DIRS"], root.path + ":/nix/share:/snap/share",
            "fish must prepend '<materializedRoot>:' to the existing XDG_DATA_DIRS so our vendor conf wins but the user's dirs are preserved")
    }

    func test_envOverrides_fish_doesNotLeakOrigZdotdir() {
        // The fish branch is a closed set of exactly two keys. A parent
        // ZDOTDIR (irrelevant to fish) must not bleed a BB_ORIG_ZDOTDIR in.
        let result = ShellIntegration.envOverrides(
            shellPath: "/usr/local/bin/fish",
            integrationDir: "/i",
            materializedRoot: root,
            parentEnv: ["ZDOTDIR": "/home/u/.zdot"],
            enabled: true
        )
        XCTAssertNil(result["BB_ORIG_ZDOTDIR"],
            "the fish branch must never emit BB_ORIG_ZDOTDIR (that's a zsh-only concern)")
        XCTAssertEqual(Set(result.keys), ["XDG_DATA_DIRS", "BB_SHELL_INTEGRATION_DIR"])
    }

    // MARK: other shells

    func test_envOverrides_bash_returnsEmpty() {
        let result = ShellIntegration.envOverrides(
            shellPath: "/bin/bash",
            integrationDir: "/opt/bb/integration",
            materializedRoot: root,
            parentEnv: ["ZDOTDIR": "/x"],
            enabled: true
        )
        XCTAssertTrue(result.isEmpty,
            "bash integration is not wired through env overrides; expected [:], got \(result)")
    }

    func test_envOverrides_unknownShell_returnsEmpty() {
        for shell in ["/usr/bin/nu", "/bin/sh", "/opt/homebrew/bin/elvish", "/bin/tcsh"] {
            let result = ShellIntegration.envOverrides(
                shellPath: shell,
                integrationDir: "/opt/bb/integration",
                materializedRoot: root,
                parentEnv: [:],
                enabled: true
            )
            XCTAssertTrue(result.isEmpty,
                "\(shell) is neither zsh nor fish; expected [:], got \(result)")
        }
    }

    // MARK: materialize

    /// Per-test workspace root, removed in tearDown.
    private var tempBase: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempBase = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("BBShellIntegrationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempBase { try? FileManager.default.removeItem(at: tempBase) }
        tempBase = nil
        try super.tearDownWithError()
    }

    /// Write a small template file with distinctive marker contents so we
    /// can prove the destination received *these* bytes (and not some
    /// default or a stale copy).
    private func writeTemplate(_ name: String, marker: String) throws -> URL {
        let url = tempBase.appendingPathComponent(name)
        try marker.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func contents(of url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    func test_materialize_freshRoot_writesBothTemplatesAndReturnsRoot() throws {
        let zMarker = "ZSHENV-\(UUID().uuidString)"
        let fMarker = "FISH-\(UUID().uuidString)"
        let zTemplate = try writeTemplate("zshenv.tmpl", marker: zMarker)
        let fTemplate = try writeTemplate("fish.tmpl", marker: fMarker)
        let root = tempBase.appendingPathComponent("materialized")   // does not exist yet

        let returned = ShellIntegration.materialize(
            into: root, zshenvTemplate: zTemplate, fishTemplate: fTemplate)

        XCTAssertEqual(returned, root,
            "materialize must return the root URL on success")

        // Intermediate directories must have been created on the way.
        let zDest = root.appendingPathComponent("zdotdir/.zshenv")
        let fDest = root.appendingPathComponent("fish/vendor_conf.d/blackbird.fish")
        XCTAssertTrue(FileManager.default.fileExists(atPath: zDest.path),
            "zshenv must be materialized at <root>/zdotdir/.zshenv")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fDest.path),
            "fish conf must be materialized at <root>/fish/vendor_conf.d/blackbird.fish")
        XCTAssertEqual(try contents(of: zDest), zMarker,
            "the materialized .zshenv must contain the zshenv template's bytes")
        XCTAssertEqual(try contents(of: fDest), fMarker,
            "the materialized blackbird.fish must contain the fish template's bytes")
    }

    func test_materialize_overwritesTamperedDestinations() throws {
        let zMarker = "ZSHENV-AUTHORITATIVE-\(UUID().uuidString)"
        let fMarker = "FISH-AUTHORITATIVE-\(UUID().uuidString)"
        let zTemplate = try writeTemplate("zshenv.tmpl", marker: zMarker)
        let fTemplate = try writeTemplate("fish.tmpl", marker: fMarker)
        let root = tempBase.appendingPathComponent("materialized")

        // Pre-seed the destinations with tampered contents.
        let zDest = root.appendingPathComponent("zdotdir/.zshenv")
        let fDest = root.appendingPathComponent("fish/vendor_conf.d/blackbird.fish")
        try FileManager.default.createDirectory(
            at: zDest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: fDest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "TAMPERED-ZSHENV".write(to: zDest, atomically: true, encoding: .utf8)
        try "TAMPERED-FISH".write(to: fDest, atomically: true, encoding: .utf8)

        let returned = ShellIntegration.materialize(
            into: root, zshenvTemplate: zTemplate, fishTemplate: fTemplate)

        XCTAssertEqual(returned, root, "materialize must still succeed over tampered files")
        XCTAssertEqual(try contents(of: zDest), zMarker,
            "materialize is authoritative: a tampered .zshenv must be replaced with the template's bytes")
        XCTAssertEqual(try contents(of: fDest), fMarker,
            "materialize is authoritative: a tampered blackbird.fish must be replaced with the template's bytes")
    }

    func test_materialize_isIdempotent() throws {
        let zMarker = "ZSHENV-\(UUID().uuidString)"
        let fMarker = "FISH-\(UUID().uuidString)"
        let zTemplate = try writeTemplate("zshenv.tmpl", marker: zMarker)
        let fTemplate = try writeTemplate("fish.tmpl", marker: fMarker)
        let root = tempBase.appendingPathComponent("materialized")

        _ = ShellIntegration.materialize(into: root, zshenvTemplate: zTemplate, fishTemplate: fTemplate)
        let second = ShellIntegration.materialize(into: root, zshenvTemplate: zTemplate, fishTemplate: fTemplate)

        XCTAssertEqual(second, root, "a second materialize over an already-materialized root must still succeed")
        XCTAssertEqual(try contents(of: root.appendingPathComponent("zdotdir/.zshenv")), zMarker)
        XCTAssertEqual(try contents(of: root.appendingPathComponent("fish/vendor_conf.d/blackbird.fish")), fMarker)
    }

    func test_materialize_fileOccupyingRootPath_returnsNil() throws {
        let zTemplate = try writeTemplate("zshenv.tmpl", marker: "Z")
        let fTemplate = try writeTemplate("fish.tmpl", marker: "F")
        // A plain FILE at the root path: materialize can't create
        // <root>/zdotdir beneath a regular file, so it must fail cleanly.
        let occupied = tempBase.appendingPathComponent("occupied")
        try "i am a file, not a directory".write(to: occupied, atomically: true, encoding: .utf8)

        let returned = ShellIntegration.materialize(
            into: occupied, zshenvTemplate: zTemplate, fishTemplate: fTemplate)

        XCTAssertNil(returned,
            "materialize must return nil when the root path is occupied by a plain file (cannot create the tree)")
    }
}

// MARK: - Behavioural: zshenv-bootstrap.zsh

/// Drives the shipped `Sources/Blackbird/Resources/shell/zshenv-bootstrap.zsh`
/// through a real `/bin/zsh` to pin the contract the Swift side depends on:
/// the bootstrap restores/clears `$ZDOTDIR`, chains the user's real
/// `.zshenv`, and defers integration loading to the first prompt (only under
/// `TERM_PROGRAM=Blackbird`), then unhooks itself.
///
/// The template is COPIED into a temp `zdotdir/.zshenv` at runtime; its
/// contents are never inspected by this test — behaviour is observed only
/// through the environment a launched zsh reports back.
final class ShellIntegrationBootstrapTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    private var workspace: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workspace = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("BBBootstrapTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workspace { try? FileManager.default.removeItem(at: workspace) }
        workspace = nil
        try super.tearDownWithError()
    }

    // MARK: repo / template / shell location

    /// Walk up from this test file's compile-time path until we find the
    /// directory that holds `project.yml` — the repo root — as the contract
    /// specifies (rather than a fixed number of `deletingLastPathComponent`
    /// hops, which breaks if the test tree is ever nested differently).
    private func repoRoot(from file: String = #filePath) -> URL {
        let fm = FileManager.default
        var dir = URL(fileURLWithPath: file).deletingLastPathComponent()
        while dir.path != "/" {
            if fm.fileExists(atPath: dir.appendingPathComponent("project.yml").path) {
                return dir
            }
            dir = dir.deletingLastPathComponent()
        }
        return dir
    }

    private enum BootstrapError: Error, CustomStringConvertible {
        case templateMissing(String)
        var description: String {
            switch self {
            case .templateMissing(let p):
                return "zshenv-bootstrap.zsh not found at \(p)"
            }
        }
    }

    /// Copy the shipped bootstrap template into `<zdotdir>/.zshenv`. We do
    /// NOT read the template's bytes — only copy them — to stay blind to the
    /// implementation. A missing template is a hard FAILURE (not a skip):
    /// these tests are meant to stay red until the template lands.
    private func installBootstrap(intoZdotdir zdotdir: URL) throws {
        let template = repoRoot()
            .appendingPathComponent("Sources/Blackbird/Resources/shell/zshenv-bootstrap.zsh")
        guard FileManager.default.fileExists(atPath: template.path) else {
            XCTFail("Expected shipped template at \(template.path). It has not landed yet — "
                + "these bootstrap tests are supposed to fail until it does.")
            throw BootstrapError.templateMissing(template.path)
        }
        try FileManager.default.createDirectory(at: zdotdir, withIntermediateDirectories: true)
        let dest = zdotdir.appendingPathComponent(".zshenv")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.copyItem(at: template, to: dest)
    }

    private func locateZsh() throws -> URL {
        let path = "/bin/zsh"
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw XCTSkip("/bin/zsh not present — cannot exercise the bootstrap")
        }
        return URL(fileURLWithPath: path)
    }

    // MARK: zsh runner

    /// Run `/bin/zsh -i -c "source '<driver>'"` with a fully specified
    /// environment and capture stdout. Interactive (`-i`) matches how the
    /// real shell registers its prompt hooks; `-c` runs our probe and exits
    /// (no read loop, so it can never hang on missing input). A generous
    /// 5 s wall guards against a genuinely stuck script — the expected
    /// runtime is a few tens of ms.
    private func runZsh(env: [String: String], driver: String) throws -> String {
        let zsh = try locateZsh()
        let driverURL = workspace.appendingPathComponent("driver-\(UUID().uuidString).zsh")
        try driver.write(to: driverURL, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = zsh
        process.arguments = ["-i", "-c", "source '\(driverURL.path)'"]
        process.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()

        let deadline = Date().addingTimeInterval(5.0)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.1)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            XCTFail("zsh hung sourcing the bootstrap probe — likely an infinite loop in the template")
            return ""
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
    }

    /// Parse `KEY=VALUE` lines (our probes emit one per line) into a dict.
    /// Values may themselves contain `=` (paths won't, but be safe): split
    /// on the FIRST `=` only. Non-matching noise lines (global-rc chatter)
    /// are ignored, so the probe's markers survive a chatty environment.
    private func parseKV(_ output: String) -> [String: String] {
        var result: [String: String] = [:]
        for raw in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw)
            guard let eq = line.firstIndex(of: "=") else { continue }
            result[String(line[line.startIndex..<eq])] = String(line[line.index(after: eq)...])
        }
        return result
    }

    /// A baseline environment with a temp HOME and PATH, but no ZDOTDIR /
    /// BB_ORIG_ZDOTDIR / integration vars — callers layer those on. Starting
    /// from a clean dict (not the parent process env) is what "environment
    /// fully specified" means: nothing about the outer test runner's real
    /// shell config can leak in.
    private func baseEnv(zdotdir: URL, home: URL) -> [String: String] {
        [
            "HOME": home.path,
            "ZDOTDIR": zdotdir.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "TERM": "xterm-256color",
        ]
    }

    /// Standard workspace scaffolding: a bootstrap `zdotdir` (with the
    /// template copied in) and an empty temp `home`.
    private func scaffold() throws -> (zdotdir: URL, home: URL) {
        let zdotdir = workspace.appendingPathComponent("zdotdir")
        let home = workspace.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try installBootstrap(intoZdotdir: zdotdir)
        return (zdotdir, home)
    }

    // MARK: (a) restore ZDOTDIR, unset BB_ORIG_ZDOTDIR

    func test_bootstrap_withOrigZdotdir_restoresZdotdirAndUnsetsOrig() throws {
        let (zdotdir, home) = try scaffold()
        let userDir = workspace.appendingPathComponent("userdir")
        try FileManager.default.createDirectory(at: userDir, withIntermediateDirectories: true)

        var env = baseEnv(zdotdir: zdotdir, home: home)
        env["BB_ORIG_ZDOTDIR"] = userDir.path

        let out = try runZsh(env: env, driver: """
        print -r -- "ZD=${ZDOTDIR-UNSET}"
        print -r -- "ORIG=${BB_ORIG_ZDOTDIR-UNSET}"
        """)
        let kv = parseKV(out)

        XCTAssertEqual(kv["ZD"], userDir.path,
            "with BB_ORIG_ZDOTDIR set, the bootstrap must restore $ZDOTDIR to it. Output: \(out)")
        XCTAssertEqual(kv["ORIG"], "UNSET",
            "the bootstrap must unset BB_ORIG_ZDOTDIR after consuming it (it's an internal handoff). Output: \(out)")
    }

    // MARK: (b) no BB_ORIG_ZDOTDIR → ZDOTDIR unset

    func test_bootstrap_withoutOrigZdotdir_leavesZdotdirUnset() throws {
        let (zdotdir, home) = try scaffold()
        let env = baseEnv(zdotdir: zdotdir, home: home)   // no BB_ORIG_ZDOTDIR

        let out = try runZsh(env: env, driver: """
        print -r -- "ZD=${ZDOTDIR-UNSET}"
        """)
        let kv = parseKV(out)

        XCTAssertEqual(kv["ZD"], "UNSET",
            "without BB_ORIG_ZDOTDIR the bootstrap must leave $ZDOTDIR unset, so the shell falls back to $HOME. Output: \(out)")
    }

    // MARK: (c) chains the user's real .zshenv

    func test_bootstrap_chainsUserRealZshenv() throws {
        let (zdotdir, home) = try scaffold()
        let userDir = workspace.appendingPathComponent("userdir")
        try FileManager.default.createDirectory(at: userDir, withIntermediateDirectories: true)
        // The user's real .zshenv exports a marker; if the bootstrap chains
        // it, the marker is visible after startup.
        try "export BB_TEST_MARKER=1\n".write(
            to: userDir.appendingPathComponent(".zshenv"), atomically: true, encoding: .utf8)

        var env = baseEnv(zdotdir: zdotdir, home: home)
        env["BB_ORIG_ZDOTDIR"] = userDir.path

        let out = try runZsh(env: env, driver: """
        print -r -- "MARKER=${BB_TEST_MARKER-UNSET}"
        """)
        let kv = parseKV(out)

        XCTAssertEqual(kv["MARKER"], "1",
            "the bootstrap must source the user's real $BB_ORIG_ZDOTDIR/.zshenv so their config still runs. Output: \(out)")
    }

    // MARK: (d) deferred integration load under Blackbird

    func test_bootstrap_deferredIntegration_loadsOnFirstPromptAndSelfRemoves() throws {
        let (zdotdir, home) = try scaffold()
        // Stub integration dir with the two files the loader is expected to
        // source. `typeset -g` makes the markers survive past the loader
        // function's scope so we can observe them from the top level.
        let stub = workspace.appendingPathComponent("integration")
        try FileManager.default.createDirectory(at: stub, withIntermediateDirectories: true)
        try "typeset -g __BB_TEST_OSC=1\n".write(
            to: stub.appendingPathComponent("osc133.zsh"), atomically: true, encoding: .utf8)
        try "typeset -g __BB_TEST_SSH=1\n".write(
            to: stub.appendingPathComponent("ssh.zsh"), atomically: true, encoding: .utf8)

        var env = baseEnv(zdotdir: zdotdir, home: home)
        env["TERM_PROGRAM"] = "Blackbird"
        env["BB_SHELL_INTEGRATION_DIR"] = stub.path

        // Before firing precmd: markers unset (load is deferred). After
        // firing the precmd hooks once: both markers set, and the loader has
        // unhooked itself so $#precmd_functions dropped by exactly one.
        let out = try runZsh(env: env, driver: """
        print -r -- "N_BEFORE=${#precmd_functions}"
        print -r -- "OSC_BEFORE=${__BB_TEST_OSC-UNSET}"
        print -r -- "SSH_BEFORE=${__BB_TEST_SSH-UNSET}"
        for f in $precmd_functions; do "$f"; done
        print -r -- "N_AFTER=${#precmd_functions}"
        print -r -- "OSC_AFTER=${__BB_TEST_OSC-UNSET}"
        print -r -- "SSH_AFTER=${__BB_TEST_SSH-UNSET}"
        """)
        let kv = parseKV(out)

        XCTAssertEqual(kv["OSC_BEFORE"], "UNSET",
            "osc133.zsh must NOT be sourced at startup — the load is deferred to the first prompt. Output: \(out)")
        XCTAssertEqual(kv["SSH_BEFORE"], "UNSET",
            "ssh.zsh must NOT be sourced at startup — the load is deferred to the first prompt. Output: \(out)")
        XCTAssertEqual(kv["OSC_AFTER"], "1",
            "after the first precmd, the loader must have sourced osc133.zsh. Output: \(out)")
        XCTAssertEqual(kv["SSH_AFTER"], "1",
            "after the first precmd, the loader must have sourced ssh.zsh. Output: \(out)")

        let before = try XCTUnwrap(kv["N_BEFORE"].flatMap { Int($0) },
            "could not read precmd_functions count before firing. Output: \(out)")
        let after = try XCTUnwrap(kv["N_AFTER"].flatMap { Int($0) },
            "could not read precmd_functions count after firing. Output: \(out)")
        XCTAssertGreaterThanOrEqual(before, 1,
            "the deferred loader must be registered in precmd_functions before the first prompt. Output: \(out)")
        XCTAssertEqual(after, before - 1,
            "the loader must remove itself from precmd_functions after running once (a one-shot). Output: \(out)")
    }

    // MARK: (e) non-Blackbird → no integration load

    func test_bootstrap_deferredIntegration_notBlackbird_loadsNothing() throws {
        let (zdotdir, home) = try scaffold()
        let stub = workspace.appendingPathComponent("integration")
        try FileManager.default.createDirectory(at: stub, withIntermediateDirectories: true)
        // Same stub files — if the loader fired here it WOULD set markers.
        try "typeset -g __BB_TEST_OSC=1\n".write(
            to: stub.appendingPathComponent("osc133.zsh"), atomically: true, encoding: .utf8)
        try "typeset -g __BB_TEST_SSH=1\n".write(
            to: stub.appendingPathComponent("ssh.zsh"), atomically: true, encoding: .utf8)

        var env = baseEnv(zdotdir: zdotdir, home: home)
        // Deliberately not Blackbird — but also NOT "Apple_Terminal":
        // macOS's /etc/zshrc_Apple_Terminal keys on that value and
        // registers its own precmd hook (update_terminal_cwd) that emits
        // an OSC 7 to stdout when the driver fires $precmd_functions,
        // polluting the first parsed output line (seen on the first CI
        // run of this suite: "]7;file://<host>/OSC=UNSET").
        env["TERM_PROGRAM"] = "SomeOtherTerm"
        env["BB_SHELL_INTEGRATION_DIR"] = stub.path

        let out = try runZsh(env: env, driver: """
        for f in $precmd_functions; do "$f"; done
        print -r -- "OSC=${__BB_TEST_OSC-UNSET}"
        print -r -- "SSH=${__BB_TEST_SSH-UNSET}"
        """)
        let kv = parseKV(out)

        XCTAssertEqual(kv["OSC"], "UNSET",
            "outside Blackbird (TERM_PROGRAM != Blackbird) the loader must not source osc133.zsh. Output: \(out)")
        XCTAssertEqual(kv["SSH"], "UNSET",
            "outside Blackbird the loader must not source ssh.zsh. Output: \(out)")
    }
}
