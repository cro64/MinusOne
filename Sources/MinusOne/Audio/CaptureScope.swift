import Foundation

/// Which apps MinusOne captures and processes.
enum CaptureScope: String, CaseIterable, Equatable {
    case allApps
    case selectedApps

    var displayName: String {
        switch self {
        case .allApps:
            return "All Apps"
        case .selectedApps:
            return "Custom"
        }
    }

    var detailText: String {
        switch self {
        case .allApps:
            return "Process all system audio (FaceTime and other apps are muted while active)"
        case .selectedApps:
            return "Only process checked apps — others like FaceTime play normally"
        }
    }
}
