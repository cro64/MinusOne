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
}
