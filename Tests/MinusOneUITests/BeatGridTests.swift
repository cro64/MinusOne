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
}
