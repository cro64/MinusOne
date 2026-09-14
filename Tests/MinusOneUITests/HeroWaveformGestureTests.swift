// Tests/MinusOneUITests/HeroWaveformGestureTests.swift
import AppKit
import XCTest
@testable import MinusOne

final class HeroWaveformGestureTests: XCTestCase {
    private func hero(width: CGFloat = 900, clipDuration: Double = 60, visibleRange: ClosedRange<Double> = 20...40) -> HeroWaveformView {
        let view = HeroWaveformView(frame: NSRect(x: 0, y: 0, width: width, height: 64))
        view.show(clipDuration: clipDuration, peakStore: PeakStore(peaksFolder: FileManager.default.temporaryDirectory))
        view.visibleRange = visibleRange
        return view
    }

    func testClickingInsideTheBoxPansWithoutSeeking() {
        let view = hero()
        var sought: [Double] = []
        var panned: [Double] = []
        view.onSeek = { sought.append($0) }
        view.onVisibleRangePanned = { panned.append($0) }

        let boxRect = view.visibleRangeRect()!
        let insideX = boxRect.midX
        view.beginDrag(atX: insideX)
        view.continueDrag(toX: insideX + 30)
        view.endDrag(atX: insideX + 30)

        XCTAssertTrue(sought.isEmpty, "a drag inside the box seeked instead of panning")
        XCTAssertFalse(panned.isEmpty)
    }

    func testDraggingInsideTheBoxPreservesItsWidth() {
        let view = hero()
        var panned: [Double] = []
        view.onVisibleRangePanned = { panned.append($0) }

        let boxRect = view.visibleRangeRect()!
        view.beginDrag(atX: boxRect.midX)
        view.continueDrag(toX: boxRect.midX + 60)
        view.endDrag(atX: boxRect.midX + 60)

        let originalDuration = 40.0 - 20.0
        let newStart = try! XCTUnwrap(panned.last)
        // The width is the caller's (DeckTimelineView's) to preserve — this view only ever reports
        // a new start time — but the reported start must still leave room for that width inside the
        // clip.
        XCTAssertLessThanOrEqual(newStart + originalDuration, 60.0 + 1e-6)
    }

    func testClickingOutsideTheBoxSeeksAndRecentersIt() {
        let view = hero()
        var sought: [Double] = []
        var panned: [Double] = []
        view.onSeek = { sought.append($0) }
        view.onVisibleRangePanned = { panned.append($0) }

        let outsideX = view.x(forTime: 50) // visibleRange is 20...40, so 50 is outside
        view.beginDrag(atX: outsideX)
        view.endDrag(atX: outsideX)

        XCTAssertEqual(sought.count, 1)
        XCTAssertEqual(sought[0], view.time(forX: outsideX), accuracy: 0.5)
        XCTAssertFalse(panned.isEmpty, "seeking outside the box should also recenter it")
    }

    func testPanningClampsAtTheStartOfTheClip() {
        let view = hero()
        var panned: [Double] = []
        view.onVisibleRangePanned = { panned.append($0) }

        let boxRect = view.visibleRangeRect()!
        view.beginDrag(atX: boxRect.midX)
        view.continueDrag(toX: -1000)
        view.endDrag(atX: -1000)

        XCTAssertEqual(try! XCTUnwrap(panned.last), 0, accuracy: 1e-6)
    }

    func testPanningClampsAtTheEndOfTheClip() {
        let view = hero()
        var panned: [Double] = []
        view.onVisibleRangePanned = { panned.append($0) }

        let boxRect = view.visibleRangeRect()!
        view.beginDrag(atX: boxRect.midX)
        view.continueDrag(toX: 100_000)
        view.endDrag(atX: 100_000)

        let duration = 40.0 - 20.0
        XCTAssertEqual(try! XCTUnwrap(panned.last), 60.0 - duration, accuracy: 1e-6)
    }

    /// Reproduces the bug from the final review: at the deck's default (fully zoomed out) viewport,
    /// `visibleRange` spans the entire clip, so `visibleRangeRect()` covers the whole band and every
    /// click lands inside it, taking the `.panningVisibleRange` branch instead of `.seeking`. A plain
    /// click (no drag in between) must still seek exactly once.
    func testClickingAnywhereAtTheFullyZoomedOutDefaultViewportStillSeeks() {
        let view = hero(clipDuration: 60, visibleRange: 0...60)
        var sought: [Double] = []
        view.onSeek = { sought.append($0) }

        let clickX = view.x(forTime: 25)
        view.beginDrag(atX: clickX)
        view.endDrag(atX: clickX)

        XCTAssertEqual(sought.count, 1, "a plain click at the default zoomed-out viewport should seek exactly once")
        XCTAssertEqual(try! XCTUnwrap(sought.first), view.time(forX: clickX), accuracy: 0.5)
    }

