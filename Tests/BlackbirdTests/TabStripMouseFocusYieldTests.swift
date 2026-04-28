import XCTest
import AppKit
@testable import Blackbird

/// Pins the contract of `shouldYieldFirstResponderToTerminal`, the
/// pure decision used by the titlebar tab strip's `mouseDown` /
/// `rightMouseDown` defer blocks and `teardownEdit` when AppKit
/// auto-promotes the strip (or one of its non-protected subviews) to
/// first responder. With the strip holding focus, subsequent
/// keystrokes have no terminal-bound recipient and AppKit rings
/// NSBeep — these tests guard the rules for when to forcibly hand
/// focus back to the terminal view, and when to leave the existing
/// first responder alone (notably during inline-rename so the user's
/// edit isn't silently committed).
///
/// Tests are written blindly against the contract spec. The
/// implementation file (TitlebarTabBar.swift) was deliberately NOT
/// read while authoring the original tests — this prevents tests that
/// pass for the wrong reason because they encode the impl rather than
/// the spec. (The signature was later renamed/generalised after
/// review feedback; only the call shape was updated, not the
/// expected outcomes.)
///
/// Memory + safety budget (per `feedback_test_memory_safety`):
///   - Each test allocates ≤ 4 plain `NSView` / `NSTextField` /
///     `NSResponder` instances. No NSWindow, no controllers, no PTYs.
///   - Total resident growth across the file: < 5 KB. Wall time: < 5 ms.
final class TabStripMouseFocusYieldTests: XCTestCase {

    // MARK: - "Restore needed" — yield focus back to the terminal

    /// Case 1 — nil first responder is broken state; restore so the
    /// next keystroke has a definite home.
    func test_nilFirstResponder_returnsTrue() {
        let strip = NSView()
        let editField = NSTextField()
        strip.addSubview(editField)
        XCTAssertTrue(
            shouldYieldFirstResponderToTerminal(
                currentFirstResponder: nil,
                claimedBy: strip,
                preserveDescendantsOf: [editField]
            ),
            "Rule 1: nil first responder must trigger a restore"
        )
    }

    /// Case 2 — first responder is a non-`NSView` `NSResponder`
    /// (the host `NSWindow` is the canonical example; window IS an
    /// NSResponder but is NOT an NSView). The bare window does not
    /// route text input usefully, so restore.
    func test_nonNSViewResponder_returnsTrue() {
        let strip = NSView()
        let editField = NSTextField()
        strip.addSubview(editField)
        let bareResponder = NSResponder()
        XCTAssertTrue(
            shouldYieldFirstResponderToTerminal(
                currentFirstResponder: bareResponder,
                claimedBy: strip,
                preserveDescendantsOf: [editField]
            ),
            "Rule 2: a non-NSView NSResponder (e.g., the host window) must trigger a restore"
        )
    }

    /// Case 3 — first responder IS the inline-rename text field;
    /// inline rename legitimately owns focus while editing. Do NOT
    /// clobber.
    func test_currentResponderIsEditField_returnsFalse() {
        let strip = NSView()
        let editField = NSTextField()
        strip.addSubview(editField)
        XCTAssertFalse(
            shouldYieldFirstResponderToTerminal(
                currentFirstResponder: editField,
                claimedBy: strip,
                preserveDescendantsOf: [editField]
            ),
            "Rule 3: must NOT restore when the editField itself is first responder (inline rename in progress)"
        )
    }

    /// Case 4 — first responder is a descendant of the editField
    /// (e.g., the field's internal field-editor `NSTextView`). Same
    /// reason as Case 3: the edit is live, leave focus alone.
    func test_currentResponderIsEditFieldDescendant_returnsFalse() {
        let strip = NSView()
        let editField = NSTextField()
        let fieldEditor = NSView() // stand-in for NSTextView field editor
        strip.addSubview(editField)
        editField.addSubview(fieldEditor)
        XCTAssertFalse(
            shouldYieldFirstResponderToTerminal(
                currentFirstResponder: fieldEditor,
                claimedBy: strip,
                preserveDescendantsOf: [editField]
            ),
            "Rule 4: must NOT restore when first responder is a descendant of the editField (field-editor case)"
        )
    }

