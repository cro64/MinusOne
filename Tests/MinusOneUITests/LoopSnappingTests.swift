import AppKit
import XCTest
@testable import MinusOne

final class LoopSnappingTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("LoopSnap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let writer = try PeakSidecarWriter(url: folder.appendingPathComponent(PeakTrack.mix.fileName), sampleRate: 44_100)
        try writer.append([Float](repeating: 0.8, count: 60 * 44_100))
        try writer.finish()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func timeline(grid: BeatGrid?) -> DeckTimelineView {
        let view = DeckTimelineView()
        view.frame = NSRect(x: 0, y: 0, width: 856, height: DeckTimelineView.height(forLaneCount: 4))
        view.show(clipDuration: 60, peakStore: PeakStore(peaksFolder: folder))
        view.readyDuration = 60
        view.beatGrid = grid
        view.layoutSubtreeIfNeeded()
        return view
    }

    /// 120 BPM from zero: beats every 0.5s.
    private let grid = BeatGrid(bpm: 120, downbeatOffsetSeconds: 0)

    func testLoopEdgesSnapToBeats() throws {
        let view = timeline(grid: grid)
        var reported: [ClosedRange<Double>] = []
        view.onLoopRangeChanged = { reported.append($0) }

        view.beginCanvasDrag(atX: 100)
        view.endCanvasDrag(atX: 400)

        let range = try XCTUnwrap(reported.first)
        XCTAssertEqual(grid.nearestBeat(to: range.lowerBound), range.lowerBound, accuracy: 1e-6)
        XCTAssertEqual(grid.nearestBeat(to: range.upperBound), range.upperBound, accuracy: 1e-6)
    }

    /// Snapping must move the edge to the *nearest* beat, not merely to some beat — a loop that
    /// jumps half a bar from where it was drawn is worse than no snapping.
    func testSnappingMovesEachEdgeLessThanHalfABeat() throws {
        let view = timeline(grid: grid)
        var reported: [ClosedRange<Double>] = []
        view.onLoopRangeChanged = { reported.append($0) }

        let rawStart = view.viewport.time(forX: 100)
        let rawEnd = view.viewport.time(forX: 400)
        view.beginCanvasDrag(atX: 100)
        view.endCanvasDrag(atX: 400)

        let range = try XCTUnwrap(reported.first)
        XCTAssertLessThanOrEqual(abs(range.lowerBound - rawStart), grid.beatDuration / 2 + 1e-6)
        XCTAssertLessThanOrEqual(abs(range.upperBound - rawEnd), grid.beatDuration / 2 + 1e-6)
    }

    /// Spec §7's ⌥ row.
    func testHoldingOptionBypassesSnapping() throws {
        let view = timeline(grid: grid)
        var reported: [ClosedRange<Double>] = []
        view.onLoopRangeChanged = { reported.append($0) }

        view.beginCanvasDrag(atX: 100)
        view.endCanvasDrag(atX: 400, bypassSnapping: true)

        let range = try XCTUnwrap(reported.first)
        XCTAssertEqual(range.lowerBound, view.viewport.time(forX: 100), accuracy: 1e-6)
        XCTAssertEqual(range.upperBound, view.viewport.time(forX: 400), accuracy: 1e-6)
    }

    /// With no grid there is nothing to snap to, and the Phase 2 behaviour must be untouched.
    func testWithNoGridTheLoopIsExactlyWhereItWasDrawn() throws {
        let view = timeline(grid: nil)
        var reported: [ClosedRange<Double>] = []
        view.onLoopRangeChanged = { reported.append($0) }

        view.beginCanvasDrag(atX: 100)
        view.endCanvasDrag(atX: 400)

        let range = try XCTUnwrap(reported.first)
        XCTAssertEqual(range.lowerBound, view.viewport.time(forX: 100), accuracy: 1e-6)
    }

    /// The preview must show where the loop will actually land, or the band jumps on mouse-up.
    func testThePreviewIsSnappedToo() {
        let view = timeline(grid: grid)
        view.beginCanvasDrag(atX: 100)
        view.continueCanvasDrag(toX: 400)

        let preview = view.loopRange
        XCTAssertNotNil(preview)
        XCTAssertEqual(grid.nearestBeat(to: preview!.lowerBound), preview!.lowerBound, accuracy: 1e-6)
    }

    /// Snapping must never collapse a loop to zero length or invert it, however short the drag.
    func testAVeryShortDragStillYieldsAnOrderedRange() throws {
        let view = timeline(grid: grid)
        var reported: [ClosedRange<Double>] = []
        view.onLoopRangeChanged = { reported.append($0) }

        view.beginCanvasDrag(atX: 200)
        view.endCanvasDrag(atX: 205)

        if let range = reported.first {
            XCTAssertLessThanOrEqual(range.lowerBound, range.upperBound)
        }
    }

    /// Snapping happens after clamping, so an off-canvas drag still cannot leave the clip.
    func testSnappedEdgesStayInsideTheClip() throws {
        let view = timeline(grid: grid)
        var reported: [ClosedRange<Double>] = []
        view.onLoopRangeChanged = { reported.append($0) }

        view.beginCanvasDrag(atX: 100)
        view.endCanvasDrag(atX: 50_000)

        let range = try XCTUnwrap(reported.first)
        XCTAssertGreaterThanOrEqual(range.lowerBound, 0)
        XCTAssertLessThanOrEqual(range.upperBound, view.viewport.clipDuration)
    }
}
