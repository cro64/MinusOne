import Foundation

/// Mixes the 4 separated stems (vocals/drums/bass/other) down to stereo output, each stem
/// independently ramped toward its target level so fader/mute changes never click.
///
/// There is deliberately no raw/dry blend in here anymore: earlier, a single `targetIntensity`
/// crossfaded between the untouched raw signal and one pre-summed "instrumental" stream, so
/// `intensity == 0` meant "100% raw, zero separation artifacts." Now that each stem is mixed
/// independently, that no longer generalizes to a single number — a 50%-vocals mix isn't "50% raw,"
/// it's "50% of the separated vocals stem." Raw passthrough (zero artifacts, used when Live is off)
/// is instead handled entirely by `NeuralSeparationPipeline.process()` never calling `process()`
/// here at all — see `masterEnabled`.
final class NeuralMixDSP {
    /// One independently-ramped level per stem, 0...1, driven by `StemMixerController.effectiveVolume(for:)`.
    let stemLevels: [SeparationStem: RealtimeParameter]
    /// Live on/off bypass gate, fully independent of the 4 stem levels — muting every stem while
    /// this stays 1 still means "Live is on, mixed to silence," not "Live is off."
    let masterEnabled: RealtimeParameter
    let makeupGainDecibels: RealtimeParameter
    let rampDurationMilliseconds: RealtimeParameter

    /// Per-callback peak of the delayed raw signal (what the user would have heard) and of the
    /// mixed output (what they actually hear). The Live tab's meter draws the gap between them as
    /// the vocal being removed.
    let dryPeak: RealtimeParameter
    let wetPeak: RealtimeParameter

    /// Per-callback peak of each stem's *raw separated* signal — measured before the stem's fader
    /// is applied, so it reflects what's actually in the music right now regardless of mute state.
    /// This is what lets the Live tab's meter color itself the same way Practice's hero waveform
    /// does: by which instrument is loudest at this instant, not by the user's current mix.
    let stemPeaks: [SeparationStem: RealtimeParameter]

    private var appliedLevels: [SeparationStem: Float]

    init(makeupGainDecibels: Float, rampDurationMilliseconds: Float) {
        stemLevels = Dictionary(uniqueKeysWithValues: SeparationStem.allCases.map { ($0, RealtimeParameter(0)) })
        appliedLevels = Dictionary(uniqueKeysWithValues: SeparationStem.allCases.map { ($0, Float(0)) })
        masterEnabled = RealtimeParameter(0)
        self.makeupGainDecibels = RealtimeParameter(makeupGainDecibels)
        self.rampDurationMilliseconds = RealtimeParameter(rampDurationMilliseconds)
        dryPeak = RealtimeParameter(0)
        wetPeak = RealtimeParameter(0)
        stemPeaks = Dictionary(uniqueKeysWithValues: SeparationStem.allCases.map { ($0, RealtimeParameter(0)) })
    }

    func reset() {
        for stem in SeparationStem.allCases {
            appliedLevels[stem] = 0
        }
        // Without this a stopped or flushed pipeline leaves the meter frozen at its last reading.
        dryPeak.store(0)
        wetPeak.store(0)
        for stem in SeparationStem.allCases {
            stemPeaks[stem]?.store(0)
        }
    }

