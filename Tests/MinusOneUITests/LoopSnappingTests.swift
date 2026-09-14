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
    /// This drag (x=200→205, above the 3pt threshold) straddles a beat boundary — its raw span
    /// covers part of two adjacent beats — so the two edges snap to *different* beats and this
    /// path never needs the zero-length fallback below. Kept alongside
    /// `testADragEntirelyInsideOneBeatExtendsToAFullBeatInsteadOfCollapsing`, which does exercise
    /// it, because a straddling short drag takes a different path through `range(from:to:)` and
    /// both are worth pinning.
    func testAVeryShortDragThatStraddlesABeatStillYieldsAnOrderedRange() throws {
        let view = timeline(grid: grid)
        var reported: [ClosedRange<Double>] = []
        view.onLoopRangeChanged = { reported.append($0) }

        view.beginCanvasDrag(atX: 200)
        view.endCanvasDrag(atX: 205)

        // Unwrapped, not `if let`: the whole assertion passes vacuously if the drag reports nothing
        // at all, which is the most likely way this could regress.
        let range = try XCTUnwrap(reported.first, "the drag reported no loop range at all")
        XCTAssertLessThanOrEqual(range.lowerBound, range.upperBound)
    }

    /// A drag that starts and ends inside a single beat snaps both edges to the same instant
    /// before the zero-length guard runs. At this fixture's zoom (724pt canvas / 60s clip =
    /// ~12.07 px/s) one beat is ~6.03pt wide, so a 4pt drag from x=4 to x=8 lands entirely inside
    /// the beat centered at t=0.5s (that beat's nearest-beat catchment is x ∈ [3.02, 9.05)) while
    /// still clearing the 3pt drag threshold. Measured with `view.viewport.time(forX:)` and
    /// `grid.nearestBeat(to:)` directly against this fixture rather than assumed:
    /// `time(forX: 4) == 0.3315s` and `time(forX: 8) == 0.6630s` both round to the beat at 0.5s.
    /// A zero-length loop makes `PracticePlaybackEngine.tick()` re-seek every timer tick and
    /// stall playback, so the reported loop must extend to a full, non-empty beat instead of
    /// collapsing — and both edges must still land on the grid.
    func testADragEntirelyInsideOneBeatExtendsToAFullBeatInsteadOfCollapsing() throws {
        let view = timeline(grid: grid)
        var reported: [ClosedRange<Double>] = []
        view.onLoopRangeChanged = { reported.append($0) }

        // Confirm the premise against this fixture's actual viewport rather than assuming it.
        XCTAssertEqual(grid.nearestBeat(to: view.viewport.time(forX: 4)), 0.5, accuracy: 1e-6)
        XCTAssertEqual(grid.nearestBeat(to: view.viewport.time(forX: 8)), 0.5, accuracy: 1e-6)

        view.beginCanvasDrag(atX: 4)
        view.endCanvasDrag(atX: 8)

        let range = try XCTUnwrap(reported.first)
        XCTAssertLessThan(range.lowerBound, range.upperBound)
        XCTAssertEqual(range.upperBound - range.lowerBound, grid.beatDuration, accuracy: 1e-6)
        XCTAssertEqual(grid.nearestBeat(to: range.lowerBound), range.lowerBound, accuracy: 1e-6)
        XCTAssertEqual(grid.nearestBeat(to: range.upperBound), range.upperBound, accuracy: 1e-6)
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

    // MARK: - Time-based entry point
    //
    // The hero waveform draws loops in whole-track time, not in this timeline's zoomed canvas x, so
    // it resolves a loop through `snappedLoopRange(fromTime:toTime:bypassSnapping:)`. Expected values
    // below are worked by hand for 120 BPM from zero (one beat = 0.5s) on the 60s fixture clip:
    // `nearestBeat` rounds `t / 0.5` to the nearest integer.

    func testTimeBasedRangeSnapsBothEdgesToTheNearestBeat() {
        let view = timeline(grid: grid)
        // 10.2 / 0.5 = 20.4 → 20 → 10.0;  14.9 / 0.5 = 29.8 → 30 → 15.0
        XCTAssertEqual(view.snappedLoopRange(fromTime: 10.2, toTime: 14.9, bypassSnapping: false), 10.0...15.0)
    }

    func testTimeBasedRangeIsTheSameWhicheverWayItIsDrawn() {
        let view = timeline(grid: grid)
        XCTAssertEqual(view.snappedLoopRange(fromTime: 14.9, toTime: 10.2, bypassSnapping: false), 10.0...15.0)
    }

    func testTimeBasedRangeHonoursTheSnappingBypass() {
        let view = timeline(grid: grid)
        XCTAssertEqual(view.snappedLoopRange(fromTime: 10.2, toTime: 14.9, bypassSnapping: true), 10.2...14.9)
    }

    func testTimeBasedRangeWithNoGridIsExactlyWhatWasDrawn() {
        let view = timeline(grid: nil)
        XCTAssertEqual(view.snappedLoopRange(fromTime: 10.2, toTime: 14.9, bypassSnapping: false), 10.2...14.9)
    }

    /// The hero hands over raw times from a pointer that can leave the view, so this entry point has
    /// to clamp to the clip itself — there is no canvas x to clamp first, as the drag path has.
    func testTimeBasedRangeClampsToTheClipBeforeSnapping() {
        let view = timeline(grid: grid)
        XCTAssertEqual(view.snappedLoopRange(fromTime: -3, toTime: 75, bypassSnapping: false), 0.0...60.0)
    }

    /// Both edges round to 10.0; a zero-length loop would stall playback, so it extends one beat
    /// forward.
    func testTimeBasedRangeInsideOneBeatExtendsForwardByABeat() {
        let view = timeline(grid: grid)
        XCTAssertEqual(view.snappedLoopRange(fromTime: 10.1, toTime: 10.2, bypassSnapping: false), 10.0...10.5)
    }

    /// Both edges round to 60.0, the clip's end; a beat forward would leave the clip, so it extends
    /// one beat back instead.
    func testTimeBasedRangeInsideTheLastBeatExtendsBackwardByABeat() {
        let view = timeline(grid: grid)
        XCTAssertEqual(view.snappedLoopRange(fromTime: 59.9, toTime: 59.95, bypassSnapping: false), 59.5...60.0)
    }
}
