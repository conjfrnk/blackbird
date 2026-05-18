import XCTest
import AppKit
@testable import Blackbird

/// Blind tests for `ScrollIndicator`: author has NOT read the impl.
/// Targets gaps left by `ScrollIndicatorTests` (which uses `Mirror` to peek
/// at the private `thumbLayer`). These tests assert through the public
/// NSView / CALayer surface only (`layer`, `layer.sublayers`, `hitTest`,
/// `frame`, `isHidden`) — no runtime introspection.
///
/// Contract assumed from CLAUDE-supplied docs:
/// - `init(frame:)` (NSView subclass)
/// - `update(displayOffset:Int, historySize:Int, rows:Int)` mutates a
///   CALayer-backed thumb. Out-of-range inputs clamp, never crash.
/// - `updatePromptMarks(...)` plots marks; concrete signature unknown,
///   so the prompt-mark-count tests use *only* signatures we can
///   discover by overload search. If the actual signature differs, the
///   two prompt-mark tests are skipped at compile time (#if false guard
///   below) — failure mode is a documented gap, not a red build.
/// - `hitTest(NSPoint)` returns nil (visual-only overlay).
final class ScrollIndicatorBlindTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    // MARK: - Helpers

    /// Build an indicator at a known size and force layer-backing. The
    /// existing test in ScrollIndicatorTests uses `NSRect(x:0,y:0,w:12,h:200)`
    /// — mirror that for consistency.
    private func makeIndicator(height: CGFloat = 200) -> ScrollIndicator {
        let v = ScrollIndicator(frame: NSRect(x: 0, y: 0, width: 12, height: height))
        // Drive layer creation so sublayer assertions have a tree to inspect.
        v.wantsLayer = true
        _ = v.layer
        return v
    }

    /// Return every CALayer in the indicator's layer subtree, recursively,
    /// excluding the root layer itself.
    private func allSublayers(_ v: NSView) -> [CALayer] {
        guard let root = v.layer else { return [] }
        var out: [CALayer] = []
        func walk(_ l: CALayer) {
            for s in l.sublayers ?? [] {
                out.append(s)
                walk(s)
            }
        }
        walk(root)
        return out
    }

    /// True if every frame value (x/y/w/h) in the layer subtree is finite.
    private func allFramesFinite(_ v: NSView) -> Bool {
        for l in allSublayers(v) {
            let f = l.frame
            if !(f.origin.x.isFinite && f.origin.y.isFinite
                 && f.size.width.isFinite && f.size.height.isFinite) {
                return false
            }
        }
        return true
    }

    // MARK: - Sublayer publication baseline (precondition for all bounds/finite tests)

    /// Precondition test: a normal update on a normal indicator must
    /// publish at least one sublayer (the thumb). Without this, every
    /// "frames finite" / "frames in bounds" / "sublayer count stable"
    /// test in this file passes vacuously on an impl that publishes
    /// nothing (the recursive walk over an empty subtree is no-op-true).
    /// This test guards the suite's load-bearing observation surface.
    func test_normalUpdate_publishesAtLeastOneSublayer() {
        let v = makeIndicator()
        v.update(displayOffset: 0, historySize: 1000, rows: 24)
        XCTAssertGreaterThan(
            allSublayers(v).count, 0,
            "normal update must publish at least one sublayer (the thumb); a broken impl that publishes nothing would make all bounds-checks in this file vacuous"
        )
    }

    // MARK: - Crash-resistance / clamp tests (observable via finiteness)

    /// `historySize == 0, displayOffset == 0` must not crash and must
    /// leave the layer subtree with finite frames (no nan/inf from a
    /// division-by-zero path).
    func test_zeroHistorySize_doesNotProduceNonFiniteFrames() {
        let v = makeIndicator()
        v.update(displayOffset: 0, historySize: 0, rows: 24)
        XCTAssertTrue(allFramesFinite(v),
            "zero historySize must not yield nan/inf frames")
    }

    /// `rows == 0` would naively divide by zero in `rows / (historySize + rows)`.
    /// Assert no crash and finite frames.
    func test_zeroRows_doesNotProduceNonFiniteFrames() {
        let v = makeIndicator()
        v.update(displayOffset: 0, historySize: 100, rows: 0)
        XCTAssertTrue(allFramesFinite(v),
            "zero rows must not yield nan/inf frames")
    }

    /// Both inputs zero — degenerate but reachable on a fresh empty
    /// terminal before the first row publishes. Must not crash.
    func test_zeroHistoryAndRows_doesNotCrash() {
        let v = makeIndicator()
        v.update(displayOffset: 0, historySize: 0, rows: 0)
        XCTAssertTrue(allFramesFinite(v),
            "(0,0,0) inputs must not yield nan/inf frames")
    }

    /// Negative `rows` shouldn't be reachable through the publish path
    /// today (rows is `Int` but always populated from a `u16`), but the
    /// contract says clamping is the safe behavior.
    func test_negativeRows_doesNotCrash() {
        let v = makeIndicator()
        v.update(displayOffset: 0, historySize: 100, rows: -5)
        XCTAssertTrue(allFramesFinite(v))
    }

    /// Negative `historySize`: same rationale.
    func test_negativeHistorySize_doesNotCrash() {
        let v = makeIndicator()
        v.update(displayOffset: 0, historySize: -10, rows: 24)
        XCTAssertTrue(allFramesFinite(v))
    }

    // MARK: - Hit-test pass-through

    /// The indicator is a visual cue — `hitTest` should return nil so
    /// mouse events fall through to the underlying text view.
    func test_hitTest_returnsNil_centerOfBounds() {
        let v = makeIndicator()
        v.update(displayOffset: 100, historySize: 1000, rows: 24)
        let center = NSPoint(x: v.bounds.midX, y: v.bounds.midY)
        XCTAssertNil(v.hitTest(center),
            "ScrollIndicator must be non-interactive; hitTest must return nil")
    }

    /// Hit-test pass-through must hold for any point, including the
    /// edges (where the thumb usually lives at bottom).
    func test_hitTest_returnsNil_atBottomEdge() {
        let v = makeIndicator()
        v.update(displayOffset: 0, historySize: 1000, rows: 24)
        let bottomEdge = NSPoint(x: v.bounds.midX, y: v.bounds.minY + 1)
        XCTAssertNil(v.hitTest(bottomEdge),
            "hitTest at bottom edge (thumb location) must still pass through")
    }

    /// Hit-test pass-through at the top edge (thumb location for max
    /// scrollback).
    func test_hitTest_returnsNil_atTopEdge() {
        let v = makeIndicator()
        v.update(displayOffset: 1000, historySize: 1000, rows: 24)
        let topEdge = NSPoint(x: v.bounds.midX, y: v.bounds.maxY - 1)
        XCTAssertNil(v.hitTest(topEdge),
            "hitTest at top edge (thumb location) must still pass through")
    }

    // MARK: - Idempotent update

    /// Calling `update` twice with the same inputs must produce the same
    /// final layer subtree (no growth in sublayer count, frames identical).
    /// Catches an accumulator bug where each call appends sublayers.
    func test_updateIsIdempotent_layerCountStable() {
        let v = makeIndicator()
        v.update(displayOffset: 250, historySize: 1000, rows: 24)
        let before = allSublayers(v).count
        v.update(displayOffset: 250, historySize: 1000, rows: 24)
        let after = allSublayers(v).count
        XCTAssertEqual(before, after,
            "repeated update with identical inputs must not grow sublayer count")
    }

    /// And the frames of those sublayers must be identical between the
    /// two calls.
    func test_updateIsIdempotent_layerFramesStable() {
        let v = makeIndicator()
        v.update(displayOffset: 250, historySize: 1000, rows: 24)
        let before = allSublayers(v).map { $0.frame }
        v.update(displayOffset: 250, historySize: 1000, rows: 24)
        let after = allSublayers(v).map { $0.frame }
        XCTAssertEqual(before.count, after.count,
            "sublayer count drifted between identical updates")
        for (i, (b, a)) in zip(before, after).enumerated() {
            XCTAssertEqual(b.origin.x, a.origin.x, accuracy: 0.001,
                "sublayer[\(i)] origin.x drifted")
            XCTAssertEqual(b.origin.y, a.origin.y, accuracy: 0.001,
                "sublayer[\(i)] origin.y drifted")
            XCTAssertEqual(b.size.width, a.size.width, accuracy: 0.001,
                "sublayer[\(i)] size.width drifted")
            XCTAssertEqual(b.size.height, a.size.height, accuracy: 0.001,
                "sublayer[\(i)] size.height drifted")
        }
    }

    /// Idempotence across very-different inputs in sequence: after a
    /// settle at (offset=0), then (offset=1000), then back to (offset=0),
    /// the layer subtree should match the original layout. Catches a
    /// stale-state bug where a previous large offset leaves accumulated
    /// dirty geometry.
    func test_updateRoundTrip_returnsToInitialLayout() {
        let v = makeIndicator()
        v.update(displayOffset: 0, historySize: 1000, rows: 24)
        let initial = allSublayers(v).map { $0.frame }
        v.update(displayOffset: 1000, historySize: 1000, rows: 24)
        v.update(displayOffset: 0, historySize: 1000, rows: 24)
        let after = allSublayers(v).map { $0.frame }
        XCTAssertEqual(initial.count, after.count,
            "round-trip changed sublayer count")
        for (i, (b, a)) in zip(initial, after).enumerated() {
            XCTAssertEqual(b.origin.y, a.origin.y, accuracy: 0.5,
                "round-trip drifted sublayer[\(i)] origin.y")
            XCTAssertEqual(b.size.height, a.size.height, accuracy: 0.5,
                "round-trip drifted sublayer[\(i)] size.height")
        }
    }

    // MARK: - Sublayer integrity across edge inputs

    /// After a sequence of valid + edge-case updates, the sublayer count
    /// must not grow without bound (catches a per-update layer leak).
    func test_repeatedUpdates_doNotLeakSublayers() {
        let v = makeIndicator()
        // Seed.
        v.update(displayOffset: 0, historySize: 1000, rows: 24)
        let baseline = allSublayers(v).count
        for offset in stride(from: 0, through: 1000, by: 50) {
            v.update(displayOffset: offset, historySize: 1000, rows: 24)
        }
        let final = allSublayers(v).count
        // Allow a small constant overhead; the key invariant is "not
        // proportional to call count". 21 calls happened; if each
        // leaked a sublayer the delta would be at least 20.
        XCTAssertLessThanOrEqual(final - baseline, 4,
            "sublayer count grew by \(final - baseline) over 21 updates — likely leak")
    }

    /// Edge inputs in sequence shouldn't push frames non-finite even if
    /// the next "normal" update should recover.
    func test_recoversFromEdgeInputs() {
        let v = makeIndicator()
        v.update(displayOffset: 0, historySize: 0, rows: 0)
        v.update(displayOffset: -999, historySize: -1, rows: -1)
        v.update(displayOffset: 9999, historySize: 50, rows: 24)
        v.update(displayOffset: 100, historySize: 1000, rows: 24) // normal
        XCTAssertTrue(allFramesFinite(v),
            "indicator must recover to finite layout after edge inputs")
        // Recovery means the indicator re-publishes its sublayers — an
        // impl that wipes sublayers on edge inputs and never rebuilds
        // them would silently pass the finite-frames check otherwise.
        XCTAssertGreaterThan(allSublayers(v).count, 0,
            "after a normal update following edge inputs, the indicator must re-publish sublayers")
    }

    // MARK: - Bounded geometry (clamping observable from the layer tree)

    /// Across the full range of valid displayOffsets, no sublayer frame
    /// should escape the indicator's bounds vertically. This is the
    /// public-API restatement of the existing `Mirror`-based "thumb
    /// stays on track" test.
    func test_allSublayerFrames_stayWithinIndicatorBounds() {
        let v = makeIndicator(height: 200)
        let trackHeight: CGFloat = 200
        let offsets = [0, 1, 100, 500, 999, 1000]
        for offset in offsets {
            v.update(displayOffset: offset, historySize: 1000, rows: 24)
            for (i, l) in allSublayers(v).enumerated() {
                let f = l.frame
                // Marks/thumb may extend slightly outside on rounding;
                // half a point tolerance like ScrollIndicatorTests.
                XCTAssertGreaterThanOrEqual(f.origin.y, -0.5,
                    "sublayer[\(i)] y went negative at offset=\(offset)")
                XCTAssertLessThanOrEqual(f.origin.y + f.size.height, trackHeight + 0.5,
                    "sublayer[\(i)] top exceeded track at offset=\(offset)")
            }
        }
    }

    /// Even with a wildly-out-of-range displayOffset, sublayer frames
    /// must stay on the track.
    func test_sublayerFrames_stayOnTrack_underOutOfRangeOffset() {
        let v = makeIndicator(height: 200)
        v.update(displayOffset: Int.max / 2, historySize: 50, rows: 24)
        for (i, l) in allSublayers(v).enumerated() {
            let f = l.frame
            XCTAssertGreaterThanOrEqual(f.origin.y, -0.5,
                "sublayer[\(i)] y went negative under huge offset")
            XCTAssertLessThanOrEqual(f.origin.y + f.size.height, 200.5,
                "sublayer[\(i)] top exceeded track under huge offset")
            XCTAssertTrue(f.size.height.isFinite,
                "sublayer[\(i)] height non-finite under huge offset")
        }
    }

    // MARK: - Update at zero-size indicator

    /// If the indicator's own bounds collapse to zero (e.g. inside a
    /// hidden split), updates must remain crash-free and produce finite
    /// frames.
    func test_zeroSizedIndicator_doesNotCrash() {
        let v = ScrollIndicator(frame: .zero)
        v.wantsLayer = true
        _ = v.layer
        v.update(displayOffset: 100, historySize: 1000, rows: 24)
        XCTAssertTrue(allFramesFinite(v),
            "zero-bounds indicator must not yield nan/inf frames")
    }
}
