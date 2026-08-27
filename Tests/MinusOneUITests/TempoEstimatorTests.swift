import XCTest
@testable import MinusOne

final class TempoEstimatorTests: XCTestCase {
    private let fps = OnsetEnvelope.framesPerSecond(sampleRate: 44_100)

    /// A synthetic envelope with a spike every beat — what a clean drum track reduces to.
    private func pulsedEnvelope(bpm: Double, seconds: Double, jitterFrames: Int = 0) -> [Float] {
        let frameCount = Int(seconds * fps)
        var envelope = [Float](repeating: 0.01, count: frameCount)
        let period = 60 / bpm * fps
        var beat = 0.0
        var rng = SystemRandomNumberGenerator()
        while beat < Double(frameCount) {
            var frame = Int(beat.rounded())
            if jitterFrames > 0 { frame += Int.random(in: -jitterFrames...jitterFrames, using: &rng) }
            if frame >= 0 && frame < frameCount { envelope[frame] = 1 }
            beat += period
        }
        return envelope
    }

    func testItRecoversAKnownTempo() throws {
        for bpm in [90.0, 120.0, 140.0] {
            let result = try XCTUnwrap(TempoEstimator.estimate(envelope: pulsedEnvelope(bpm: bpm, seconds: 20), framesPerSecond: fps))
            XCTAssertEqual(result.bpm, bpm, accuracy: 2, "recovered \(result.bpm) for \(bpm)")
        }
    }

    /// Spec §6's stated purpose for the preference window: a 75 BPM pulse also correlates at 150,
    /// and a 160 BPM pulse at 80. The weighting must pick the musically likely one rather than
    /// whichever lag happens to peak.
    func testTheOctavePreferenceResolvesHalfAndDoubleTime() throws {
        let slow = try XCTUnwrap(TempoEstimator.estimate(envelope: pulsedEnvelope(bpm: 75, seconds: 20), framesPerSecond: fps))
        XCTAssertEqual(slow.bpm, 150, accuracy: 3, "75 BPM should read as its 150 BPM octave")

        let fast = try XCTUnwrap(TempoEstimator.estimate(envelope: pulsedEnvelope(bpm: 180, seconds: 20), framesPerSecond: fps))
        XCTAssertEqual(fast.bpm, 90, accuracy: 3, "180 BPM should read as its 90 BPM octave")
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
