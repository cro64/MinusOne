import Foundation

/// Finds the tempo an onset envelope repeats at.
///
/// Autocorrelation alone cannot tell 75 BPM from 150: a pulse correlates with itself at every
/// multiple of its period, so the raw peak is an arbitrary octave. The preference weighting is what
/// turns that into a musical answer, and it is why spec §6 specifies one.
enum TempoEstimator {
    static let minimumBPM = 60.0
    static let maximumBPM = 200.0

    /// Log-normal, centred at 120 BPM. Sigma is set so 80 and 160 — the ends of spec §6's stated
    /// preference band — still score about 0.6, while 60 and 200 fall away sharply.
    static func octaveWeight(bpm: Double) -> Double {
        guard bpm > 0 else { return 0 }
        let sigma = 0.55
        let octavesFromCentre = log2(bpm / 120)
        return exp(-0.5 * (octavesFromCentre / sigma) * (octavesFromCentre / sigma))
    }

    static func autocorrelation(_ envelope: [Float], maximumLag: Int) -> [Float] {
        guard envelope.count > maximumLag, maximumLag > 0 else { return [] }
        var mean: Float = 0
        for value in envelope { mean += value }
        mean /= Float(envelope.count)
        let centred = envelope.map { $0 - mean }

        var result = [Float](repeating: 0, count: maximumLag + 1)
        for lag in 0...maximumLag {
            var sum: Float = 0
            for index in 0..<(centred.count - lag) {
                sum += centred[index] * centred[index + lag]
            }
            result[lag] = sum / Float(centred.count - lag)
        }
        return result
    }

    /// Returns the best tempo plus the raw peak and mean *absolute* weighted correlation, which
    /// `BeatDetector` turns into a confidence.
    static func estimate(envelope: [Float], framesPerSecond: Double) -> (bpm: Double, peak: Double, mean: Double)? {
        guard framesPerSecond > 0 else { return nil }
        let shortestLag = Int((60 / maximumBPM * framesPerSecond).rounded(.down))
        let longestLag = Int((60 / minimumBPM * framesPerSecond).rounded(.up))
        guard shortestLag >= 1, envelope.count > longestLag * 2 else { return nil }

        let correlation = autocorrelation(envelope, maximumLag: longestLag)
        guard correlation.count > longestLag else { return nil }

        var bestLag = shortestLag
        var bestScore = -Double.greatestFiniteMagnitude
        var magnitudeSum = 0.0
        var scoreCount = 0

        for lag in shortestLag...longestLag {
            let bpm = 60 * framesPerSecond / Double(lag)
            let score = Double(correlation[lag]) * octaveWeight(bpm: bpm)
            // The magnitude, not the signed score. A correlation is as likely to be negative as
            // positive at an unrelated lag, so a signed average is a near-zero quantity whose sign
            // flips between noise draws — and dividing a peak by it handed white noise a
            // confidence in the millions, which is backwards for a gate whose whole job is to
            // reject noise.
            magnitudeSum += abs(score)
            scoreCount += 1
            if score > bestScore {
                bestScore = score
                bestLag = lag
            }
        }
        guard scoreCount > 0, bestScore > 0 else { return nil }

        let mean = magnitudeSum / Double(scoreCount)
        return (bpm: 60 * framesPerSecond / Double(bestLag), peak: bestScore, mean: max(mean, 1e-9))
    }
}
