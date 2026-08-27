import XCTest
@testable import MinusOne

final class TapTempoTests: XCTestCase {
    func testOneTapCannotYieldATempo() {
        var tap = TapTempo()
        XCTAssertNil(tap.tap(at: 0))
        XCTAssertEqual(tap.tapCount, 1)
    }

    func testTwoTapsGiveTheInterval() throws {
        var tap = TapTempo()
        _ = tap.tap(at: 0)
        let bpm = try XCTUnwrap(tap.tap(at: 0.5))
        XCTAssertEqual(bpm, 120, accuracy: 0.001)
    }

    /// The median is what makes this usable by a human: one clumsy tap in eight must not drag the
    /// answer the way a mean would.
    func testOneBadTapDoesNotDragTheAnswer() throws {
        var tap = TapTempo()
        var time = 0.0
        for index in 0..<6 {
            _ = tap.tap(at: time)
            // A single wild interval in the middle.
            time += index == 3 ? 1.4 : 0.5
        }
        let bpm = try XCTUnwrap(tap.tap(at: time))
        XCTAssertEqual(bpm, 120, accuracy: 6, "a single bad tap moved the tempo to \(bpm)")
    }

    /// Stopping and starting again must begin a new measurement, not average across the pause.
    func testAPauseStartsAFreshMeasurement() throws {
        var tap = TapTempo()
        _ = tap.tap(at: 0)
        _ = tap.tap(at: 0.5)
        XCTAssertEqual(tap.tapCount, 2)

        XCTAssertNil(tap.tap(at: 10), "a tap after a long pause should restart, not extend")
        XCTAssertEqual(tap.tapCount, 1)

        let bpm = try XCTUnwrap(tap.tap(at: 10.4))
        XCTAssertEqual(bpm, 150, accuracy: 0.001)
    }

    /// Only the recent taps count, so a drifting tempo follows the hand rather than its history.
    ///
    /// Asserted through the tempo rather than through `tapCount`: a count alone cannot tell which
    /// taps survived the trim, so it would pass just as happily if the *oldest* taps were the ones
    /// kept — the exact inversion of what this test is named for.
    func testItKeepsOnlyTheRecentTaps() throws {
        var tap = TapTempo(maximumTaps: 4)
        // Six taps at 120 BPM...
        var time = 0.0
        for _ in 0..<6 {
            _ = tap.tap(at: time)
            time += 0.5
        }
        // ...then four at 240, which is all the window should be able to see by the end.
        time = 2.75
        var bpm: Double?
        for _ in 0..<4 {
            bpm = tap.tap(at: time)
            time += 0.25
        }
        XCTAssertEqual(try XCTUnwrap(bpm), 240, accuracy: 0.001,
                       "the tempo still reflects the older, slower taps")
        XCTAssertLessThanOrEqual(tap.tapCount, 4)
    }

    func testResetClearsEverything() {
        var tap = TapTempo()
        _ = tap.tap(at: 0)
        _ = tap.tap(at: 0.5)
        tap.reset()
        XCTAssertEqual(tap.tapCount, 0)
        XCTAssertNil(tap.tap(at: 1.0))
    }

    /// Two taps at the same instant would divide by zero.
    func testSimultaneousTapsAreIgnoredRatherThanDividingByZero() {
        var tap = TapTempo()
        _ = tap.tap(at: 5)
        let bpm = tap.tap(at: 5)
        if let bpm { XCTAssertTrue(bpm.isFinite) }
    }
}
