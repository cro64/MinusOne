import AVFoundation
import XCTest
@testable import MinusOne

/// `PracticePlaybackEngine.filePosition` is the only place a wrapped loop iteration becomes a
/// file position — the loop-playback equivalent of `BeatGrid` being the only place a time becomes
/// a musical position. Pure and parameterized rather than reading instance state, specifically so
/// this can be tested without a running `AVAudioEngine`: a real one crashes outright in this test
/// environment (no audio device — see this plan's Global Constraints).
final class PracticePlaybackEngineLoopMathTests: XCTestCase {
    private let sampleRate = 44_100.0

    func testNoLoopMapsElapsedTimeStraightThrough() {
        let position = PracticePlaybackEngine.filePosition(
            elapsedSampleTime: 5_000, segmentStartFrame: 1_000,
            loopEnabled: false, range: nil, sampleRate: sampleRate
        )
        XCTAssertEqual(position, 6_000)
    }

    func testLoopEnabledWithNoRangeYetBehavesLikeNoLoop() {
        let position = PracticePlaybackEngine.filePosition(
            elapsedSampleTime: 5_000, segmentStartFrame: 1_000,
            loopEnabled: true, range: nil, sampleRate: sampleRate
        )
        XCTAssertEqual(position, 6_000)
    }

    func testStillInTheLeadInBeforeReachingTheLoopEnd() {
        // range 1.0...3.0s => loopStartFrame 44_100, loopEndFrame 132_300, leadInLength 132_300.
        let position = PracticePlaybackEngine.filePosition(
            elapsedSampleTime: 44_100, segmentStartFrame: 0,
            loopEnabled: true, range: 1.0...3.0, sampleRate: sampleRate
        )
        XCTAssertEqual(position, 44_100, "still inside the lead-in, must not have wrapped yet")
    }

    func testWrapsExactlyAtTheLoopBoundary() {
        let position = PracticePlaybackEngine.filePosition(
            elapsedSampleTime: 132_300, segmentStartFrame: 0,
            loopEnabled: true, range: 1.0...3.0, sampleRate: sampleRate
        )
        XCTAssertEqual(position, 44_100, "the instant the lead-in ends, position must be exactly loopStartFrame")
    }

    func testPartwayIntoTheFirstLoopIteration() {
        let position = PracticePlaybackEngine.filePosition(
            elapsedSampleTime: 132_300 + 20_000, segmentStartFrame: 0,
            loopEnabled: true, range: 1.0...3.0, sampleRate: sampleRate
        )
        XCTAssertEqual(position, 44_100 + 20_000)
    }

    func testWrapsCorrectlyAcrossMultipleCompleteIterations() {
        // loopLength = 132_300 - 44_100 = 88_200. Land 5_000 frames into the 3rd loop body.
        let elapsed = AVAudioFramePosition(132_300) + 2 * 88_200 + 5_000
        let position = PracticePlaybackEngine.filePosition(
            elapsedSampleTime: elapsed, segmentStartFrame: 0,
            loopEnabled: true, range: 1.0...3.0, sampleRate: sampleRate
        )
        XCTAssertEqual(position, 44_100 + 5_000, "must collapse to the same offset regardless of how many iterations elapsed")
    }

    func testSegmentStartingExactlyAtTheLoopStartWrapsOneLoopLengthLater() {
        // Playback resumed already at the loop's own start (the common case: `seek` jumped there).
        let position = PracticePlaybackEngine.filePosition(
            elapsedSampleTime: 88_200, segmentStartFrame: 44_100,
            loopEnabled: true, range: 1.0...3.0, sampleRate: sampleRate
        )
        XCTAssertEqual(position, 44_100, "one full loop length after starting at loopStart, must be back at loopStart")
    }

    func testLoopDisabledWithAStaleRangeStillSetDoesNotWrap() {
        let position = PracticePlaybackEngine.filePosition(
            elapsedSampleTime: 500_000, segmentStartFrame: 0,
            loopEnabled: false, range: 1.0...3.0, sampleRate: sampleRate
        )
        XCTAssertEqual(position, 500_000, "loop disabled must never wrap, even with a range left over from before")
    }

    func testDegenerateZeroLengthRangeFallsBackToLinearWithNoCrash() {
        let position = PracticePlaybackEngine.filePosition(
            elapsedSampleTime: 500_000, segmentStartFrame: 0,
            loopEnabled: true, range: 2.0...2.0, sampleRate: sampleRate
        )
        XCTAssertEqual(position, 500_000, "a zero-length loop range must not wrap (and must not divide by zero)")
    }

