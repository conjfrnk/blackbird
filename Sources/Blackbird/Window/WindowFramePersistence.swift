import AppKit
import Foundation

/// Saves a `MainWindowController`'s window frame to the AppKit autosave store on
/// user-driven move/resize, split out of the controller so the
/// save-gating/screen-reconfig logic is one cohesive concern. The restore side
/// (off-screen nudging) is the free `nudgeFrameOntoVisibleScreen` functions; the
/// autosave NAME stays on `MainWindowController` (its window identity, used by
/// `setFrameAutosaveName`/`setFrameUsingName` in init/restore).
///
/// Why explicit saves: AppKit's implicit autosave-on-move/resize doesn't fire
/// for this window's tabbing config, so the controller's `windowDidMove` /
/// `windowDidResize` delegate methods drive `saveCurrentFrame()` here.
///
/// `unowned let controller`: the controller owns this (`lazy var`), so its
/// lifetime is a strict subset of the controller's. `saveCurrentFrame` runs only
/// from the move/resize delegate methods and `armScreenReconfigSuppression` only
/// from the `@objc` screen-params handler — all controller-alive paths, never
/// deinit — so the back-ref is never read after teardown.
final class WindowFramePersistence {
    unowned let controller: MainWindowController

    init(controller: MainWindowController) {
        self.controller = controller
    }

    /// After a display reconfiguration, AppKit relocates windows onto the new
    /// arrangement; those relocations must NOT be persisted (they'd clobber the
    /// user's saved multi-display frame). Suppress non-user-driven saves for a
    /// settle window after the last `didChangeScreenParameters`. Audit S5-006.
    private static let screenReconfigSettleInterval: TimeInterval = 2.0
    private var suppressSavesUntil: Date = .distantPast

    /// Arm the screen-reconfig settle suppression. Called from the controller's
    /// `screenParametersDidChange` notification handler.
    func armScreenReconfigSuppression() {
        suppressSavesUntil = Date().addingTimeInterval(Self.screenReconfigSettleInterval)
    }

    /// Persist the current window frame, unless suppressed: a show-window is in
    /// progress, a screen-reconfig settle window is active (and the change isn't
    /// positively user-driven), or the window is full-screen.
    func saveCurrentFrame() {
        guard !controller.isPerformingShowWindow else { return }
        guard let win = controller.window else { return }
        // Audit S5-006 (gate 3): a display reconfiguration is in progress or just
        // happened — the move/resize that triggered us is AppKit relocating the
        // window, not the user. Persisting it would clobber the user's saved
        // multi-display frame. A USER-driven change bypasses the gate: AppKit's
        // reconfiguration relocations never occur during a live left-button drag
        // or a live resize, so those signals positively identify the user.
        // NSEvent.pressedMouseButtons is GLOBAL (app-wide), so a left button held
        // for an unrelated reason — dragging a DIFFERENT window, a force-press
        // elsewhere — would misclassify THIS window's reconfiguration relocation
        // as user-driven and clobber the saved multi-display frame. Scope the
        // button signal to this window: a real title-bar drag keeps the pointer
        // over the window as it moves, so require the pointer within this
        // window's frame. inLiveResize is already per-window.
        let userDriven = Self.isUserDrivenFrameChange(
            leftButtonDown: (NSEvent.pressedMouseButtons & 1) != 0,
            pointerInWindowFrame: win.frame.contains(NSEvent.mouseLocation),
            inLiveResize: win.inLiveResize
        )
        guard userDriven || Date() >= suppressSavesUntil else { return }
        guard !win.styleMask.contains(.fullScreen) else { return }
        win.saveFrame(usingName: MainWindowController.frameAutosaveName)
    }

    /// Decide whether a windowDidMove/Resize is genuinely user-driven (and so may
    /// bypass the S5-006 screen-reconfig settle suppression). A live resize is
    /// always user-driven. A left-button drag counts ONLY when the pointer is
    /// over THIS window — a title-bar drag carries the pointer with the window,
    /// whereas a left button held while a different window or app is being
    /// manipulated must not green-light saving this window's AppKit-relocated
    /// frame. Pure so the window-scoping logic is unit-testable without
    /// synthesizing NSEvents.
    static func isUserDrivenFrameChange(
        leftButtonDown: Bool,
        pointerInWindowFrame: Bool,
        inLiveResize: Bool
    ) -> Bool {
        inLiveResize || (leftButtonDown && pointerInWindowFrame)
    }
}
