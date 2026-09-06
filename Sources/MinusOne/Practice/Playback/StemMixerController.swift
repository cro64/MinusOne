import Foundation

/// Per-stem volume/mute state and the mixing logic to resolve them into an effective playback
/// volume. Kept independent of AVFoundation so the mix math is easy to reason about.
///
/// There is deliberately no separate "solo" state: soloing one stem is identical, in terms of
/// what actually plays, to muting every other stem — `isolateStem(_:)` reaches that same outcome
/// directly instead of maintaining a second, redundant flag alongside `mutedStems`.
final class StemMixerController {
    private var faderVolumes: [SeparationStem: Float] = Dictionary(
        uniqueKeysWithValues: SeparationStem.allCases.map { ($0, Float(1)) }
    )
    private var mutedStems: Set<SeparationStem> = []

    func volume(for stem: SeparationStem) -> Float {
        faderVolumes[stem] ?? 1
    }

    func isMuted(_ stem: SeparationStem) -> Bool {
        mutedStems.contains(stem)
    }

    func setVolume(_ volume: Float, for stem: SeparationStem) {
        faderVolumes[stem] = min(1, max(0, volume))
    }

    func setMuted(_ muted: Bool, for stem: SeparationStem) {
        if muted {
            mutedStems.insert(stem)
        } else {
            mutedStems.remove(stem)
        }
    }

    /// The Cmd-click gesture on a stem's mute control: mute every other stem, unmute this one.
    /// Reassigns the whole mute set rather than adding to it, so isolating a second stem replaces
    /// the first isolation instead of leaving every stem muted.
    func isolateStem(_ stem: SeparationStem) {
        mutedStems = Set(SeparationStem.allCases.filter { $0 != stem })
    }

    /// Combines fader + mute into the volume that should actually be applied to the stem's player.
    func effectiveVolume(for stem: SeparationStem) -> Float {
        isMuted(stem) ? 0 : volume(for: stem)
    }
}
