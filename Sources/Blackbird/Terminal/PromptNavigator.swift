import Foundation
import BBCore

/// Prompt-mark navigation for `TerminalSession` (OSC 133 A).
///
/// Pure extraction from `TerminalSession` (REFACTOR.md Part IV — the prompt-nav
/// concern): the ring of recorded prompt-start positions, the jump cursor, the
/// scroll-to-mark math, and the **clear-epoch machinery** that prevents a
/// phantom prompt mark from being inserted across a ⌘K clear. Extracted from
/// the god-object with the queue confinement and the epoch-comparison semantics
/// of the clear epoch unchanged; a prompt's position now comes from the core
/// stamp on the event rather than a snapshot taken at record time, which
/// is also why the former ring-generation token is gone.
///
/// ## Why the `@Published` stores stay on the session
/// `session.promptMarks` and `session.lastPromptMark` remain `@Published` on the
/// `TerminalSession` `ObservableObject` (the navigator drives them through the
/// `unowned session`, exactly as `SnapshotCoalescer` drives `@Published snapshot`
/// via `session.publish(_:)`). Moving them onto a plain collaborator would drop
/// the `objectWillChange` / projected-publisher surface — a behavior change. This
/// navigator owns the *machinery* (cursor, the two epochs) and the
/// *logic* (record / scroll / jump); the observable arrays stay where the UI
/// already reads them.
///
/// ## The clear-epoch cross-queue invariant (audit S5-008) — LOAD-BEARING
/// A late prompt-mark append must self-discard if a ⌘K clear happened in
/// between. The OSC 133 A event fires on `coreQueue` during `feed` (before ⌘K's
/// clear); its `recordPromptStart` call drains on main (after `clearAll`
/// completed). `clearEpochCore` (**coreQueue-confined**) is read on coreQueue at
/// event-fire time (`currentClearEpochCore`) and bumped inside `clearAll`'s
/// `coreQueue.sync` (`bumpClearEpochCore()`); the captured value rides the hop to
/// main and is compared against `clearEpochMain` (**main-confined**, bumped in
/// `resetForClear()`) at `recordPromptStart` entry. An event that predates the
/// clear carries a stale epoch and its append self-discards — **do not merge the
/// two epochs, do not move which queue touches each.**
///
/// ## Why a reflow needs no token
/// The core stamps each A mark with the position it had when the mark was parsed
/// (`BBTerm.Event.promptMark`), so `recordPromptStart` appends synchronously on
/// main: nothing is in flight between the stamp and the append. A resize wipes
/// the ring from a main hop enqueued after the resize ran on coreQueue, so after
/// the hop of every event parsed before it. A pre-reflow mark is appended and then
/// wiped; a post-reflow mark is stamped on the new grid and survives.
///
/// ## Lifetime
/// Methods read the `unowned session` directly: the session strongly owns this
/// navigator for its whole lifetime and nothing here defers work past a call.
public final class PromptNavigator {

    /// Position of a recorded prompt, anchored to the core's monotonic
    /// lines-scrolled counter (audit S5-004). The previous
    /// (historySize, gridRow) anchor broke the moment scrollback
    /// saturated: history_size plateaus at the cap while content keeps
    /// rotating out, so post-saturation marks all compared equal and
    /// ⌘[ silently jumped to the live bottom; the fix-#22 eviction
    /// guard ('elapsed > 100_000') was unsatisfiable dead code because
    /// elapsed ≤ cap by construction. linesScrolled never plateaus, so
    /// the anchor algebra — the marked row sits (now − linesScrolled)
    /// rows above its recorded gridRow — survives eviction, and
    /// eviction itself becomes exactly detectable (offset > history).
    public struct PromptMark: Equatable, Hashable {
        /// `BBSnapshot.linesScrolled` at the moment the prompt was
        /// emitted (primary-screen monotonic counter).
        public let linesScrolled: UInt64
        /// Grid row (0 = top of the live grid) at the moment the prompt
        /// was emitted.
        public let gridRow: Int
    }

    /// The owning session. `unowned` because the session strongly owns this
    /// navigator for its whole lifetime; synchronous methods read it directly.
    /// Deferred/async blocks that can outlive teardown capture `[weak session]`
    /// instead — never this `unowned` reference.
    private unowned let session: TerminalSession

