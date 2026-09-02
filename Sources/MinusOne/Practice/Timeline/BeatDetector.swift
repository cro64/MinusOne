import AVFoundation
import Foundation

/// Tempo, downbeat and confidence from an isolated drums stem.
///
/// Running on separated drums rather than a full mix is an accuracy advantage most detectors do
/// not have (spec §6): there is no vocal or harmonic energy to mistake for a transient.
///
/// The confidence gate is the load-bearing part. Rubato, live and expressively-timed material will
/// defeat any of this, and a grid drawn confidently in the wrong place is worse than no grid — so
/// below the threshold the detection is discarded entirely and the deck stays on clock time.
enum BeatDetector {
    struct Detection: Equatable {
        let bpm: Double
        let downbeatOffsetSeconds: Double
        /// Peak of the octave-weighted autocorrelation over its mean absolute weighted
        /// correlation — a peakiness ratio, ≥ 0.
        let confidence: Double
    }

    /// A detection is kept when its confidence is at or above this, so a *lower* threshold is the
    /// permissive one: it admits more marginal detections and puts more wrong grids on screen.
    ///
    /// Measured on `BeatDetectorTests.testMeasureConfidenceSeparation`, which spans the whole
    /// 60–200 BPM search range: synthetic drum tracks score 10.88–28.73 (the floor is the 174 BPM
    /// fixture) and white noise scores 2.41–3.71. 9.0 sits just below the musical floor, which is
    /// the *permissive* end of that gap — chosen to keep every genuine detection rather than to
    /// suppress marginal ones, and defensible only because the gap is as wide as it is: nothing
    /// musical came within 17% of the threshold from above, and nothing noisy within 140% from
    /// below.
    ///
    /// What the number is not: white noise is not the material that actually defeats detection.
    /// Rubato, live and expressively-timed playing produce a real but wrong peak, and nothing in
    /// this measurement says where those score. The gate is a floor against nonsense, not a
    /// guarantee that everything above it is right — which is why the manual override in spec §6
    /// is not optional, and why the failure mode below the gate is deliberately the safe one:
    /// suppress the grid, fall back to m:ss, leave the field empty, invite a tap.
    static let confidenceThreshold: Double = 9.0

    static func detect(samples: [Float], sampleRate: Double) -> Detection? {
        let envelope = OnsetEnvelope.compute(samples: samples, sampleRate: sampleRate)
        guard !envelope.isEmpty else { return nil }
        let fps = OnsetEnvelope.framesPerSecond(sampleRate: sampleRate)
        guard let tempo = TempoEstimator.estimate(envelope: envelope, framesPerSecond: fps) else { return nil }

        return Detection(
            bpm: tempo.bpm,
            downbeatOffsetSeconds: downbeatOffset(envelope: envelope, bpm: tempo.bpm, framesPerSecond: fps),
            confidence: tempo.peak / tempo.mean
        )
    }

    /// Spec §6 step 3: for each candidate offset within one bar, sum the envelope at the implied
    /// downbeat positions and take the maximum.
    ///
    /// Searched over a *bar* rather than a beat because the downbeat is what the offset names —
    /// searching one beat period would find a beat and call it bar one.
    static func downbeatOffset(envelope: [Float], bpm: Double, framesPerSecond: Double) -> Double {
        guard bpm > 0, framesPerSecond > 0, !envelope.isEmpty else { return 0 }
        let beatFrames = 60 / bpm * framesPerSecond
        let barFrames = beatFrames * 4
        guard barFrames >= 1 else { return 0 }

        var bestOffset = 0.0
        var bestScore = -Float.greatestFiniteMagnitude
        var candidate = 0.0
        while candidate < barFrames {
            var score: Float = 0
            var position = candidate
            while position < Double(envelope.count) {
                let frame = Int(position.rounded())
                if frame >= 0 && frame < envelope.count { score += envelope[frame] }
                position += barFrames
            }
            if score > bestScore {
                bestScore = score
                bestOffset = candidate
            }
            candidate += 1
        }
        return bestOffset / framesPerSecond
    }

    /// Reads a stem file and detects from its mono downmix.
    static func detect(audioURL: URL) throws -> Detection? {
        let file = try AVAudioFile(forReading: audioURL)
        let format = file.processingFormat
        guard file.length > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))
        else { return nil }
        try file.read(into: buffer)

        let frames = Int(buffer.frameLength)
        guard frames > 0, let channels = buffer.floatChannelData else { return nil }
        var mono = [Float](repeating: 0, count: frames)
        if format.channelCount == 1 {
            mono.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: channels[0], count: frames) }
        } else {
            for frame in 0..<frames {
                mono[frame] = (channels[0][frame] + channels[1][frame]) * 0.5
            }
        }
        return detect(samples: mono, sampleRate: format.sampleRate)
    }
}
