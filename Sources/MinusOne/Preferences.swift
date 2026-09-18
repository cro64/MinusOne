import Foundation

final class Preferences {
    static let defaultMakeupGainDecibels: Float = 4.5
    static let defaultRampDurationMilliseconds: Float = 50.0

    /// Live's default stem mix: vocals muted, everything else at full fader — reproduces the old
    /// single-slider "remove vocals" default exactly.
    static let defaultMutedLiveStems: Set<SeparationStem> = [.vocals]

    private enum Key {
        static let makeupGainDecibels = "makeupGainDecibels"
        static let rampDurationMilliseconds = "rampDurationMilliseconds"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
        static let separationModelVariant = "separationModelVariant"
        static let captureScope = "captureScope"
        static let selectedAppBundleIDs = "selectedAppBundleIDs"
        static let appearance = "appearance"
        static let recordingSource = "recordingSource"
        static let stemExportFormat = "stemExportFormat"
        static let heroWaveformEnabled = "heroWaveformEnabled"
        static let heroWaveformHeight = "heroWaveformHeight"
        static let mutedLiveStems = "mutedLiveStems"

        static func liveStemFaderVolume(_ stem: SeparationStem) -> String {
            "liveStemFaderVolume.\(stem.rawValue)"
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults? = nil) {
        let resolved = defaults ?? UserDefaults(suiteName: "com.minusone.app") ?? .standard
        self.defaults = resolved
        self.defaults.register(defaults: [
            Key.makeupGainDecibels: Double(Self.defaultMakeupGainDecibels),
            Key.rampDurationMilliseconds: Double(Self.defaultRampDurationMilliseconds),
            Key.hasCompletedOnboarding: false,
            Key.separationModelVariant: SeparationModelVariant.balanced.rawValue,
            Key.captureScope: CaptureScope.allApps.rawValue,
            Key.selectedAppBundleIDs: [String](),
            Key.appearance: AppAppearance.system.rawValue,
            Key.recordingSource: RecordingSource.systemAudio.storedValue,
            Key.heroWaveformEnabled: true,
            // 45, not the original 64: `WindowSizingTests
            // .testTheDeckFitsTheMinimumWindowHeightAtDefaultHeroHeightWithStatusVisible` measures the
            // deck with `statusLabel` visible (a clip still separating — a common state, not an edge
            // case) and 64 left only ~1pt of margin at `WindowSizing.minimum.height`. 45 leaves ~20pt.
            Key.heroWaveformHeight: Double(45),
            Key.mutedLiveStems: Self.defaultMutedLiveStems.map(\.rawValue)
        ])
        for stem in SeparationStem.allCases {
            self.defaults.register(defaults: [Key.liveStemFaderVolume(stem): Double(1)])
        }
    }

    func liveStemFaderVolume(for stem: SeparationStem) -> Float {
        clamp(Float(defaults.double(forKey: Key.liveStemFaderVolume(stem))), 0, 1)
    }

    func setLiveStemFaderVolume(_ volume: Float, for stem: SeparationStem) {
        defaults.set(Double(clamp(volume, 0, 1)), forKey: Key.liveStemFaderVolume(stem))
    }

    var mutedLiveStems: Set<SeparationStem> {
        get {
            let raw = defaults.stringArray(forKey: Key.mutedLiveStems) ?? []
            return Set(raw.compactMap(SeparationStem.init(rawValue:)))
        }
        set {
            defaults.set(newValue.map(\.rawValue), forKey: Key.mutedLiveStems)
        }
    }

    /// Builds a `StemMixerController` seeded from the persisted per-stem fader/mute state — the
    /// single place Live's fader values and mute set turn into the mixer Practice already trusts.
    func liveStemMixerSnapshot() -> StemMixerController {
        let mixer = StemMixerController()
        let muted = mutedLiveStems
        for stem in SeparationStem.allCases {
            mixer.setVolume(liveStemFaderVolume(for: stem), for: stem)
            mixer.setMuted(muted.contains(stem), for: stem)
        }
        return mixer
    }

