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

    /// Spec §6 step 2b. How finely the period sweep steps, in frames — 0.02 frames is 0.23 ms at
    /// 86.13 fps, which over a three-minute clip is well under a frame of accumulated drift.
    static let refinementPeriodStep = 0.02
    /// How finely the phase sweep steps, in frames. Sub-frame because the phase and the period
    /// trade off against each other: a coarse phase makes a slightly wrong period score as well as
    /// the right one.
    static let refinementPhaseStep = 0.25

    /// Mean envelope value at the beat positions a (period, phase) pair implies.
    ///
    /// The *mean*, not the sum: a shorter period samples more positions, and a sum would prefer it
    /// by that count alone — a systematic tilt toward faster tempi of a few percent, which is the
    /// same size as the error being corrected.
    ///
    /// Linearly interpolated rather than rounded to the nearest frame, so the score varies smoothly
    /// with the period instead of stepping whenever a beat position crosses a frame boundary.
    static func combScore(envelope: [Float], period: Double, phase: Double) -> Double {
        guard period > 0, envelope.count > 1 else { return 0 }
        var sum = 0.0
        var count = 0
        var position = max(0, phase)
        let limit = Double(envelope.count - 1)
        while position <= limit {
            let lower = Int(position)
            let fraction = position - Double(lower)
            let a = Double(envelope[lower])
            let b = Double(envelope[min(lower + 1, envelope.count - 1)])
            sum += a + (b - a) * fraction
            count += 1
            position += period
        }
        return count > 0 ? sum / Double(count) : 0
    }

    /// Spec §6 step 2b: the beat period in frames, refined off the integer lag grid.
    ///
    /// Autocorrelation can only report an integer lag, and at 86.13 fps the reachable tempi are
    /// 1.6 BPM apart at 90 and 5.9 apart at 174 — up to a 1% error. A tempo error is a *rate*
    /// error, so it accumulates: measured on a synthetic click track, the shipped integer-lag
    /// estimate put the bar lines up to half a beat out somewhere in every clip over about a
    /// minute, and `BeatDetector.downbeatOffset` cannot help because recentring the phase only
    /// moves where the drift is worst.
    ///
    /// Parabolic interpolation of the correlation peak was tried first and only halves the error,
    /// because an impulse train's autocorrelation peak is not parabolic. This instead sweeps the
    /// period and the phase jointly over the envelope — the same comb-scoring technique
    /// `BeatDetector.downbeatOffset` uses for phase — and takes the pair whose implied beat
    /// positions carry the most onset energy.
    static func refinedPeriod(envelope: [Float], around lag: Int, shortestLag: Int, longestLag: Int) -> Double {
        let low = max(Double(shortestLag), Double(lag) - 1)
        let high = min(Double(longestLag), Double(lag) + 1)
        guard high >= low, low > 0, envelope.count > 1 else { return Double(lag) }

        var bestPeriod = Double(lag)
        var bestScore = -Double.greatestFiniteMagnitude
        var period = low
        while period <= high + 1e-9 {
            var phase = 0.0
            while phase < period {
                let score = combScore(envelope: envelope, period: period, phase: phase)
                if score > bestScore {
                    bestScore = score
                    bestPeriod = period
                }
                phase += refinementPhaseStep
            }
            period += refinementPeriodStep
        }
        return bestPeriod
    }

    /// Returns the best tempo plus the raw peak and mean *absolute* weighted correlation, which
    /// `BeatDetector` turns into a confidence.
    ///
    /// The tempo is refined off the integer lag grid (`refinedPeriod`); `peak` and `mean` are not
    /// touched by that and remain the octave-weighted autocorrelation figures at the winning
    /// integer lag, so the confidence the caller computes means exactly what it did before.
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
        let period = refinedPeriod(
            envelope: envelope,
            around: bestLag,
            shortestLag: shortestLag,
            longestLag: longestLag
        )
        return (bpm: 60 * framesPerSecond / period, peak: bestScore, mean: max(mean, 1e-9))
    }
}
