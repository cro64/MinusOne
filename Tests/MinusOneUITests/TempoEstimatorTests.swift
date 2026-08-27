import XCTest
@testable import MinusOne

final class TempoEstimatorTests: XCTestCase {
    private let fps = OnsetEnvelope.framesPerSecond(sampleRate: 44_100)

    /// A synthetic envelope with a spike every beat — what a clean drum track reduces to.
    ///
    /// The jitter is a fixed repeating pattern rather than a random draw: at these tempos one
    /// integer lag step is several BPM, so a random jitter puts the recovered tempo on the wrong
    /// side of the tolerance a few percent of the time, and a test that only usually passes cannot
    /// tell a regression from a bad roll.
    private func pulsedEnvelope(bpm: Double, seconds: Double, jitterFrames: Int = 0) -> [Float] {
        let frameCount = Int(seconds * fps)
        var envelope = [Float](repeating: 0.01, count: frameCount)
        let period = 60 / bpm * fps
        let jitterPattern = [0, 1, -1, 2, -2, 1, 0, -1]
        var beat = 0.0
        var index = 0
        while beat < Double(frameCount) {
            var frame = Int(beat.rounded())
            if jitterFrames > 0 {
                frame += max(-jitterFrames, min(jitterFrames, jitterPattern[index % jitterPattern.count]))
            }
            if frame >= 0 && frame < frameCount { envelope[frame] = 1 }
            beat += period
            index += 1
        }
        return envelope
    }

    func testItRecoversAKnownTempo() throws {
        for bpm in [90.0, 120.0, 140.0] {
            let result = try XCTUnwrap(TempoEstimator.estimate(envelope: pulsedEnvelope(bpm: bpm, seconds: 20), framesPerSecond: fps))
            XCTAssertEqual(result.bpm, bpm, accuracy: 2, "recovered \(result.bpm) for \(bpm)")
        }
    }

    /// Spec §6's stated purpose for the preference window. Autocorrelation peaks at integer
    /// multiples of the true period and never at sub-multiples, so the octave error that can
    /// actually occur is always "too slow": a 128 BPM pulse correlates at its own lag *and* at its
    /// 64 BPM half-time lag, and lag quantisation splits the former across two adjacent lags while
    /// the latter lands cleanly — so the raw peak is the half-time, and only the weighting picks
    /// the musical answer. The 180 BPM case is the same mechanism seen from the other side: the
    /// weighting pulls a too-fast reading down into the preferred band rather than up out of it.
    func testTheOctavePreferenceResolvesHalfAndDoubleTime() throws {
        let fast = try XCTUnwrap(TempoEstimator.estimate(envelope: pulsedEnvelope(bpm: 128, seconds: 20), framesPerSecond: fps))
        XCTAssertEqual(fast.bpm, 128, accuracy: 3, "128 BPM collapsed to its 64 BPM half-time")

        let veryFast = try XCTUnwrap(TempoEstimator.estimate(envelope: pulsedEnvelope(bpm: 180, seconds: 20), framesPerSecond: fps))
        XCTAssertEqual(veryFast.bpm, 90, accuracy: 3, "180 BPM should read as its 90 BPM octave")
    }

    /// The weight is what does that, so pin its shape independently of the estimator.
    func testTheOctaveWeightFavoursTheMiddleOfTheRange() {
        XCTAssertGreaterThan(TempoEstimator.octaveWeight(bpm: 120), TempoEstimator.octaveWeight(bpm: 60))
        XCTAssertGreaterThan(TempoEstimator.octaveWeight(bpm: 120), TempoEstimator.octaveWeight(bpm: 200))
        XCTAssertGreaterThan(TempoEstimator.octaveWeight(bpm: 100), TempoEstimator.octaveWeight(bpm: 65))
        XCTAssertGreaterThan(TempoEstimator.octaveWeight(bpm: 150), TempoEstimator.octaveWeight(bpm: 195))
    }

    /// Tolerating a little sloppiness is the difference between working on real drums and only on
    /// synthetic ones.
    func testItSurvivesModestTimingJitter() throws {
        let result = try XCTUnwrap(TempoEstimator.estimate(envelope: pulsedEnvelope(bpm: 128, seconds: 25, jitterFrames: 2), framesPerSecond: fps))
        XCTAssertEqual(result.bpm, 128, accuracy: 4)
    }

    /// Noise must not read as a confident tempo — the peak-to-mean ratio is what Task 4 gates on,
    /// so it has to be visibly lower here than for a real pulse.
    func testNoiseProducesAFlatterCorrelation() throws {
        var rng = SystemRandomNumberGenerator()
        let noise = (0..<Int(20 * fps)).map { _ in Float.random(in: 0...1, using: &rng) }
        let noisy = try XCTUnwrap(TempoEstimator.estimate(envelope: noise, framesPerSecond: fps))
        let clean = try XCTUnwrap(TempoEstimator.estimate(envelope: pulsedEnvelope(bpm: 120, seconds: 20), framesPerSecond: fps))
        XCTAssertGreaterThan(clean.peak / clean.mean, (noisy.peak / noisy.mean) * 2,
                             "a clean pulse must be far peakier than noise")
    }

    func testTooShortAnEnvelopeYieldsNoEstimate() {
        XCTAssertNil(TempoEstimator.estimate(envelope: [], framesPerSecond: fps))
        XCTAssertNil(TempoEstimator.estimate(envelope: [Float](repeating: 1, count: 10), framesPerSecond: fps))
    }
}
