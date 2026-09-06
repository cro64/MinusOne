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

    /// Companion to the above: a real drag (a `continueDrag` call before release) in that same
    /// fully-zoomed-out state must still pan, not seek — the fix must not turn every drag into a
    /// seek, only a plain click that never actually dragged.
    func testDraggingAtTheFullyZoomedOutDefaultViewportStillPansWithoutSeeking() {
        let view = hero(clipDuration: 60, visibleRange: 0...60)
        var sought: [Double] = []
        var panned: [Double] = []
        view.onSeek = { sought.append($0) }
        view.onVisibleRangePanned = { panned.append($0) }

        let startX = view.x(forTime: 25)
        view.beginDrag(atX: startX)
        view.continueDrag(toX: view.x(forTime: 40))
        view.endDrag(atX: view.x(forTime: 40))

        XCTAssertTrue(sought.isEmpty, "a real drag at the default zoomed-out viewport should pan, not seek")
        XCTAssertFalse(panned.isEmpty)
    }
}
