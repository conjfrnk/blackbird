import AppKit
import OSLog
import Sparkle
import ObjectiveC.runtime

/// `SPUStandardUserDriver` doesn't expose its "up to date" alert method publicly, so a subclass can't
/// override it; the IMP is replaced on the class at launch instead.
@MainActor
enum SparkleAlertOverride {
    fileprivate static let logger = Logger(
        subsystem: "dev.conjfrnk.blackbird",
        category: "SparkleAlertOverride"
    )

    /// Only IMPs minted by `imp_implementationWithBlock` may go to `imp_removeBlock`, never the runtime-owned
    /// original. `@MainActor` is what stops `install()` freeing a trampoline that is still executing.
    private static var installedBlockIMP: IMP?

    private static var originalIMP: IMP?

    static func isOnLatestVersion(_ error: Error) -> Bool {
        let info = (error as NSError).userInfo
        guard let raw = info[SPUNoUpdateFoundReasonKey] else { return false }
        let code: Int? = (raw as? NSNumber)?.intValue ?? (raw as? Int)
        guard let code else { return false }
        return code == Int(SPUNoUpdateFoundReason.onLatestVersion.rawValue)
    }

    internal static func upToDateMessage(name: String, version: String) -> String {
        if version.isEmpty {
            return "\(name) is the latest version."
        }
        return "\(name) \(version) is the latest version."
    }

    enum UpToDatePresentation: Equatable {
        case sheet
        case runModal
        /// Something modal is already in flight, the app isn't foreground, or the parent already has a
        /// sheet (`runModal()` would deadlock against it).
        case drop
    }

    static func presentationDecision(
        hasParent: Bool,
        parentHasSheet: Bool,
        appModal: Bool,
        appActive: Bool
    ) -> UpToDatePresentation {
        if hasParent && !parentHasSheet && !appModal && appActive { return .sheet }
        if appModal || !appActive || parentHasSheet { return .drop }
        return .runModal
    }

    /// Every tab in an `NSWindowTabGroup` reports `isVisible == true`; front-ness lives in
    /// `tabGroup.selectedWindow`. A sheet attached to a non-selected tab forces a tab switch.
    internal static func resolveSheetParent(
        windows: [SheetParentResolvable],
        keyWindow: SheetParentResolvable?,
        mainWindow: SheetParentResolvable?
    ) -> SheetParentResolvable? {
        if let key = keyWindow, key.bb_isTerminalWindow, !key.bb_hasAttachedSheet {
            return key.bb_selectedTabWindow
        }
        if let main = mainWindow, main.bb_isTerminalWindow, !main.bb_hasAttachedSheet {
            return main.bb_selectedTabWindow
        }
        if let term = windows.first(where: { $0.bb_isTerminalWindow && !$0.bb_hasAttachedSheet }) {
            return term.bb_selectedTabWindow
        }
        // Returned as-is, not via bb_selectedTabWindow: callers must not route a selectable tab group
        // through this branch.
        return keyWindow ?? mainWindow
    }

    private static func presentUpToDate(ack: @escaping () -> Void) {
        let name = Bundle.main
            .object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Blackbird"
        let version: String = {
            if let v = Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String, !v.isEmpty {
                return v
            }
            logger.fault(
                "SparkleAlertOverride: CFBundleShortVersionString missing from Info.plist"
            )
            return ""
        }()
        let alert = NSAlert()
        alert.messageText = "You're up to date"
        alert.informativeText = Self.upToDateMessage(name: name, version: version)
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")

        // Don't stack modals: a blocking runModal() during applicationShouldTerminate while a sheet is up
        // can deadlock the quit flow.
        let parentWindow = Self.resolveSheetParent(
            windows: NSApp.windows,
            keyWindow: NSApp.keyWindow,
            mainWindow: NSApp.mainWindow
        ) as? NSWindow
        switch Self.presentationDecision(
            hasParent: parentWindow != nil,
            parentHasSheet: parentWindow?.attachedSheet != nil,
            appModal: NSApp.modalWindow != nil,
            appActive: NSApp.isActive
        ) {
        case .sheet:
            if let window = parentWindow {
                alert.beginSheetModal(for: window) { _ in ack() }
            }
        case .drop:
            logger.warning(
                "Sparkle 'up to date' alert dropped: another modal is active or app is not foreground"
            )
            ack()
        case .runModal:
            _ = alert.runModal()
            ack()
        }
    }

    static func install() {
        let cls: AnyClass = SPUStandardUserDriver.self
        let sel = NSSelectorFromString("showUpdateNotFoundWithError:acknowledgement:")
        guard let method = class_getInstanceMethod(cls, sel) else {
            logger.fault(
                "SparkleAlertOverride: target selector `showUpdateNotFoundWithError:acknowledgement:` not found on SPUStandardUserDriver — Sparkle API drift?"
            )
            return
        }

        typealias Block = @convention(block) (AnyObject, Error, @escaping () -> Void) -> Void
        let block: Block = { driver, error, ack in
            // Sparkle calls this for every no-update outcome (`SPUNoUpdateFoundReasonKey`: newer-than-latest
            // build, macOS too old or too new, arm64-only item on Intel); only OnLatestVersion is "up to date".
            if Self.isOnLatestVersion(error) {
                Self.presentUpToDate(ack: ack)
            } else if let orig = originalIMP {
                typealias Original = @convention(c) (AnyObject, Selector, Error, @escaping () -> Void) -> Void
                let fn = unsafeBitCast(orig, to: Original.self)
                fn(driver, sel, error, ack)
            } else {
                logger.error("SparkleAlertOverride: no original IMP to forward a non-latest no-update reason to")
                ack()
            }
        }
        let imp = imp_implementationWithBlock(block as Any)
        // `installedBlockIMP` is nil on the first install: the prior IMP is then the runtime's, not ours to free.
        let prior = installedBlockIMP
        let runtimePrior = method_setImplementation(method, imp)
        if originalIMP == nil { originalIMP = runtimePrior }
        if let prior {
            imp_removeBlock(prior)
        }
        installedBlockIMP = imp
    }

    #if DEBUG
    internal static var _installedBlockIMPForTests: IMP? {
        installedBlockIMP
    }

    /// Restores the original IMP to the class slot so the next dispatch can't land on a freed trampoline.
    internal static func _resetForTests() {
        defer {
            installedBlockIMP = nil
            originalIMP = nil
        }
        let cls: AnyClass = SPUStandardUserDriver.self
        let sel = NSSelectorFromString("showUpdateNotFoundWithError:acknowledgement:")
        guard let method = class_getInstanceMethod(cls, sel) else { return }
        if let orig = originalIMP {
            method_setImplementation(method, orig)
        }
        if let p = installedBlockIMP {
            imp_removeBlock(p)
        }
    }
    #endif
}

// MARK: - Sheet-parent resolution seam

@MainActor
protocol SheetParentResolvable: AnyObject {
    var bb_isTerminalWindow: Bool { get }
    var bb_hasAttachedSheet: Bool { get }
    var bb_selectedTabWindow: SheetParentResolvable { get }
}

extension NSWindow: SheetParentResolvable {
    var bb_isTerminalWindow: Bool { windowController is MainWindowController }
    var bb_hasAttachedSheet: Bool { attachedSheet != nil }
    var bb_selectedTabWindow: SheetParentResolvable { tabGroup?.selectedWindow ?? self }
}