    /// `rawLeft`/`rawRight` (the delayed dry signal) are used only for `dryPeak` metering — the
    /// before/after comparison the Live tab's meter draws — never mixed into the output; the output
    /// is purely the weighted sum of `stems`.
    func process(
        rawLeft: UnsafePointer<Float>,
        rawRight: UnsafePointer<Float>,
        stems: [SeparationStem: (left: UnsafePointer<Float>, right: UnsafePointer<Float>)],
        outputLeft: UnsafeMutablePointer<Float>,
        outputRight: UnsafeMutablePointer<Float>,
        frameCount: Int,
        sampleRate: Double
    ) {
        guard frameCount > 0 else { return }

        var dryPeakAccumulator: Float = 0
        for frame in 0..<frameCount {
            dryPeakAccumulator = max(dryPeakAccumulator, abs(rawLeft[frame]), abs(rawRight[frame]))
        }
        dryPeak.store(dryPeakAccumulator)

        let rampMilliseconds = clamp(rampDurationMilliseconds.load(), 30, 80)
        let rampFrames = max(1, Int(sampleRate * Double(rampMilliseconds) / 1000.0))
        let makeupLinear = decibelsToLinear(clamp(makeupGainDecibels.load(), 0, 12))

        outputLeft.update(repeating: 0, count: frameCount)
        outputRight.update(repeating: 0, count: frameCount)

        var wetPeakAccumulator: Float = 0

        for (stem, buffers) in stems {
            let target = clamp(stemLevels[stem]?.load() ?? 0, 0, 1)
            var applied = appliedLevels[stem] ?? 0
            var rawPeakAccumulator: Float = 0

            for frame in 0..<frameCount {
                if applied != target {
                    let delta = target - applied
                    let step = min(abs(delta), 1.0 / Float(rampFrames))
                    applied += delta.sign == .minus ? -step : step
                }
                outputLeft[frame] += buffers.left[frame] * applied
                outputRight[frame] += buffers.right[frame] * applied
                rawPeakAccumulator = max(rawPeakAccumulator, abs(buffers.left[frame]), abs(buffers.right[frame]))
            }

            appliedLevels[stem] = applied
            stemPeaks[stem]?.store(rawPeakAccumulator)
        }

        // A flat output boost, applied to whatever the current stem mix produces — not scaled by
        // which stems happen to be muted. An earlier version tied this to "how much vocal is being
        // removed," which meant the slider did precisely nothing whenever vocals wasn't muted (e.g.
        // an Isolate-Vocals mix, or just unmuting vocals to listen) — surprising for a control
        // labeled plainly "Gain." A flat boost is simple, always audible, and still reproduces the
        // old single-slider default exactly (that default only ever ran with vocals muted anyway).
        //
        // Nothing upstream ever guaranteed the mixed-and-boosted result stays within ±1.0 — up to 4
        // summed stems, then multiplied by up to 12dB (~4x) of gain, can genuinely exceed full
        // scale, which the audio hardware doesn't "clip" gracefully, it wraps/distorts harshly
        // (heard as crackle or hiss). `softLimit` is the safety net that was missing: transparent
        // below `limiterThreshold`, and a smooth (not hard-edged) compression above it, so normal
        // playback is untouched but an over never reaches the output raw.
        for frame in 0..<frameCount {
            outputLeft[frame] = softLimit(outputLeft[frame] * makeupLinear)
            outputRight[frame] = softLimit(outputRight[frame] * makeupLinear)
            wetPeakAccumulator = max(wetPeakAccumulator, abs(outputLeft[frame]), abs(outputRight[frame]))
        }

        wetPeak.store(wetPeakAccumulator)
    }

    private func decibelsToLinear(_ decibels: Float) -> Float {
        pow(10, decibels / 20)
    }

    private func clamp(_ value: Float, _ lower: Float, _ upper: Float) -> Float {
        min(max(value, lower), upper)
    }

    /// Below `limiterThreshold` this is the identity function — normal-level audio passes through
    /// completely unchanged. Above it, a tanh soft-knee compresses toward (but never quite reaches)
    /// full scale, instead of a hard clamp's sharp corner, which is its own source of audible
    /// high-frequency distortion.
    private let limiterThreshold: Float = 0.9

    private func softLimit(_ sample: Float) -> Float {
        let magnitude = abs(sample)
        guard magnitude > limiterThreshold else { return sample }
        let headroom = 1 - limiterThreshold
        let excess = (magnitude - limiterThreshold) / headroom
        let compressed = limiterThreshold + headroom * tanh(excess)
        return sample < 0 ? -compressed : compressed
    }
}
