import Foundation

/// FIFO of PTY chunks whose parse was deferred because a user action was
/// waiting on `coreQueue` (see the feed-deferral notes on `TerminalSession`).
///
/// Owns the one invariant the two-field version spread over six call sites:
/// `head` indexes the next unparsed chunk, and parsed chunks are released
/// incrementally — a saturating stream plus a user action every ~16 ms (a
/// scroll drag) makes every drain yield before reaching the end, so without
/// compaction the parsed `Data` (128 KiB each) would stay referenced by the
/// array and grow at the parse rate, ≈30 MiB per second of scrolling, freed
/// only when the user stopped. `FeedBudget` bounds *unparsed* bytes; this
/// bounds resident ones.
///
/// Pure value type, confined to whichever queue owns the `TerminalSession`'s
/// parser (`coreQueue`). Exposed for tests.
struct DeferredFeedQueue {
    private var chunks: [Data] = []
    private var head = 0

    /// Compact once this many parsed entries lead the array. Amortised O(1)
    /// per pop; keeps at most `compactionThreshold - 1` parsed chunks alive.
    static let compactionThreshold = 8

    init() {}

    var isEmpty: Bool { head >= chunks.count }
    /// Unparsed chunks still queued.
    var count: Int { chunks.count - head }

    mutating func append(_ chunk: Data) {
        chunks.append(chunk)
    }

    /// Next chunk in arrival order, or nil when drained. Releases parsed
    /// entries as it goes.
    mutating func popFirst() -> Data? {
        guard head < chunks.count else { return nil }
        let chunk = chunks[head]
        // Drop the reference now so the bytes are freed even if compaction
        // waits a few more pops.
        chunks[head] = Data()
        head += 1
        if head >= chunks.count {
            chunks.removeAll(keepingCapacity: true)
            head = 0
        } else if head >= Self.compactionThreshold {
            chunks.removeFirst(head)
            head = 0
        }
        return chunk
    }

    mutating func removeAll() {
        chunks.removeAll()
        head = 0
    }
}
