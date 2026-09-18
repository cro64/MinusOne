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
    case processTapPermissionDenied
    case noPhysicalOutput
    case noSelectedAudioProcesses
    case coreAudio(String, OSStatus)
    case unsupportedFormat(String)

    var errorDescription: String? {
        switch self {
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
