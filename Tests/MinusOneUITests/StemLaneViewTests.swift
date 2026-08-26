import AppKit
import XCTest
@testable import MinusOne

final class StemLaneViewTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("StemLane-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func writeTrack(_ track: PeakTrack, seconds: Double, magnitude: Float) throws {
        let writer = try PeakSidecarWriter(url: folder.appendingPathComponent(track.fileName), sampleRate: 44_100)
        try writer.append([Float](repeating: magnitude, count: Int(seconds * 44_100)))
        try writer.finish()
    }

    private func lane(
        _ track: PeakTrack,
        store: PeakStore,
        width: CGFloat = 680,
        clipDuration: Double = 60
    ) -> StemLaneView {
        let view = StemLaneView(track: track, peakStore: store)
        view.frame = NSRect(x: 0, y: 0, width: width, height: TimelineMetrics.laneHeight)
        view.viewport = Viewport(clipDuration: clipDuration, widthPoints: width)
        return view
    }

    /// Risk 1 in spec §11, as an assertion: four sibling lanes reading one viewport must agree on
    /// the x of every column exactly, not nearly.
    func testEveryLaneAgreesOnBarPositions() throws {
        try writeTrack(.mix, seconds: 60, magnitude: 0.9)
        for stem in SeparationStem.allCases {
            try writeTrack(.stem(stem), seconds: 60, magnitude: 0.4)
        }
        let store = PeakStore(peaksFolder: folder)
        let lanes = SeparationStem.allCases.map { lane(.stem($0), store: store) }
        let reference = lanes[0].renderedBars().map(\.x)
        XCTAssertFalse(reference.isEmpty)
        for other in lanes.dropFirst() {
            XCTAssertEqual(other.renderedBars().map(\.x), reference)
        }
    }

    /// The bars must span the visible range, one per 3pt slot.
    func testItDrawsOneBarPerSlot() throws {
        try writeTrack(.mix, seconds: 60, magnitude: 0.9)
        let store = PeakStore(peaksFolder: folder)
        let bars = lane(.mix, store: store, width: 680).renderedBars()
        XCTAssertEqual(bars.count, TimelineMetrics.barCount(forWidth: 680))
        XCTAssertEqual(bars[0].x, 0, accuracy: 0.001)
        XCTAssertEqual(bars[0].time, 0, accuracy: 0.001)
        XCTAssertLessThanOrEqual(bars[bars.count - 1].x, 680)
    }

    /// Zooming is a re-bin, not a stretch: the same lane at a deeper zoom must show a later last
    /// time and the same bar count.
    func testZoomingChangesTheTimeRangeNotTheBarCount() throws {
        try writeTrack(.mix, seconds: 60, magnitude: 0.9)
        let store = PeakStore(peaksFolder: folder)
        let view = lane(.mix, store: store)
        let wide = view.renderedBars()
        view.viewport = view.viewport.zoomed(by: 8, around: 340)
        let close = view.renderedBars()
        XCTAssertEqual(close.count, wide.count)
        XCTAssertLessThan(close[close.count - 1].time - close[0].time, wide[wide.count - 1].time - wide[0].time)
    }

    /// Mix-relative normalisation, spec §5: a stem 30 dB under the mix still occupies half its
    /// lane rather than vanishing, and stays honestly quieter than a loud one.
    func testAQuietStemIsShorterThanALoudOneButNotInvisible() throws {
        try writeTrack(.mix, seconds: 10, magnitude: 1.0)
        try writeTrack(.stem(.drums), seconds: 10, magnitude: 1.0)
        try writeTrack(.stem(.bass), seconds: 10, magnitude: 0.0316) // −30 dB
        let store = PeakStore(peaksFolder: folder)

        let loud = PeakScaling.height(magnitude: 1.0, reference: store.normalizationReference)
        let quiet = PeakScaling.height(magnitude: 0.0316, reference: store.normalizationReference)
        XCTAssertEqual(loud, 1.0, accuracy: 0.01)
        XCTAssertEqual(quiet, 0.5, accuracy: 0.02)
    }

    /// The lane must actually paint, in the stem's identity hue.
    func testItPaintsInTheStemsIdentityColor() throws {
        try writeTrack(.mix, seconds: 10, magnitude: 0.9)
        try writeTrack(.stem(.vocals), seconds: 10, magnitude: 0.9)
        let store = PeakStore(peaksFolder: folder)
        let view = lane(.stem(.vocals), store: store, width: 300, clipDuration: 10)

        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)

        let expected = try XCTUnwrap(SeparationStem.vocals.identityColor.usingColorSpace(.sRGB))
        var matched = 0
        var inked = 0
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                guard let pixel = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), pixel.alphaComponent > 0.05 else { continue }
                inked += 1
                if abs(pixel.redComponent - expected.redComponent) < 0.08,
                   abs(pixel.greenComponent - expected.greenComponent) < 0.08,
                   abs(pixel.blueComponent - expected.blueComponent) < 0.08 {
                    matched += 1
                }
            }
        }
        XCTAssertGreaterThan(inked, 0, "the lane drew nothing at all")
        XCTAssertGreaterThan(Double(matched) / Double(inked), 0.8, "the lane is not drawn in the vocals hue")
    }

    /// The unseparated tail: peaks stop at 4s of a 10s clip, so the back half must read as the
    /// tertiary tail colour rather than as the front half stretched across the lane.
    func testTheUnseparatedTailIsDrawnSeparately() throws {
        try writeTrack(.mix, seconds: 10, magnitude: 0.9)
        try writeTrack(.stem(.drums), seconds: 4, magnitude: 0.9)
        let store = PeakStore(peaksFolder: folder)
        let view = lane(.stem(.drums), store: store, width: 300, clipDuration: 10)

        let bars = view.renderedBars()
        let readyBars = bars.filter { $0.time < store.availableDuration(for: .stem(.drums)) }
        XCTAssertGreaterThan(readyBars.count, 0)
        XCTAssertLessThan(readyBars.count, bars.count, "the whole lane counted as ready")
        XCTAssertEqual(bars.last?.column, .silent, "past the ready edge must read silent, not stretched")
    }

    /// The cache is what keeps a 60 fps playhead from re-rendering four waveforms. Same inputs →
    /// no re-render; a changed viewport → a re-render.
    func testItReusesItsBitmapUntilSomethingChanges() throws {
        try writeTrack(.mix, seconds: 10, magnitude: 0.9)
        let store = PeakStore(peaksFolder: folder)
        let view = lane(.mix, store: store, width: 300, clipDuration: 10)

        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        XCTAssertEqual(view.renderCount, 1)
        view.cacheDisplay(in: view.bounds, to: rep)
        XCTAssertEqual(view.renderCount, 1, "an unchanged lane re-rendered its bars")

        view.viewport = view.viewport.zoomed(by: 2, around: 150)
        view.cacheDisplay(in: view.bounds, to: rep)
        XCTAssertEqual(view.renderCount, 2, "a zoom did not invalidate the cache")
    }

    /// Appearance is in the cache key because a stored colour is this codebase's documented
    /// failure mode (DesignColors.swift:19, LiveWaveformView.swift:33).
    func testSwitchingAppearanceRerenders() throws {
        try writeTrack(.mix, seconds: 10, magnitude: 0.9)
        let store = PeakStore(peaksFolder: folder)
        let view = lane(.mix, store: store, width: 300, clipDuration: 10)
        view.appearance = NSAppearance(named: .aqua)

        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        XCTAssertEqual(view.renderCount, 1)

        view.appearance = NSAppearance(named: .darkAqua)
        view.cacheDisplay(in: view.bounds, to: rep)
        XCTAssertEqual(view.renderCount, 2, "a light/dark switch reused the old bitmap")
    }

    func testAZeroWidthLaneRendersNothingRatherThanCrashing() throws {
        try writeTrack(.mix, seconds: 10, magnitude: 0.9)
        let store = PeakStore(peaksFolder: folder)
        XCTAssertTrue(lane(.mix, store: store, width: 0, clipDuration: 10).renderedBars().isEmpty)
    }
}
