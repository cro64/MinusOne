import Foundation

/// Where a Practice recording is captured from.
///
/// System audio (the default) taps whatever the machine is playing; an input device records a
/// microphone or interface directly, for practising along to something rather than capturing it.
/// The device is held by UID rather than `AudioDeviceID` because IDs are reassigned across reboots
/// and re-plugs — the same reason `Preferences` stores output devices by UID elsewhere.
enum RecordingSource: Equatable {
    case systemAudio
    case inputDevice(uid: String)

    /// Round-trips through `UserDefaults` as a single string. The empty string is system audio, so
    /// a missing/blank default lands on the same case as a fresh install.
    var storedValue: String {
        switch self {
        case .systemAudio: return ""
        case .inputDevice(let uid): return uid
        }
    }

    init(storedValue: String?) {
        guard let storedValue, !storedValue.isEmpty else {
            self = .systemAudio
            return
        }
        self = .inputDevice(uid: storedValue)
    }

    var isMicrophone: Bool {
        if case .inputDevice = self { return true }
        return false
    }

    /// Resolves to a device that still exists, or `nil` if the selection has been unplugged.
    var resolvedDevice: AudioDevice? {
        guard case .inputDevice(let uid) = self else { return nil }
        return CoreAudioDevices.device(withUID: uid)
    }

    /// Name for the picker and for status copy. Falls back to a "no longer available" phrasing
    /// rather than a bare UID when the selected device has gone away.
    var displayName: String {
        switch self {
        case .systemAudio:
            return "System audio"
        case .inputDevice(let uid):
            return CoreAudioDevices.device(withUID: uid)?.name ?? "Unavailable device"
        }
    }
}
