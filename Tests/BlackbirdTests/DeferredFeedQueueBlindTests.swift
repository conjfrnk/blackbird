import XCTest
import Foundation
@testable import Blackbird

/// Blind behaviour tests for `DeferredFeedQueue`, written from the spec
/// alone without sight of `Sources/Blackbird/Terminal/DeferredFeedQueue.swift`.
///
/// Contract under test: `DeferredFeedQueue` is a value-type FIFO of `Data`
/// chunks. `append(_:)` enqueues at the tail; `popFirst()` returns chunks in
/// arrival order and `nil` when empty; `count` is the number of chunks
/// appended but not yet popped; `isEmpty` is `count == 0`; `removeAll()`
/// discards every queued chunk. `compactionThreshold` (≥ 2) is the number of
/// pops after which the implementation must, at the latest, release popped
/// entries — compaction is a memory concern with no direct observable, so
/// these tests pin it *indirectly*: the head/tail bookkeeping must survive a
/// compaction at every multiple of the threshold with arrival order intact.
///
/// **Payload encoding.** Every chunk carries its own sequence number so a
/// wrong-order or duplicated pop is caught by content, not just by count:
/// bytes 0..<4 are the index as little-endian `UInt32`, the remaining bytes
/// are a per-index fill byte.
///
/// **Memory / time pre-flight** (per `feedback_test_memory_safety`):
///  - Largest single allocation is the 10 000 × 16-byte stress corpus
///    (≈160 KiB of payload plus `Data` headers, well under 1 MiB) and one
///    4 KiB chunk for the byte-equality test.
///  - Compaction tests allocate `3 × compactionThreshold` 16-byte chunks;
///    even a threshold in the thousands stays in the low hundreds of KiB.
///  - No `BBTerm`, no `TerminalView`, no session, no window, no runloop.
///    Each test is pure in-memory struct manipulation — microseconds, except
///    the stress test which is bounded at 50 ms of queue work (payload
///    construction is done *outside* the timed region so the bound measures
///    the queue, not `Data` allocation).
final class DeferredFeedQueueBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Helpers

    /// A 16-byte chunk whose first four bytes are `index` (little-endian
    /// `UInt32`) and whose remaining bytes are `UInt8(index & 0xFF)`.
    private func chunk(_ index: Int, size: Int = 16) -> Data {
        precondition(size >= 4)
        var bytes = [UInt8](repeating: UInt8(truncatingIfNeeded: index), count: size)
        let value = UInt32(truncatingIfNeeded: index).littleEndian
        withUnsafeBytes(of: value) { raw in
            for i in 0..<4 { bytes[i] = raw[i] }
        }
        return Data(bytes)
    }

    /// Decodes the sequence number written by `chunk(_:)`.
    private func index(of data: Data) -> Int {
        precondition(data.count >= 4)
        var value: UInt32 = 0
        withUnsafeMutableBytes(of: &value) { raw in
            data.prefix(4).copyBytes(to: raw)
        }
        return Int(UInt32(littleEndian: value))
    }

    /// Pops one chunk, failing the test (not crashing) if the queue is empty,
    /// and asserts its sequence number.
    private func popExpecting(
        _ expected: Int,
        from queue: inout DeferredFeedQueue,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let popped = try XCTUnwrap(
            queue.popFirst(),
            "expected chunk #\(expected) but the queue was empty",
            file: file, line: line
        )
        XCTAssertEqual(
            index(of: popped), expected,
            "popped chunk out of arrival order", file: file, line: line
        )
        XCTAssertEqual(
            popped, chunk(expected),
            "popped chunk #\(expected) bytes differ from what was appended",
            file: file, line: line
        )
    }

    // MARK: - 0. Threshold sanity

    /// The spec guarantees `compactionThreshold ≥ 2`; every compaction test
    /// below sizes its corpus from it, so pin the lower bound explicitly.
    func testCompactionThresholdIsAtLeastTwo() {
        XCTAssertGreaterThanOrEqual(DeferredFeedQueue.compactionThreshold, 2)
    }

    // MARK: - 1. Fresh queue

    func testFreshQueueIsEmptyWithZeroCountAndNilPop() {
        var queue = DeferredFeedQueue()
        XCTAssertTrue(queue.isEmpty)
        XCTAssertEqual(queue.count, 0)
        XCTAssertNil(queue.popFirst())
        // Popping from an empty queue must not disturb its emptiness.
        XCTAssertTrue(queue.isEmpty)
        XCTAssertEqual(queue.count, 0)
    }

    // MARK: - 2. FIFO order + count bookkeeping

    func testPopsFiveDistinctChunksInArrivalOrderAndCountDecrementsPerPop() throws {
        let payloads = ["alpha", "bravo", "charlie", "delta", "echo"].map { Data($0.utf8) }
        var queue = DeferredFeedQueue()

        for (i, payload) in payloads.enumerated() {
            queue.append(payload)
            XCTAssertEqual(queue.count, i + 1, "count must track appends")
            XCTAssertFalse(queue.isEmpty)
        }

        for (i, expected) in payloads.enumerated() {
            let popped = try XCTUnwrap(queue.popFirst(), "pop #\(i) returned nil")
            XCTAssertEqual(popped, expected, "pop #\(i) out of arrival order")
            XCTAssertEqual(queue.count, payloads.count - i - 1, "count must decrement per pop")
        }

        XCTAssertTrue(queue.isEmpty, "queue must be empty after the last pop")
        XCTAssertEqual(queue.count, 0)
        XCTAssertNil(queue.popFirst(), "a further pop past the last chunk must be nil")
    }

    // MARK: - 3. Interleaving

    func testInterleavedAppendsAndPopsPreserveArrivalOrder() throws {
        let a = Data("A".utf8), b = Data("B".utf8), c = Data("C".utf8)
        var queue = DeferredFeedQueue()

        queue.append(a)
        queue.append(b)
        XCTAssertEqual(try XCTUnwrap(queue.popFirst()), a)
        XCTAssertEqual(queue.count, 1)

        queue.append(c)
        XCTAssertEqual(queue.count, 2)
        XCTAssertEqual(try XCTUnwrap(queue.popFirst()), b)
        XCTAssertEqual(try XCTUnwrap(queue.popFirst()), c)

        XCTAssertNil(queue.popFirst())
        XCTAssertTrue(queue.isEmpty)
        XCTAssertEqual(queue.count, 0)
    }

    // MARK: - 4. Reusable after draining

    func testQueueIsReusableAfterDrainingToEmpty() throws {
        var queue = DeferredFeedQueue()

        for i in 0..<3 { queue.append(chunk(i)) }
        for i in 0..<3 { try popExpecting(i, from: &queue) }
        XCTAssertTrue(queue.isEmpty)
        XCTAssertNil(queue.popFirst())

        // Second life: fresh indices, order must still be arrival order and
        // nothing from the first life may resurface.
        for i in 10..<14 { queue.append(chunk(i)) }
        XCTAssertEqual(queue.count, 4)
        for i in 10..<14 { try popExpecting(i, from: &queue) }
        XCTAssertTrue(queue.isEmpty)
        XCTAssertNil(queue.popFirst())
    }

    // MARK: - 5. removeAll

    func testRemoveAllOnNonEmptyQueueEmptiesItAndAppendStillWorks() throws {
        var queue = DeferredFeedQueue()
        for i in 0..<5 { queue.append(chunk(i)) }
        // Pop one first so removeAll runs on a queue with a non-zero head.
        try popExpecting(0, from: &queue)
        XCTAssertEqual(queue.count, 4)

        queue.removeAll()
        XCTAssertTrue(queue.isEmpty)
        XCTAssertEqual(queue.count, 0)
        XCTAssertNil(queue.popFirst(), "no chunk may survive removeAll")

        queue.append(chunk(99))
        XCTAssertFalse(queue.isEmpty)
        XCTAssertEqual(queue.count, 1)
        try popExpecting(99, from: &queue)
        XCTAssertNil(queue.popFirst())
    }

    func testRemoveAllOnEmptyQueueIsHarmless() {
        var queue = DeferredFeedQueue()
        queue.removeAll()
        XCTAssertTrue(queue.isEmpty)
        XCTAssertEqual(queue.count, 0)
        XCTAssertNil(queue.popFirst())
    }

    // MARK: - 6. Compaction (indirect)

    /// Append 3N, pop 3N−1 — crossing the compaction point at N and 2N with
    /// the queue never emptying, and landing one pop short of 3N — then
    /// append one more and pop the last two. If the head index were stale
    /// after any compaction the final two pops would return the wrong chunk,
    /// a duplicate, or nil.
    func testIndexBookkeepingSurvivesCompactionAtEveryMultipleOfThreshold() throws {
        let n = DeferredFeedQueue.compactionThreshold
        var queue = DeferredFeedQueue()

        for i in 0..<(3 * n) { queue.append(chunk(i)) }
        XCTAssertEqual(queue.count, 3 * n)

        for i in 0..<(3 * n - 1) { try popExpecting(i, from: &queue) }
        XCTAssertEqual(queue.count, 1, "exactly one chunk must remain")
        XCTAssertFalse(queue.isEmpty)

        queue.append(chunk(3 * n))
        XCTAssertEqual(queue.count, 2)

        try popExpecting(3 * n - 1, from: &queue)
        try popExpecting(3 * n, from: &queue)
        XCTAssertTrue(queue.isEmpty)
        XCTAssertEqual(queue.count, 0)
        XCTAssertNil(queue.popFirst())
    }

    /// Pop exactly N chunks from a 2N-deep queue (so compaction is due but
    /// the queue is not empty), then keep appending and popping: order must
    /// continue seamlessly across the compaction boundary.
    func testPoppingExactlyThresholdChunksThenContinuingKeepsArrivalOrder() throws {
        let n = DeferredFeedQueue.compactionThreshold
        var queue = DeferredFeedQueue()

        for i in 0..<(2 * n) { queue.append(chunk(i)) }
        for i in 0..<n { try popExpecting(i, from: &queue) }
        XCTAssertEqual(queue.count, n, "N chunks must still be queued after N pops")
        XCTAssertFalse(queue.isEmpty)

        // Continue with more appends so the tail grows after the compaction.
        for i in (2 * n)..<(3 * n) { queue.append(chunk(i)) }
        XCTAssertEqual(queue.count, 2 * n)

        for i in n..<(3 * n) { try popExpecting(i, from: &queue) }
        XCTAssertTrue(queue.isEmpty)
        XCTAssertNil(queue.popFirst())
    }

    /// Repeated compaction cycles without ever emptying: pop exactly N, append
    /// N, several times over. The head must keep advancing correctly on every
    /// cycle, not just the first.
    func testRepeatedCompactionCyclesWithoutEmptyingKeepArrivalOrder() throws {
        let n = DeferredFeedQueue.compactionThreshold
        var queue = DeferredFeedQueue()
        var nextAppend = 0
        var nextPop = 0

        for _ in 0..<n { queue.append(chunk(nextAppend)); nextAppend += 1 }

        for _ in 0..<4 {
            for _ in 0..<n { queue.append(chunk(nextAppend)); nextAppend += 1 }
            for _ in 0..<n { try popExpecting(nextPop, from: &queue); nextPop += 1 }
            XCTAssertEqual(queue.count, n)
            XCTAssertFalse(queue.isEmpty)
        }

        for _ in 0..<n { try popExpecting(nextPop, from: &queue); nextPop += 1 }
        XCTAssertEqual(nextPop, nextAppend)
        XCTAssertTrue(queue.isEmpty)
        XCTAssertNil(queue.popFirst())
    }

    // MARK: - 7. Byte fidelity

    func testPoppedChunkBytesEqualAppendedBytesForMultiKiBChunk() throws {
        let size = 4096
        let original = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        XCTAssertEqual(original.count, size)

        var queue = DeferredFeedQueue()
        queue.append(Data("prefix".utf8))
        queue.append(original)
        queue.append(Data("suffix".utf8))

        XCTAssertEqual(try XCTUnwrap(queue.popFirst()), Data("prefix".utf8))
        let popped = try XCTUnwrap(queue.popFirst())
        XCTAssertEqual(popped.count, size)
        XCTAssertEqual(popped, original, "popped bytes must equal the appended bytes")
        XCTAssertEqual(Array(popped.suffix(8)), Array(original.suffix(8)))
        XCTAssertEqual(try XCTUnwrap(queue.popFirst()), Data("suffix".utf8))
        XCTAssertNil(queue.popFirst())
    }

    // MARK: - 8. Stress

    /// 10 000 appends of 16-byte chunks, interleaved with pops so that about
    /// N/2 chunks are queued at any moment (the queue never empties mid-run,
    /// so compaction fires repeatedly). The popped sequence must equal the
    /// appended sequence. Only the queue operations are timed.
    func testStressTenThousandInterleavedAppendsAndPopsPreserveSequence() throws {
        let total = 10_000
        let n = DeferredFeedQueue.compactionThreshold
        let steadyDepth = max(1, n / 2)
        XCTAssertLessThan(steadyDepth, total, "threshold too large for this corpus")

        // Build payloads outside the timed region.
        let corpus: [Data] = (0..<total).map { chunk($0) }
        var popped: [Data] = []
        popped.reserveCapacity(total)

        var queue = DeferredFeedQueue()
        let start = DispatchTime.now()

        // Prime to the steady-state depth.
        var appended = 0
        while appended < steadyDepth {
            queue.append(corpus[appended]); appended += 1
        }
        // Steady state: one append, one pop; depth stays at steadyDepth.
        while appended < total {
            queue.append(corpus[appended]); appended += 1
            if let d = queue.popFirst() { popped.append(d) } else { break }
        }
        // Drain.
        while let d = queue.popFirst() { popped.append(d) }

        let elapsedNs = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
        let elapsedMs = Double(elapsedNs) / 1_000_000

        XCTAssertEqual(popped.count, total, "every appended chunk must be popped exactly once")
        XCTAssertTrue(queue.isEmpty)
        XCTAssertEqual(queue.count, 0)
        XCTAssertNil(queue.popFirst())

        // Sequence check by index first (cheap, points at the first divergence),
        // then full byte equality.
        for (i, d) in popped.enumerated() where index(of: d) != i {
            XCTFail("popped chunk at position \(i) carries index \(index(of: d))")
            break
        }
        XCTAssertEqual(popped, corpus, "popped payloads must equal the appended sequence")

        XCTAssertLessThan(elapsedMs, 50, "queue work for \(total) chunks took \(elapsedMs) ms")
    }

    // MARK: - Value semantics

    /// `DeferredFeedQueue` is a `struct`: a copy is independent of the
    /// original, so popping from the copy must not drain the original.
    func testCopyOfQueueIsIndependentOfOriginal() throws {
        var original = DeferredFeedQueue()
        for i in 0..<3 { original.append(chunk(i)) }

        var copy = original
        try popExpecting(0, from: &copy)
        try popExpecting(1, from: &copy)

        XCTAssertEqual(copy.count, 1)
        XCTAssertEqual(original.count, 3, "popping the copy must not affect the original")
        for i in 0..<3 { try popExpecting(i, from: &original) }
        XCTAssertTrue(original.isEmpty)
        try popExpecting(2, from: &copy)
        XCTAssertTrue(copy.isEmpty)
    }
}
