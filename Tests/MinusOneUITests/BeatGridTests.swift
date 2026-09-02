import XCTest
@testable import MinusOne

final class BeatGridTests: XCTestCase {
    /// 120 BPM with the first downbeat half a second in.
    private let grid = BeatGrid(bpm: 120, downbeatOffsetSeconds: 0.5)

    func testBeatAndBarDurations() {
        XCTAssertEqual(grid.beatDuration, 0.5, accuracy: 1e-9)
        XCTAssertEqual(grid.barDuration, 2.0, accuracy: 1e-9)
    }

    /// Bar 1 beat 1 sits exactly on the downbeat offset — that is what the offset means.
    func testTheFirstDownbeatIsBarOneBeatOne() {
        XCTAssertEqual(grid.position(at: 0.5), BeatGrid.Position(bar: 1, beat: 1))
        XCTAssertEqual(grid.time(bar: 1, beat: 1), 0.5, accuracy: 1e-9)
    }

    func testPositionsAdvanceThroughTheBar() {
        XCTAssertEqual(grid.position(at: 1.0), BeatGrid.Position(bar: 1, beat: 2))
        XCTAssertEqual(grid.position(at: 1.5), BeatGrid.Position(bar: 1, beat: 3))
        XCTAssertEqual(grid.position(at: 2.0), BeatGrid.Position(bar: 1, beat: 4))
        XCTAssertEqual(grid.position(at: 2.5), BeatGrid.Position(bar: 2, beat: 1))
    }

    /// A clip almost always starts before its first downbeat, so bar numbers must stay continuous
    /// backwards rather than clamping at 1 — otherwise the ruler's first labels all read "1".
    func testTimesBeforeTheDownbeatGetEarlierBarNumbers() {
        XCTAssertEqual(grid.position(at: -0.5), BeatGrid.Position(bar: 0, beat: 3))
        XCTAssertEqual(grid.position(at: 0.0), BeatGrid.Position(bar: 0, beat: 4))
        XCTAssertEqual(grid.position(at: 0.4999), BeatGrid.Position(bar: 0, beat: 4))
        XCTAssertEqual(grid.time(bar: 0, beat: 1), -1.5, accuracy: 1e-9)
    }

    /// Round-trip: every position must map back to the time it came from.
    func testPositionAndTimeRoundTrip() {
        for bar in -2...8 {
            for beat in 1...4 {
                let time = grid.time(bar: bar, beat: beat)
                XCTAssertEqual(grid.position(at: time), BeatGrid.Position(bar: bar, beat: beat),
                               "bar \(bar) beat \(beat) at \(time)")
            }
        }
    }

    func testBeatTimesCoverTheRequestedRangeAndNothingElse() {
        let beats = grid.beatTimes(from: 0.9, to: 2.6)
        XCTAssertEqual(beats, [1.0, 1.5, 2.0, 2.5])
    }

    func testDownbeatTimesAreEveryFourthBeat() {
        let downbeats = grid.downbeatTimes(from: 0, to: 7)
        XCTAssertEqual(downbeats, [0.5, 2.5, 4.5, 6.5])
    }

    /// What loop snapping is built on: the nearest beat, not the preceding one.
    func testNearestBeatRoundsToTheCloserSide() {
        XCTAssertEqual(grid.nearestBeat(to: 1.1), 1.0, accuracy: 1e-9)
        XCTAssertEqual(grid.nearestBeat(to: 1.4), 1.5, accuracy: 1e-9)
        XCTAssertEqual(grid.nearestBeat(to: 1.25), 1.5, accuracy: 1e-9)
        XCTAssertEqual(grid.nearestBeat(to: -0.1), 0.0, accuracy: 1e-9)
    }

    /// A nonsensical tempo must not produce infinities that poison every consumer.
    func testDegenerateTemposAreClampedRatherThanDividingByZero() {
        let zero = BeatGrid(bpm: 0, downbeatOffsetSeconds: 0)
        XCTAssertTrue(zero.beatDuration.isFinite)
        XCTAssertGreaterThan(zero.beatDuration, 0)
        XCTAssertTrue(zero.beatTimes(from: 0, to: 1).allSatisfy { $0.isFinite })
    }

    func testAnEmptyRangeYieldsNoBeats() {
        XCTAssertTrue(grid.beatTimes(from: 3, to: 3).isEmpty)
        XCTAssertTrue(grid.beatTimes(from: 5, to: 2).isEmpty)
    }

    /// A tempo the detector can actually return, and the reason every 120 BPM fixture above is
    /// blind to the defect these three pin. 126.048… BPM is autocorrelation lag 41 at the STFT's
    /// 86.1328125 frames/second and 0.7314… s is frame 63 on the same grid, so neither
    /// `beatDuration` nor the offset is exactly representable in binary and
    /// `(time(beatIndex: i) - offset) / beatDuration` lands at `i - ε`, which floors to `i - 1`.
    /// Measured before the fix: 4 of the first 40 indices round-tripped wrong (i = 1, 2, 35, 39).
    /// On screen that is two full-height ticks both labelled "1" and bar lines missing elsewhere.
    private var irrationalGrid: BeatGrid {
        BeatGrid(bpm: 126.04801829268293, downbeatOffsetSeconds: 0.7314285714285714)
    }

    func testTheBeatIndexRoundTripIsExactAtATempoThatIsNotBinaryExact() {
        let grid = irrationalGrid
        for index in -20...200 {
            let time = grid.time(beatIndex: index)
            let bar = Int((Double(index) / 4).rounded(.down)) + 1
            var beat = index % 4
            if beat < 0 { beat += 4 }
            XCTAssertEqual(grid.position(at: time), BeatGrid.Position(bar: bar, beat: beat + 1),
                           "beat index \(index) at \(time) did not round-trip")
        }
    }

    /// What `TimelineRulerView.barLabels()` depends on: every downbeat the grid reports must be
    /// classified as beat 1, and consecutive downbeats must be exactly one bar apart. Before the
    /// fix this range produced duplicate bar numbers and missing bar lines.
    func testDownbeatTimesAreOneBarApartAtANonBinaryTempo() throws {
        let grid = irrationalGrid
        let downbeats = grid.downbeatTimes(from: 0, to: 120)
        XCTAssertFalse(downbeats.isEmpty)
        for time in downbeats {
            XCTAssertEqual(grid.position(at: time).beat, 1, "downbeat at \(time) was not beat 1")
        }
        let bars = try downbeats.map { grid.position(at: $0).bar }
        let firstBar = try XCTUnwrap(bars.first)
        XCTAssertEqual(bars, Array(firstBar...(firstBar + bars.count - 1)),
                       "bar numbers are not consecutive: \(bars)")
        for index in 1..<downbeats.count {
            XCTAssertEqual(downbeats[index] - downbeats[index - 1], grid.barDuration, accuracy: 1e-9,
                           "downbeats \(index - 1) and \(index) are not one bar apart")
        }
    }

    /// The range edges carry the same rounding hazard: a `start` that *is* a beat must be included
    /// rather than rounded up past itself, and likewise an `end`.
    func testBeatTimesIncludeRangeEndsThatAreThemselvesBeats() throws {
        let grid = irrationalGrid
        let first = grid.time(beatIndex: 10)
        let last = grid.time(beatIndex: 20)
        let beats = grid.beatTimes(from: first, to: last)
        XCTAssertEqual(beats.count, 11, "dropped a beat at one of the range ends")
        XCTAssertEqual(try XCTUnwrap(beats.first), first, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(beats.last), last, accuracy: 1e-12)
    }
}
