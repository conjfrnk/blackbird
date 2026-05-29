import XCTest
import Metal
import MetalKit
import QuartzCore
@testable import Blackbird

/// Decomposition microbenchmark for the per-tab / per-startup `MetalRenderer`
/// init cost. Every ⌘T new tab and the first-launch window construct a fresh
/// `MetalRenderer`, whose init does (in order): `makeDefaultLibrary`, four
/// `makeFunction`, two `makeRenderPipelineState` (cell + cursor PSOs), a
/// `GlyphAtlas` allocation (two textures zeroed via CPU memcpy), three
/// instance-buffer allocations, and `prewarmCommonGlyphs` (~223 CoreText
/// rasterisations). This bench attributes the wall-clock cost to each
/// sub-step so an optimization (e.g. a shared per-device pipeline cache) is
/// driven by real numbers, not a guess about which step dominates.
///
/// **Gated** behind `BB_RUN_STARTUP_BENCH=1` — it is a measurement tool, not
/// a pass/fail gate, and prints to stdout. CI never runs it (no env var),
/// keeping the per-test time budget intact. Run locally with:
///
///   BB_RUN_STARTUP_BENCH=1 scripts/test.sh \
///     -only-testing:BlackbirdTests/StartupLatencyBenchTests
///
/// Memory: each iteration holds at most ONE live renderer (~10–12 MB of atlas
/// textures at 13pt@2x: 64×64 slots × ~16×31 px → ~2 MB mono r8 + ~8 MB color
/// bgra8 — plus 3 instance buffers ≈ 2 MB) and releases it before the next,
/// so peak RSS stays ~12 MB regardless of iteration count. Safe per the
/// project's test-memory rule.
final class StartupLatencyBenchTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        TestHostTermination.shared.register()
    }

    /// Median is the headline (robust to a cold first sample); min shows the
    /// floor. Iterations are warm — the first call pays any one-time process
    /// cost (dyld, Metal shader-cache warm), later calls show the steady
    /// per-tab cost a user actually feels on the 2nd..Nth tab.
    private struct Stat {
        let label: String
        let medianMs: Double
        let minMs: Double
        let maxMs: Double
        let n: Int
    }

    private func measure(_ label: String, iterations: Int, _ body: () throws -> Void) rethrows -> Stat {
        var samples: [Double] = []
        samples.reserveCapacity(iterations)
        for _ in 0..<iterations {
            let t0 = CACurrentMediaTime()
            try body()
            samples.append((CACurrentMediaTime() - t0) * 1000.0)
        }
        let sorted = samples.sorted()
        let median = sorted[sorted.count / 2]
        return Stat(label: label, medianMs: median, minMs: sorted.first ?? 0,
                    maxMs: sorted.last ?? 0, n: iterations)
    }

    private func report(_ stats: [Stat]) {
        print("\n=== StartupLatencyBench (per-construction wall-clock) ===")
        for s in stats {
            let line = String(
                format: "  %-28@  median=%6.2f ms   min=%6.2f ms   max=%6.2f ms   (n=%d)",
                s.label as NSString, s.medianMs, s.minMs, s.maxMs, s.n
            )
            print(line)
        }
        print("=========================================================\n")
    }

    func test_metalRendererInit_costDecomposition() throws {
        try XCTSkipIf(
            ProcessInfo.processInfo.environment["BB_RUN_STARTUP_BENCH"] != "1",
            "startup-latency bench is opt-in; set BB_RUN_STARTUP_BENCH=1"
        )
        let device = try requireMetalDevice()
        let metrics = CellMetrics(font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        let scale: CGFloat = 2.0
        // Matches MetalRenderer.atlasCapacity (kept as a literal so the bench
        // doesn't depend on the symbol's access level).
        let capacity = 4096
        let iters = 12

        // Warm the process once so the first measured sample isn't paying a
        // one-time cost we don't want to attribute to any single step.
        _ = try XCTUnwrap(MetalRenderer(device: device, metrics: metrics, scale: scale))

        // (a) Full renderer init — the number a new tab actually pays.
        //     XCTUnwrap inside the loop so a regression that makes init
        //     return nil fails the bench loudly instead of recording a
        //     meaningless near-zero timing against a failed construction.
        let full = try measure("MetalRenderer.init (full)", iterations: iters) {
            _ = try XCTUnwrap(MetalRenderer(device: device, metrics: metrics, scale: scale))
        }

        // (b) GlyphAtlas allocation only (mono texture + zeroing memcpy; the
        //     color atlas is now lazy so this no longer pays for it).
        let atlasInit = try measure("GlyphAtlas.init (alloc+zero)", iterations: iters) {
            _ = try XCTUnwrap(GlyphAtlas(device: device, metrics: metrics, capacityGlyphs: capacity, scale: scale))
        }

        // (c) GlyphAtlas allocation + prewarm (the ~223 CoreText rasterisations).
        let atlasPrewarm = try measure("GlyphAtlas.init + prewarm", iterations: iters) {
            let a = try XCTUnwrap(GlyphAtlas(device: device, metrics: metrics, capacityGlyphs: capacity, scale: scale))
            a.prewarmCommonGlyphs()
        }

        // (d) Library load + both PSO builds in isolation — replicates the
        // exact Metal calls MetalRenderer.init makes for the cell + cursor
        // pipelines. This is the cost a shared per-device pipeline cache
        // would remove from every tab after the first.
        let pipeline = try measure("Library + 2× makeRenderPipelineState", iterations: iters) {
            guard let library = device.makeDefaultLibrary(),
                  let vtx = library.makeFunction(name: "vertex_cell"),
                  let frag = library.makeFunction(name: "fragment_cell"),
                  let cvtx = library.makeFunction(name: "vertex_cursor"),
                  let cfrag = library.makeFunction(name: "fragment_cursor")
            else {
                XCTFail("default library / shader functions unavailable in test host")
                return
            }
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = vtx
            desc.fragmentFunction = frag
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            desc.colorAttachments[0].isBlendingEnabled = true
            desc.colorAttachments[0].rgbBlendOperation = .add
            desc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            _ = try device.makeRenderPipelineState(descriptor: desc)
            let cdesc = MTLRenderPipelineDescriptor()
            cdesc.vertexFunction = cvtx
            cdesc.fragmentFunction = cfrag
            cdesc.colorAttachments[0].pixelFormat = .bgra8Unorm
            _ = try device.makeRenderPipelineState(descriptor: cdesc)
        }

        report([full, atlasInit, atlasPrewarm, pipeline])

        // Sanity: the bench ran. No threshold — this is a measurement, not a gate.
        XCTAssertGreaterThan(full.medianMs, 0, "full renderer init should take measurable time")
    }
}
