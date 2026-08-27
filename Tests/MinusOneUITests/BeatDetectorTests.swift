import XCTest
@testable import MinusOne

final class BeatDetectorTests: XCTestCase {
    private let sampleRate = 44_100.0

    /// A drum-ish click track: a loud burst on each downbeat, quieter on the other beats, so the
    /// downbeat search has something to find.
    private func drumTrack(seconds: Double, bpm: Double, downbeatOffset: Double, beatsPerBar: Int = 4) -> [Float] {
        var samples = [Float](repeating: 0, count: Int(seconds * sampleRate))
        let beatDuration = 60 / bpm
        var index = 0
        var time = downbeatOffset
        // Fill backwards from the first downbeat too, so the clip does not start conveniently on it.
        var backfill = downbeatOffset - beatDuration
        var backIndex = -1
        while backfill > 0 {
            addBurst(&samples, at: backfill, amplitude: backIndex % beatsPerBar == 0 ? 0.95 : 0.4)
            backfill -= beatDuration
            backIndex -= 1
        }
        while time < seconds {
            addBurst(&samples, at: time, amplitude: index % beatsPerBar == 0 ? 0.95 : 0.4)
            time += beatDuration
            index += 1
        }
        return samples
    }

    private func addBurst(_ samples: inout [Float], at seconds: Double, amplitude: Float) {
        let start = Int(seconds * sampleRate)
        guard start >= 0 else { return }
        for offset in 0..<220 where start + offset < samples.count {
            samples[start + offset] = amplitude * (1 - Float(offset) / 220)
        }
    }

    private func noise(seconds: Double) -> [Float] {
        var rng = SystemRandomNumberGenerator()
        return (0..<Int(seconds * sampleRate)).map { _ in Float.random(in: -0.5...0.5, using: &rng) }
    }

    func testItDetectsAKnownTempo() throws {
        for bpm in [100.0, 128.0] {
            let detection = try XCTUnwrap(BeatDetector.detect(samples: drumTrack(seconds: 20, bpm: bpm, downbeatOffset: 0.75), sampleRate: sampleRate))
            XCTAssertEqual(detection.bpm, bpm, accuracy: 2, "recovered \(detection.bpm) for \(bpm)")
        }
    }

    /// The downbeat is what turns a tempo into a grid — without it the bar lines are in the wrong
    /// place and the ruler is confidently wrong, which spec §6 rates worse than blank.
    func testItFindsTheDownbeatPhase() throws {
        let offset = 0.75
        let detection = try XCTUnwrap(BeatDetector.detect(samples: drumTrack(seconds: 20, bpm: 120, downbeatOffset: offset), sampleRate: sampleRate))
        // Phase is only meaningful modulo one bar.
        let barDuration = 60 / detection.bpm * 4
        let error = abs((detection.downbeatOffsetSeconds - offset).truncatingRemainder(dividingBy: barDuration))
        let wrapped = min(error, barDuration - error)
        XCTAssertLessThan(wrapped, 0.08, "downbeat off by \(wrapped)s")
    }

    /// The grid must land on the beats it claims. This is the assertion that would catch a
    /// half-beat phase error that the modulo check above could still wave through.
    func testTheResultingGridLandsOnTheBeats() throws {
        let detection = try XCTUnwrap(BeatDetector.detect(samples: drumTrack(seconds: 20, bpm: 120, downbeatOffset: 0.75), sampleRate: sampleRate))
        let grid = BeatGrid(bpm: detection.bpm, downbeatOffsetSeconds: detection.downbeatOffsetSeconds)
        for expected in [0.75, 1.25, 1.75, 2.25, 2.75] {
            XCTAssertEqual(grid.nearestBeat(to: expected), expected, accuracy: 0.08, "beat at \(expected)")
        }
    }

    func testNoiseIsRejectedRatherThanGuessedAt() {
        let detection = BeatDetector.detect(samples: noise(seconds: 20), sampleRate: sampleRate)
        if let detection {
            XCTAssertLessThan(detection.confidence, BeatDetector.confidenceThreshold,
                              "noise scored \(detection.confidence), at or above the threshold")
        }
    }

    func testAClipTooShortToAnalyseYieldsNothing() {
        XCTAssertNil(BeatDetector.detect(samples: [Float](repeating: 0, count: 1000), sampleRate: sampleRate))
    }

    /// Prints the separation the threshold is chosen from. Not a pass/fail gate on its own — Step 5
    /// reads these numbers and sets the constant, and the assertion below only guards the ordering
    /// that makes any threshold possible at all.
    func testMeasureConfidenceSeparation() throws {
        var musical: [Double] = []
        for bpm in [90.0, 110.0, 128.0, 145.0] {
            let detection = try XCTUnwrap(BeatDetector.detect(samples: drumTrack(seconds: 20, bpm: bpm, downbeatOffset: 0.5), sampleRate: sampleRate))
            musical.append(detection.confidence)
            print("MEASURED confidence, drums at \(bpm) BPM: \(detection.confidence)")
        }
        var noisy: [Double] = []
        for trial in 1...4 {
            if let detection = BeatDetector.detect(samples: noise(seconds: 20), sampleRate: sampleRate) {
                noisy.append(detection.confidence)
                print("MEASURED confidence, noise trial \(trial): \(detection.confidence)")
            } else {
                print("MEASURED confidence, noise trial \(trial): no estimate at all")
            }
        }
        let lowestMusical = musical.min() ?? 0
        let highestNoise = noisy.max() ?? 0
        print("MEASURED separation: lowest musical \(lowestMusical) vs highest noise \(highestNoise)")
        XCTAssertGreaterThan(lowestMusical, highestNoise,
                             "musical and noise confidences overlap — no threshold can separate them")
    }
}
