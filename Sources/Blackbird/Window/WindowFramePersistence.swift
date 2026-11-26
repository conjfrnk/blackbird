import AppKit
import Foundation

/// The window never registers the autosave name: AppKit's implicit autosave-on-move/resize
/// would write a display change's relocation past every gate below.
final class WindowFramePersistence {
    unowned let controller: MainWindowController

    init(controller: MainWindowController) {
        self.controller = controller
    }

    /// After a display reconfiguration AppKit relocates windows; those frames must not be persisted.
    private static let screenReconfigSettleInterval: TimeInterval = 5.0
    private var suppressSavesUntil: Date = .distantPast

    /// AppKit posts `didChangeScreenParameters` a few ms AFTER relocating the windows, so a change
    /// that is not user-driven commits only after this delay, with the suppression re-checked.
    private static let deferredSaveDelay: TimeInterval = 0.3
    private var pendingDeferredSave: DispatchWorkItem?

    /// `.fullScreen` reaches the styleMask only when the enter animation completes, but `windowDidResize` fires mid-animation.
    private static let fullScreenEntrySuppressionTimeout: TimeInterval = 5.0
    private var fullScreenEntrySuppressedUntil: Date = .distantPast

    func armScreenReconfigSuppression() {
        suppressSavesUntil = Date().addingTimeInterval(Self.screenReconfigSettleInterval)
    }

    func armFullScreenEntrySuppression() {
        fullScreenEntrySuppressedUntil = Date().addingTimeInterval(Self.fullScreenEntrySuppressionTimeout)
    }

    func resolveFullScreenEntrySuppression() {
        fullScreenEntrySuppressedUntil = .distantPast
    }

    /// Pass `knownUserDriven: true` only from the end of a live resize that began with the button down:
    /// AppKit clears `inLiveResize` before that callback. A display change's relocation must not pass it.
    func saveCurrentFrame(knownUserDriven: Bool = false) {
        guard !controller.isPerformingShowWindow else { return }
        guard let win = controller.window else { return }
        // `NSEvent.pressedMouseButtons` is app-wide, so also require the pointer inside this window's frame.
        let userDriven = knownUserDriven || Self.isUserDrivenFrameChange(
            leftButtonDown: (NSEvent.pressedMouseButtons & 1) != 0,
            pointerInWindowFrame: win.frame.contains(NSEvent.mouseLocation),
            inLiveResize: win.inLiveResize
        )
        if userDriven {
            persist(win)
        } else if Date() >= suppressSavesUntil {
            scheduleDeferredSave()
        }
    }

    private func scheduleDeferredSave() {
        pendingDeferredSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.commitDeferredSave() }
        pendingDeferredSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.deferredSaveDelay, execute: work)
    }

    private func commitDeferredSave() {
        pendingDeferredSave = nil
        guard let win = controller.window, Date() >= suppressSavesUntil else { return }
        persist(win)
    }

    /// A no-op with nothing pending: an untouched window's default frame must never overwrite the saved one.
    func flushPendingSave() {
        guard let pending = pendingDeferredSave else { return }
        pending.cancel()
        commitDeferredSave()
    }

    private func persist(_ win: NSWindow) {
        guard !win.styleMask.contains(.fullScreen), Date() >= fullScreenEntrySuppressedUntil else { return }
        win.saveFrame(usingName: MainWindowController.frameAutosaveName)
    }

    static func isUserDrivenFrameChange(
        leftButtonDown: Bool,
        pointerInWindowFrame: Bool,
        inLiveResize: Bool
    ) -> Bool {
        inLiveResize || (leftButtonDown && pointerInWindowFrame)
    }
}
