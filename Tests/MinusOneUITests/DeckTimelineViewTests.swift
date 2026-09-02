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
        // against spec §8's budget of 22 + 288 + 12 plus spacing. The toolbar (Task 10) adds its
        // own 38pt row plus a 4pt gap on top of that 342.
        XCTAssertEqual(DeckTimelineView.height(forLaneCount: 4), 342 + TimelineMetrics.toolbarHeight + TimelineMetrics.laneSpacing, accuracy: 0.001)
        XCTAssertEqual(DeckTimelineView.height(forLaneCount: 1), 22 + 4 + 72 + 4 + 12 + TimelineMetrics.toolbarHeight + TimelineMetrics.laneSpacing, accuracy: 0.001)
    }

    /// Spec §8 budgeted 38pt for the tempo row; the container now actually reserves it.
    func testTheHeightIncludesTheToolbar() {
        let withToolbar = DeckTimelineView.height(forLaneCount: 4)
        let expected = TimelineMetrics.toolbarHeight + TimelineMetrics.laneSpacing
            + TimelineMetrics.rulerHeight + TimelineMetrics.laneSpacing
            + (4 * TimelineMetrics.laneHeight + 3 * TimelineMetrics.laneSpacing)
            + TimelineMetrics.laneSpacing + TimelineMetrics.scrollIndicatorHeight
        XCTAssertEqual(withToolbar, expected, accuracy: 0.001)
    }

    /// The toolbar shares the canvas column with the ruler and lanes — a tempo field floating over
    /// the lane headers would read as belonging to one stem.
    func testTheToolbarSharesTheCanvasColumn() throws {
        try writeTrack(.mix, seconds: 60)
        let view = timeline(width: 856)
        XCTAssertEqual(view.toolbarForTesting.frame.minX, TimelineMetrics.headerWidth, accuracy: 0.001)
        XCTAssertEqual(view.toolbarForTesting.frame.width, 856 - TimelineMetrics.headerWidth, accuracy: 0.001)
    }

    /// Editing the tempo by hand produces a grid, and the container reports it so the deck can
    /// persist it with `isBeatGridUserSet`.
    func testEditingTheTempoReportsANewGrid() throws {
        try writeTrack(.mix, seconds: 60)
        let view = timeline()
        view.beatGrid = BeatGrid(bpm: 120, downbeatOffsetSeconds: 0.5)

        var reported: [BeatGrid] = []
        view.onBeatGridEdited = { reported.append($0) }
        view.toolbarForTesting.commitBPMForTesting("96")

        let grid = try XCTUnwrap(reported.first)
        XCTAssertEqual(grid.bpm, 96, accuracy: 0.001)
        XCTAssertEqual(grid.downbeatOffsetSeconds, 0.5, accuracy: 0.001, "editing the tempo moved the downbeat")
    }

    /// Dragging the marker moves the downbeat and keeps the tempo.
    func testDraggingTheDownbeatMarkerMovesOnlyThePhase() throws {
        try writeTrack(.mix, seconds: 60)
        let view = timeline()
        view.beatGrid = BeatGrid(bpm: 120, downbeatOffsetSeconds: 0.5)
        view.layoutSubtreeIfNeeded()

        var reported: [BeatGrid] = []
        view.onBeatGridEdited = { reported.append($0) }

        let markerX = view.viewport.x(forTime: 0.5)
        XCTAssertTrue(view.beginDownbeatDrag(atX: markerX), "the marker was not grabbable at its own x")
        view.continueDownbeatDrag(toX: markerX + 40)
        view.endDownbeatDrag()

        let grid = try XCTUnwrap(reported.last)
        XCTAssertEqual(grid.bpm, 120, accuracy: 0.001, "dragging the downbeat changed the tempo")
        XCTAssertGreaterThan(grid.downbeatOffsetSeconds, 0.5)
    }

    /// A click on the marker that never moves is not an edit. `endDownbeatDrag` used to fire
    /// `onBeatGridEdited` unconditionally once the grab succeeded, and the deck answers that by
    /// setting `isBeatGridUserSet = true` — which permanently blocks re-detection for the clip. A
    /// stray double-click on the marker latched it forever.
    func testAClickOnTheMarkerThatDoesNotMoveItReportsNoEdit() throws {
        try writeTrack(.mix, seconds: 60)
        let view = timeline()
        let original = BeatGrid(bpm: 120, downbeatOffsetSeconds: 0.5)
        view.beatGrid = original
        view.layoutSubtreeIfNeeded()

        var reported: [BeatGrid] = []
        view.onBeatGridEdited = { reported.append($0) }

        let markerX = view.viewport.x(forTime: 0.5)
        XCTAssertTrue(view.beginDownbeatDrag(atX: markerX))
        view.endDownbeatDrag()

        XCTAssertTrue(reported.isEmpty, "a zero-movement click reported an edit: \(reported)")
        XCTAssertEqual(view.beatGrid, original)
    }

    /// And a drag that does move it still reports, so the guard above cannot be satisfied by
    /// simply never reporting.
    func testAMovedMarkerStillReportsAnEditAfterTheZeroMovementGuard() throws {
        try writeTrack(.mix, seconds: 60)
        let view = timeline()
        view.beatGrid = BeatGrid(bpm: 120, downbeatOffsetSeconds: 0.5)
        view.layoutSubtreeIfNeeded()

        var reported: [BeatGrid] = []
        view.onBeatGridEdited = { reported.append($0) }

        let markerX = view.viewport.x(forTime: 0.5)
        XCTAssertTrue(view.beginDownbeatDrag(atX: markerX))
        view.continueDownbeatDrag(toX: markerX + 40)
        view.endDownbeatDrag()
        XCTAssertEqual(reported.count, 1)
    }

    /// The field must show the tempo the grid is actually using. `BeatGrid.init` clamps to
    /// 1...400, so a raw tap result outside that diverged: the grid, ruler and persisted clip used
    /// 400 while the field read the raw number — and because `setBPM` also records it as the last
    /// accepted value, a later Enter on the field was rejected (the toolbar accepts 20...400) and
    /// restored the wrong number, making the divergence sticky. Two taps in quick succession, which
    /// a stray double-click produces, reach this.
    func testTappingFasterThanTheGridAllowsLeavesTheFieldAgreeingWithTheGrid() throws {
        try writeTrack(.mix, seconds: 60)
        let view = timeline()
        var reported: [BeatGrid] = []
        view.onBeatGridEdited = { reported.append($0) }

        // Back-to-back, so the implied tempo is far above the grid's 400 BPM ceiling.
        view.toolbarForTesting.tapForTesting()
        view.toolbarForTesting.tapForTesting()

        let grid = try XCTUnwrap(reported.last)
        XCTAssertEqual(grid.bpm, 400, accuracy: 0.001, "fixture no longer exceeds the grid's clamp")
        XCTAssertEqual(view.toolbarForTesting.displayedBPMForTesting, "400",
                       "the field shows a tempo the grid is not using")
    }

    /// A grab far from the marker is not a downbeat drag — it must fall through to the loop gesture.
    func testAGrabAwayFromTheMarkerIsNotADownbeatDrag() throws {
        try writeTrack(.mix, seconds: 60)
        let view = timeline()
        view.beatGrid = BeatGrid(bpm: 120, downbeatOffsetSeconds: 0.5)
        view.layoutSubtreeIfNeeded()
        XCTAssertFalse(view.beginDownbeatDrag(atX: view.viewport.x(forTime: 0.5) + 200))
    }

    func testWithNoGridThereIsNoDownbeatToDrag() throws {
        try writeTrack(.mix, seconds: 60)
        let view = timeline()
        view.beatGrid = nil
        XCTAssertFalse(view.beginDownbeatDrag(atX: 100))
    }
}