    /// Companion to the above. At the default viewport the visible-range box spans the whole band
    /// but is not drawn, so there is nothing visible to pan: a real drag there draws a loop, the way
    /// the single deck waveform did before the timeline existed. This used to assert a no-op pan.
    func testDraggingAtTheFullyZoomedOutDefaultViewportDrawsALoop() {
        let view = hero(clipDuration: 60, visibleRange: 0...60)
        var sought: [Double] = []
        var panned: [Double] = []
        var looped: [ClosedRange<Double>] = []
        view.onSeek = { sought.append($0) }
        view.onVisibleRangePanned = { panned.append($0) }
        view.onLoopRangeChanged = { looped.append($0) }

        view.beginDrag(atX: 375) // 25s at 15pt/s
        view.continueDrag(toX: 600) // 40s
        view.endDrag(atX: 600)

        XCTAssertEqual(looped.count, 1)
        XCTAssertEqual(looped[0].lowerBound, 25, accuracy: 1e-6)
        XCTAssertEqual(looped[0].upperBound, 40, accuracy: 1e-6)
        XCTAssertTrue(sought.isEmpty, "a loop drag seeked")
        XCTAssertTrue(panned.isEmpty, "a loop drag panned the zoom box")
    }

    // MARK: - Loop
    //
    // Fixture: 900pt wide, 60s clip, visible range 20...40 — so 15pt per second and the box spans
    // x 300...600. Times below are worked from that ratio by hand.

    func testDraggingOutsideTheBoxDrawsALoopWithoutSeekingOrPanning() {
        let view = hero()
        var sought: [Double] = []
        var panned: [Double] = []
        var looped: [ClosedRange<Double>] = []
        view.onSeek = { sought.append($0) }
        view.onVisibleRangePanned = { panned.append($0) }
        view.onLoopRangeChanged = { looped.append($0) }

        view.beginDrag(atX: 675) // 45s
        view.continueDrag(toX: 825) // 55s
        view.endDrag(atX: 825)

        XCTAssertEqual(looped.count, 1)
        XCTAssertEqual(looped[0].lowerBound, 45, accuracy: 1e-6)
        XCTAssertEqual(looped[0].upperBound, 55, accuracy: 1e-6)
        XCTAssertEqual(view.loopRange, looped[0])
        XCTAssertTrue(sought.isEmpty, "the loop drag seeked on mouse-down")
        XCTAssertTrue(panned.isEmpty, "the loop drag recentered the zoom box")
    }

    func testTheLoopBandPreviewsDuringTheDragWithoutCommitting() {
        let view = hero()
        var looped: [ClosedRange<Double>] = []
        view.onLoopRangeChanged = { looped.append($0) }

        view.beginDrag(atX: 675)
        view.continueDrag(toX: 825)

        let preview = try! XCTUnwrap(view.loopRange, "no band while dragging")
        XCTAssertEqual(preview.lowerBound, 45, accuracy: 1e-6)
        XCTAssertEqual(preview.upperBound, 55, accuracy: 1e-6)
        XCTAssertTrue(looped.isEmpty, "the loop was committed mid-drag")
    }

    /// A click outside the box after a loop exists must seek and must not wipe the loop — the
    /// preview state has to roll back rather than be kept or cleared.
    func testAClickSeeksAndLeavesAnExistingLoopAlone() {
        let view = hero()
        var sought: [Double] = []
        var looped: [ClosedRange<Double>] = []
        view.onSeek = { sought.append($0) }
        view.onLoopRangeChanged = { looped.append($0) }

        view.beginDrag(atX: 675)
        view.continueDrag(toX: 825)
        view.endDrag(atX: 825)

        view.beginDrag(atX: 150) // 10s, outside the box
        view.endDrag(atX: 150)

        XCTAssertEqual(looped.count, 1, "the click committed another loop")
        XCTAssertEqual(view.loopRange?.lowerBound ?? -1, 45, accuracy: 1e-6)
        XCTAssertEqual(view.loopRange?.upperBound ?? -1, 55, accuracy: 1e-6)
        XCTAssertEqual(sought.count, 1)
        XCTAssertEqual(sought[0], 10, accuracy: 1e-6)
    }

    /// A drag that goes past the threshold and comes back to where it started is a click, decided at
    /// release. The band it previewed on the way must roll back to the loop that was there before,
    /// not stay as a stray preview or vanish.
    func testADragThatReturnsToItsStartRestoresThePreviousLoop() {
        let view = hero()
        var looped: [ClosedRange<Double>] = []
        view.onLoopRangeChanged = { looped.append($0) }

        view.beginDrag(atX: 675)
        view.continueDrag(toX: 825)
        view.endDrag(atX: 825) // commits 45...55

        view.beginDrag(atX: 150) // 10s
        view.continueDrag(toX: 240) // previews 10...16
        view.continueDrag(toX: 151)
        view.endDrag(atX: 151) // back within 3pt of the start

        XCTAssertEqual(looped.count, 1, "the round trip committed a loop")
        XCTAssertEqual(view.loopRange?.lowerBound ?? -1, 45, accuracy: 1e-6, "the preview was kept instead of rolled back")
        XCTAssertEqual(view.loopRange?.upperBound ?? -1, 55, accuracy: 1e-6)
    }

