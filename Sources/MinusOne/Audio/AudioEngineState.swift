import AudioToolbox
import Foundation

enum AudioPermissionKind: Equatable {
    case microphone
    case systemAudioRecording
}

enum AudioEngineStatus: Equatable {
    case idle
    case passthrough
    case active
    case warmingUp
    case permissionRequired(AudioPermissionKind)
    case error(String)

    var displayText: String {
        switch self {
        case .idle:
            return "Idle"
        case .passthrough:
            return "Ready — system audio passthrough"
        case .active:
            return "Active — reducing vocals"
        case .warmingUp:
            return "Warming up — neural model loading"
        case .permissionRequired(.microphone):
            return "Microphone permission required for BlackHole"
        case .permissionRequired(.systemAudioRecording):
            return "System Audio Recording permission required"
        case .error(let message):
            return message
        }
    }
}

/// Throws `AudioEngineError.coreAudio(message, status)` unless `status` is `noErr`.
///
/// Free function rather than a method on either caller: `AudioEngine` and `ProcessTapSession` each
/// carried a byte-identical private `check(_:_:)`, and every new CoreAudio call site had to pick
/// one to live next to.
func checkCoreAudio(_ status: OSStatus, _ message: String) throws {
    guard status == noErr else {
        throw AudioEngineError.coreAudio(message, status)
    }
}

enum AudioEngineError: Error, LocalizedError {
    case blackHoleMissing
    case blackHoleDriverInstalledButNotLoaded
    case processTapPermissionDenied
    case noPhysicalOutput
    case noSelectedAudioProcesses
    case coreAudio(String, OSStatus)
    case unsupportedFormat(String)

    var errorDescription: String? {
        switch self {
        case .blackHoleMissing:
            return "BlackHole is not installed. Install BlackHole 2ch from existential.audio/blackhole, then reopen MinusOne."
        case .blackHoleDriverInstalledButNotLoaded:
            return "BlackHole is installed, but CoreAudio has not loaded it yet. Restart CoreAudio or reboot, then reopen MinusOne."
        case .processTapPermissionDenied:
            return "System audio capture permission denied. Grant System Audio Recording in System Settings."
        case .noPhysicalOutput:
            return "No compatible physical output device was found."
        case .noSelectedAudioProcesses:
            return "No selected apps are currently playing audio. Start playback in a checked app, or switch to All Apps."
        case .coreAudio(let message, let status):
            return "\(message) (OSStatus \(status))"
        case .unsupportedFormat(let message):
            return message
        }
    }

    var isLikelyPermissionDenied: Bool {
        switch self {
        case .processTapPermissionDenied:
            return true
        case .coreAudio(_, let status):
            return AudioPermission.isPermissionDeniedStatus(status)
        default:
            return false
        }
    }
}
