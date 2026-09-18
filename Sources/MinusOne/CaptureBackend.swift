import Foundation

/// Process Tap is the only capture backend — BlackHole (the old macOS 14.0/14.1 fallback) was
/// dropped once the app's minimum system version became 14.2, which is Process Tap's own
/// requirement. Kept as a named type rather than collapsing `activeCaptureBackend` to a `Bool`:
/// it still reads naturally at its call sites (`MenuBarController`'s tooltip suffix) and leaves
/// room if a future capture backend is ever added.
enum CaptureBackend: Int {
    case processTap = 0

    var displayName: String {
        "Process Tap"
    }
}
