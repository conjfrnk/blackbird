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
    /// A plain `@MainActor`-isolated static — the enum's `@MainActor`
    /// annotation already serialises every access, so no lock is needed.
    /// (A lock would not have bought real safety anyway: it does NOT close
    /// the imp_removeBlock-while-prior-IMP-still-executing window — only the
    /// @MainActor invariant does, by preventing `install()` from running while
    /// a Sparkle UI thread is mid-call into the prior trampoline. If that
    /// invariant were ever dropped, defer the free instead of adding a lock.)
    private static var installedBlockIMP: IMP?

    /// The runtime-owned original IMP captured the first time `install()`
    /// runs. Used by `_resetForTests` so the test seam can restore the
    /// class to its pre-install state instead of leaving a freed
    /// trampoline pointer in the method slot. Nil before any install ran.
    /// Production code never reads this — the original IMP is meaningful
    /// only for test isolation.
    private static var originalIMP: IMP?

    /// Build the "up to date" informative text. Extracted so the empty-
    /// version path is unit-testable without an in-process Sparkle UI hop.
    /// When `version` is empty (Info.plist missing CFBundleShortVersionString
    /// — the EH-005 grep target), the version segment is omitted so the
    /// user sees `"Blackbird is the latest version."` instead of the prior
    /// `"Blackbird  is the latest version."` double-space malformation.
    /// The fault log on the missing key fires separately and remains the
    /// authoritative diagnostic. Audit S2-009.
    internal static func upToDateMessage(name: String, version: String) -> String {
        if version.isEmpty {
            return "\(name) is the latest version."
        }
        return "\(name) \(version) is the latest version."
    }

    /// How to present the "up to date" alert.
    enum UpToDatePresentation: Equatable {
        /// Window-modal sheet attached to an eligible parent window.
        case sheet
        /// App-modal `runModal()` — no eligible sheet parent, but nothing else
        /// is modal and the app is foreground.
        case runModal
        /// Don't present — something modal is already in flight, the app isn't
        /// foreground, or the parent already has a sheet (so `runModal()` would
        /// deadlock against it). The user can re-trigger via Check for Updates.
        case drop
    }

    /// Pure presentation truth-table (audit #23 / L11) — extracted so the
    /// modal-stacking decision is unit-testable even though the modal
    /// interactions themselves aren't headless-testable. `parentHasSheet` is
    /// `false` when there's no parent (`hasParent == false`).
    ///   - sheet  ⇐ an eligible parent (no sheet) AND nothing app-modal AND app foreground
    ///   - drop   ⇐ anything app-modal OR app not foreground OR the parent already has a sheet
    ///   - runModal ⇐ otherwise (no parent, but presentable)
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

    /// Resolve which window an "up to date" sheet should attach to.
    ///
    /// Returns the currently-SELECTED tab of the frontmost terminal window —
    /// never a non-selected tab — so `beginSheetModal(for:)` can't force a tab
    /// switch. Background: `NSApp.windows` is registration/arrival order, and
    /// every tab in an `NSWindowTabGroup` reports `isVisible == true` (AppKit
    /// never `orderOut`s background tabs; front-ness lives in `occlusionState`
    /// / `tabGroup.selectedWindow`, not `isVisible`). The previous
    /// `.first { isVisible }` predicate therefore attached the sheet to the
    /// earliest-created tab, and `beginSheetModal` surfaced it — yanking
    /// selection to tab 1 on every "Check for Updates" with multiple tabs open.
    ///
    /// Preference order: the key window's group's selected tab, else the main
    /// window's, else the first terminal window's, else the key/main window
    /// as-is (so the alert still shows when no terminal window exists). Pure +
    /// injectable so it is unit-testable without fabricating a real
    /// `NSWindowTabGroup` (sibling of how `upToDateMessage` was extracted).
    /// Settings/About/panels are excluded by construction: they aren't
    /// `MainWindowController` windows, preserving the audit-L11
    /// "don't anchor to Settings" guarantee.
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
        // No terminal window at all (e.g. only Settings open) — fall back so
        // the alert still appears rather than being silently dropped. NOTE:
        // this returns the window AS-IS (not via bb_selectedTabWindow); it is
        // the untabbed-only escape hatch. Callers must not route a selectable
        // tab group through this branch, or the tab-yank bug this resolver
        // fixes would re-open. Unreachable today: a terminal key/main window is
        // caught by the selected-tab branches above.
        return keyWindow ?? mainWindow
    }

    /// The "up to date" alert body that `install()` swizzles into
    /// `SPUStandardUserDriver`, extracted so install() stays a thin
    /// swizzle trampoline. Computes the display name/version, builds the
    /// alert, and presents it per `presentationDecision`, calling `ack`
    /// once the alert is shown, dismissed, or deliberately dropped.
    private static func presentUpToDate(ack: @escaping () -> Void) {
        let name = Bundle.main
            .object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Blackbird"
        let version: String = {
            if let v = Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String, !v.isEmpty {
                return v
            }
            // Missing/empty version means a corrupted bundle — surface so a
            // user reporting "the alert says 'Blackbird  is the latest'" can
            // grep for the cause. One log per session per miss; the alert
            // path is user-driven (Check for Updates), not a hot path.
            // Audit EH-005.
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

        // Audit #23 / L11: avoid stacking modals (a blocking runModal() during
        // applicationShouldTerminate while a sheet is up can deadlock the quit
        // flow), and never anchor the sheet to the Settings window
        // (`resolveSheetParent` targets the selected terminal tab so the sheet
        // can't yank selection to tab 1). The sheet/runModal/drop choice is the
        // unit-tested `presentationDecision`; the modal interactions themselves
        // aren't headless-testable.
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
            // `.sheet` is only returned when `hasParent` — parentWindow is
            // non-nil here; the `if let` can't fail.
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
        // Thin trampoline: the alert presentation lives in `presentUpToDate`
        // (the swizzled-in selector ignores the driver + error args).
        let block: Block = { _, _, ack in
            Self.presentUpToDate(ack: ack)
        }
        let imp = imp_implementationWithBlock(block as Any)
        // F-S7-001: free the previously-installed block IMP, if any. We
        // discriminate by `installedBlockIMP`: nil on the very first call
        // (so the prior IMP returned by `method_setImplementation` is the
        // runtime-owned original — leave it alone), non-nil on subsequent
        // calls (so the prior IMP is one we minted via
        // `imp_implementationWithBlock` and must release). @MainActor
        // serialises the whole swap so a re-install can't observe a
        // half-updated tracking state.
        let prior = installedBlockIMP
        let runtimePrior = method_setImplementation(method, imp)
        // Capture the runtime-owned original on first install so
        // `_resetForTests` can restore it. After first install,
        // `runtimePrior` is our previous IMP and is dropped (we'll
        // free it via `imp_removeBlock` below).
        if originalIMP == nil { originalIMP = runtimePrior }
        if let prior {
            imp_removeBlock(prior)
        }
        installedBlockIMP = imp
    }

    #if DEBUG
    /// Test-only accessor for the IMP we installed. Lets
    /// `SparkleAlertOverrideTests` assert that re-install replaces the
    /// tracked IMP. DEBUG-gated — release builds carry no test surface.
    internal static var _installedBlockIMPForTests: IMP? {
        installedBlockIMP
    }

    /// Test-only reset for cross-test isolation. Restores the runtime-
    /// owned original IMP to the class slot (so the next dispatch on
    /// `showUpdateNotFoundWithError:` lands in Sparkle's default body,
    /// not on a freed trampoline), frees the IMP we minted, and clears
    /// the tracking field. After this, calling `install()` again is
    /// equivalent to a fresh first install: it re-captures the original
    /// (which is now on the slot again) and tracks a fresh block IMP.
    internal static func _resetForTests() {
        // Always clear tracking state, even if the selector lookup fails.
        // Without this, an early return on a Sparkle API rename would leave
        // a stale tracked IMP behind and the contract documented in the
        // type doc ("clears the tracking field") would be violated. We
        // can't restore the original to a method we can't find — but we
        // can at least keep the tracking honest.
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

/// Minimal window facts `SparkleAlertOverride.resolveSheetParent` needs,
/// abstracted so the resolution logic is unit-testable without fabricating a
/// real `NSWindowTabGroup` (AppKit only creates one for genuinely-tabbed
/// windows, and `selectedWindow` cannot be set directly). Production conformer
/// is `NSWindow`; tests inject lightweight stubs.
@MainActor
protocol SheetParentResolvable: AnyObject {
    /// Owned by a `MainWindowController` — a terminal window. Excludes
    /// Settings/About/panels by construction (the audit-L11 guarantee).
    var bb_isTerminalWindow: Bool { get }
    /// A sheet is already attached (cannot stack another).
    var bb_hasAttachedSheet: Bool { get }
    /// The window AppKit would surface for a sheet: the tab group's selected
    /// tab, or `self` when the window isn't tabbed. Array position in
    /// `NSApp.windows` is NOT this; `tabGroup.selectedWindow` is the authority.
    var bb_selectedTabWindow: SheetParentResolvable { get }
}

extension NSWindow: SheetParentResolvable {
    var bb_isTerminalWindow: Bool { windowController is MainWindowController }
    var bb_hasAttachedSheet: Bool { attachedSheet != nil }
    var bb_selectedTabWindow: SheetParentResolvable { tabGroup?.selectedWindow ?? self }
}
