import AppKit
import XCTest
@testable import MinusOne

final class TimelineScrollIndicatorTests: XCTestCase {
    private func indicator(width: CGFloat = 680, clipDuration: Double = 240) -> TimelineScrollIndicatorView {
        let view = TimelineScrollIndicatorView()
        view.frame = NSRect(x: 0, y: 0, width: width, height: TimelineMetrics.scrollIndicatorHeight)
        view.viewport = Viewport(clipDuration: clipDuration, widthPoints: width, minVisibleDuration: 1)
        return view
    }

    /// Nothing is off-screen at full zoom-out, so a thumb spanning the whole track would be noise.
    func testThereIsNoThumbWhenTheWholeClipIsVisible() {
        XCTAssertNil(indicator().thumbRect())
    }

    func testTheThumbShowsTheVisibleShareOfTheClip() throws {
        let view = indicator()
        view.viewport = view.viewport.zoomed(by: 4, around: 340)
        let rect = try XCTUnwrap(view.thumbRect())
        XCTAssertEqual(rect.width / view.bounds.width, 0.25, accuracy: 0.02)
    }

    func testTheThumbFollowsThePan() throws {
        let view = indicator()
        view.viewport = view.viewport.zoomed(by: 8, around: 340)
        let before = try XCTUnwrap(view.thumbRect()).minX
        view.viewport = view.viewport.scrolled(toStartTime: 200)
        let after = try XCTUnwrap(view.thumbRect()).minX
        XCTAssertGreaterThan(after, before)
    }

    /// A deep zoom on a long clip would otherwise produce a sub-pixel thumb nobody can grab.
    func testTheThumbNeverGetsTooSmallToGrab() throws {
        let view = indicator(clipDuration: 600)
        view.viewport = view.viewport.zoomed(by: 1000, around: 340)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(view.thumbRect()).width, 24)
    }

    func testDraggingTheThumbReportsAStartTime() throws {
        let view = indicator()
        view.viewport = view.viewport.zoomed(by: 4, around: 0)
        var reported: [Double] = []
        view.onScrubToStartTime = { reported.append($0) }

        let thumb = try XCTUnwrap(view.thumbRect())
        view.beginScrub(atX: thumb.midX)
        view.continueScrub(toX: thumb.midX + 100)
        XCTAssertEqual(reported.count, 1)
        XCTAssertGreaterThan(try XCTUnwrap(reported.first), view.viewport.startTime)
    }

    /// Grabbing the thumb anywhere but its centre must not teleport it under the pointer.
    func testDraggingKeepsTheGrabOffset() throws {
        let view = indicator()
        view.viewport = view.viewport.zoomed(by: 4, around: 0)
        var reported: [Double] = []
        view.onScrubToStartTime = { reported.append($0) }

        let thumb = try XCTUnwrap(view.thumbRect())
        view.beginScrub(atX: thumb.minX + 2)
        view.continueScrub(toX: thumb.minX + 2)
        XCTAssertEqual(try XCTUnwrap(reported.first), view.viewport.startTime, accuracy: 0.001)
    }

    /// The thumb has to be visible *against* the track, which is why a plain "is there ink?"
    /// threshold cannot express this: the track legitimately spans the full width. Measured on an
    /// offscreen rep — track alpha 0.40, thumb over track 0.76 — so 0.5 separates them.
    func testItPaintsTheThumbDistinctlyFromTheTrack() throws {
        let view = indicator(width: 300)
        view.viewport = view.viewport.zoomed(by: 4, around: 0)
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)

        func columnsAbove(_ alpha: CGFloat) -> Int {
            (0..<rep.pixelsWide).filter { x in
                (0..<rep.pixelsHigh).contains { (rep.colorAt(x: x, y: $0)?.alphaComponent ?? 0) > alpha }
            }.count
        }

        XCTAssertEqual(columnsAbove(0.2), rep.pixelsWide, "the track should span the full width")
        let thumbColumns = columnsAbove(0.5)
        XCTAssertGreaterThan(thumbColumns, 0, "the thumb did not paint")
        XCTAssertLessThan(thumbColumns, rep.pixelsWide, "the thumb covers the whole track")
    }
}
