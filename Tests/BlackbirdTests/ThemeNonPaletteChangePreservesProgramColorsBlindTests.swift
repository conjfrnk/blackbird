import XCTest
import AppKit
import Combine
@testable import Blackbird
@testable import BBCore

/// Blind regression coverage for settings-prefs-theme-1.
///
/// CONTRACT (derived from terminal / macOS conventions, not from the
/// implementation): a program running in a tab may recolour the terminal
/// with OSC 4 (palette slot), OSC 10 (default foreground), OSC 11 (default
/// background) and OSC 12 (cursor colour). Those colours belong to the
/// running program and persist until the program resets them (OSC 104 /
/// 110 / 111 / 112) or the app's *resolved theme palette* genuinely changes
/// (different theme, light/dark mode actually resolving to the other
/// palette).
///
/// Changes that do NOT change the resolved palette must therefore leave the
/// program's colours alone:
///   - dragging the Settings translucency slider,
///   - toggling "Blink cursor",
///   - changing the cursor shape,
///   - the macOS light/dark appearance flipping while the theme mode is
///     pinned to Dark (sunset auto-switch).
///
/// Observation strategy: a headless `TerminalSession` (no PTY, no shell) is
/// registered with `ThemeManager` exactly like a window controller would be.
/// The program colours are set by feeding real OSC sequences through the VT
/// parser, and read back two ways: resolved cell colours from a core
/// snapshot (ANSI slot 1, default fg, default bg) and the core's own reply to
/// an OSC 12 `?` query (cursor). No implementation detail of
/// `ThemeManager` / `PaletteApplier` is used.
///
/// A control test proves the rig really can see a palette push: a genuine
/// theme change must still replace the program colours with the new theme's
/// palette. Without it, a "colours preserved" result could be vacuous.
///
/// Memory / time pre-flight: one 2x2-cell headless session per test (a few
/// hundred bytes of grid, no PTY, no Metal, no window); each test spins the
/// main run loop for roughly 1 s in total. Far inside the default budget.
@MainActor
final class ThemeNonPaletteChangePreservesProgramColorsBlindTests: XCTestCase {

    // MARK: - Program colours (deliberately unlike any built-in theme)

    private static let progAnsi1: UInt32  = 0x0A1B2C
    private static let progFg: UInt32     = 0x1D2E3F
    private static let progBg: UInt32     = 0x2E3F4A
    private static let progCursor: UInt32 = 0x3F4A5B

    // MARK: - Preferences / appearance hygiene

    private var savedThemeRaw: String = ""
    private var savedThemeModeRaw: String = ""
    private var savedTranslucency: Double = 0
    private var savedCursorBlink: Bool = false
    private var savedCursorShapeRaw: String = ""
    private var savedAppAppearance: NSAppearance?

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    override func setUp() {
        super.setUp()
        let p = Preferences.shared
        savedThemeRaw       = p.themeRaw
        savedThemeModeRaw   = p.themeModeRaw
        savedTranslucency   = p.translucency
        savedCursorBlink    = p.cursorBlink
        savedCursorShapeRaw = p.cursorShapeRaw
        savedAppAppearance  = NSApp?.appearance
    }

    override func tearDown() {
        let p = Preferences.shared
        p.themeRaw       = savedThemeRaw
        p.themeModeRaw   = savedThemeModeRaw
        p.translucency   = savedTranslucency
        p.cursorBlink    = savedCursorBlink
        p.cursorShapeRaw = savedCursorShapeRaw
        NSApp?.appearance = savedAppAppearance
        // Drain ThemeManager's queued main-queue applies before the next
        // test body runs (same rationale as ThemeManagerBlindTests).
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        super.tearDown()
    }

    // MARK: - Rig

    private final class StubOwner: NSObject {}

    /// Thread-safe sink for the bytes the core wants written back to the PTY
    /// (OSC colour query replies). Events fire on the session's core queue.
    private final class ReplyBox: @unchecked Sendable {
        private let lock = NSLock()
        private var chunks: [Data] = []
        func append(_ d: Data) { lock.lock(); chunks.append(d); lock.unlock() }
        func takeAll() -> String {
            lock.lock(); defer { lock.unlock() }
            let s = chunks.map { String(decoding: $0, as: UTF8.self) }.joined()
            chunks.removeAll()
            return s
        }
    }

