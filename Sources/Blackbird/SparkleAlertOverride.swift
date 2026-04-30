import AppKit
import OSLog
import Sparkle
import ObjectiveC.runtime
import os

/// Sparkle's default "up to date" alert is wordy: it shows the display
/// version twice (e.g. "Blackbird 0.1.0 (0.1.0)") and tacks on a parenthetical
/// with the CFBundleVersion, which users don't need. `SPUStandardUserDriver`
/// doesn't expose that method publicly, so Swift can't `override` it via a
/// subclass. Instead, replace the IMP on the class at launch — there's only
/// ever one instance, so the behaviour is equivalent.
@MainActor
enum SparkleAlertOverride {
    // EI-01: every other os.Logger in the project uses
    // "dev.conjfrnk.blackbird"; `scripts/run-with-probe.sh` filters on
    // it. The earlier "com.blackbird.terminal" subsystem made the
    // selector-drift fault and the missing-CFBundleShortVersionString
    // warning invisible to the canonical `log stream --predicate
    // 'subsystem == "dev.conjfrnk.blackbird"'` query.
    fileprivate static let logger = Logger(
        subsystem: "dev.conjfrnk.blackbird",
        category: "SparkleAlertOverride"
    )

    /// Last block IMP we installed via `imp_implementationWithBlock`. Tracked
    /// so a re-install can call `imp_removeBlock` on the prior IMP — without
    /// it, every re-call leaks the previous block (F-S7-001). The runtime-
    /// owned original SPUStandardUserDriver IMP returned by the FIRST
    /// `method_setImplementation` is NOT tracked here and must NOT be passed
    /// to `imp_removeBlock`: only IMPs we created via
    /// `imp_implementationWithBlock` are eligible for removal. Discrimination
    /// is by nil-check on this field (nil ⇒ first install ⇒ skip the remove).
    ///
    /// Wrapped in `OSAllocatedUnfairLock` to match the project's canonical
    /// shape for shared mutable statics (sibling pattern of
    /// `MainThreadWatchdog.lastMainHeartbeat`, `WindowBlur.didLogBlurRC`,
    /// `ScrollIndicator.didLogOutOfRange`, etc.). Today the `@MainActor`
    /// annotation on the enum guarantees serial access; the lock is
    /// belt-and-suspenders against a refactor that promotes a non-MainActor
    /// caller. Note: the lock does NOT eliminate a potential
    /// imp_removeBlock-while-prior-IMP-still-executing window — that
    /// would only matter if `install()` ran while a Sparkle UI thread was
    /// mid-call into the prior trampoline, which the @MainActor invariant
    /// already prevents. If that invariant is dropped, the lock alone is
    /// insufficient — defer the free instead.
    private static let installedBlockIMP =
        OSAllocatedUnfairLock<IMP?>(initialState: nil)

    /// Invoked once during app launch. Idempotent — `method_setImplementation`
    /// is safe to call repeatedly. On re-install, the previous block IMP is
    /// freed via `imp_removeBlock` (F-S7-001); the very first install's prior
    /// IMP is the runtime-owned original and is left untouched.
    static func install() {
        let cls: AnyClass = SPUStandardUserDriver.self
        let sel = NSSelectorFromString("showUpdateNotFoundWithError:acknowledgement:")
        guard let method = class_getInstanceMethod(cls, sel) else {
            // A Sparkle major-version bump that renames or removes
            // this selector silently disables the override and lets
            // the bare Sparkle UX surface again. Log the miss so the
            // regression is greppable from `log stream --predicate
            // 'category == "SparkleAlertOverride"'` instead of a
            // user-reported "the alert came back". Audit EH-009.
            logger.fault(
                "SparkleAlertOverride: target selector `showUpdateNotFoundWithError:acknowledgement:` not found on SPUStandardUserDriver — Sparkle API drift?"
            )
            return
        }

        typealias Block = @convention(block) (AnyObject, Error, @escaping () -> Void) -> Void
        let block: Block = { _, _, ack in
            let name = Bundle.main
                .object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Blackbird"
            let version: String = {
                if let v = Bundle.main.object(
                    forInfoDictionaryKey: "CFBundleShortVersionString"
                ) as? String, !v.isEmpty {
                    return v
                }
                // Missing/empty version means a corrupted bundle —
                // surface so a user reporting "the alert says
                // 'Blackbird  is the latest'" can grep for the cause.
                // One log per session per miss; the alert path is
                // user-driven (Check for Updates), not a hot path.
                // Audit EH-005.
                logger.fault(
                    "SparkleAlertOverride: CFBundleShortVersionString missing from Info.plist"
                )
                return ""
            }()
            let alert = NSAlert()
            alert.messageText = "You're up to date"
            alert.informativeText = "\(name) \(version) is the latest version."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")

            // Audit #23: avoid stacking modals. A blocking `runModal()` here
            // can deadlock the quit flow if Sparkle fires this during
            // `applicationShouldTerminate(_:)` while a window-modal sheet
            // (e.g. "Save changes?") is already up. Prefer a sheet attached
            // to the key/main window; fall back to `runModal()` only when no
            // other modal is active and the app is foreground; otherwise
            // drop the alert (the user can re-trigger via Check for Updates).
            //
            // Modal interactions are not unit-testable in headless CI, so
            // there's no regression test for this — see audit ID #23.
            // TODO(audit #23): revisit if SUUpdater grows a non-blocking API.
            let parentWindow = NSApp.keyWindow ?? NSApp.mainWindow
            if let window = parentWindow,
               window.attachedSheet == nil,
               NSApp.modalWindow == nil,
               NSApp.isActive {
                alert.beginSheetModal(for: window) { _ in
                    ack()
                }
                return
            }

            if NSApp.modalWindow != nil || !NSApp.isActive {
                logger.warning(
                    "Sparkle 'up to date' alert dropped: another modal is active or app is not foreground"
                )
                ack()
                return
            }

            _ = alert.runModal()
            ack()
        }
        let imp = imp_implementationWithBlock(block as Any)
        // F-S7-001: free the previously-installed block IMP, if any. We
        // discriminate by `installedBlockIMP`: nil on the very first call
        // (so the prior IMP returned by `method_setImplementation` is the
        // runtime-owned original — leave it alone), non-nil on subsequent
        // calls (so the prior IMP is one we minted via
        // `imp_implementationWithBlock` and must release). The whole
        // swap happens under one lock so a hypothetical concurrent
        // re-install can't observe a half-updated tracking state.
        installedBlockIMP.withLock { prior in
            method_setImplementation(method, imp)
            if let prior {
                imp_removeBlock(prior)
            }
            prior = imp
        }
    }

    #if DEBUG
    /// Test-only accessor for the IMP we installed. Lets
    /// `SparkleAlertOverrideTests` assert that re-install replaces the
    /// tracked IMP. DEBUG-gated — release builds carry no test surface.
    internal static var _installedBlockIMPForTests: IMP? {
        installedBlockIMP.withLock { $0 }
    }

    /// Test-only reset to make `install()` re-entrant across test methods.
    /// Frees the currently-tracked IMP (mimicking what a real re-install
    /// would do) and resets the tracking field. Does NOT restore the
    /// original SPUStandardUserDriver IMP — there's no use case for that
    /// in production, and the test only needs `installedBlockIMP` to be
    /// observable / reset-able.
    internal static func _resetForTests() {
        installedBlockIMP.withLock { prior in
            if let p = prior {
                imp_removeBlock(p)
            }
            prior = nil
        }
    }
    #endif
}
