import Foundation

/// Per-stem volume/mute/solo state and the mixing logic to resolve them into an effective
/// playback volume. Kept independent of AVFoundation so the mix math is easy to reason about.
final class StemMixerController {
    private var faderVolumes: [SeparationStem: Float] = Dictionary(
        uniqueKeysWithValues: SeparationStem.allCases.map { ($0, Float(1)) }
    )
    private var mutedStems: Set<SeparationStem> = []
    private(set) var soloedStem: SeparationStem?

    func volume(for stem: SeparationStem) -> Float {
        faderVolumes[stem] ?? 1
    }

    func isMuted(_ stem: SeparationStem) -> Bool {
        mutedStems.contains(stem)
    }

    func isSoloed(_ stem: SeparationStem) -> Bool {
        soloedStem == stem
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

    func toggleSolo(_ stem: SeparationStem) {
        soloedStem = (soloedStem == stem) ? nil : stem
    }

    /// Combines fader + mute + solo into the volume that should actually be applied to the stem's player.
    func effectiveVolume(for stem: SeparationStem) -> Float {
        let fader = volume(for: stem)
        if isMuted(stem) { return 0 }
        if let soloedStem {
            return stem == soloedStem ? fader : 0
        }
        return fader
    }
}