    private struct Colors: Equatable, CustomStringConvertible {
        var ansi1: UInt32
        var fg: UInt32
        var bg: UInt32
        var cursor: UInt32?
        var description: String {
            func hex(_ v: UInt32) -> String { String(format: "#%06X", v) }
            return "ansi1=\(hex(ansi1)) fg=\(hex(fg)) bg=\(hex(bg)) cursor=\(cursor.map(hex) ?? "nil")"
        }
    }

    private final class Rig {
        let session: TerminalSession
        let owner = StubOwner()
        let replies = ReplyBox()
        init(session: TerminalSession) { self.session = session }
    }

    /// Let queued main-queue pref sinks run and the session's core queue
    /// drain what they scheduled.
    private func settle(_ rig: Rig? = nil) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.25))
        rig?.session.coreQueue.sync {}
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        rig?.session.coreQueue.sync {}
    }

    /// Default-install preferences (dark mode, default theme, default
    /// translucency, no blink, follow-shell cursor) with the OS in LIGHT
    /// appearance, and ThemeManager's change-detection state primed by real
    /// palette-affecting writes while no session is registered yet.
    private func establishBaselinePrefs() throws {
        let app = try XCTUnwrap(NSApp, "NSApp must be alive in the xctest host")
        let p = Preferences.shared
        // Two genuine palette changes so the manager has certainly observed
        // and cached the final state, whatever its internal gating is.
        p.themeModeRaw = Preferences.ThemeMode.dark.rawValue
        p.themeRaw = Theme.solarized.rawValue
        settle()
        p.themeRaw = Preferences.defaultThemeChoice.rawValue
        p.translucency = 5
        p.cursorBlink = false
        p.cursorShapeRaw = Preferences.CursorShape.followShell.rawValue
        app.appearance = NSAppearance(named: .aqua)
        // Make sure the OS-appearance observation is live in this host.
        ThemeManager.shared.attach(toApp: app)
        settle()
    }

    /// Headless session registered with ThemeManager like a window would be.
    private func makeRegisteredRig() -> Rig {
        let session = TerminalSession.makeHeadlessForTests()
        let rig = Rig(session: session)
        let replies = rig.replies
        session.coreQueue.sync {
            session.bbterm.setColorQueryEnabled(true)
            session.bbterm.onEvent { ev in
                if case .ptyWrite(let d) = ev { replies.append(d) }
            }
        }
        ThemeManager.shared.register(
            owner: rig.owner,
            sessionProvider: { [weak session] in session },
            viewProvider: { nil }
        )
        settle(rig)
        return rig
    }

    private func feed(_ rig: Rig, _ s: String) {
        rig.session.feedBytesForTests(Data(s.utf8))
    }

    /// Read the colours the user would currently see for ANSI slot 1, the
    /// default fg / bg, and the cursor.
    private func readColors(_ rig: Rig, file: StaticString = #filePath, line: UInt = #line) throws -> Colors {
        // Re-print two probe cells (SGR 31 = ANSI slot 1; SGR 39 = default fg).
        // Colour STATE is untouched; only cells at (0,0) and (0,1) change.
        feed(rig, "\u{1b}[H\u{1b}[31mR\u{1b}[39mD\u{1b}[0m")
        let snap = try XCTUnwrap(rig.session.takeSnapshotForTests(), "snapshot", file: file, line: line)
        XCTAssertEqual(snap.cols * snap.rows, 4,
                       "fixture: headless session grid is expected to be 2x2", file: file, line: line)
        let redCell = snap.cellsPointer[0]
        let defFgCell = snap.cellsPointer[1]
        let untouched = snap.cellsPointer[3]   // row 1 col 1: never written
        XCTAssertEqual(redCell.ch, UInt32(UInt8(ascii: "R")), "fixture: probe cell 0 holds 'R'", file: file, line: line)
        XCTAssertEqual(defFgCell.ch, UInt32(UInt8(ascii: "D")), "fixture: probe cell 1 holds 'D'", file: file, line: line)

        // Cursor colour via OSC 12 query (reply goes through the core's
        // colour-query path into the session's ptyWrite event).
        _ = rig.replies.takeAll()
        feed(rig, "\u{1b}]12;?\u{1b}\\")
        rig.session.coreQueue.sync {}
        let reply = rig.replies.takeAll()
        return Colors(ansi1: redCell.fg & 0xFFFFFF,
                      fg: defFgCell.fg & 0xFFFFFF,
                      bg: untouched.bg & 0xFFFFFF,
                      cursor: Self.parseRGBReply(reply))
    }

    /// Parse `rgb:RR/GG/BB` (2 or 4 hex digits per channel) out of an OSC
    /// colour reply; take the high byte of each channel.
    private static func parseRGBReply(_ s: String) -> UInt32? {
        guard let r = s.range(of: #"rgb:([0-9a-fA-F]{2,4})/([0-9a-fA-F]{2,4})/([0-9a-fA-F]{2,4})"#,
                              options: .regularExpression) else { return nil }
        let parts = s[r].dropFirst(4).split(separator: "/")
        guard parts.count == 3 else { return nil }
        var out: UInt32 = 0
        for part in parts {
            guard let v = UInt32(part.prefix(2), radix: 16) else { return nil }
            out = (out << 8) | v
        }
        return out
    }

    private func themeColors(_ palette: ThemePalette) -> Colors {
        Colors(ansi1: palette.ansi[1] & 0xFFFFFF,
               fg: palette.foreground & 0xFFFFFF,
               bg: palette.background & 0xFFFFFF,
               cursor: palette.cursor & 0xFFFFFF)
    }

    private var programColors: Colors {
        Colors(ansi1: Self.progAnsi1, fg: Self.progFg, bg: Self.progBg, cursor: Self.progCursor)
    }

    /// A program recolours the terminal via OSC 4 / 10 / 11 / 12.
    private func programSetsColors(_ rig: Rig) {
        feed(rig, "\u{1b}]4;1;rgb:0a/1b/2c\u{1b}\\")
        feed(rig, "\u{1b}]10;rgb:1d/2e/3f\u{1b}\\")
        feed(rig, "\u{1b}]11;rgb:2e/3f/4a\u{1b}\\")
        feed(rig, "\u{1b}]12;rgb:3f/4a/5b\u{1b}\\")
    }

    /// Common scenario: baseline -> theme palette live -> program recolours
    /// -> `trigger` -> program colours must be untouched.
    private func assertTriggerPreservesProgramColors(
        _ triggerName: String,
        file: StaticString = #filePath, line: UInt = #line,
        trigger: (Rig) throws -> Void
    ) throws {
        try establishBaselinePrefs()
        let rig = makeRegisteredRig()
        defer { withExtendedLifetime(rig) {} }

        // Precondition A: the theme palette really is live in the session
        // (so "unchanged" below cannot be a no-op rig).
        let theme = themeColors(ThemeManager.shared.resolvedPalette)
        let themed = try readColors(rig, file: file, line: line)
        XCTAssertEqual(themed, theme,
                       "precondition: registered session shows the resolved theme palette before the program recolours it",
                       file: file, line: line)

        // Precondition B: the program colours are distinct from the theme
        // and are what the user sees after the OSC sequences.
        XCTAssertNotEqual(programColors, theme,
                          "fixture: program colours must differ from the theme palette", file: file, line: line)
        programSetsColors(rig)
        let programmed = try readColors(rig, file: file, line: line)
        XCTAssertEqual(programmed, programColors,
                       "precondition: OSC 4/10/11/12 colours are live in the session before the trigger",
                       file: file, line: line)

        try trigger(rig)
        settle(rig)

        let after = try readColors(rig, file: file, line: line)
        XCTAssertEqual(
            after, programmed,
            """
            \(triggerName) does not change the resolved palette, so the \
            program-set OSC colours must survive. before=\(programmed) \
            after=\(after) themePalette=\(theme)
            """,
            file: file, line: line)
    }

    // MARK: - Tests

    /// Control: a REAL palette change (different theme) still replaces the
    /// program colours with the new palette. Proves the rig can observe a
    /// palette push, so the "preserved" tests below are not vacuous, and
    /// pins that a fix must not stop genuine theme changes from applying.
    func test_control_genuineThemeChange_stillRepushesPalette() throws {
        try establishBaselinePrefs()
        let rig = makeRegisteredRig()
        programSetsColors(rig)
        let programmed = try readColors(rig)
        XCTAssertEqual(programmed, programColors,
                       "precondition: program colours live before the theme change")

        Preferences.shared.themeRaw = Theme.catppuccin.rawValue
        settle(rig)

        let expected = themeColors(Theme.catppuccin.palette(dark: true))
        XCTAssertEqual(ThemeManager.shared.resolvedPalette, Theme.catppuccin.palette(dark: true),
                       "fixture: dark mode + Catppuccin resolves to the Catppuccin dark palette")
        let after = try readColors(rig)
        XCTAssertEqual(after, expected,
                       "a genuine theme change must apply the new theme palette. after=\(after) expected=\(expected)")
        withExtendedLifetime(rig) {}
    }

    /// Dragging the Settings translucency slider must not wipe program colours.
    func test_translucencySliderChange_preservesProgramColors() throws {
        try assertTriggerPreservesProgramColors("Changing translucency") { _ in
            Preferences.shared.translucency = 8
        }
    }

    /// Toggling "Blink cursor" must not wipe program colours.
    func test_cursorBlinkToggle_preservesProgramColors() throws {
        try assertTriggerPreservesProgramColors("Toggling cursor blink") { _ in
            Preferences.shared.cursorBlink = true
        }
    }

    /// Changing the cursor shape must not wipe program colours.
    func test_cursorShapeChange_preservesProgramColors() throws {
        try assertTriggerPreservesProgramColors("Changing cursor shape") { _ in
            Preferences.shared.cursorShapeRaw = Preferences.CursorShape.bar.rawValue
        }
    }

    /// The macOS light/dark appearance flipping while the theme mode is
    /// pinned to Dark (sunset auto-switch) resolves to the SAME palette, so
    /// it must not wipe program colours.
    func test_osAppearanceFlip_withModePinnedToDark_preservesProgramColors() throws {
        let app = try XCTUnwrap(NSApp, "NSApp must be alive in the xctest host")
        try assertTriggerPreservesProgramColors("Flipping the OS appearance while mode is Dark") { _ in
            XCTAssertEqual(Preferences.shared.themeMode, .dark,
                           "precondition: theme mode is pinned to Dark")
            let before = app.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
            XCTAssertEqual(before, .aqua, "precondition: OS starts in light appearance")
            let paletteBefore = ThemeManager.shared.resolvedPalette
            app.appearance = NSAppearance(named: .darkAqua)
            let after = app.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
            XCTAssertEqual(after, .darkAqua, "the simulated OS flip must reach effectiveAppearance")
            XCTAssertEqual(ThemeManager.shared.resolvedPalette, paletteBefore,
                           "fixture: with mode pinned to Dark the resolved palette must not change on an OS flip")
        }
    }

    /// Cost side of the same bug: a burst of slider ticks must not push the
    /// palette into (and re-publish a snapshot for) every live session. A
    /// headless session with no input produces no snapshot of its own, so
    /// any publish here is a palette push.
    func test_translucencySliderBurst_doesNotRepublishSnapshots() throws {
        try establishBaselinePrefs()
        let rig = makeRegisteredRig()
        settle(rig)

        var publishes = 0
        let sub = rig.session.$snapshot.dropFirst().sink { _ in publishes += 1 }
        defer { sub.cancel() }

        let ticks: [Double] = [6, 7, 8, 9, 10, 9, 8, 7, 6, 4]
        XCTAssertEqual(ticks.count, 10, "fixture: ten slider ticks")
        for v in ticks {
            Preferences.shared.translucency = v
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
        }
        settle(rig)

        XCTAssertEqual(
            publishes, 0,
            "\(ticks.count) translucency slider ticks leave the resolved palette unchanged, yet the session republished \(publishes) snapshot(s) (palette re-pushed per tick)")
        withExtendedLifetime(rig) {}
    }
}
