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

    /// The runtime-owned original IMP captured the first time `install()`
    /// runs. Used by `_resetForTests` so the test seam can restore the
    /// class to its pre-install state instead of leaving a freed
    /// trampoline pointer in the method slot. Nil before any install ran.
    /// Production code never reads this — the original IMP is meaningful
    /// only for test isolation.
    private static let originalIMP =
        OSAllocatedUnfairLock<IMP?>(initialState: nil)

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
        // the alert still appears rather than being silently dropped.
        return keyWindow ?? mainWindow
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
            alert.informativeText = Self.upToDateMessage(name: name, version: version)
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
            // TODO(audit #23): revisit if SPUUpdater grows a non-blocking API.
            //
            // Audit L11. NSApp.keyWindow can be the Settings window if the
            // user clicked "Check for Updates Now" from Settings → Updates.
            // Attaching the "up to date" sheet to Settings is visually
            // wrong and dismisses awkwardly when the user closes Settings
            // mid-presentation. Prefer the first eligible terminal window
            // (a MainWindowController's window without an attached sheet)
            // before falling back to keyWindow / mainWindow — that gives
            // the alert a stable visual home regardless of where the
            // check was triggered.
            // Target the ACTIVE/selected tab, not array position. See
            // `resolveSheetParent` — attaching the sheet to a non-selected tab
            // forces AppKit to surface (select) that tab, which is exactly the
            // "Check for Updates kicks me back to tab 1" bug.
            let parentWindow = Self.resolveSheetParent(
                windows: NSApp.windows,
                keyWindow: NSApp.keyWindow,
                mainWindow: NSApp.mainWindow
            ) as? NSWindow
            if let window = parentWindow,
               window.attachedSheet == nil,
               NSApp.modalWindow == nil,
               NSApp.isActive {
                alert.beginSheetModal(for: window) { _ in
                    ack()
                }
                return
            }

            // Drop the alert if anything modal is in flight or the app
            // isn't foreground. The third branch (parentWindow has an
            // attached sheet but no app-modal session) was previously
            // missing — execution would fall through to runModal() and
            // deadlock against the existing sheet, exactly the case the
            // sheet-path guard above means to prevent. (audit #23)
            if NSApp.modalWindow != nil
                || !NSApp.isActive
                || (parentWindow?.attachedSheet != nil) {
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
            let runtimePrior = method_setImplementation(method, imp)
            // Capture the runtime-owned original on first install so
            // `_resetForTests` can restore it. After first install,
            // `runtimePrior` is our previous IMP and is dropped (we'll
            // free it via `imp_removeBlock` below).
            originalIMP.withLock { orig in
                if orig == nil { orig = runtimePrior }
            }
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
            installedBlockIMP.withLock { $0 = nil }
            originalIMP.withLock { $0 = nil }
        }
        let cls: AnyClass = SPUStandardUserDriver.self
        let sel = NSSelectorFromString("showUpdateNotFoundWithError:acknowledgement:")
        guard let method = class_getInstanceMethod(cls, sel) else { return }
        installedBlockIMP.withLock { prior in
            originalIMP.withLock { orig in
                if let orig {
                    method_setImplementation(method, orig)
                }
            }
            if let p = prior {
                imp_removeBlock(p)
            }
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
