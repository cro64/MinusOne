import AppKit
import XCTest
@testable import MinusOne

final class TimelineRulerTests: XCTestCase {
    private func ruler(clipDuration: Double, width: CGFloat = 680) -> TimelineRulerView {
        let view = TimelineRulerView()
        view.frame = NSRect(x: 0, y: 0, width: width, height: TimelineMetrics.rulerHeight)
        view.viewport = Viewport(clipDuration: clipDuration, widthPoints: width)
        return view
    }

    /// The ladder exists so labels never collide: whatever the zoom, adjacent labelled ticks stay
    /// at least 60pt apart.
    func testLabelledTicksNeverCrowd() {
        for pixelsPerSecond in stride(from: CGFloat(0.02), through: 600, by: 0.7) {
            let interval = TimelineRulerView.tickInterval(pixelsPerSecond: pixelsPerSecond)
            let spacing = CGFloat(interval) * pixelsPerSecond
            XCTAssertGreaterThanOrEqual(
                spacing, 60,
                "at \(pixelsPerSecond) px/s the \(interval)s interval puts labels \(spacing)pt apart"
            )
        }
    }

    /// Zooming in must give a finer ruler, not the same one stretched.
    func testZoomingInChoosesAFinerInterval() {
        let wide = TimelineRulerView.tickInterval(pixelsPerSecond: 3)
        let close = TimelineRulerView.tickInterval(pixelsPerSecond: 300)
        XCTAssertLessThan(close, wide)
    }

    func testTicksCoverTheVisibleRangeAndNothingElse() {
        let view = ruler(clipDuration: 240)
        let times = view.tickTimes()
        XCTAssertFalse(times.isEmpty)
        for time in times {
            XCTAssertGreaterThanOrEqual(time, view.viewport.startTime - 0.001)
            XCTAssertLessThanOrEqual(time, view.viewport.endTime + 0.001)
        }
        XCTAssertEqual(times, times.sorted())
    }

    func testTicksFollowThePannedViewport() {
        let view = ruler(clipDuration: 240)
        view.viewport = view.viewport.zoomed(by: 16, around: 340)
        let before = view.tickTimes()
        view.viewport = view.viewport.panned(byPoints: -200)
        let after = view.tickTimes()
        XCTAssertNotEqual(before, after)
        XCTAssertGreaterThan(after[0], before[0])
    }

    func testLabelsAreMinutesAndSecondsWhenTicksAreASecondApartOrMore() {
        XCTAssertEqual(TimelineRulerView.label(forTime: 125, interval: 5), "2:05")
        XCTAssertEqual(TimelineRulerView.label(forTime: 0, interval: 30), "0:00")
    }

    /// Under a second apart, m:ss would print the same string on adjacent ticks.
    func testSubSecondIntervalsGetADecimal() {
        XCTAssertEqual(TimelineRulerView.label(forTime: 125.4, interval: 0.25), "2:05.4")
        XCTAssertEqual(TimelineRulerView.label(forTime: 3.0, interval: 0.5), "0:03.0")
    }

    /// The tenths digit must be the tick's own tenth, not whatever truncating a float lands on.
    func testEveryTenthTickLabelsItsOwnTenth() {
        for step in 0...600 {
            let time = Double(step) / 10
            let expected = String(format: "%d:%02d.%d", step / 600, (step / 10) % 60, step % 10)
            XCTAssertEqual(TimelineRulerView.label(forTime: time, interval: 0.1), expected, "step \(step)")
        }
    }

    /// Rounding up past .9 has to carry into the seconds rather than printing a tenth of 10.
    func testARoundedUpTenthCarriesIntoTheSeconds() {
        XCTAssertEqual(TimelineRulerView.label(forTime: 59.97, interval: 0.1), "1:00.0")
        XCTAssertEqual(TimelineRulerView.label(forTime: 3.98, interval: 0.1), "0:04.0")
    }

    func testItDrawsWithoutCrashingOnAZeroWidthRuler() throws {
        let view = ruler(clipDuration: 240, width: 0)
        XCTAssertTrue(view.tickTimes().isEmpty)
    }

    func testItPaintsSomething() throws {
        let view = ruler(clipDuration: 240)
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        var inked = 0
        for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: rep.pixelsHigh - 2)?.alphaComponent ?? 0) > 0.05 {
            inked += 1
        }
        XCTAssertGreaterThan(inked, 0, "the ruler drew no ticks")
    }
}