    /// Under the same 3pt threshold as `DeckTimelineView`: pointer jitter during a click is a click.
    func testAMovementUnderThreePointsIsAClickNotALoop() {
        let view = hero()
        var sought: [Double] = []
        var looped: [ClosedRange<Double>] = []
        view.onSeek = { sought.append($0) }
        view.onLoopRangeChanged = { looped.append($0) }

        view.beginDrag(atX: 675)
        view.continueDrag(toX: 677)
        view.endDrag(atX: 677)

        XCTAssertTrue(looped.isEmpty, "a 2pt wobble drew a loop")
        XCTAssertNil(view.loopRange)
        XCTAssertEqual(sought.count, 1)
    }

    /// The deck supplies snapping, because the beat grid lives on the timeline. The resolver must see
    /// clip **times**, not the hero's pixels — the hero's points-per-second ratio differs from the
    /// timeline's — and both the preview and the committed loop must come from it, or the band jumps
    /// on release.
    func testTheResolverReceivesTimesAndShapesBothPreviewAndCommit() {
        let view = hero()
        var calls: [(Double, Double, Bool)] = []
        view.loopRangeResolver = { from, to, bypass in
            calls.append((from, to, bypass))
            return 50...52
        }
        var looped: [ClosedRange<Double>] = []
        view.onLoopRangeChanged = { looped.append($0) }

        view.beginDrag(atX: 675)
        view.continueDrag(toX: 825)
        XCTAssertEqual(view.loopRange, 50...52, "the preview did not go through the resolver")
        view.endDrag(atX: 825)

        XCTAssertEqual(looped, [50...52])
        let last = try! XCTUnwrap(calls.last)
        XCTAssertEqual(last.0, 45, accuracy: 1e-6, "the resolver was handed pixels, not a time")
        XCTAssertEqual(last.1, 55, accuracy: 1e-6)
        XCTAssertFalse(last.2)
    }

    func testTheSnappingBypassReachesTheResolver() {
        let view = hero()
        var bypassFlags: [Bool] = []
        view.loopRangeResolver = { from, to, bypass in
            bypassFlags.append(bypass)
            return min(from, to)...max(from, to)
        }

        view.beginDrag(atX: 675)
        view.continueDrag(toX: 825, bypassSnapping: true)
        view.endDrag(atX: 825, bypassSnapping: true)

        XCTAssertFalse(bypassFlags.isEmpty)
        XCTAssertTrue(bypassFlags.allSatisfy { $0 }, "⌥ was dropped before reaching the resolver")
    }

    /// `mouseDragged` keeps arriving after the pointer leaves the view, and `time(forX:)` extrapolates
    /// past both ends. `PracticePlaybackEngine.setLoopRange` stores whatever it is given.
    func testALoopDraggedPastTheViewsEdgeStaysInsideTheClip() {
        let view = hero()
        var looped: [ClosedRange<Double>] = []
        view.onLoopRangeChanged = { looped.append($0) }

        view.beginDrag(atX: 675)
        view.continueDrag(toX: 5_000)
        view.endDrag(atX: 5_000)

        XCTAssertEqual(looped.count, 1)
        XCTAssertEqual(looped[0].lowerBound, 45, accuracy: 1e-6)
        XCTAssertEqual(looped[0].upperBound, 60, accuracy: 1e-6)
    }

    /// A loop belongs to the clip it was drawn on; `DeckTimelineView.show` clears its own band the
    /// same way.
    func testShowingANewClipClearsTheLoopBand() {
        let view = hero()
        view.loopRange = 10...20
        view.show(clipDuration: 30, peakStore: PeakStore(peaksFolder: FileManager.default.temporaryDirectory))
        XCTAssertNil(view.loopRange)
    }

    // MARK: - Zoom

    /// Scroll/pinch on the hero should zoom the same timeline the box tracks — reported as a factor
    /// plus the TIME under the pointer, not a pixel x, since the hero's whole-track coordinate space
    /// and the zoomed timeline's canvas use different points-per-second ratios.
    func testZoomGestureFiresOnZoomWithTheTimeUnderThePointer() {
        let view = hero()
        var calls: [(factor: Double, time: Double)] = []
        view.onZoom = { calls.append(($0, $1)) }

        view.zoomGesture(byFactor: 2, atX: 450)

        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].factor, 2, accuracy: 1e-9)
        XCTAssertEqual(calls[0].time, view.time(forX: 450), accuracy: 1e-6)
    }

    func testZoomGestureWithNoHandlerDoesNotCrash() {
        hero().zoomGesture(byFactor: 1.5, atX: 100)
    }
}
