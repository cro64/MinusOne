import XCTest
@testable import MinusOne

final class ViewportResizeTests: XCTestCase {
    /// Spec §7: during separation and across a window resize the viewport holds still. Widening
    /// the window shows the same seconds at more pixels per second, not a different span.
    func testResizingKeepsTheVisibleTimeRange() {
        var viewport = Viewport(clipDuration: 240, widthPoints: 680, minVisibleDuration: 1.3)
        viewport = viewport.zoomed(by: 8, around: 340)
        let startBefore = viewport.startTime
        let durationBefore = viewport.visibleDuration

        let resized = viewport.resized(toWidth: 900, minVisibleDuration: 1.7)
        XCTAssertEqual(resized.widthPoints, 900)
        XCTAssertEqual(resized.startTime, startBefore, accuracy: 1e-9)
        XCTAssertEqual(resized.visibleDuration, durationBefore, accuracy: 1e-9)
        XCTAssertGreaterThan(resized.pixelsPerSecond, viewport.pixelsPerSecond)
    }

    /// A narrower window stores fewer bars, so 1:1 with the peak data is a *longer* span — and a
    /// viewport already zoomed past the new limit must be pulled back to it.
    func testResizingRespectsTheNewZoomLimit() {
        var viewport = Viewport(clipDuration: 240, widthPoints: 900, minVisibleDuration: 0.5)
        viewport = viewport.zoomed(by: 1000, around: 450)
        XCTAssertEqual(viewport.visibleDuration, 0.5, accuracy: 1e-9)

        let resized = viewport.resized(toWidth: 400, minVisibleDuration: 2.0)
        XCTAssertEqual(resized.minVisibleDuration, 2.0, accuracy: 1e-9)
        XCTAssertEqual(resized.visibleDuration, 2.0, accuracy: 1e-9)
    }

    func testResizingAZoomedOutViewportKeepsItZoomedOut() {
        let viewport = Viewport(clipDuration: 240, widthPoints: 680)
        let resized = viewport.resized(toWidth: 420, minVisibleDuration: 2.2)
        XCTAssertEqual(resized.startTime, 0, accuracy: 1e-9)
        XCTAssertEqual(resized.visibleDuration, 240, accuracy: 1e-9)
    }

    func testScrollingToAnAbsoluteStartTime() {
        var viewport = Viewport(clipDuration: 240, widthPoints: 680, minVisibleDuration: 1)
        viewport = viewport.zoomed(by: 10, around: 340)
        let scrolled = viewport.scrolled(toStartTime: 100)
        XCTAssertEqual(scrolled.startTime, 100, accuracy: 1e-9)
        XCTAssertEqual(scrolled.visibleDuration, viewport.visibleDuration, accuracy: 1e-9)
    }

    func testScrollingClampsAtBothEnds() {
        var viewport = Viewport(clipDuration: 240, widthPoints: 680, minVisibleDuration: 1)
        viewport = viewport.zoomed(by: 10, around: 340)
        XCTAssertEqual(viewport.scrolled(toStartTime: -50).startTime, 0, accuracy: 1e-9)
        let far = viewport.scrolled(toStartTime: 10_000)
        XCTAssertEqual(far.endTime, 240, accuracy: 1e-6)
    }
}
