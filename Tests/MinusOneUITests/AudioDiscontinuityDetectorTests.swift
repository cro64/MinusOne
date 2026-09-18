import XCTest
@testable import MinusOne

final class AudioDiscontinuityDetectorTests: XCTestCase {
    private let sampleRate = 48_000.0

    /// Feeds one callback's worth of frames, all at the given constant sample value.
    @discardableResult
    private func feed(
        _ detector: AudioDiscontinuityDetector,
        value: Float,
        frameCount: Int = 512,
        at position: UInt64
    ) -> Bool {
        let left = Array(repeating: value, count: frameCount)
        let right = Array(repeating: value, count: frameCount)
        return left.withUnsafeBufferPointer { leftPtr in
            right.withUnsafeBufferPointer { rightPtr in
                detector.evaluate(
                    left: leftPtr.baseAddress!,
                    right: rightPtr.baseAddress!,
                    frameCount: frameCount,
                    absolutePosition: position
                )
            }
        }
    }

    /// Regression test: a silence gap (e.g. the pause between two tracks) followed by audio
    /// resuming must NOT trigger a flush/re-warm anymore — that used to force a full ~20s re-warm
    /// on every ordinary track change, which was worse than the thing it protected against.
    func testSilenceThenResumedAudioDoesNotTrigger() {
        let detector = AudioDiscontinuityDetector(sampleRate: sampleRate)
        var position: UInt64 = 0
        var triggered = false

        // A few seconds of normal-level audio.
        for _ in 0..<20 {
            triggered = feed(detector, value: 0.2, at: position) || triggered
            position += 512
        }
        // Silence for well over the old 150ms threshold.
        for _ in 0..<40 {
            triggered = feed(detector, value: 0.0, at: position) || triggered
            position += 512
        }
        // Audio resumes at normal level (a new track starting).
        for _ in 0..<20 {
            triggered = feed(detector, value: 0.2, at: position) || triggered
            position += 512
        }

        XCTAssertFalse(triggered)
    }

    /// A genuine sample-level glitch (e.g. a device hot-swap click) must still trigger.
    ///
    /// Starts well past sample 0: `lastTriggerPosition` defaults to 0, and the retrigger cooldown
    /// (`absolutePosition >= lastTriggerPosition + minRetriggerSamples`) would otherwise suppress
    /// a trigger near the very start of the stream as if a previous trigger had just fired there —
    /// harmless in production (the pipeline is always well past this position by the time anything
    /// interesting happens) but worth not tripping over in a test that starts at position 0.
    func testHardSampleJumpStillTriggers() {
        let detector = AudioDiscontinuityDetector(sampleRate: sampleRate)
        let start: UInt64 = 10 * UInt64(sampleRate)
        _ = feed(detector, value: 0.1, at: start)
        let triggered = feed(detector, value: 0.9, at: start + 512)
        XCTAssertTrue(triggered)
    }

    func testResetClearsTriggerCooldownAndLastSample() {
        let detector = AudioDiscontinuityDetector(sampleRate: sampleRate)
        let start: UInt64 = 10 * UInt64(sampleRate)
        _ = feed(detector, value: 0.1, at: start)
        let didTrigger = feed(detector, value: 0.9, at: start + 512) // triggers, starts cooldown
        XCTAssertTrue(didTrigger)

        detector.reset()

        // Without a "last sample" to jump from, this shouldn't trigger even though it's a big
        // value — there's nothing to be discontinuous *with* yet.
        let triggeredRightAfterReset = feed(detector, value: 0.9, at: start + 1024)
        XCTAssertFalse(triggeredRightAfterReset)
    }
}
