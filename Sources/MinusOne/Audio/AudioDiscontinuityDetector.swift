import Foundation

/// Detects a genuine sample-level audio glitch (e.g. a device hot-swap click) in live system
/// audio — a hard, discontinuous jump between two consecutive samples that a real waveform
/// couldn't produce.
///
/// This used to also flush on "silence for a while, then audio resumes," meant to catch a track
/// change — but that fires on every ordinary pause between songs, forcing a full ~20s re-warm each
/// time, which is worse than the thing it was protecting against (an inference window that
/// straddles two songs, producing at most one ~10s stretch of slightly-off separation right at the
/// transition). Keeping only the hard-jump trigger, since that one guards against something a
/// user can't just wait out — a real glitch would otherwise get mixed across a stale window
/// indefinitely, not just for one transition.
final class AudioDiscontinuityDetector {
    private var lastLeft: Float = 0
    private var lastRight: Float = 0
    private var hasLastSample = false
    private var lastTriggerPosition: UInt64 = 0

    private let hardSampleJumpThreshold: Float = 0.65
    private let minRetriggerSamples: UInt64

    init(sampleRate: Double, minRetriggerSeconds: Double = 2.5) {
        minRetriggerSamples = UInt64(sampleRate * minRetriggerSeconds)
    }

    func reset() {
        lastLeft = 0
        lastRight = 0
        hasLastSample = false
        lastTriggerPosition = 0
    }

    func evaluate(
        left: UnsafePointer<Float>,
        right: UnsafePointer<Float>,
        frameCount: Int,
        absolutePosition: UInt64
    ) -> Bool {
        guard frameCount > 0 else { return false }

        var triggered = false
        if hasLastSample {
            let jump = max(abs(left[0] - lastLeft), abs(right[0] - lastRight))
            if jump >= hardSampleJumpThreshold {
                triggered = true
            }
        }

        lastLeft = left[frameCount - 1]
        lastRight = right[frameCount - 1]
        hasLastSample = true

        guard triggered else { return false }
        guard absolutePosition >= lastTriggerPosition + minRetriggerSamples else { return false }
        lastTriggerPosition = absolutePosition
        return true
    }
}
