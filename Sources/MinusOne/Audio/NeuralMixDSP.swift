import Foundation

/// Crossfades between delayed raw audio and the separated instrumental stream.
final class NeuralMixDSP {
    let targetIntensity: RealtimeParameter
    let makeupGainDecibels: RealtimeParameter
    let rampDurationMilliseconds: RealtimeParameter

    /// Per-callback peak of the *delayed* raw signal (what the user would have heard) and of the
    /// mixed output (what they actually hear). The Live tab's meter draws the gap between them as
    /// the vocal being removed.
    ///
    /// These are published from here, and not from `AudioEngine`'s IO proc, specifically because
    /// of alignment: the pipeline delays playback by `NeuralSeparationPipeline.playbackDelaySeconds`
    /// (~6s), so measuring at the IO proc would compare input-now against output-from-6s-ago and
    /// the before/after comparison would be meaningless. Inside `process`, `raw*` is already the
    /// delayed dry and `instrumental*` is the aligned separated signal, so the two peaks describe
    /// the same instant of audio.
    let dryPeak: RealtimeParameter
    let wetPeak: RealtimeParameter

    private var appliedIntensity: Float = 0

    init(makeupGainDecibels: Float, rampDurationMilliseconds: Float) {
        targetIntensity = RealtimeParameter(0)
        self.makeupGainDecibels = RealtimeParameter(makeupGainDecibels)
        self.rampDurationMilliseconds = RealtimeParameter(rampDurationMilliseconds)
        dryPeak = RealtimeParameter(0)
        wetPeak = RealtimeParameter(0)
    }

    func reset() {
        appliedIntensity = 0
        // Without this a stopped or flushed pipeline leaves the meter frozen at its last reading.
        dryPeak.store(0)
        wetPeak.store(0)
    }

    func process(
        rawLeft: UnsafePointer<Float>,
        rawRight: UnsafePointer<Float>,
        instrumentalLeft: UnsafePointer<Float>,
        instrumentalRight: UnsafePointer<Float>,
        outputLeft: UnsafeMutablePointer<Float>,
        outputRight: UnsafeMutablePointer<Float>,
        frameCount: Int,
        sampleRate: Double
    ) {
        guard frameCount > 0 else { return }

        let target = clamp(targetIntensity.load(), 0, 1)
        let rampMilliseconds = clamp(rampDurationMilliseconds.load(), 30, 80)
        let rampFrames = max(1, Int(sampleRate * Double(rampMilliseconds) / 1000.0))
        let makeupLinear = decibelsToLinear(clamp(makeupGainDecibels.load(), 0, 12))

        // Accumulated in the existing per-frame loop rather than in separate passes over the
        // buffers — the samples are already loaded here, so metering costs two `max`es per frame.
        var dryPeakAccumulator: Float = 0
        var wetPeakAccumulator: Float = 0

        for frame in 0..<frameCount {
            if appliedIntensity != target {
                let delta = target - appliedIntensity
                let step = min(abs(delta), 1.0 / Float(rampFrames))
                appliedIntensity += delta.sign == .minus ? -step : step
            }

            let intensity = appliedIntensity
            let dry = 1 - intensity

            var outLeft = rawLeft[frame] * dry + instrumentalLeft[frame] * intensity
            var outRight = rawRight[frame] * dry + instrumentalRight[frame] * intensity

            let loudnessComp = 1 + (makeupLinear - 1) * intensity
            outLeft *= loudnessComp
            outRight *= loudnessComp

            outputLeft[frame] = outLeft
            outputRight[frame] = outRight

            dryPeakAccumulator = max(dryPeakAccumulator, abs(rawLeft[frame]), abs(rawRight[frame]))
            wetPeakAccumulator = max(wetPeakAccumulator, abs(outLeft), abs(outRight))
        }

        dryPeak.store(dryPeakAccumulator)
        wetPeak.store(wetPeakAccumulator)
    }

    private func decibelsToLinear(_ decibels: Float) -> Float {
        pow(10, decibels / 20)
    }

    private func clamp(_ value: Float, _ lower: Float, _ upper: Float) -> Float {
        min(max(value, lower), upper)
    }
}
