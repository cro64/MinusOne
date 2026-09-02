import AppKit
import XCTest
@testable import MinusOne

final class BeatRulerTests: XCTestCase {
    private func ruler(clipDuration: Double = 240, width: CGFloat = 680, grid: BeatGrid?) -> TimelineRulerView {
        let view = TimelineRulerView()
        view.frame = NSRect(x: 0, y: 0, width: width, height: TimelineMetrics.rulerHeight)
        view.viewport = Viewport(clipDuration: clipDuration, widthPoints: width)
        view.beatGrid = grid
        return view
    }

    /// Without a grid the ruler is exactly what Phase 2 shipped. This is the fallback spec §6
    /// requires when confidence is too low, so it must be a real code path, not an accident.
    func testWithNoGridItStillProducesTimeTicks() {
        let view = ruler(grid: nil)
        XCTAssertFalse(view.tickTimes().isEmpty)
        XCTAssertTrue(view.beatTickTimes().isEmpty)
        XCTAssertTrue(view.barLabels().isEmpty)
    }

    /// Zoomed in far enough, every beat gets a tick.
    func testBeatTicksLandOnEveryBeat() {
        let grid = BeatGrid(bpm: 120, downbeatOffsetSeconds: 0.5)
        let view = ruler(clipDuration: 60, grid: grid)
        view.viewport = view.viewport.zoomed(by: 8, around: 0)

        let ticks = view.beatTickTimes()
        XCTAssertFalse(ticks.isEmpty)
        for tick in ticks {
            XCTAssertEqual(grid.nearestBeat(to: tick), tick, accuracy: 1e-6, "tick at \(tick) is not a beat")
            XCTAssertGreaterThanOrEqual(tick, view.viewport.startTime - 1e-9)
            XCTAssertLessThanOrEqual(tick, view.viewport.endTime + 1e-9)
        }
    }

    /// Labels are bar numbers, and bar 1 is the detected downbeat.
    func testBarLabelsCountFromTheDownbeat() {
        let grid = BeatGrid(bpm: 120, downbeatOffsetSeconds: 0.5)
        let view = ruler(clipDuration: 60, grid: grid)
        view.viewport = view.viewport.zoomed(by: 4, around: 0)

        let labels = view.barLabels()
        XCTAssertFalse(labels.isEmpty)
        for label in labels {
            XCTAssertEqual(grid.position(at: label.time).beat, 1, "labelled a time that is not a downbeat")
            XCTAssertEqual(grid.position(at: label.time).bar, label.bar)
        }
    }

    /// The whole point of a stride: zoomed out, labelling every bar would print hundreds of
    /// overlapping numbers.
    func testBarLabelsThinOutWhenZoomedOut() {
        let grid = BeatGrid(bpm: 120, downbeatOffsetSeconds: 0)
        let zoomedOut = ruler(clipDuration: 600, grid: grid)
        let zoomedIn = ruler(clipDuration: 600, grid: grid)
        zoomedIn.viewport = zoomedIn.viewport.zoomed(by: 20, around: 340)

        let outLabels = zoomedOut.barLabels()
        let inLabels = zoomedIn.barLabels()
        XCTAssertGreaterThan(zoomedOut.viewport.visibleDuration, zoomedIn.viewport.visibleDuration)
        // Both must stay legible: no more labels than fit at the minimum spacing.
        for view in [zoomedOut, zoomedIn] {
            let labels = view.barLabels()
            guard labels.count > 1 else { continue }
            for index in 1..<labels.count {
                let gap = view.viewport.x(forTime: labels[index].time) - view.viewport.x(forTime: labels[index - 1].time)
                XCTAssertGreaterThanOrEqual(gap, 30, "bar labels only \(gap)pt apart")
            }
        }
        XCTAssertLessThan(outLabels.count, 200, "labelling every bar of a 10-minute clip")
        XCTAssertFalse(inLabels.isEmpty)
    }

