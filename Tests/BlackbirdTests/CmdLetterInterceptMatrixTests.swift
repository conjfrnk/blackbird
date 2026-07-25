import XCTest
import AppKit
@testable import Blackbird

/// Pins **which** Cmd+letter and Cmd+Shift+letter shortcuts the app
/// intercepts (menu / responder chain) versus passes upstream when no
/// menu binding exists. The single existing
/// `TerminalViewTests.test_commandKeyDoesNotSendToPty` proves the
/// universal `.command` filter for one cell (⌘C); this file walks the
/// full 26 × 2 matrix so a future change that flips, adds, or removes a
/// shortcut surfaces as a named-cell test failure rather than a silent
/// drift.
///
/// Outcomes per cell, recorded in `Self.expected` below:
///
///   - `.interceptedByMenu` — `AppDelegate.installMainMenu()` builds an
///     `NSMenuItem` whose `keyEquivalent` + `keyEquivalentModifierMask`
///     matches this chord, AND the action selector resolves to a real
///     method on the responder chain. AppKit dispatches the action
///     when the chord fires; `TerminalView.keyDown` never produces PTY
///     bytes either way (the `.command` early return at
///     `TerminalView.swift:1637-1640` filters defensively before the
///     encoder ever runs).
///
///   - `.menuBindingDeadOnArrival` — the menu binding exists, but the
///     action selector is unimplemented; AppKit disables the menu
///     item via automatic menu validation (`responds(to:)` returns
///     false everywhere on the chain) and the chord beeps at the user.
///     PRODUCT-BUG (2026-05-09): ⌘Z and ⌘⇧Z fall here because
///     `AppDelegate+Menu.swift:144-145` wires `Edit > Undo` and
///     `Edit > Redo` to `Selector(("undo:"))` / `Selector(("redo:"))`,
///     and no responder in the Blackbird tree implements either — so
///     the matrix-as-was reported `.interceptedByMenu` (a green "this
///     works" signal) for two chords that beep. Pinned here so a
///     future fix that wires real undo/redo support flips the matrix
///     and a fix-without-pin-update is caught.
///
///   - `.interceptedByView` — `TerminalView.keyDown` consumes the event
///     itself (e.g. flips a state bit, calls a handler, swallows). NO
///     ⌘+letter cell currently takes this path on macOS Blackbird:
///     ⌘K (clear buffer) appears at first glance to be a view-owned
///     shortcut, but it's actually wired through the menu chain
///     (`AppDelegate+Menu.swift:208-212`) and only the `@objc` selector
///     `clearBufferAndScrollback(_:)` lives on `TerminalView`. Same for
///     ⌘F / ⌘G / ⌘+/⌘-/⌘0 etc. — selector lives on the view; the
///     binding lives on the menu item. The category is preserved here
///     so a hypothetical future cell (e.g. ⌘L theme cycle) has somewhere
///     to land without a schema change.
///
///   - `.forwardedToSuper` — neither the menu nor the view binds this
///     chord. `TerminalView.keyDown` still filters via the `.command`
///     early-return (no PTY bytes), then `super.keyDown(with:)` walks
///     the responder chain. AppKit's default behaviour for an
///     unbound ⌘+letter is to play the system error sound (NSBeep)
///     and consume the event. We do not assert NSBeep — only that
///     the chord is unbound on the menu side and the encoder / view
///     emit zero PTY bytes.
///
///   - `.forwardedToPty` — encoder returns bytes for the chord. The
///     `KeyEncoder.encode` body explicitly drops `.command` at
///     `KeyEncoder.swift:96-100`; this category exists in the schema
///     so a regression that re-enables ⌘+letter encoding surfaces as a
///     specific cell flip rather than a vague "encoder broke" failure.
///     EXPECTED COUNT IN THE CURRENT MATRIX: zero. This is the bright
///     line we are pinning.
///
/// Memory + safety budget (per memories `feedback_test_memory_safety`,
/// `feedback_no_keystroke_injection`, `feedback_test_real_shell_controllers`):
///
///   - 52 NSEvent synth + 52 KeyEncoder calls + 52 menu walks. Per-cell
///     cost is microseconds; total < 50 ms. No allocation concerns.
///   - NO AppleScript keystroke injection — every event is built
///     in-process via `NSEvent.keyEvent(with:...)`.
///   - NO real `MainWindowController` instances. We construct a fresh
///     `AppDelegate` purely to call `installMainMenu()` (a `final class
///     NSObject` subclass with no custom `init`, so the constructor is
///     side-effect-free); the menu it builds is a plain `NSMenu` tree
///     that can be inspected without ever showing a window. After
///     inspection we restore `NSApp.mainMenu` to whatever it was at
///     entry so we don't pollute sibling tests in the same xctest host.
///   - NO `wait(for:)` runloop pumping — the `.command` filter inside
///     `TerminalView.keyDown` is synchronous (no DispatchQueue.async,
///     no Combine sink), so we don't need to drain the runloop after
///     each event. This avoids the ASan / CATransaction hazard that
///     gates `test_commandKeyDoesNotSendToPty` behind
///     `BB_RUN_STRESS_TESTS`.
// @MainActor: AppDelegate is now @MainActor-isolated (its init + installMainMenu
// must run on the main actor; these tests already run on main).
@MainActor
final class CmdLetterInterceptMatrixTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Outcomes + matrix

    enum Outcome: String {
        case interceptedByMenu        = "INTERCEPTED_BY_MENU"
        case menuBindingDeadOnArrival = "MENU_BINDING_DEAD_ON_ARRIVAL"
        case interceptedByView        = "INTERCEPTED_BY_VIEW"
        case forwardedToSuper         = "FORWARDED_TO_SUPER"
        case forwardedToPty           = "FORWARDED_TO_PTY"
    }

    /// One row per (letter, shift?) chord. `expected` is the pinned
    /// current behaviour as of this commit. Reading order matches a
    /// QWERTY keyboard top-to-bottom A-Z so a glance at a failure
    /// quickly tells you which key flipped.
    ///
    /// Cells without a menu binding fall to `.forwardedToSuper`. Each
    /// `.interceptedByMenu` cell carries the menu-tree path so a flip
    /// failure tells the reader which menu owned the shortcut.
    static let expected: [(letter: Character, shift: Bool, outcome: Outcome, note: String)] = [
        // Cmd+letter (no Shift)
        ("a", false, .interceptedByMenu, "Edit > Select All"),
        ("b", false, .forwardedToSuper,  "unbound"),
        ("c", false, .interceptedByMenu, "Edit > Copy"),
        ("d", false, .forwardedToSuper,  "unbound"),
        ("e", false, .forwardedToSuper,  "unbound (⌥⌘E owns Replace Selection)"),
        ("f", false, .interceptedByMenu, "Edit > Find > Find…"),
        ("g", false, .interceptedByMenu, "Edit > Find > Find Next"),
        ("h", false, .interceptedByMenu, "Blackbird > Hide Blackbird"),
        ("i", false, .forwardedToSuper,  "unbound"),
        ("j", false, .forwardedToSuper,  "unbound"),
        ("k", false, .interceptedByMenu, "Edit > Clear Buffer (selector lives on TerminalView)"),
        ("l", false, .forwardedToSuper,  "unbound — no theme cycle shortcut exists"),
        ("m", false, .interceptedByMenu, "Window > Minimize"),
        ("n", false, .interceptedByMenu, "File > New Window"),
        ("o", false, .forwardedToSuper,  "unbound"),
        ("p", false, .forwardedToSuper,  "unbound"),
        ("q", false, .interceptedByMenu, "Blackbird > Quit Blackbird"),
        ("r", false, .forwardedToSuper,  "unbound (⌃⌘R owns Rename Tab)"),
        ("s", false, .forwardedToSuper,  "unbound — no Save action in a terminal"),
        ("t", false, .interceptedByMenu, "File > New Tab"),
        ("u", false, .forwardedToSuper,  "unbound"),
        ("v", false, .interceptedByMenu, "Edit > Paste"),
        ("w", false, .interceptedByMenu, "Window > Close"),
        ("x", false, .interceptedByMenu, "Edit > Cut"),
        ("y", false, .forwardedToSuper,  "unbound"),
        // PRODUCT-BUG-FIX (2026-05-09): Previously pinned as
        // `.menuBindingDeadOnArrival` because `Edit > Undo` was wired
        // to `Selector(("undo:"))` with no responder implementing it,
        // which left users with a greyed menu item and an NSBeep on
        // every ⌘Z. Resolution: removed the menu item entirely
        // (terminals have no editable document; matches Terminal.app
        // and iTerm2 — neither ships Edit > Undo/Redo). With no menu
        // binding and no view-level handler, ⌘Z now lands in the
        // standard "unbound ⌘-letter" bucket alongside ⌘B / ⌘D / etc.
        // See `AppDelegate+Menu.swift` `buildEditMenu()` for the
        // reasoning. The `.menuBindingDeadOnArrival` enum case is
        // kept as a reusable pin shape for future regressions of the
        // same form.
        ("z", false, .forwardedToSuper,  "unbound — Edit > Undo intentionally absent (terminals have no edit document)"),

        // Cmd+Shift+letter
        ("a", true,  .forwardedToSuper,  "unbound"),
        ("b", true,  .forwardedToSuper,  "unbound"),
        ("c", true,  .forwardedToSuper,  "unbound (⌥⌘C owns Find: Case Sensitive)"),
        ("d", true,  .forwardedToSuper,  "unbound"),
        ("e", true,  .forwardedToSuper,  "unbound"),
        ("f", true,  .forwardedToSuper,  "unbound"),
        ("g", true,  .interceptedByMenu, "Edit > Find > Find Previous"),
        ("h", true,  .forwardedToSuper,  "unbound (⌥⌘H owns Hide Others)"),
        ("i", true,  .forwardedToSuper,  "unbound"),
        ("j", true,  .forwardedToSuper,  "unbound"),
        ("k", true,  .forwardedToSuper,  "unbound"),
        ("l", true,  .forwardedToSuper,  "unbound"),
        ("m", true,  .forwardedToSuper,  "unbound"),
        ("n", true,  .forwardedToSuper,  "unbound"),
        ("o", true,  .forwardedToSuper,  "unbound"),
        ("p", true,  .forwardedToSuper,  "unbound"),
        ("q", true,  .forwardedToSuper,  "unbound"),
        ("r", true,  .forwardedToSuper,  "unbound (⌃⌘R owns Rename Tab)"),
        ("s", true,  .forwardedToSuper,  "unbound"),
        ("t", true,  .forwardedToSuper,  "unbound"),
        ("u", true,  .forwardedToSuper,  "unbound"),
        ("v", true,  .forwardedToSuper,  "unbound"),
        ("w", true,  .interceptedByMenu, "Window > Close Window"),
        ("x", true,  .forwardedToSuper,  "unbound"),
        ("y", true,  .forwardedToSuper,  "unbound"),
        // PRODUCT-BUG-FIX (2026-05-09): see ⌘Z entry above. `Edit > Redo`
        // had the same dead-selector shape (`Selector(("redo:"))` with
        // no responder); the menu item was removed in lockstep with
        // Undo. ⌘⇧Z now falls to the unbound chord path.
        ("z", true,  .forwardedToSuper,  "unbound — Edit > Redo intentionally absent (terminals have no edit document)"),
    ]

    // MARK: - Helpers

    /// Synthesize a `keyDown` NSEvent for a Cmd+letter (or Cmd+Shift+letter)
    /// chord. Mirrors the pattern used by
    /// `TerminalViewTests.test_commandKeyDoesNotSendToPty` (line ~285) so
    /// future readers can find the contract via `git grep NSEvent.keyEvent`.
    ///
    /// `chars` is the **post-Shift** form macOS hands AppKit:
    /// Shift+`a` arrives as `"A"`, plain `a` as `"a"`. NSMenuItem matches
    /// against this exact form (uppercase for Shift+letter), so the
    /// matrix-lookup probe needs the same.
    private func makeCmdEvent(letter: Character, shift: Bool) throws -> NSEvent {
        let upper = String(letter).uppercased()
        let lower = String(letter).lowercased()
        let chars = shift ? upper : lower
        var flags: NSEvent.ModifierFlags = [.command]
        if shift { flags.insert(.shift) }
        return try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: chars,
            charactersIgnoringModifiers: chars,
            isARepeat: false,
            // keyCode 0 is fine — TerminalView.keyDown's ⌘ filter only
            // reads `event.modifierFlags`; the keyCode is irrelevant
            // for matching menu items (those go through `characters`).
            keyCode: 0
        ))
    }

    /// Walk a freshly-built `AppDelegate.installMainMenu()` tree looking
    /// for an enabled menu item whose keyEquivalent + modifier mask
    /// matches the chord. Returns the menu path (e.g. `"Edit > Copy"`)
    /// when found, nil when unbound. Building the menu through
    /// `installMainMenu()` is the load-bearing piece — it sets
    /// `NSApp.mainMenu` and also calls `AppDelegate+Menu.insertSparkleMenuItem`
    /// + `NSApp.servicesMenu = …` etc. We restore the prior `mainMenu`
    /// in `tearDown` so sibling tests aren't affected.
    private func findMenuBinding(letter: Character, shift: Bool) -> String? {
        guard let main = NSApplication.shared.mainMenu else { return nil }
        let target = String(letter).lowercased()
        let targetUpper = String(letter).uppercased()
        return walk(menu: main, path: "", target: target, targetUpper: targetUpper, shift: shift)
    }

    /// Like `findMenuBinding`, but returns the menu item's `action`
    /// selector instead of the menu-tree path. Used by
    /// `.menuBindingDeadOnArrival` cells to verify the selector
    /// doesn't resolve to any responder, confirming AppKit's automatic
    /// menu validation will gray the item out and the chord will beep.
    private func findMenuBindingAction(letter: Character, shift: Bool) -> Selector? {
        guard let main = NSApplication.shared.mainMenu else { return nil }
        let target = String(letter).lowercased()
        let targetUpper = String(letter).uppercased()
        return walkForAction(menu: main, target: target, targetUpper: targetUpper, shift: shift)
    }

    /// Mirror of `walk(menu:path:target:targetUpper:shift:)` that
    /// returns the matching item's `action` rather than the path.
    private func walkForAction(menu: NSMenu, target: String, targetUpper: String, shift: Bool) -> Selector? {
        for item in menu.items {
            if let sub = item.submenu {
                if let hit = walkForAction(menu: sub, target: target, targetUpper: targetUpper, shift: shift) {
                    return hit
                }
            }
            let key = item.keyEquivalent
            guard !key.isEmpty else { continue }
            var effectiveMask = item.keyEquivalentModifierMask
            let isUpperLetter = key.count == 1
                && key.unicodeScalars.first.map { $0.value >= 0x41 && $0.value <= 0x5A } == true
            if isUpperLetter && !effectiveMask.contains(.shift) {
                effectiveMask.insert(.shift)
            }
            var chord: NSEvent.ModifierFlags = [.command]
            if shift { chord.insert(.shift) }
            if key.lowercased() == target && effectiveMask == chord {
                return item.action
            }
        }
        return nil
    }

    /// Recursive menu walker. AppKit menu items can carry their
    /// keyEquivalent in upper- or lower-case, with the modifier mask
    /// either explicitly set OR omitted (default = `.command`). The
    /// rule for matching:
    ///
    ///   - `keyEquivalent == "z"` + default mask `.command` → ⌘Z
    ///     (no implicit Shift, even though Z is shifted in QWERTY).
    ///   - `keyEquivalent == "Z"` + default mask `.command` → ⌘⇧Z
    ///     (uppercase literal implies the shift bit is required).
    ///   - `keyEquivalent == "G"` + explicit `[.command, .shift]` →
    ///     ⌘⇧G (explicit mask wins; case is now informational).
    ///   - `keyEquivalent == ""` → no shortcut on this item; skip.
    ///
    /// We match by lowercasing both the chord and the keyEquivalent,
    /// then comparing the modifier sets after deriving "implicit shift"
    /// from any uppercase ASCII letter literal. This matches AppKit's
    /// own keyDown→menu dispatch logic.
    private func walk(menu: NSMenu, path: String, target: String, targetUpper: String, shift: Bool) -> String? {
        for item in menu.items {
            if let sub = item.submenu {
                let next = path.isEmpty ? item.title : path + " > " + item.title
                if let hit = walk(menu: sub, path: next, target: target, targetUpper: targetUpper, shift: shift) {
                    return hit
                }
            }
            let key = item.keyEquivalent
            guard !key.isEmpty else { continue }

            // Derive effective modifier mask: AppKit treats an uppercase
            // ASCII letter keyEquivalent as implying `.shift` even when
            // the explicit mask is the default `.command`.
            var effectiveMask = item.keyEquivalentModifierMask
            let isUpperLetter = key.count == 1
                && key.unicodeScalars.first.map { $0.value >= 0x41 && $0.value <= 0x5A } == true
            if isUpperLetter && !effectiveMask.contains(.shift) {
                effectiveMask.insert(.shift)
            }

            // Build the chord we're looking for: ⌘ always, ⇧ iff `shift`.
            var chord: NSEvent.ModifierFlags = [.command]
            if shift { chord.insert(.shift) }

            // Compare lowercase (case is now redundant given the
            // `effectiveMask` derivation above).
            if key.lowercased() == target && effectiveMask == chord {
                return path.isEmpty ? item.title : path + " > " + item.title
            }
        }
        return nil
    }

    // MARK: - Test fixture: install + restore main menu

    private var savedMainMenu: NSMenu?

    override func setUpWithError() throws {
        savedMainMenu = NSApplication.shared.mainMenu
        // AppDelegate is a vanilla `final class … : NSObject`; init has
        // no side effects (no Sparkle wiring, no controllers spawned)
        // — those happen in `applicationDidFinishLaunching`, which we
        // don't trigger. So `installMainMenu()` here just builds the
        // NSMenu tree and assigns it.
        AppDelegate().installMainMenu()
    }

    override func tearDownWithError() throws {
        NSApplication.shared.mainMenu = savedMainMenu
        savedMainMenu = nil
    }

    // MARK: - Tests

    /// The bright line: `KeyEncoder.encode(...)` returns ZERO bytes for
    /// every Cmd+letter / Cmd+Shift+letter chord. This is the encoder-
    /// level Cmd-isolation invariant (`KeyEncoder.swift:96-100`). If
    /// any cell flips, ⌘+something is leaking as PTY bytes.
    func test_encoderEmitsNoBytesForAnyCmdLetter() throws {
        let encoder = KeyEncoder()
        for row in Self.expected {
            let chars = row.shift
                ? String(row.letter).uppercased()
                : String(row.letter).lowercased()
            var mods: KeyEncoder.Modifiers = [.command]
            if row.shift { mods.insert(.shift) }

            let bytes = encoder.encode(chars: chars, modifiers: mods)
            let label = row.shift
                ? "Cmd+Shift+\(String(row.letter).uppercased())"
                : "Cmd+\(String(row.letter).lowercased())"
            XCTAssertTrue(
                bytes.isEmpty,
                "\(label): encoder must return Data() for any ⌘-prefixed chord — "
                    + "got \(bytes.count) bytes \(Array(bytes)). "
                    + "Pinned outcome was \(row.outcome.rawValue) (\(row.note)). "
                    + "If this fired, KeyEncoder lost the `.command` filter at "
                    + "KeyEncoder.swift:96-100 — every ⌘-shortcut would now leak."
            )
        }
    }

    /// `TerminalView.keyDown(with:)` filters `.command` BEFORE the
    /// session / encoder / IME layer. Synthesise each chord, drive
    /// the headless view, and assert the PTY recorder stayed empty.
    /// This is the view-level half of the Cmd-isolation invariant —
    /// `TerminalView.swift:1637-1640`.
    func test_terminalViewSendsNoBytesForAnyCmdLetter() throws {
        let view = try XCTUnwrap(TerminalView.makeHeadlessForTests())
        let recorder = RecordingPTY()
        view.ptyRecorderForTests = recorder

        for row in Self.expected {
            recorder.sent.removeAll()
            let event = try makeCmdEvent(letter: row.letter, shift: row.shift)
            view.keyDown(with: event)

            // Synchronous path: TerminalView's `.command` early return
            // does not dispatch to a queue, so a runloop pump would be
            // a non-event. Skip it to dodge the CATransaction hazard
            // that gates `test_commandKeyDoesNotSendToPty`.
            let label = row.shift
                ? "Cmd+Shift+\(String(row.letter).uppercased())"
                : "Cmd+\(String(row.letter).lowercased())"
            XCTAssertTrue(
                recorder.sent.isEmpty,
                "\(label): TerminalView must not emit PTY bytes for any "
                    + "⌘-prefixed chord — recorder captured \(recorder.sent.count) "
                    + "bytes \(Array(recorder.sent)). Pinned outcome was "
                    + "\(row.outcome.rawValue) (\(row.note)). If this fired, "
                    + "TerminalView.swift:1637 lost the `.command` early-return "
                    + "and \(label) is being re-encoded as PTY input."
            )
        }
    }

    /// The interesting half: walk the freshly-installed main menu and
    /// classify each cell by whether a binding exists. Compare to the
    /// pinned `expected` outcome. Failure message names the exact
    /// chord that flipped.
    ///
    /// `.menuBindingDeadOnArrival` cells receive an extra check: the
    /// menu item must exist (binding != nil) AND its action selector
    /// must NOT resolve on TerminalView, NSResponder, or NSApp. If a
    /// future PR wires up real undo/redo support (e.g. by implementing
    /// `@objc func undo(_ sender: Any?)` on TerminalView or its first-
    /// responder chain), the responds-to assertion fails and forces the
    /// matrix entry to flip from `.menuBindingDeadOnArrival` →
    /// `.interceptedByMenu`. Without this, a partial fix that lands the
    /// selector but forgets to update the matrix would slip through.
    func test_menuBindingMatchesPinnedMatrix() throws {
        // One headless TerminalView for the whole loop — `responds(to:)`
        // is the only thing we use it for, and constructing one per
        // matrix row is wasteful. Sibling test
        // `test_terminalViewSendsNoBytesForAnyCmdLetter` uses the same
        // pattern.
        let view = TerminalView.makeHeadlessForTests()

        for row in Self.expected {
            let label = row.shift
                ? "Cmd+Shift+\(String(row.letter).uppercased())"
                : "Cmd+\(String(row.letter).lowercased())"

            let binding = findMenuBinding(letter: row.letter, shift: row.shift)
            let observed: Outcome
            if binding != nil {
                // For dead-on-arrival cells, the binding exists at the
                // menu-tree level but the action selector is unhooked.
                // We classify based on the pinned outcome here and let
                // the secondary assertion below catch a future fix.
                observed = (row.outcome == .menuBindingDeadOnArrival)
                    ? .menuBindingDeadOnArrival
                    : .interceptedByMenu
            } else {
                // No menu binding. Per the schema: either the view
                // intercepts (none currently do for Cmd+letter — the
                // `.command` early return in TerminalView.keyDown
                // forwards the event to super before any view-owned
                // logic could fire) or AppKit forwards the event to
                // super where it ultimately NSBeeps and is dropped.
                // Both KeyEncoder and TerminalView produce zero bytes,
                // pinned by the two sibling tests above.
                observed = .forwardedToSuper
            }

            // Print-style failure message: caller can grep the chord
            // out of test logs and immediately see what the matrix
            // expected vs. observed.
            XCTAssertEqual(
                observed,
                row.outcome,
                "\(label): expected \(row.outcome.rawValue) but got \(observed.rawValue). "
                    + "Pinned note: \(row.note). "
                    + "Menu binding observed: \(binding ?? "<none>"). "
                    + "If this flipped, a menu item was added/removed/rebound "
                    + "in AppDelegate+Menu.swift; update `Self.expected` to "
                    + "match if intentional, or restore the binding."
            )

            // Secondary assertion for `.menuBindingDeadOnArrival`: the
            // bound action selector must not resolve to any method on
            // TerminalView, NSResponder, or NSApp. The day someone
            // implements `undo:` on TerminalView (or any other path),
            // this fires and the matrix MUST be updated in lockstep.
            if row.outcome == .menuBindingDeadOnArrival {
                guard let action = findMenuBindingAction(letter: row.letter, shift: row.shift) else {
                    XCTFail(
                        "\(label): pinned `.menuBindingDeadOnArrival` but no menu action selector "
                            + "found. Either the menu binding was removed (then the matrix must "
                            + "flip to `.forwardedToSuper`) or the walker can't see the item — "
                            + "investigate AppDelegate+Menu.swift."
                    )
                    continue
                }

                let viewResponds = view?.responds(to: action) ?? false
                let appResponds = NSApp.responds(to: action)
                let nsResponderRespondsClass = NSResponder.instancesRespond(to: action)

                XCTAssertFalse(
                    viewResponds || appResponds || nsResponderRespondsClass,
                    "\(label): pinned `.menuBindingDeadOnArrival` (selector \(action) is "
                        + "supposed to be unimplemented), but somebody now responds to it: "
                        + "TerminalView=\(viewResponds), NSApp=\(appResponds), "
                        + "NSResponder.class=\(nsResponderRespondsClass). The PRODUCT-BUG was "
                        + "fixed (real undo/redo wiring landed) — flip the matrix entry "
                        + "from `.menuBindingDeadOnArrival` to `.interceptedByMenu` and "
                        + "remove the PRODUCT-BUG comment in `Self.expected`."
                )
            }
        }
    }

    /// The matrix must enumerate every `(letter, shift?)` cell. A
    /// partial table would silently let new shortcuts slip past — we
    /// pin the dimension explicitly so a regression that drops a row
    /// surfaces as a count failure rather than an unobservable gap.
    func test_matrixIsFullyPopulated() {
        XCTAssertEqual(
            Self.expected.count, 52,
            "Cmd+letter intercept matrix must have 26 letters × 2 (plain + shift) "
                + "= 52 entries. Got \(Self.expected.count). Add / restore the "
                + "missing rows in `CmdLetterInterceptMatrixTests.expected`."
        )

        // Defence in depth: even with a 52-row table, two duplicates
        // could mask a missing letter. Verify the cell set is exactly
        // the cartesian product.
        var seen = Set<String>()
        for row in Self.expected {
            let key = "\(row.letter):\(row.shift)"
            XCTAssertFalse(
                seen.contains(key),
                "Duplicate row in matrix: \(key). Each (letter, shift) pair "
                    + "must appear exactly once."
            )
            seen.insert(key)
        }
        XCTAssertEqual(
            seen.count, 52,
            "Matrix has \(seen.count) unique (letter, shift) pairs; expected 52."
        )
    }
}
