import AppKit
import XCTest
@testable import MinusOne

final class DeckTimelineGestureTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeckGesture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let writer = try PeakSidecarWriter(url: folder.appendingPathComponent(PeakTrack.mix.fileName), sampleRate: 44_100)
        try writer.append([Float](repeating: 0.8, count: 60 * 44_100))
        try writer.finish()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func timeline(width: CGFloat = 856, ready: Double = 60) -> DeckTimelineView {
        let view = DeckTimelineView()
        view.frame = NSRect(x: 0, y: 0, width: width, height: DeckTimelineView.height(forLaneCount: 4))
        view.show(clipDuration: 60, peakStore: PeakStore(peaksFolder: folder))
        view.readyDuration = ready
        view.layoutSubtreeIfNeeded()
        return view
    }

    // MARK: - Pan and zoom

    func testPanningMovesTheViewInTime() {
        let view = timeline()
        view.zoom(by: 6, aroundX: 300)
        let before = view.viewport.startTime
        // Negative dx drags the waveform left, which moves the view forward in time.
        view.pan(byPoints: -120)
        XCTAssertGreaterThan(view.viewport.startTime, before)
    }

    func testPanningStopsAtTheStartOfTheClip() {
        let view = timeline()
        view.zoom(by: 6, aroundX: 300)
        view.pan(byPoints: 100_000)
        XCTAssertEqual(view.viewport.startTime, 0, accuracy: 1e-9)
    }

    /// Spec §7: zoom is anchored so the instant under the pointer stays under the pointer.
    func testZoomIsAnchoredAtThePointer() {
        let view = timeline()
        let anchor: CGFloat = 300
        let instant = view.viewport.time(forX: anchor)
        view.zoom(by: 3, aroundX: anchor)
        XCTAssertEqual(view.viewport.time(forX: anchor), instant, accuracy: 1e-6)
    }

    func testZoomingOutStopsAtTheWholeClip() {
        let view = timeline()
        view.zoom(by: 8, aroundX: 300)
        view.zoom(by: 0.0001, aroundX: 300)
        XCTAssertEqual(view.viewport.visibleDuration, 60, accuracy: 1e-6)
        XCTAssertEqual(view.viewport.startTime, 0, accuracy: 1e-9)
    }

    func testZoomingInStopsAtTheStoredResolution() {
        let view = timeline()
        for _ in 0..<40 { view.zoom(by: 2, aroundX: 300) }
        XCTAssertEqual(view.viewport.visibleDuration, view.viewport.minVisibleDuration, accuracy: 1e-9)
    }

    // MARK: - Canvas column

    /// The header column belongs to the faders. A scroll or a click there must not move the view
    /// or seek.
    func testPointsOverTheHeaderAreNotCanvasPoints() {
        let view = timeline()
        XCTAssertNil(view.canvasX(forWindowPoint: NSPoint(x: 40, y: 100)))
        XCTAssertEqual(try XCTUnwrap(view.canvasX(forWindowPoint: NSPoint(x: TimelineMetrics.headerWidth + 25, y: 100))), 25, accuracy: 0.001)
    }

    // MARK: - Seek and loop

    func testATapSeeksToTheInstantUnderIt() {
        let view = timeline()
        var sought: [Double] = []
        view.onSeek = { sought.append($0) }

        view.beginCanvasDrag(atX: 200)
        view.endCanvasDrag(atX: 201)
        XCTAssertEqual(sought.count, 1)
        XCTAssertEqual(sought[0], view.viewport.time(forX: 201), accuracy: 1e-6)
    }

    /// Same rule the old waveform enforced: no seeking into audio separation has not produced.
    func testATapPastTheReadyEdgeDoesNotSeek() {
        let view = timeline(ready: 10)
        var sought: [Double] = []
        view.onSeek = { sought.append($0) }

        let x = view.viewport.x(forTime: 50)
        view.beginCanvasDrag(atX: x)
        view.endCanvasDrag(atX: x)
        XCTAssertTrue(sought.isEmpty)
    }

    func testADragSetsTheLoopRange() {
        let view = timeline()
        var reported: [ClosedRange<Double>] = []
        view.onLoopRangeChanged = { reported.append($0) }

        view.beginCanvasDrag(atX: 100)
        view.continueCanvasDrag(toX: 400)
        view.endCanvasDrag(atX: 400)

        XCTAssertEqual(reported.count, 1)
        let range = try! XCTUnwrap(reported.first)
        XCTAssertEqual(range.lowerBound, view.viewport.time(forX: 100), accuracy: 1e-6)
        XCTAssertEqual(range.upperBound, view.viewport.time(forX: 400), accuracy: 1e-6)
        XCTAssertEqual(view.loopRange, range)
    }

    /// Dragging right-to-left is the same loop as dragging left-to-right.
    func testABackwardsDragIsTheSameRange() {
        let view = timeline()
        view.beginCanvasDrag(atX: 400)
        view.continueCanvasDrag(toX: 100)
        view.endCanvasDrag(atX: 100)
        let range = try! XCTUnwrap(view.loopRange)
        XCTAssertLessThan(range.lowerBound, range.upperBound)
    }

    /// The band follows the pointer during the drag, before anything is committed.
    func testTheLoopBandPreviewsDuringTheDrag() {
        let view = timeline()
        var reported: [ClosedRange<Double>] = []
        view.onLoopRangeChanged = { reported.append($0) }

        view.beginCanvasDrag(atX: 100)
        view.continueCanvasDrag(toX: 250)
        XCTAssertNotNil(view.loopRange)
        XCTAssertTrue(reported.isEmpty, "the loop was committed mid-drag")
    }

    /// A tap after a loop exists must not wipe it — the preview has to be rolled back, not kept.
    func testATapLeavesAnExistingLoopAlone() {
        let view = timeline()
        view.beginCanvasDrag(atX: 100)
        view.continueCanvasDrag(toX: 400)
        view.endCanvasDrag(atX: 400)
        let committed = try! XCTUnwrap(view.loopRange)

        view.beginCanvasDrag(atX: 600)
        view.endCanvasDrag(atX: 600)
        XCTAssertEqual(view.loopRange, committed)
    }

    // MARK: - Hover

    func testHoverTracksThePointerAndClearsOnExit() {
        let view = timeline()
        view.setHover(atX: 200)
        XCTAssertEqual(view.hoverTimeForTesting, view.viewport.time(forX: 200))
        view.setHover(atX: nil)
        XCTAssertNil(view.hoverTimeForTesting)
    }

    // MARK: - Edge clamping

    /// A drag off the left edge must not commit a loop that starts before the clip.
    func testADragOffTheLeftEdgeStaysInsideTheClip() throws {
        let view = timeline()
        view.zoom(by: 4, aroundX: 300)
        var reported: [ClosedRange<Double>] = []
        view.onLoopRangeChanged = { reported.append($0) }

        view.beginCanvasDrag(atX: 200)
        view.continueCanvasDrag(toX: -500)
        view.endCanvasDrag(atX: -500)

        let range = try XCTUnwrap(reported.first)
        XCTAssertGreaterThanOrEqual(range.lowerBound, 0)
        XCTAssertLessThanOrEqual(range.upperBound, view.viewport.clipDuration)
    }

    /// And a drag off the right edge must not commit one that ends past it.
    func testADragOffTheRightEdgeStaysInsideTheClip() throws {
        let view = timeline()
        view.zoom(by: 4, aroundX: 300)
        var reported: [ClosedRange<Double>] = []
        view.onLoopRangeChanged = { reported.append($0) }

        view.beginCanvasDrag(atX: 100)
        view.endCanvasDrag(atX: 50_000)

        let range = try XCTUnwrap(reported.first)
        XCTAssertGreaterThanOrEqual(range.lowerBound, 0)
        XCTAssertLessThanOrEqual(range.upperBound, view.viewport.clipDuration)
    }

    /// `PracticePlaybackEngine.seek` happens to clamp, but this interface must not hand it a
    /// negative time in the first place.
    func testATapAtTheLeftEdgeNeverSeeksBeforeZero() {
        let view = timeline()
        var sought: [Double] = []
        view.onSeek = { sought.append($0) }

        view.beginCanvasDrag(atX: -2)
        view.endCanvasDrag(atX: -2)

        XCTAssertEqual(sought.count, 1)
        XCTAssertGreaterThanOrEqual(sought[0], 0)
    }
}
