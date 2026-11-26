import Foundation

/// Confined to the parser's queue (`coreQueue`). Parsed chunks are released incrementally: a drain that
/// keeps yielding to user actions would otherwise leave every parsed `Data` referenced by the array.
struct DeferredFeedQueue {
    private var chunks: [Data] = []
    private var head = 0

    static let compactionThreshold = 8

    init() {}

    var isEmpty: Bool { head >= chunks.count }
    var count: Int { chunks.count - head }

    mutating func append(_ chunk: Data) {
        chunks.append(chunk)
    }

    mutating func popFirst() -> Data? {
        guard head < chunks.count else { return nil }
        let chunk = chunks[head]
        // Drop the reference now so the bytes are freed even if compaction waits a few more pops.
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
