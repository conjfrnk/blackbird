import XCTest
import AppKit
@testable import Blackbird

/// Coverage for the tab-close focus bug: closing the active tab left
/// the surviving tab without a sensible first responder, so keystrokes
/// hit nothing and AppKit emitted NSBeep until the user clicked the
/// window. The fix in `MainWindowController.windowDidBecomeKey` calls
/// `shouldRestoreFirstResponder(currentFirstResponder:preserveDescendantsOf:)`
/// to decide whether to forcibly hand focus back to the TerminalView.
/// These tests pin every branch of that decision so future "respect
/// what's already focused" rules can be added without regressing the
/// contract.
///
/// The helper takes an array of "protected roots" because focus can
/// legitimately live in two unrelated subtrees of a single window: the
/// TerminalView (which contains the FindBar) AND the titlebar tab
/// strip (which contains the inline rename text field). Either must
/// keep focus through a `windowDidBecomeKey` callback.
///
/// Memory + safety budget (per `feedback_test_memory_safety`):
///   - Each test allocates ≤ 4 plain `NSView` instances. No windows,
///     no controllers, no PTYs.
///   - Total resident growth across the file: < 5 KB. Wall time: < 5 ms.
final class FirstResponderRestoreTests: XCTestCase {

    // MARK: - "Restore needed" — forcibly hand focus to the target

    /// First responder is nil — common when a freshly-promoted tab
    /// hasn't been clicked yet. The fix MUST restore.
    func test_nilCurrentResponder_returnsTrue() {
        let target = NSView()
        XCTAssertTrue(
            shouldRestoreFirstResponder(
                currentFirstResponder: nil,
                preserveDescendantsOf: [target]
            ),
            "nil first responder must trigger a restore"
        )
    }

    /// First responder is some view from a different window or a
    /// stale view that's no longer in the hierarchy. Restore.
    func test_unrelatedView_returnsTrue() {
        let target = NSView()
        let stranger = NSView()
        XCTAssertTrue(
            shouldRestoreFirstResponder(
                currentFirstResponder: stranger,
                preserveDescendantsOf: [target]
            ),
            "an unrelated view must trigger a restore"
        )
    }

    /// First responder is a non-`NSView` responder. The most common
    /// case is the window itself — `NSWindow` is an `NSResponder` but
    /// is NOT an `NSView` subclass, so the cast to `NSView` returns
    /// nil. The helper must default to "restore" rather than silently
    /// leaving focus on the bare window object.
    func test_nonNSViewResponder_returnsTrue() {
        let target = NSView()
        let bare = NSResponder()
        XCTAssertTrue(
            shouldRestoreFirstResponder(
                currentFirstResponder: bare,
                preserveDescendantsOf: [target]
            ),
            "a non-NSView responder must trigger a restore"
        )
    }

    /// Two subtrees protected; first responder is in NEITHER. Must
    /// restore. This pins the multi-root case where the user has
    /// neither the TerminalView nor the titlebar-rename field focused
    /// (e.g., AppKit elevated the window itself or a transient view).
    func test_unrelatedView_withMultipleRoots_returnsTrue() {
        let terminal = NSView()
        let titlebar = NSView()
        let stranger = NSView()
        XCTAssertTrue(
            shouldRestoreFirstResponder(
                currentFirstResponder: stranger,
                preserveDescendantsOf: [terminal, titlebar]
            ),
            "an unrelated view must trigger a restore even when multiple roots are protected"
        )
    }

    // MARK: - "Restore unwanted" — leave the existing responder alone

    /// First responder is the (only) protected root itself — already
    /// correct, no-op. `NSView.isDescendant(of:)` returns true when
    /// the receiver IS the argument, so the helper handles this case
    /// without a separate identity check.
    func test_currentResponderIsRoot_returnsFalse() {
        let target = NSView()
        XCTAssertFalse(
            shouldRestoreFirstResponder(
                currentFirstResponder: target,
                preserveDescendantsOf: [target]
            ),
            "must NOT restore when the protected root is already first responder"
        )
    }

    /// First responder is a direct child of the protected root.
    func test_currentResponderIsDirectChild_returnsFalse() {
        let target = NSView()
        let child = NSView()
        target.addSubview(child)
        XCTAssertFalse(
            shouldRestoreFirstResponder(
                currentFirstResponder: child,
                preserveDescendantsOf: [target]
            ),
            "must NOT restore when first responder is a direct child"
        )
    }

    /// First responder is a deeply-nested descendant — the actual
    /// shape of the FindBar text field (TerminalView > FindBar > NSTextField).
    /// Leave focus alone.
    func test_currentResponderIsDeepDescendant_returnsFalse() {
        let target = NSView()
        let intermediate = NSView()
        let leaf = NSView()
        target.addSubview(intermediate)
        intermediate.addSubview(leaf)
        XCTAssertFalse(
            shouldRestoreFirstResponder(
                currentFirstResponder: leaf,
                preserveDescendantsOf: [target]
            ),
            "must NOT restore when first responder is a deep descendant"
        )
    }

    /// First responder is in the SECOND of two protected roots — the
    /// titlebar-rename scenario. The TerminalView is one protected
    /// root, the titlebar tab strip is another, and the inline rename
    /// `NSTextField` lives inside the strip (not under TerminalView).
    /// Stealing focus here would silently destroy a mid-rename when
    /// the user app-switches and comes back — `windowDidBecomeKey`
    /// fires on return, the rename field's `resignFirstResponder`
    /// commits an empty/partial value, the user's edit is lost.
    func test_currentResponderInSecondaryRoot_returnsFalse() {
        let terminal = NSView()
        let titlebar = NSView()
        let renameField = NSView()
        titlebar.addSubview(renameField)
        XCTAssertFalse(
            shouldRestoreFirstResponder(
                currentFirstResponder: renameField,
                preserveDescendantsOf: [terminal, titlebar]
            ),
            "must NOT restore when first responder lives in a non-primary protected root (e.g., the inline rename field in the titlebar strip)"
        )
    }

    /// Empty protected-roots array degenerates to "always restore"
    /// (only nil and non-NSView responders short-circuit earlier).
    /// Pins the contract that the helper makes no implicit assumption
    /// about a "default" target view.
    func test_emptyProtectedRoots_anyView_returnsTrue() {
        let any = NSView()
        XCTAssertTrue(
            shouldRestoreFirstResponder(
                currentFirstResponder: any,
                preserveDescendantsOf: []
            ),
            "empty protectedRoots must always trigger a restore for any NSView responder"
        )
    }

    /// Sibling under a shared parent that is NOT itself a protected
    /// root. Sibling has no ancestry link to either root, so it's
    /// "unrelated" — restore.
    func test_siblingHierarchyView_returnsTrue() {
        let parent = NSView()
        let target = NSView()
        let sibling = NSView()
        parent.addSubview(target)
        parent.addSubview(sibling)
        XCTAssertTrue(
            shouldRestoreFirstResponder(
                currentFirstResponder: sibling,
                preserveDescendantsOf: [target]
            ),
            "a sibling under a non-protected common parent counts as unrelated for the target"
        )
    }
}
