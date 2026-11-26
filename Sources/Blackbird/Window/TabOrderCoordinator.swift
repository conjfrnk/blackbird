import AppKit
import os

/// Per-tab-group visual order layered over `NSWindowTabGroup`. Reordering `tabGroup.windows` itself
/// needs detach-then-reattach, which animates the strip; windows are routed by identity, never by position.
final class TabOrderCoordinator {

    static let shared = TabOrderCoordinator()

    /// Posted with `object` = the `NSWindowTabGroup`.
    static let orderDidChange = Notification.Name("dev.conjfrnk.blackbird.tabOrderDidChange")

    internal struct WeakWindow {
        weak var value: NSWindow?
    }

    /// Keyed by `ObjectIdentifier(tabGroup)`. AppKit deallocates an empty group and hands out a fresh
    /// instance later, so a dead group's key is never read again and must be purged.
    private var ordersByGroup: [ObjectIdentifier: [WeakWindow]] = [:]

    private enum ReinsertAnchor {
        case front
        /// A neighbor that has deallocated or is absent from the destination means an ordinary append.
        case afterNeighbor(WeakWindow)
    }
    private struct DepartureHint {
        weak var departed: NSWindow?
        let anchor: ReinsertAnchor
    }

    /// One-shot hints, consumed the next time that exact window is newly seen in any group.
    /// An array of weak references, not a dictionary, so a dead window's hint can be detected and purged.
    private var departureHints: [DepartureHint] = []

    private static let logger = Logger(subsystem: "dev.conjfrnk.blackbird",
                                       category: "tabOrder")

    private init() {}

    func orderedTabs(for group: NSWindowTabGroup) -> [NSWindow] {
        return reconcile(stored: ordersByGroup[ObjectIdentifier(group)] ?? [],
                         live: group.windows,
                         commitTo: ObjectIdentifier(group))
    }

    func orderedTabs(of window: NSWindow) -> [NSWindow] {
        guard let group = window.tabGroup else { return [window] }
        return orderedTabs(for: group)
    }

    func move(window: NSWindow, to newIndex: Int, in group: NSWindowTabGroup) {
        var current = orderedTabs(for: group)
        guard let oldIndex = current.firstIndex(where: { $0 === window }) else {
            Self.logger.notice("move: window not present in group's visual order after reconcile; ignoring")
            return
        }
        let clamped = max(0, min(newIndex, current.count - 1))
        if clamped == oldIndex { return }
        current.remove(at: oldIndex)
        current.insert(window, at: clamped)
        ordersByGroup[ObjectIdentifier(group)] = current.map(WeakWindow.init)
        NotificationCenter.default.post(name: Self.orderDidChange, object: group)
    }

    func nextWindow(after window: NSWindow, in group: NSWindowTabGroup) -> NSWindow? {
        let order = orderedTabs(for: group)
        guard order.count > 1,
              let idx = order.firstIndex(where: { $0 === window }) else { return nil }
        return order[(idx + 1) % order.count]
    }

    func previousWindow(before window: NSWindow, in group: NSWindowTabGroup) -> NSWindow? {
        let order = orderedTabs(for: group)
        guard order.count > 1,
              let idx = order.firstIndex(where: { $0 === window }) else { return nil }
        return order[(idx - 1 + order.count) % order.count]
    }

    static func neighborIndexAfterClose(closingIndex: Int, count: Int) -> Int? {
        guard count > 1, closingIndex >= 0, closingIndex < count else { return nil }
        return closingIndex + 1 < count ? closingIndex + 1 : closingIndex - 1
    }

    // MARK: - Internal (testable)

    /// A nil `commitTo` writes no order back; departure hints are recorded either way.
    internal func reconcile(stored: [WeakWindow],
                            live: [NSWindow],
                            commitTo key: ObjectIdentifier?) -> [NSWindow] {
        var seen = Set<ObjectIdentifier>()
        var result: [NSWindow] = []
        for (index, entry) in stored.enumerated() {
            guard let w = entry.value else { continue }
            if live.contains(where: { $0 === w }) {
                result.append(w)
                seen.insert(ObjectIdentifier(w))
            } else {
                // The left neighbor comes from the stored order, not the partial `result`.
                if index == 0 {
                    departureHints.append(DepartureHint(departed: w, anchor: .front))
                } else {
                    departureHints.append(DepartureHint(
                        departed: w,
                        anchor: .afterNeighbor(WeakWindow(value: stored[index - 1].value))))
                }
            }
        }
        for w in live where !seen.contains(ObjectIdentifier(w)) {
            if let hintIndex = departureHints.firstIndex(where: { $0.departed === w }) {
                let hint = departureHints[hintIndex]
                // Consumed on the first join anywhere, matched or not: an unmatched hint kept alive
                // would move the window next to its old neighbour on a later, unrelated join.
                departureHints.remove(at: hintIndex)
                switch hint.anchor {
                case .front:
                    Self.logger.debug("reconcile: restored departed window to the front of its destination order (hint match)")
                    result.insert(w, at: 0)
                    continue
                case .afterNeighbor(let box):
                    if let neighbor = box.value,
                       let neighborIndex = result.firstIndex(where: { $0 === neighbor }) {
                        Self.logger.debug("reconcile: restored departed window after its remembered neighbor at index \(neighborIndex, privacy: .public) (hint match)")
                        result.insert(w, at: neighborIndex + 1)
                        continue
                    }
                }
            }
            result.append(w)
        }
        if let key {
            ordersByGroup[key] = result.map(WeakWindow.init)
            purgeDeadGroups()
            purgeStaleDepartureHints()
        }
        return result
    }

    private func purgeStaleDepartureHints() {
        departureHints.removeAll { $0.departed == nil }
    }

    private static func isDeadGroup(_ weaks: [WeakWindow]) -> Bool {
        !weaks.contains { $0.value != nil }
    }

    internal func purgeDeadGroups() {
        ordersByGroup = ordersByGroup.filter { !Self.isDeadGroup($1) }
    }

    #if DEBUG
    internal func reconcileForTesting(stored: [NSWindow?], live: [NSWindow]) -> [NSWindow] {
        let weaks = stored.map { WeakWindow(value: $0) }
        return reconcile(stored: weaks, live: live, commitTo: nil)
    }

    internal func setOrderForTesting(_ windows: [NSWindow], in group: NSWindowTabGroup) {
        ordersByGroup[ObjectIdentifier(group)] = windows.map(WeakWindow.init)
    }

    internal func resetForTesting() {
        ordersByGroup.removeAll()
        departureHints.removeAll()
    }

    internal func departureHintCountForTesting() -> Int {
        departureHints.filter { $0.departed != nil }.count
    }

    // MARK: Dead-group purge seams

    internal func seedRawForTesting(_ key: ObjectIdentifier, _ weaks: [WeakWindow]) {
        ordersByGroup[key] = weaks
    }

    internal func storedGroupKeysForTesting() -> Set<ObjectIdentifier> {
        Set(ordersByGroup.keys)
    }

    internal func reconcileCommittingForTesting(key: ObjectIdentifier,
                                                stored: [NSWindow?],
                                                live: [NSWindow]) -> [NSWindow] {
        reconcile(stored: stored.map { WeakWindow(value: $0) },
                  live: live,
                  commitTo: key)
    }
    #endif
}
