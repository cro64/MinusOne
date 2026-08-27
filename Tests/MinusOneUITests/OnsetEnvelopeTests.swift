import XCTest
@testable import MinusOne

final class OnsetEnvelopeTests: XCTestCase {
    private let sampleRate = 44_100.0

    /// A click track: an impulse burst every `interval` seconds, silence between.
    private func clickTrack(seconds: Double, interval: Double, amplitude: Float = 0.9) -> [Float] {
        var samples = [Float](repeating: 0, count: Int(seconds * sampleRate))
        var t = 0.0
        while t < seconds {
            let start = Int(t * sampleRate)
            // A short burst rather than a single sample: one sample is narrower than the STFT hop
            // and can land between frames.
            for offset in 0..<220 where start + offset < samples.count {
                let decay = 1 - Float(offset) / 220
                samples[start + offset] = amplitude * decay
            }
            t += interval
        }
        return samples
    }

    func testFrameRateMatchesTheSpec() {
        XCTAssertEqual(OnsetEnvelope.framesPerSecond(sampleRate: 44_100), 86.13, accuracy: 0.01)
    }

    func testSilenceProducesAFlatEnvelope() {
        let envelope = OnsetEnvelope.compute(samples: [Float](repeating: 0, count: 44_100), sampleRate: sampleRate)
        XCTAssertFalse(envelope.isEmpty)
        XCTAssertEqual(envelope.max() ?? 0, 0, accuracy: 1e-6)
    }

    /// The load-bearing property: envelope peaks land where the clicks are. Without this every
    /// downstream stage is measuring noise.
    func testPeaksLandOnTheClicks() {
        let interval = 0.5
        let envelope = OnsetEnvelope.compute(samples: clickTrack(seconds: 4, interval: interval), sampleRate: sampleRate)
        let fps = OnsetEnvelope.framesPerSecond(sampleRate: sampleRate)

        let threshold = (envelope.max() ?? 0) * 0.5
        let peakFrames = envelope.indices.filter { envelope[$0] > threshold }
        XCTAssertGreaterThanOrEqual(peakFrames.count, 6, "expected a peak per click")

        // Every strong frame must sit within two frames of a click.
        for frame in peakFrames {
            let time = Double(frame) / fps
            let nearestClick = (time / interval).rounded() * interval
            XCTAssertLessThan(abs(time - nearestClick), 2 / fps,
                              "peak at \(time)s is not near a click")
        }
    }

    /// Half-wave rectification is what makes it an *onset* envelope: energy appearing counts,
    /// energy disappearing does not. Without it a note ending reads as loudly as a note starting.
    func testOnlyRisingEnergyCounts() {
        // One burst then silence: the attack must produce a far larger response than the release.
        var samples = [Float](repeating: 0, count: Int(sampleRate))
        for index in 0..<Int(sampleRate / 2) {
            samples[index] = 0.8 * sinf(Float(index) * 0.05)
        }
        let envelope = OnsetEnvelope.compute(samples: samples, sampleRate: sampleRate)
        let fps = OnsetEnvelope.framesPerSecond(sampleRate: sampleRate)

        let attackFrame = Int(0.02 * fps)
        let releaseFrame = Int(0.52 * fps)
        let attack = envelope[max(0, attackFrame - 2)...min(envelope.count - 1, attackFrame + 4)].max() ?? 0
        let release = envelope[max(0, releaseFrame - 2)...min(envelope.count - 1, releaseFrame + 4)].max() ?? 0
        XCTAssertGreaterThan(attack, release * 4, "the release rivals the attack — not rectified")
    }

    func testAShortBufferDoesNotCrash() {
        XCTAssertTrue(OnsetEnvelope.compute(samples: [0, 1, 0], sampleRate: sampleRate).isEmpty)
        XCTAssertTrue(OnsetEnvelope.compute(samples: [], sampleRate: sampleRate).isEmpty)
    }
}