    /// Current index inside `session.promptMarks` when cycling via
    /// `jumpToPreviousPrompt` / `jumpToNextPrompt`. Nil means "not in
    /// a jump cycle"; any new OSC 133 A resets to nil so the next Prev
    /// jump starts from the newest mark again. Main-confined.
    private var promptCursor: Int?

    private static let promptMarkCap = 200

    /// Clear-epoch pair (audit S5-008). The race spans the event hop: the
    /// OSC 133 A event fires on coreQueue during feed BEFORE ⌘K's clear, while
    /// the main-side event switch (and its recordPromptStart call) drains AFTER
    /// clearAll completed on main. The epoch is captured AT EVENT-FIRE TIME on
    /// coreQueue (`clearEpochCore`, coreQueue-confined, bumped inside clearAll's
    /// coreQueue.sync) and compared on main against `clearEpochMain` (main-owned,
    /// bumped in resetForClear): an event that predates the clear carries a
    /// stale epoch and its append self-discards.
    private var clearEpochCore: UInt64 = 0
    private var clearEpochMain: UInt64 = 0

    init(session: TerminalSession) {
        self.session = session
    }

    // MARK: - Clear-epoch machinery (cross-queue, S5-008)

    /// Read on **coreQueue** at OSC 133 event-fire time. Ordered against
    /// `bumpClearEpochCore()` because both run inside the session's coreQueue
    /// serialization (the event dispatches synchronously inside `bb_term_input`
    /// on coreQueue; the bump runs inside `clearAll`'s `coreQueue.sync`). The
    /// captured value rides the main hop so the prompt-mark append can tell
    /// "event predates the clear" from "genuine post-clear prompt".
    var currentClearEpochCore: UInt64 { clearEpochCore }

    /// Bump the coreQueue-confined clear epoch. MUST be called on **coreQueue**
    /// (the session invokes it inside `clearAll`'s `coreQueue.sync`, after
    /// `bbterm.clearAll()`). Events fired on coreQueue BEFORE this point carry
    /// the pre-bump epoch and their prompt-mark appends self-discard on main.
    func bumpClearEpochCore() {
        clearEpochCore &+= 1
    }

    /// ⌘K (`clearAll`) reset of the main-owned prompt state. MUST run on
    /// **main** — the session calls it from the `@MainActor` `resetPromptState`
    /// closure (via `onMain`). Bumps the main-side clear epoch so events that
    /// FIRED before the clear (but drain after) self-discard instead of
    /// re-inserting a mark anchored to the scrollback we just deleted. Then
    /// wipes the ring + last mark + cycle cursor.
    func resetForClear() {
        clearEpochMain &+= 1
        session.promptMarks = []
        promptCursor = nil
        session.lastPromptMark = nil
    }

    /// Reflow invalidation (audit S5-004/S5-005): ANY applied grid-size change
    /// invalidates lines-scrolled anchors. MUST run on **main** — the session
    /// calls it from `noteAppliedGridSize`'s `main.async` hop, which is queued
    /// after the hop of every mark parsed before the resize, so it also wipes
    /// those. Wipes the ring + cursor. Does NOT touch `lastPromptMark` or
    /// `clearEpochMain` — a reflow is not a clear.
    func invalidateForReflow() {
        session.promptMarks = []
        promptCursor = nil
    }

    // MARK: - Prompt navigation

    /// Record the position at which an OSC 133 A was parsed. Called on main
    /// from the event switch with the (lines scrolled, grid row) the core
    /// stamped on the event as it parsed the mark. A snapshot taken here would
    /// show wherever the core has got to by now: a burst of prompts or output
    /// parsed behind the mark would collapse every mark onto the last row or
    /// push it far below its prompt.
    /// A new prompt resets `promptCursor` to nil so the next jump
    /// starts from the newest mark.
    func recordPromptStart(linesScrolled: UInt64, gridRow: Int, eventClearEpoch: UInt64) {
        // The ring and cursor are main-owned.
        dispatchPrecondition(condition: .onQueue(.main))
        // Audit S5-008: an event that fired on coreQueue before ⌘K's clear but
        // drained on main after it arrives here with a stale epoch.
        guard eventClearEpoch == clearEpochMain else { return }
        // Audit fix-#11: terminate() could have run between the event firing
        // and this main drain; don't mutate promptMarks on a session whose
        // consumers are tearing down.
        if session.isTerminatedLocked() { return }
        session.promptMarks.append(PromptMark(linesScrolled: linesScrolled, gridRow: gridRow))
        if session.promptMarks.count > Self.promptMarkCap {
            session.promptMarks.removeFirst(session.promptMarks.count - Self.promptMarkCap)
        }
        promptCursor = nil
    }

