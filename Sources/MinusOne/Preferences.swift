import Foundation

final class Preferences {
    static let defaultTargetIntensity: Float = 1.0
    static let defaultMakeupGainDecibels: Float = 4.5
    static let defaultRampDurationMilliseconds: Float = 50.0

    private enum Key {
        static let targetIntensity = "targetIntensity"
        static let makeupGainDecibels = "makeupGainDecibels"
        static let rampDurationMilliseconds = "rampDurationMilliseconds"
        static let lastReductionEnabled = "lastReductionEnabled"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
        static let separationModelVariant = "separationModelVariant"
        static let captureScope = "captureScope"
        static let selectedAppBundleIDs = "selectedAppBundleIDs"
        static let appearance = "appearance"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults? = nil) {
        let resolved = defaults ?? UserDefaults(suiteName: "com.minusone.app") ?? .standard
        self.defaults = resolved
        self.defaults.register(defaults: [
            Key.targetIntensity: Double(Self.defaultTargetIntensity),
            Key.makeupGainDecibels: Double(Self.defaultMakeupGainDecibels),
            Key.rampDurationMilliseconds: Double(Self.defaultRampDurationMilliseconds),
            Key.lastReductionEnabled: false,
            Key.hasCompletedOnboarding: false,
            Key.separationModelVariant: SeparationModelVariant.balanced.rawValue,
            Key.captureScope: CaptureScope.allApps.rawValue,
            Key.selectedAppBundleIDs: [String](),
            Key.appearance: AppAppearance.system.rawValue
        ])
    }

    var targetIntensity: Float {
        get { clamp(Float(defaults.double(forKey: Key.targetIntensity)), 0, 1) }
        set { defaults.set(Double(clamp(newValue, 0, 1)), forKey: Key.targetIntensity) }
    }

    var makeupGainDecibels: Float {
        get { clamp(Float(defaults.double(forKey: Key.makeupGainDecibels)), 0, 12) }
        set { defaults.set(Double(clamp(newValue, 0, 12)), forKey: Key.makeupGainDecibels) }
    }

    var rampDurationMilliseconds: Float {
        get { clamp(Float(defaults.double(forKey: Key.rampDurationMilliseconds)), 30, 80) }
        set { defaults.set(Double(clamp(newValue, 30, 80)), forKey: Key.rampDurationMilliseconds) }
    }

    var lastReductionEnabled: Bool {
        get { defaults.bool(forKey: Key.lastReductionEnabled) }
        set { defaults.set(newValue, forKey: Key.lastReductionEnabled) }
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
