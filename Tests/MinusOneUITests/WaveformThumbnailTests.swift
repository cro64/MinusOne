import AppKit
import XCTest
@testable import MinusOne

final class WaveformThumbnailTests: XCTestCase {
    /// Interleaved min/max pairs: loud at the edges, dead silent through the middle third.
    private func peaksWithASilentMiddle(columns: Int = 600) -> [Float] {
        var peaks: [Float] = []
        for index in 0..<columns {
            let isSilent = index >= columns / 3 && index < 2 * columns / 3
            let magnitude: Float = isSilent ? 0 : 0.9
            peaks.append(-magnitude)
            peaks.append(magnitude)
        }
        return peaks
    }

    private func thumbnail(width: CGFloat, peaks: [Float]) -> WaveformView {
        let view = WaveformView()
        view.frame = NSRect(x: 0, y: 0, width: width, height: 18)
        view.peaks = peaks
        return view
    }

    /// The core regression: at the real sidebar width, 600 source columns must collapse to the
    /// number of bars that fit, not be drawn one-per-source on top of each other.
    func testItBinsToTheNumberOfBarsThatFitTheWidth() {
        let view = thumbnail(width: 200, peaks: peaksWithASilentMiddle())
        let columns = view.renderedColumns()
        let expected = Int(200 / (TimelineMetrics.barWidth + TimelineMetrics.barGap))
        XCTAssertEqual(columns.count, expected)
        XCTAssertLessThan(columns.count, 300, "600 columns must not survive into a 200pt row")
    }

    /// If binning were wrong, the silent middle would be smeared over by its loud neighbours —
    /// which is exactly what a solid block looks like.
    func testTheSilentMiddleStaysSilent() {
        let columns = thumbnail(width: 200, peaks: peaksWithASilentMiddle()).renderedColumns()
        let middle = columns[columns.count / 2]
        XCTAssertEqual(middle.magnitude, 0, accuracy: 1e-6)
    }

    func testTheLoudEndsStayLoud() {
        let columns = thumbnail(width: 200, peaks: peaksWithASilentMiddle()).renderedColumns()
        XCTAssertEqual(columns[0].magnitude, 0.9, accuracy: 1e-3)
        XCTAssertEqual(columns[columns.count - 1].magnitude, 0.9, accuracy: 1e-3)
    }

    func testItAdaptsToTheWidestSidebar() {
        let narrow = thumbnail(width: 200, peaks: peaksWithASilentMiddle()).renderedColumns()
        let wide = thumbnail(width: 340, peaks: peaksWithASilentMiddle()).renderedColumns()
        XCTAssertGreaterThan(wide.count, narrow.count)
    }

    func testAnEmptyPeakArrayRendersNothingRatherThanCrashing() {
        XCTAssertTrue(thumbnail(width: 200, peaks: []).renderedColumns().isEmpty)
    }

    func testAZeroWidthViewRendersNothingRatherThanCrashing() {
        XCTAssertTrue(thumbnail(width: 0, peaks: peaksWithASilentMiddle()).renderedColumns().isEmpty)
    }

    /// Drawing must actually work in a bitmap context — the binning is only half the fix.
    func testItDrawsWithoutCoveringTheEntireRow() throws {
        let view = thumbnail(width: 200, peaks: peaksWithASilentMiddle())
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)

        var paintedColumns = 0
        for x in 0..<rep.pixelsWide {
            var columnHasInk = false
            for y in 0..<rep.pixelsHigh where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 {
                columnHasInk = true
                break
            }
            if columnHasInk { paintedColumns += 1 }
        }
        XCTAssertGreaterThan(paintedColumns, 0, "nothing was drawn at all")
        XCTAssertLessThan(
            Double(paintedColumns) / Double(rep.pixelsWide), 0.9,
            "every pixel column has ink — the thumbnail is still a solid smear"
        )
    }

    /// Spec §14: the view used to compute x two ways — bars by index and everything else by
    /// fraction of the width. There is one way now, and it is the one the timeline uses.
    func testItUsesTheSharedBarGeometry() {
        let columns = thumbnail(width: 300, peaks: peaksWithASilentMiddle()).renderedColumns()
        XCTAssertEqual(columns.count, TimelineMetrics.barCount(forWidth: 300))
    }
}
