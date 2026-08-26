import AppKit
import XCTest
@testable import MinusOne

final class DeckTimelineViewTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeckTimeline-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func writeTrack(_ track: PeakTrack, seconds: Double, magnitude: Float = 0.8) throws {
        let writer = try PeakSidecarWriter(url: folder.appendingPathComponent(track.fileName), sampleRate: 44_100)
        try writer.append([Float](repeating: magnitude, count: Int(seconds * 44_100)))
        try writer.finish()
    }

    private func timeline(width: CGFloat = 856, clipDuration: Double = 60) -> DeckTimelineView {
        let view = DeckTimelineView()
        let store = PeakStore(peaksFolder: folder)
        view.frame = NSRect(x: 0, y: 0, width: width, height: DeckTimelineView.height(forLaneCount: 4))
        view.show(clipDuration: clipDuration, peakStore: store)
        view.layoutSubtreeIfNeeded()
        return view
    }

    /// Spec §9: a clip that was never separated still gets a deck — one mix lane, not four empty
    /// stem lanes implying stems that do not exist.
    func testAClipWithNoStemsGetsAMixLane() throws {
        try writeTrack(.mix, seconds: 60)
        XCTAssertEqual(timeline().tracks, [.mix])
    }

    func testASeparatedClipGetsFourStemLanes() throws {
        try writeTrack(.mix, seconds: 60)
        for stem in SeparationStem.allCases { try writeTrack(.stem(stem), seconds: 60) }
        XCTAssertEqual(timeline().tracks, SeparationStem.allCases.map(PeakTrack.stem))
    }

    /// Risk 1 in spec §11 again, this time at the layout level: the lanes and the ruler must share
    /// one canvas origin and one canvas width, or a time drawn in the ruler lands somewhere else
    /// in the lanes.
    func testTheRulerLanesAndOverlayShareOneCanvasColumn() throws {
        try writeTrack(.mix, seconds: 60)
        for stem in SeparationStem.allCases { try writeTrack(.stem(stem), seconds: 60) }
        let view = timeline(width: 856)

        let canvases = view.canvasFramesForTesting
        XCTAssertFalse(canvases.isEmpty)
        for frame in canvases {
            XCTAssertEqual(frame.minX, TimelineMetrics.headerWidth, accuracy: 0.001)
            XCTAssertEqual(frame.width, 856 - TimelineMetrics.headerWidth, accuracy: 0.001)
        }
    }

    func testEveryChildSharesTheContainersViewport() throws {
        try writeTrack(.mix, seconds: 60)
        for stem in SeparationStem.allCases { try writeTrack(.stem(stem), seconds: 60) }
        let view = timeline()
        for viewport in view.childViewportsForTesting {
            XCTAssertEqual(viewport, view.viewport)
        }
    }

    /// Maximum zoom is 1:1 with the stored peaks and no further — spec §7. At 724pt of canvas that
    /// is 241 bars over a 172.27 column/second sidecar, ≈1.4 seconds.
    func testTheZoomLimitComesFromTheStoredColumnRate() throws {
        try writeTrack(.mix, seconds: 60)
        let view = timeline(width: 856)
        let bars = TimelineMetrics.barCount(forWidth: 856 - TimelineMetrics.headerWidth)
        let expected = Double(bars) / (44_100.0 / 256.0)
        XCTAssertEqual(view.viewport.minVisibleDuration, expected, accuracy: 0.01)
    }

    /// Spec §7: during separation the lanes grow underneath the viewport; the visible range does
    /// not move.
    func testRefreshingPeaksLeavesTheViewportAlone() throws {
        try writeTrack(.mix, seconds: 60)
        let view = timeline()
        view.zoom(by: 4, aroundX: 200)
        let before = view.viewport

        try writeTrack(.stem(.drums), seconds: 20)
        view.refreshPeaks()
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.viewport.startTime, before.startTime, accuracy: 1e-9)
        XCTAssertEqual(view.viewport.visibleDuration, before.visibleDuration, accuracy: 1e-9)
    }

    /// A stem whose sidecar writer failed is still playable — `OfflineSeparationEngine` catches
    /// that per stem — and its lane header carries the only fader, mute, solo and export it has.
    /// So one stem's peaks are enough to bring all four lanes back.
    func testAPartiallySeparatedClipStillGetsAllFourLanes() throws {
        try writeTrack(.mix, seconds: 60)
        try writeTrack(.stem(.drums), seconds: 20)
        let view = timeline()
        XCTAssertEqual(view.tracks, SeparationStem.allCases.map(PeakTrack.stem))
        XCTAssertEqual(view.canvasFramesForTesting.count, 4 + 3, "one frame per lane plus ruler, overlay and indicator")
    }

    /// …but the lane set does change, because stems now exist where none did.
    func testRefreshingPeaksPicksUpNewlySeparatedStems() throws {
        try writeTrack(.mix, seconds: 60)
        let view = timeline()
        XCTAssertEqual(view.tracks, [.mix])
        for stem in SeparationStem.allCases { try writeTrack(.stem(stem), seconds: 20) }
        view.refreshPeaks()
        XCTAssertEqual(view.tracks, SeparationStem.allCases.map(PeakTrack.stem))
    }

    /// A window resize must not move the view (spec §7's rule, applied to the other thing that
    /// changes width).
    func testResizingHoldsTheVisibleRangeStill() throws {
        try writeTrack(.mix, seconds: 60)
        let view = timeline(width: 856)
        view.zoom(by: 6, aroundX: 300)
        let before = view.viewport

        view.frame = NSRect(x: 0, y: 0, width: 1000, height: view.frame.height)
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.viewport.startTime, before.startTime, accuracy: 1e-6)
        XCTAssertEqual(view.viewport.visibleDuration, before.visibleDuration, accuracy: 1e-6)
        XCTAssertEqual(view.viewport.widthPoints, 1000 - TimelineMetrics.headerWidth, accuracy: 0.001)
    }

    /// `resized` must pull the view back off the clip's end when a narrower window widens the zoom
    /// limit past what remains. Nothing else exercises that branch of `clamped()`, and reordering
    /// its two lines would go uncaught.
    func testResizingAtTheClipEndPullsTheViewBack() throws {
        try writeTrack(.mix, seconds: 60)
        let view = timeline(width: 856)
        view.zoom(by: 12, aroundX: 700)
        let atEnd = view.viewport.scrolled(toStartTime: view.viewport.clipDuration)
        XCTAssertEqual(atEnd.endTime, 60, accuracy: 1e-6)

        let narrowed = atEnd.resized(toWidth: 200, minVisibleDuration: 30)
        XCTAssertEqual(narrowed.visibleDuration, 30, accuracy: 1e-6)
        XCTAssertEqual(narrowed.endTime, 60, accuracy: 1e-6)
        XCTAssertEqual(narrowed.startTime, 30, accuracy: 1e-6)
    }

    /// The whole point of the render cache: a playhead tick must not re-rasterise four waveforms.
    func testMovingThePlayheadDoesNotRerenderTheLanes() throws {
        try writeTrack(.mix, seconds: 60)
        for stem in SeparationStem.allCases { try writeTrack(.stem(stem), seconds: 60) }
        let view = timeline()

        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let renders = view.laneRenderCountsForTesting
        XCTAssertEqual(renders, [1, 1, 1, 1])

        for time in stride(from: 0.0, to: 2.0, by: 0.05) {
            view.setPlayheadTime(time)
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        XCTAssertEqual(view.laneRenderCountsForTesting, renders, "the playhead re-rendered the waveforms")
    }

    func testTheHeightFitsSpecEightsBudget() {
        // Ruler 22 + 4pt + (4 lanes at 72 with three 4pt gaps = 300) + 4pt + 12pt indicator = 342,
        // against spec §8's budget of 22 + 288 + 12 plus spacing.
        XCTAssertEqual(DeckTimelineView.height(forLaneCount: 4), 342, accuracy: 0.001)
        XCTAssertEqual(DeckTimelineView.height(forLaneCount: 1), 22 + 4 + 72 + 4 + 12, accuracy: 0.001)
    }
}
