import AppKit
import OSLog
import Sparkle
import ObjectiveC.runtime

/// Sparkle's default "up to date" alert is wordy: it shows the display
/// version twice (e.g. "Blackbird 0.1.0 (0.1.0)") and tacks on a parenthetical
/// with the CFBundleVersion, which users don't need. `SPUStandardUserDriver`
/// doesn't expose that method publicly, so Swift can't `override` it via a
/// subclass. Instead, replace the IMP on the class at launch — there's only
/// ever one instance, so the behaviour is equivalent.
@MainActor
enum SparkleAlertOverride {
    fileprivate static let logger = Logger(
        subsystem: "com.blackbird.terminal",
        category: "SparkleAlertOverride"
    )

    /// Invoked once during app launch. Idempotent — `method_setImplementation`
    /// is safe to call repeatedly with the same block.
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
        method_setImplementation(method, imp)
    }
}