    /// Scroll the viewport to the previous recorded prompt. First press
    /// from a resting state jumps to the newest mark; subsequent presses
    /// walk backwards through `session.promptMarks`. No-op when the ring is
    /// empty (shell hasn't sourced the OSC 133 integration, or no commands
    /// have run yet).
    @discardableResult
    func jumpToPreviousPrompt() -> Bool {
        guard !session.promptMarks.isEmpty else { return false }
        let next: Int = {
            if let cur = promptCursor {
                return max(0, cur - 1)
            }
            return session.promptMarks.count - 1
        }()
        // Already at the oldest mark: report "no more prompts" so the
        // caller's beep fires (it used to fire only for an empty ring).
        if let cur = promptCursor, next == cur { return false }
        promptCursor = next
        scrollToMark(session.promptMarks[next])
        return true
    }

    /// Walk forward through the prompt ring toward the live view. No-op
    /// when the user isn't already in a jump cycle — there's no "newer"
    /// prompt than the one currently live. Returns true when a jump
    /// happened so the view can surface "no more prompts" feedback.
    @discardableResult
    func jumpToNextPrompt() -> Bool {
        guard let cur = promptCursor, !session.promptMarks.isEmpty else { return false }
        let next = min(session.promptMarks.count - 1, cur + 1)
        if next == cur { return false }
        promptCursor = next
        scrollToMark(session.promptMarks[next])
        return true
    }

    /// Compute and apply the scroll delta that places a given mark near
    /// the top of the current viewport.
    ///
    /// Math (audit S5-004): the mark was recorded at live-grid row
    /// `gridRow` when the primary screen's monotonic counter read
    /// `linesScrolled`. Every line scrolled since moves the marked row
    /// one row further up, so the display offset that puts it at the
    /// viewport top is `(counterNow − linesScrolled) − gridRow`. Unlike
    /// the previous history_size anchor, the counter never plateaus at
    /// the scrollback cap, so this stays exact after saturation — and
    /// eviction is exactly `target > history` (the row scrolled past
    /// retention), replacing the unsatisfiable fix-#22 threshold guard.
    /// A negative target means the marked row is still at/below the
    /// viewport top in the live grid (or a clear collapsed history);
    /// clamp to 0 = live bottom.
    private func scrollToMark(_ mark: PromptMark) {
        // M-12: same tripwire rationale as recordPromptStart above. The
        // public callers (jumpToPreviousPrompt / jumpToNextPrompt) run on
        // main today, but a future event-driven path could land here from
        // coreQueue and hit the sync self-deadlock invisibly.
        guard let snap = session.performUserAction({ self.session.bbterm.snapshot() }) else {
            return
        }
        // Monotonic by contract; the defensive branch guards a future
        // regression rather than a reachable state.
        let scrolledSince = snap.linesScrolled >= mark.linesScrolled
            ? Int(clamping: snap.linesScrolled - mark.linesScrolled)
            : 0
        let target = scrolledSince - mark.gridRow
        if target > snap.historySize {
            // Evicted: the anchored row scrolled past retention. Drop
            // the orphaned mark and let the cycle promotion re-enter on
            // the next press (audit S5-004 — this check is exact, and
            // unlike its dead predecessor it actually fires).
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
    /// Internal hook for `PromptJumpTests` — appends a mark with the FIFO
    /// cap applied, without needing a real shell to emit OSC 133. Not
    /// public because the ring lifecycle is otherwise owned entirely by
    /// the event switch.
    func _testAppendMark(_ mark: PromptMark) {
        session.promptMarks.append(mark)
        if session.promptMarks.count > Self.promptMarkCap {
            session.promptMarks.removeFirst(session.promptMarks.count - Self.promptMarkCap)
        }
        promptCursor = nil
    }

    /// Internal accessor exposing the otherwise-private cycle index so
    /// tests can assert exact walk behaviour.
    var _testPromptCursor: Int? { promptCursor }
    #endif
}
