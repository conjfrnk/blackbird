import XCTest
import ObjectiveC.runtime
import Sparkle
@testable import Blackbird

/// Pin SparkleAlertOverride.install()'s F-S7-001 swizzle-leak fix.
///
/// Memory pre-flight: < 1 MB peak (no allocations beyond two block IMPs and
/// a couple of pointer comparisons), < 50 ms wall (no Sparkle UI, no I/O).
///
/// What we pin:
///  1. After the first `install()`, the override tracks a non-nil IMP.
///  2. After a second `install()`, the tracked IMP is different (a fresh
///     block was minted) — proving the install path is replace-not-skip.
///  3. The leak fix itself is observable indirectly via `_installedBlockIMPForTests`:
///     the previous IMP is replaced rather than retained alongside the new
///     one. We can't directly observe `imp_removeBlock` succeeded without
///     a sentinel object captured by the block (which would require widening
///     the test seam beyond the v0.2 scope), but the replacement contract
///     is what would have been violated by a missing-tracking bug.
@MainActor
final class SparkleAlertOverrideTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Reset the tracking state so each test method starts from a known
        // pre-install posture, regardless of test ordering.
        SparkleAlertOverride._resetForTests()
    }

    override func tearDown() {
        // Leave the override in a clean state for any other test that might
        // observe Sparkle alert behavior — DiagnosticReportStoreTests etc.
        // don't, but symmetry with setUp is cheap.
        SparkleAlertOverride._resetForTests()
        super.tearDown()
    }

    func testFirstInstallTracksOurIMP() {
        // Memory: < 64 KB (one block IMP, one pointer field). Wall: ~5 ms.
        XCTAssertNil(SparkleAlertOverride._installedBlockIMPForTests,
                     "after _resetForTests, tracking field must be nil")
        SparkleAlertOverride.install()
        XCTAssertNotNil(SparkleAlertOverride._installedBlockIMPForTests,
                        "after first install, our installed block IMP must be tracked so a re-install can free it (F-S7-001)")
    }

    func testRepeatedInstallReplacesTrackedIMP() {
        // Memory: < 128 KB (two block IMPs in flight; the first is freed by
        // the second install via imp_removeBlock). Wall: ~10 ms.
        SparkleAlertOverride.install()
        let firstTrackedIMP = SparkleAlertOverride._installedBlockIMPForTests
        XCTAssertNotNil(firstTrackedIMP, "first install must track an IMP")

        SparkleAlertOverride.install()
        let secondTrackedIMP = SparkleAlertOverride._installedBlockIMPForTests
        XCTAssertNotNil(secondTrackedIMP, "second install must track an IMP")

        // Compare as raw pointers — IMP is a function pointer typedef and
        // doesn't conform to Equatable directly.
        let first = unsafeBitCast(firstTrackedIMP!, to: UnsafeRawPointer.self)
        let second = unsafeBitCast(secondTrackedIMP!, to: UnsafeRawPointer.self)
        XCTAssertNotEqual(first, second,
                          "re-install must mint a fresh IMP and replace the tracking field; without this contract, every call leaks the prior block (F-S7-001)")
    }

    func testInstalledIMPMatchesClassMethodImpl() throws {
        // Memory: < 64 KB. Wall: ~5 ms.
        // The IMP we track must be the same one currently installed on the
        // class — not a stale reference from a previous override life.
        SparkleAlertOverride.install()
        let tracked = try XCTUnwrap(SparkleAlertOverride._installedBlockIMPForTests,
                                    "install() must populate the tracking field")

        let cls: AnyClass = SPUStandardUserDriver.self
        let sel = NSSelectorFromString("showUpdateNotFoundWithError:acknowledgement:")
        let live = class_getMethodImplementation(cls, sel)

        let trackedRaw = unsafeBitCast(tracked, to: UnsafeRawPointer.self)
        let liveRaw = unsafeBitCast(live, to: UnsafeRawPointer.self)
        XCTAssertEqual(trackedRaw, liveRaw,
                       "tracked IMP must match the live class IMP — divergence means a future re-install would free an IMP that's not actually installed")
    }

    // MARK: - upToDateMessage (S2-009)

    /// When CFBundleShortVersionString is missing/empty, the inline format
    /// `"\(name) \(version) is the latest version."` produced
    /// `"Blackbird  is the latest version."` — a double-space malformation
    /// the user sees instead of the intended diagnostic.
    func testUpToDateMessage_emptyVersion_doesNotProduceDoubleSpace() {
        let msg = SparkleAlertOverride.upToDateMessage(name: "Blackbird", version: "")
        XCTAssertFalse(msg.contains("  "),
                       "double-space malforms the alert text; got: \(msg)")
        XCTAssertTrue(msg.contains("Blackbird"), "app name preserved")
        XCTAssertTrue(msg.contains("latest"), "diagnostic shape preserved")
    }

    func testUpToDateMessage_normalVersion_includesIt() {
        let msg = SparkleAlertOverride.upToDateMessage(name: "Blackbird", version: "0.2.5")
        XCTAssertEqual(msg, "Blackbird 0.2.5 is the latest version.")
    }

    // MARK: - resolveSheetParent (selected-tab targeting)
    //
    // Bug being pinned: the Sparkle "you're up to date" alert attached its
    // sheet to the FIRST-created tab in the window list rather than the
    // currently-SELECTED tab. Attaching a sheet yanks selection to that tab,
    // so a user sitting on tab 3 would get bounced to tab 1 just to see the
    // "no updates" notice. resolveSheetParent must always resolve to the
    // group's SELECTED tab (via bb_selectedTabWindow), preferring key, then
    // main, then the first eligible terminal window, and only falling back to
    // key ?? main when nothing terminal-and-sheet-free exists.
    //
    // Memory/time pre-flight: each case allocates a handful of tiny stub
    // objects and runs pure pointer logic — < 64 KB peak, < 5 ms wall. No
    // Sparkle UI, no AppKit windows, no I/O.

    /// Stub conforming to the resolution protocol. `bb_selectedTabWindow`
    /// returns an injected `_selected` (modelling "the selected tab of this
    /// group is some OTHER window"), or `self` when none is injected
    /// (modelling a standalone / already-selected window).
    final class StubResolvableWindow: SheetParentResolvable {
        var bb_isTerminalWindow: Bool
        var bb_hasAttachedSheet: Bool
        var _selected: SheetParentResolvable?
        var bb_selectedTabWindow: SheetParentResolvable { _selected ?? self }

        init(isTerminal: Bool, hasSheet: Bool = false, selected: SheetParentResolvable? = nil) {
            self.bb_isTerminalWindow = isTerminal
            self.bb_hasAttachedSheet = hasSheet
            self._selected = selected
        }
    }

    /// A. Multi-tab group, no key/main hint: the resolver must walk to the
    /// SELECTED tab, not blindly take windows[0]. Each tab reports tab2 as
    /// the group's selected window, so even though tab0 is first in the
    /// array, the result must be tab2.
    func testResolveSheetParent_multiTabGroup_returnsSelectedTabNotFirst() {
        let tab2 = StubResolvableWindow(isTerminal: true)
        let tab0 = StubResolvableWindow(isTerminal: true, selected: tab2)
        let tab1 = StubResolvableWindow(isTerminal: true, selected: tab2)
        // tab2's own bb_selectedTabWindow returns self (no injected selected).

        let result = SparkleAlertOverride.resolveSheetParent(
            windows: [tab0, tab1, tab2],
            keyWindow: nil,
            mainWindow: nil
        )
        XCTAssertTrue(result === tab2,
                      "must resolve to the SELECTED tab (tab2), not the first array element (tab0)")
        XCTAssertFalse(result === tab0,
                       "windows[0] is not the selected tab — attaching here would yank selection (the regression)")
    }

    /// B. keyWindow is a terminal with no sheet → return its selected tab,
    /// which is a DIFFERENT window than the keyWindow itself.
    func testResolveSheetParent_keyWindowTerminal_returnsItsSelectedTab() {
        let sel = StubResolvableWindow(isTerminal: true)
        let key = StubResolvableWindow(isTerminal: true, selected: sel)

        let result = SparkleAlertOverride.resolveSheetParent(
            windows: [key, sel],
            keyWindow: key,
            mainWindow: nil
        )
        XCTAssertTrue(result === sel,
                      "key window's bb_selectedTabWindow (sel) is the target, not the key window object itself")
        XCTAssertFalse(result === key, "must not attach to the key window when it is not its own selected tab")
    }

    /// C. keyWindow is the Settings window (non-terminal). The resolver must
    /// skip it, find the terminal group in `windows`, and return that group's
    /// SELECTED tab — not the Settings key window and not the first terminal
    /// tab in the array.
    func testResolveSheetParent_nonTerminalKey_picksSelectedTabOfTerminalGroup() {
        let settingsKey = StubResolvableWindow(isTerminal: false)
        let termSel = StubResolvableWindow(isTerminal: true)
        let termFirst = StubResolvableWindow(isTerminal: true, selected: termSel)

        let result = SparkleAlertOverride.resolveSheetParent(
            windows: [termFirst, termSel],
            keyWindow: settingsKey,
            mainWindow: nil
        )
        XCTAssertTrue(result === termSel,
                      "must resolve to the terminal group's selected tab (termSel)")
        XCTAssertFalse(result === settingsKey,
                       "Settings (non-terminal) window must not host the update sheet")
        XCTAssertFalse(result === termFirst,
                       "first terminal tab in the array is not the selected tab")
    }

    /// D. A single standalone terminal window whose selected tab is itself:
    /// the result is that window unchanged.
    func testResolveSheetParent_standaloneTerminal_returnsItself() {
        let standalone = StubResolvableWindow(isTerminal: true)

        let result = SparkleAlertOverride.resolveSheetParent(
            windows: [standalone],
            keyWindow: nil,
            mainWindow: nil
        )
        XCTAssertTrue(result === standalone,
                      "a standalone terminal window whose selected tab is itself must be returned as-is")
    }

    /// E. No terminal windows anywhere: fall back to key ?? main so the
    /// alert still has somewhere to show rather than being silently dropped.
    func testResolveSheetParent_noTerminalWindows_fallsBackToKey() {
        let nonTerm = StubResolvableWindow(isTerminal: false)
        let settingsKey = StubResolvableWindow(isTerminal: false)

        let result = SparkleAlertOverride.resolveSheetParent(
            windows: [nonTerm],
            keyWindow: settingsKey,
            mainWindow: nil
        )
        XCTAssertTrue(result === settingsKey,
                      "with no terminal window available, fall back to the key window so the alert still shows")
    }
}
