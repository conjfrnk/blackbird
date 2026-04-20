import AppKit
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
    /// Invoked once during app launch. Idempotent — `method_setImplementation`
    /// is safe to call repeatedly with the same block.
    static func install() {
        let cls: AnyClass = SPUStandardUserDriver.self
        let sel = NSSelectorFromString("showUpdateNotFoundWithError:acknowledgement:")
        guard let method = class_getInstanceMethod(cls, sel) else { return }

        typealias Block = @convention(block) (AnyObject, Error, @escaping () -> Void) -> Void
        let block: Block = { _, _, ack in
            let name = Bundle.main
                .object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Blackbird"
            let version = Bundle.main
                .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
            let alert = NSAlert()
            alert.messageText = "You're up to date"
            alert.informativeText = "\(name) \(version) is the latest version."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            _ = alert.runModal()
            ack()
        }
        let imp = imp_implementationWithBlock(block as Any)
        method_setImplementation(method, imp)
    }
}