    /// Persists a `StemMixerController`'s full fader/mute state in one call, so callers don't have
    /// to remember to write both halves separately after every mixer mutation.
    func persistLiveStemMixer(_ mixer: StemMixerController) {
        for stem in SeparationStem.allCases {
            setLiveStemFaderVolume(mixer.volume(for: stem), for: stem)
        }
        mutedLiveStems = Set(SeparationStem.allCases.filter { mixer.isMuted($0) })
    }

    var makeupGainDecibels: Float {
        get { clamp(Float(defaults.double(forKey: Key.makeupGainDecibels)), 0, 12) }
        set { defaults.set(Double(clamp(newValue, 0, 12)), forKey: Key.makeupGainDecibels) }
    }

    var rampDurationMilliseconds: Float {
        get { clamp(Float(defaults.double(forKey: Key.rampDurationMilliseconds)), 30, 80) }
        set { defaults.set(Double(clamp(newValue, 30, 80)), forKey: Key.rampDurationMilliseconds) }
    }

    var heroWaveformEnabled: Bool {
        get { defaults.bool(forKey: Key.heroWaveformEnabled) }
        set { defaults.set(newValue, forKey: Key.heroWaveformEnabled) }
    }

    /// Clamped to `HeroWaveformView`'s own resize-handle range, so a value written before that
    /// range ever changes (or corrupted by hand-editing defaults) can't hand back a height the view
    /// wasn't built to draw at.
    var heroWaveformHeight: Double {
        get { Double(clamp(Float(defaults.double(forKey: Key.heroWaveformHeight)), Float(HeroWaveformView.minimumHeight), Float(HeroWaveformView.maximumHeight))) }
        set { defaults.set(Double(clamp(Float(newValue), Float(HeroWaveformView.minimumHeight), Float(HeroWaveformView.maximumHeight))), forKey: Key.heroWaveformHeight) }
    }

    var hasCompletedOnboarding: Bool {
        get { defaults.bool(forKey: Key.hasCompletedOnboarding) }
        set { defaults.set(newValue, forKey: Key.hasCompletedOnboarding) }
    }

    var separationModelVariant: SeparationModelVariant {
        get {
            guard let raw = defaults.string(forKey: Key.separationModelVariant),
                  let variant = SeparationModelVariant.fromPersisted(raw) else {
                return .balanced
            }
            return variant
        }
        set { defaults.set(newValue.rawValue, forKey: Key.separationModelVariant) }
    }

    /// Where Practice recordings are captured from. Deliberately *not* shared with Live's capture
    /// settings: Live is always a system-audio path, and recording a mic take shouldn't change what
    /// vocal reduction is listening to.
    var recordingSource: RecordingSource {
        get { RecordingSource(storedValue: defaults.string(forKey: Key.recordingSource)) }
        set { defaults.set(newValue.storedValue, forKey: Key.recordingSource) }
    }

    /// Last container picked in the stem export save panel, so the popup opens where it was left.
    var stemExportFormat: StemExportFormat {
        get {
            guard let raw = defaults.string(forKey: Key.stemExportFormat),
                  let format = StemExportFormat(rawValue: raw) else {
                return .default
            }
            return format
        }
        set { defaults.set(newValue.rawValue, forKey: Key.stemExportFormat) }
    }

    var captureScope: CaptureScope {
        get {
            guard let raw = defaults.string(forKey: Key.captureScope),
                  let scope = CaptureScope(rawValue: raw) else {
                return .allApps
            }
            return scope
        }
        set { defaults.set(newValue.rawValue, forKey: Key.captureScope) }
    }

    var appearance: AppAppearance {
        get {
            guard let raw = defaults.string(forKey: Key.appearance),
                  let appearance = AppAppearance(rawValue: raw) else {
                return .system
            }
            return appearance
        }
        set { defaults.set(newValue.rawValue, forKey: Key.appearance) }
    }

    var selectedAppBundleIDs: Set<String> {
        get {
            Set(defaults.stringArray(forKey: Key.selectedAppBundleIDs) ?? [])
        }
        set {
            defaults.set(Array(newValue).sorted(), forKey: Key.selectedAppBundleIDs)
        }
    }
}

private func clamp<T: Comparable>(_ value: T, _ lower: T, _ upper: T) -> T {
    min(max(value, lower), upper)
}