    /// The ordinary pickup-bar configuration, and the one the 120 BPM fixtures above cannot see:
    /// a tempo whose beat duration is not exactly representable in binary, a nonzero downbeat
    /// offset, and a visible range that starts before bar 1 so the labels cross bar 0. Every
    /// labelled time must be a real downbeat, its bar number must match `position(at:)`, and the
    /// numbers must ascend by exactly the stride with no repeats. Before the fix this produced
    /// two ticks both labelled the same bar and gaps where bar lines went missing.
    func testBarLabelsStayConsecutiveAtAStrideAcrossBarZero() throws {
        let grid = BeatGrid(bpm: 126.04801829268293, downbeatOffsetSeconds: 0.7314285714285714)
        let view = ruler(clipDuration: 240, grid: grid)
        let pixelsPerBar = CGFloat(grid.barDuration) * view.viewport.pixelsPerSecond
        let stride = TimelineRulerView.barStride(pixelsPerBar: pixelsPerBar)
        XCTAssertGreaterThan(stride, 1, "fixture no longer exercises a stride > 1")
        XCTAssertLessThan(view.viewport.startTime, grid.downbeatOffsetSeconds,
                          "fixture no longer starts before bar 1")

        let labels = view.barLabels()
        XCTAssertFalse(labels.isEmpty)
        for label in labels {
            XCTAssertEqual(grid.position(at: label.time).beat, 1,
                           "labelled \(label.time), which is not a downbeat")
            XCTAssertEqual(grid.position(at: label.time).bar, label.bar)
        }
        for index in 1..<labels.count {
            XCTAssertEqual(labels[index].bar - labels[index - 1].bar, stride,
                           "bar numbers \(labels.map(\.bar)) do not ascend by the stride \(stride)")
        }
    }

    /// Musicians count phrases from 1, 5, 9 — not 2, 4, 8. `bar % stride == 0` labelled the wrong
    /// members of the sequence entirely once the stride grew past 1.
    func testStridedBarLabelsStartAtBarOneRatherThanTheStride() {
        let grid = BeatGrid(bpm: 120, downbeatOffsetSeconds: 0)
        let view = ruler(clipDuration: 600, grid: grid)
        let stride = TimelineRulerView.barStride(
            pixelsPerBar: CGFloat(grid.barDuration) * view.viewport.pixelsPerSecond
        )
        XCTAssertGreaterThan(stride, 1)

        let bars = view.barLabels().map(\.bar)
        XCTAssertFalse(bars.isEmpty)
        for bar in bars {
            XCTAssertEqual((bar - 1) % stride, 0,
                           "labelled bar \(bar), which is not 1 + a multiple of the stride \(stride)")
        }
        XCTAssertTrue(bars.contains(1), "bar 1 was never labelled at stride \(stride): \(bars)")
    }

    func testTheStrideGrowsAsBarsGetNarrower() {
        XCTAssertEqual(TimelineRulerView.barStride(pixelsPerBar: 200), 1)
        XCTAssertGreaterThan(TimelineRulerView.barStride(pixelsPerBar: 10), TimelineRulerView.barStride(pixelsPerBar: 100))
        XCTAssertGreaterThan(TimelineRulerView.barStride(pixelsPerBar: 1), TimelineRulerView.barStride(pixelsPerBar: 10))
    }

    /// Beat ticks are dropped entirely when they would be a smear — bars alone stay readable.
    func testBeatTicksDisappearWhenTheyWouldCrowd() {
        let grid = BeatGrid(bpm: 120, downbeatOffsetSeconds: 0)
        let view = ruler(clipDuration: 3600, grid: grid)
        XCTAssertTrue(view.beatTickTimes().isEmpty, "drew a beat tick per 0.5s across an hour")
    }

    func testItPaintsWithAGrid() throws {
        let view = ruler(clipDuration: 60, grid: BeatGrid(bpm: 120, downbeatOffsetSeconds: 0.5))
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let inked = (0..<rep.pixelsWide).contains { x in
            (0..<rep.pixelsHigh).contains { (rep.colorAt(x: x, y: $0)?.alphaComponent ?? 0) > 0.05 }
        }
        XCTAssertTrue(inked, "the ruler drew nothing with a grid set")
    }

    /// The marker is the affordance — without it the downbeat is draggable but invisible.
    func testTheDownbeatMarkerPaints() throws {
        let grid = BeatGrid(bpm: 120, downbeatOffsetSeconds: 2.0)
        let view = ruler(clipDuration: 20, grid: grid)
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)

        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        let markerColumn = Int(view.viewport.x(forTime: 2.0) * scale)
        let inkAtMarker = (0..<rep.pixelsHigh).contains {
            (rep.colorAt(x: markerColumn, y: $0)?.alphaComponent ?? 0) > 0.05
        }
        XCTAssertTrue(inkAtMarker, "no marker drawn at the downbeat")
    }
}
