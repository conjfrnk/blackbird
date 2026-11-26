import Foundation
import BBCore

/// Prompt-mark navigation (OSC 133 A). The `@Published` stores stay on the session; this owns the cursor and the two clear epochs.
public final class PromptNavigator {

    /// Anchored to the core's monotonic lines-scrolled counter, which never plateaus at the scrollback cap.
    public struct PromptMark: Equatable, Hashable {
        public let linesScrolled: UInt64
        /// 0 = top of the live grid.
        public let gridRow: Int
        fileprivate var absoluteRow: UInt64 {
            linesScrolled &+ UInt64(clamping: gridRow)
        }
    }

    private unowned let session: TerminalSession

    /// Nil means not in a jump cycle. Main-confined.
    private var promptCursor: Int?

    private static let promptMarkCap = 200

    /// `clearEpochCore` is coreQueue-confined, `clearEpochMain` main-confined. An OSC 133 A event that fired before a ⌘K
    /// clear but drains on main after it carries a stale epoch and self-discards; never merge the two or swap their queues.
    private var clearEpochCore: UInt64 = 0
    private var clearEpochMain: UInt64 = 0

    init(session: TerminalSession) {
        self.session = session
    }

    // MARK: - Clear-epoch machinery

    /// Read on coreQueue at OSC 133 event-fire time.
    var currentClearEpochCore: UInt64 { clearEpochCore }

    /// Must be called on coreQueue, inside `clearAll`'s `coreQueue.sync`, after `bbterm.clearAll()`.
    func bumpClearEpochCore() {
        clearEpochCore &+= 1
    }

    /// Must run on main.
    func resetForClear() {
        clearEpochMain &+= 1
        session.promptMarks = []
        promptCursor = nil
        session.lastPromptMark = nil
    }

    /// Must run on main. Leaves `lastPromptMark` and `clearEpochMain` alone: a reflow is not a clear.
    func invalidateForReflow() {
        session.promptMarks = []
        promptCursor = nil
    }

    // MARK: - Prompt navigation

    /// The position is the core's stamp on the event; a snapshot taken here would show wherever the core has got to by now.
    func recordPromptStart(linesScrolled: UInt64, gridRow: Int, eventClearEpoch: UInt64) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard eventClearEpoch == clearEpochMain else { return }
        if session.isTerminatedLocked() { return }
        let mark = PromptMark(linesScrolled: linesScrolled, gridRow: gridRow)
        // fish >= 4 re-emits A on every repaint. Compare absolute rows, not struct equality: the same row can carry a different scroll origin.
        if let last = session.promptMarks.last, last.absoluteRow == mark.absoluteRow {
            promptCursor = nil
            return
        }
        session.promptMarks.append(mark)
        if session.promptMarks.count > Self.promptMarkCap {
            session.promptMarks.removeFirst(session.promptMarks.count - Self.promptMarkCap)
        }
        promptCursor = nil
    }

    @discardableResult
    func jumpToPreviousPrompt() -> Bool {
        guard !session.promptMarks.isEmpty else { return false }
        let next: Int = {
            if let cur = promptCursor {
                return max(0, cur - 1)
            }
            return session.promptMarks.count - 1
        }()
        if let cur = promptCursor, next == cur { return false }
        promptCursor = next
        scrollToMark(session.promptMarks[next])
        return true
    }

    @discardableResult
    func jumpToNextPrompt() -> Bool {
        guard let cur = promptCursor, !session.promptMarks.isEmpty else { return false }
        let next = min(session.promptMarks.count - 1, cur + 1)
        if next == cur { return false }
        promptCursor = next
        scrollToMark(session.promptMarks[next])
        return true
    }

    /// The target offset is `(counterNow − linesScrolled) − gridRow`; the mark is evicted exactly when that exceeds the history size.
    private func scrollToMark(_ mark: PromptMark) {
        guard let snap = session.performUserAction({ self.session.bbterm.snapshot() }) else {
            return
        }
        let scrolledSince = snap.linesScrolled >= mark.linesScrolled
            ? Int(clamping: snap.linesScrolled - mark.linesScrolled)
            : 0
        let target = scrolledSince - mark.gridRow
        if target > snap.historySize {
            session.promptMarks.removeAll { $0 == mark }
            if let cursor = promptCursor, cursor >= session.promptMarks.count {
                promptCursor = session.promptMarks.isEmpty ? nil : session.promptMarks.count - 1
            }
            return
        }
        let clampedTarget = max(0, min(target, snap.historySize))
        let delta = clampedTarget - snap.displayOffset
        if delta != 0 {
            session.scroll(delta: Int32(clamping: delta))
        }
    }

    // MARK: - Test-only access

    #if DEBUG
    func _testAppendMark(_ mark: PromptMark) {
        session.promptMarks.append(mark)
        if session.promptMarks.count > Self.promptMarkCap {
            session.promptMarks.removeFirst(session.promptMarks.count - Self.promptMarkCap)
        }
        promptCursor = nil
    }

    var _testPromptCursor: Int? { promptCursor }
    #endif
}