    /// Case 5 — first responder IS the strip itself; AppKit
    /// auto-promoted it on click. Restore so keystrokes don't ring.
    func test_currentResponderIsStrip_returnsTrue() {
        let strip = NSView()
        let editField = NSTextField()
        strip.addSubview(editField)
        XCTAssertTrue(
            shouldYieldFirstResponderToTerminal(
                currentFirstResponder: strip,
                claimedBy: strip,
                preserveDescendantsOf: [editField]
            ),
            "Rule 5: must restore when the strip itself is first responder (AppKit auto-promotion)"
        )
    }

    /// Case 6 — first responder is a descendant of the strip but
    /// NOT of the editField (some other subview AppKit promoted on
    /// click, e.g., a tab button). Restore.
    func test_currentResponderIsStripDescendantNotEditField_returnsTrue() {
        let strip = NSView()
        let editField = NSTextField()
        let otherSubview = NSView()
        strip.addSubview(editField)
        strip.addSubview(otherSubview)
        XCTAssertTrue(
            shouldYieldFirstResponderToTerminal(
                currentFirstResponder: otherSubview,
                claimedBy: strip,
                preserveDescendantsOf: [editField]
            ),
            "Rule 6: must restore when first responder is a strip descendant outside the editField subtree"
        )
    }

    /// Case 7 — first responder is some unrelated view (terminal
    /// view, find-bar text field, etc.) that is neither under the
    /// strip nor under the editField. Focus is already where
    /// keystrokes belong; do not clobber.
    func test_currentResponderIsUnrelatedView_returnsFalse() {
        let strip = NSView()
        let editField = NSTextField()
        strip.addSubview(editField)
        let unrelated = NSView() // e.g., the TerminalView or FindBar field
        XCTAssertFalse(
            shouldYieldFirstResponderToTerminal(
                currentFirstResponder: unrelated,
                claimedBy: strip,
                preserveDescendantsOf: [editField]
            ),
            "Rule 7: must NOT restore when first responder is an unrelated view (terminal, find bar, etc.)"
        )
    }

    /// Case 8 — degenerate: protectedRoots is empty (no rename in
    /// progress) and the strip itself was promoted. Restore.
    func test_emptyProtectedRoots_currentResponderIsStrip_returnsTrue() {
        let strip = NSView()
        XCTAssertTrue(
            shouldYieldFirstResponderToTerminal(
                currentFirstResponder: strip,
                claimedBy: strip,
                preserveDescendantsOf: []
            ),
            "Rule 8: must restore when protectedRoots is empty and strip itself is first responder"
        )
    }

    /// Case 9 — empty protectedRoots and first responder is some
    /// unrelated view. Leave focus alone.
    func test_emptyProtectedRoots_currentResponderUnrelated_returnsFalse() {
        let strip = NSView()
        let unrelated = NSView()
        XCTAssertFalse(
            shouldYieldFirstResponderToTerminal(
                currentFirstResponder: unrelated,
                claimedBy: strip,
                preserveDescendantsOf: []
            ),
            "Rule 9: must NOT restore when protectedRoots is empty and first responder is unrelated"
        )
    }

    /// Case 10 — pathological: a protected root identical to the
    /// claimant. Impossible in practice (the strip is never one of
    /// its own protected roots), but the spec pins that the
    /// preservation branch fires first, so the answer is FALSE.
    func test_protectedRootSameAsClaimant_returnsFalse() {
        let strip = NSTextField() // both roles played by the same object
        XCTAssertFalse(
            shouldYieldFirstResponderToTerminal(
                currentFirstResponder: strip,
                claimedBy: strip,
                preserveDescendantsOf: [strip]
            ),
            "Rule 10: when a protected root === claimant, preservation wins → FALSE"
        )
    }

    /// Case 11 — multi-root preservation: two protected roots, FR
    /// inside the second. Mirror of FirstResponderRestoreTests' multi-
    /// root case so the new shape composes the same way.
    func test_multipleProtectedRoots_currentResponderInSecond_returnsFalse() {
        let strip = NSView()
        let root1 = NSView()
        let root2 = NSView()
        let leaf = NSView()
        root2.addSubview(leaf)
        XCTAssertFalse(
            shouldYieldFirstResponderToTerminal(
                currentFirstResponder: leaf,
                claimedBy: strip,
                preserveDescendantsOf: [root1, root2]
            ),
            "Rule 11: a descendant of any protected root must NOT trigger a restore"
        )
    }
}
