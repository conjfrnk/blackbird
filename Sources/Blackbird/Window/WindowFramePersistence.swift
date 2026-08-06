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
    ///
    /// 5.0s (not the original 2.0s): a slow wake-from-sleep display
    /// renegotiation (external display / dock DDC handshake) can emit its
    /// relocating `windowDidMove` well after a shorter window would have
    /// expired (A4, RCA docs/rca-tab-behaviors-2026-07-01.md). Safe to widen
    /// — `isUserDrivenFrameChange` already bypasses this suppression
    /// entirely for a genuine user drag/resize, so a longer window only
    /// defers AppKit's OWN non-user-driven relocations, never a real save.
    /// Each `didChangeScreenParameters` re-arms the full interval, so a
    /// multi-step renegotiation that keeps firing the notification is
    /// already covered regardless of this constant; this only helps the
    /// single-relocation-arrives-late case.
    private static let screenReconfigSettleInterval: TimeInterval = 5.0
    private var suppressSavesUntil: Date = .distantPast

    /// Suppressed from `windowWillEnterFullScreen` until the transition
    /// resolves OR this deadline passes, whichever comes first.
    /// `saveCurrentFrame`'s `styleMask.contains(.fullScreen)` check alone
    /// isn't sufficient: that flag only lands once AppKit's enter animation
    /// completes, but `windowDidResize` can fire mid-animation — with a
    /// near-screen-sized frame — before the flag is set. Saving that frame
    /// would have the next launch open screen-sized WITHOUT fullscreen,
    /// burying the traffic lights under the menu bar (A3, RCA
    /// docs/rca-tab-behaviors-2026-07-01.md). The symmetric EXIT animation
    /// doesn't need the same guard: `.fullScreen` is still set in the
    /// styleMask for the whole exit animation (it only clears once exit
    /// completes), so the existing check already covers it.
    ///
    /// Time-bounded (a `Date` deadline, not a bare `Bool`) as a defensive
    /// backstop: AppKit's documented contract guarantees
    /// `windowDidEnterFullScreen` or `windowDidFailToEnterFullScreen` fires
    /// after `windowWillEnterFullScreen`, but a bare boolean cleared ONLY by
    /// that callback has no self-heal path if that contract were ever
    /// violated (a hung/aborted transition, a future AppKit change) — every
    /// subsequent frame save would silently stay suppressed for the rest of
    /// the window's life with zero diagnostic signal. Mirrors
    /// `suppressSavesUntil`'s existing time-bounded shape rather than
    /// introducing a structurally different suppression mechanism
    /// (type-design review).
    private static let fullScreenEntrySuppressionTimeout: TimeInterval = 5.0
    private var fullScreenEntrySuppressedUntil: Date = .distantPast

    /// Arm the screen-reconfig settle suppression. Called from the controller's
    /// `screenParametersDidChange` notification handler.
    func armScreenReconfigSuppression() {
        suppressSavesUntil = Date().addingTimeInterval(Self.screenReconfigSettleInterval)
    }

    /// Called from the controller's `windowWillEnterFullScreen` delegate hook.
    func armFullScreenEntrySuppression() {
        fullScreenEntrySuppressedUntil = Date().addingTimeInterval(Self.fullScreenEntrySuppressionTimeout)
    }

    /// Called from the controller's `windowDidEnterFullScreen` /
    /// `windowDidFailToEnterFullScreen` delegate hooks — the transition has
    /// resolved one way or the other, so resume the ordinary styleMask-based
    /// gate immediately rather than waiting out the defensive timeout.
    func resolveFullScreenEntrySuppression() {
        fullScreenEntrySuppressedUntil = .distantPast
    }

    /// Persist the current window frame, unless suppressed: a show-window is in
    /// progress, a screen-reconfig settle window is active (and the change isn't
    /// positively user-driven), the window is full-screen, or a fullscreen-enter
    /// transition is in flight.
    /// - Parameter knownUserDriven: pass `true` from a callback that is itself
    ///   positive proof of a user gesture, when the usual live signals have
    ///   already gone. `windowDidEndLiveResize` is exactly that case: AppKit
    ///   clears `inLiveResize` *before* posting it, and it is driven by the
    ///   mouse-UP so no button is down — so both disjuncts of
    ///   `isUserDrivenFrameChange` read false and the S5-006 settle window
    ///   would silently drop the only save of the whole drag. (Before the
    ///   end-of-drag save existed, every mid-drag `windowDidResize` bypassed
    ///   the gate on `inLiveResize`, so the suppression never had a chance to
    ///   eat the user's resize; it does now.)
    func saveCurrentFrame(knownUserDriven: Bool = false) {
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
        let userDriven = knownUserDriven || Self.isUserDrivenFrameChange(
            leftButtonDown: (NSEvent.pressedMouseButtons & 1) != 0,
            pointerInWindowFrame: win.frame.contains(NSEvent.mouseLocation),
            inLiveResize: win.inLiveResize
        )
        guard userDriven || Date() >= suppressSavesUntil else { return }
        guard !win.styleMask.contains(.fullScreen), Date() >= fullScreenEntrySuppressedUntil else { return }
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
