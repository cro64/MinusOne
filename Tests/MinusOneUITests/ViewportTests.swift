import XCTest
@testable import MinusOne

/// Pure-logic cover for the timeline's time↔pixel arithmetic. Nothing here launches the app —
/// these run under `swift test --filter ViewportTests`.
final class ViewportTests: XCTestCase {
    private func viewport(duration: Double = 240, width: CGFloat = 600) -> Viewport {
        Viewport(clipDuration: duration, widthPoints: width)
    }

    func testANewViewportShowsTheWholeClip() {
        let sut = viewport()
        XCTAssertEqual(sut.startTime, 0, accuracy: 1e-9)
        XCTAssertEqual(sut.visibleDuration, 240, accuracy: 1e-9)
        XCTAssertEqual(sut.x(forTime: 240), 600, accuracy: 1e-6)
    }

    func testTimeAndXRoundTrip() {
        let sut = viewport().zoomed(by: 8, around: 300)
        for x in stride(from: CGFloat(0), through: 600, by: 60) {
            XCTAssertEqual(sut.x(forTime: sut.time(forX: x)), x, accuracy: 1e-4)
        }
    }

    /// The whole point of anchored zoom: the instant under the pointer must not move.
    func testZoomKeepsTheAnchoredInstantUnderThePointer() {
        let sut = viewport()
        let anchorX: CGFloat = 420
        let anchorTime = sut.time(forX: anchorX)
        let zoomed = sut.zoomed(by: 6, around: anchorX)
        XCTAssertEqual(zoomed.x(forTime: anchorTime), anchorX, accuracy: 1e-4)
    }

    func testZoomingInStopsAtTheMinimumVisibleDuration() {
        var sut = Viewport(clipDuration: 240, widthPoints: 600, minVisibleDuration: 1.2)
        for _ in 0..<40 { sut = sut.zoomed(by: 2, around: 300) }
        XCTAssertEqual(sut.visibleDuration, 1.2, accuracy: 1e-9)
    }

    func testZoomingOutStopsAtTheWholeClip() {
        var sut = viewport().zoomed(by: 32, around: 300)
        for _ in 0..<40 { sut = sut.zoomed(by: 0.5, around: 300) }
        XCTAssertEqual(sut.visibleDuration, 240, accuracy: 1e-9)
        XCTAssertEqual(sut.startTime, 0, accuracy: 1e-9)
    }

    func testPanningClampsAtTheStartOfTheClip() {
        let sut = viewport().zoomed(by: 4, around: 300).panned(byPoints: 100_000)
        XCTAssertEqual(sut.startTime, 0, accuracy: 1e-9)
    }

    func testPanningClampsAtTheEndOfTheClip() {
        let sut = viewport().zoomed(by: 4, around: 300).panned(byPoints: -100_000)
        XCTAssertEqual(sut.endTime, 240, accuracy: 1e-6)
    }

    func testAZeroLengthClipDoesNotProduceNaN() {
        let sut = Viewport(clipDuration: 0, widthPoints: 600)
        XCTAssertTrue(sut.pixelsPerSecond.isFinite)
        XCTAssertTrue(sut.time(forX: 300).isFinite)
    }
}