    func testIsFrameInsideLoopRangeIsTrueStrictlyInsideTheRange() {
        XCTAssertTrue(PracticePlaybackEngine.isFrameInsideLoopRange(2.0, range: 1.0...3.0, sampleRate: sampleRate))
    }

    func testIsFrameInsideLoopRangeIsTrueExactlyAtTheLowerBound() {
        XCTAssertTrue(PracticePlaybackEngine.isFrameInsideLoopRange(1.0, range: 1.0...3.0, sampleRate: sampleRate))
    }

    func testIsFrameInsideLoopRangeIsFalseExactlyAtTheUpperBound() {
        // The crux of the fix: the upper bound is exclusive, matching scheduleSegment's own gate.
        XCTAssertFalse(PracticePlaybackEngine.isFrameInsideLoopRange(3.0, range: 1.0...3.0, sampleRate: sampleRate))
    }

    func testIsFrameInsideLoopRangeIsFalseBeforeTheRange() {
        XCTAssertFalse(PracticePlaybackEngine.isFrameInsideLoopRange(0.5, range: 1.0...3.0, sampleRate: sampleRate))
    }

    func testIsFrameInsideLoopRangeIsFalseForADegenerateZeroLengthRange() {
        XCTAssertFalse(PracticePlaybackEngine.isFrameInsideLoopRange(2.0, range: 2.0...2.0, sampleRate: sampleRate))
    }

    func testLoopIterationsToScheduleReturnsExactlyOneCandidateWhenNoLiveTimingYet() {
        // The very first queue, right after the lead-in and before playback has started: always
        // exactly one candidate, regardless of how short the loop is.
        let sampleTimes = PracticePlaybackEngine.loopIterationsToSchedule(
            alreadyScheduled: 0, leadInLength: 50, loopLength: 100,
            currentPlayerSampleTime: nil, lookaheadFrames: 1_000
        )
        XCTAssertEqual(sampleTimes, [50])
    }

    func testLoopIterationsToScheduleReturnsEmptyWhenAlreadyEnoughMarginIsBanked() {
        // One iteration already queued (index 1's candidate starts at 88_200), and that is already
        // more than the 44_100-frame lookahead ahead of a player position of 0 — nothing more to do.
        let sampleTimes = PracticePlaybackEngine.loopIterationsToSchedule(
            alreadyScheduled: 1, leadInLength: 0, loopLength: 88_200,
            currentPlayerSampleTime: 0, lookaheadFrames: 44_100
        )
        XCTAssertEqual(sampleTimes, [], "already banked more than one lookahead window of margin")
    }

    func testLoopIterationsToScheduleReturnsTheNextCandidateOnceWithinTheLookaheadWindow() {
        // Candidate for index 1 is 88_200; once the player is within 44_100 frames of that, it must
        // be queued (and only that one — index 2's candidate, 176_400, is still comfortably ahead).
        let sampleTimes = PracticePlaybackEngine.loopIterationsToSchedule(
            alreadyScheduled: 1, leadInLength: 0, loopLength: 88_200,
            currentPlayerSampleTime: 44_101, lookaheadFrames: 44_100
        )
        XCTAssertEqual(sampleTimes, [88_200])
    }

    func testLoopIterationsToScheduleQueuesMultipleIterationsForAShortLoop() {
        // A 100-frame loop against a 250-frame lookahead: one iteration of margin (100 frames) is
        // not enough, so this must keep queuing until the banked margin clears the window.
        let sampleTimes = PracticePlaybackEngine.loopIterationsToSchedule(
            alreadyScheduled: 1, leadInLength: 0, loopLength: 100,
            currentPlayerSampleTime: 0, lookaheadFrames: 250
        )
        XCTAssertEqual(sampleTimes, [100, 200], "a loop shorter than the lookahead window must bank several iterations at once")
    }

    func testLoopIterationsToScheduleReturnsEmptyForAZeroLengthLoop() {
        let sampleTimes = PracticePlaybackEngine.loopIterationsToSchedule(
            alreadyScheduled: 0, leadInLength: 0, loopLength: 0,
            currentPlayerSampleTime: nil, lookaheadFrames: 44_100
        )
        XCTAssertEqual(sampleTimes, [], "a degenerate zero-length loop must not schedule anything (and must not loop forever)")
    }
}
