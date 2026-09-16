import AppKit

/// Quitting used to drop a take: `ClipRecorder` only finishes a file when something stops it, and
/// `applicationWillTerminate` doesn't. That cost a real recording when Sparkle installed a postponed
/// update on quit, so termination now waits for the take to reach the library.
final class RecordingTerminationGuard {
    var isRecording: () -> Bool = { false }
    var stopRecordingAndSave: (_ completion: @escaping () -> Void) -> Void = { $0() }
    /// Safety net: if importing stalls, quitting still happens rather than hanging forever.
    var timeout: TimeInterval = 5

    func terminationReply(onSaved: @escaping () -> Void) -> NSApplication.TerminateReply {
        guard isRecording() else { return .terminateNow }

        AppLogger.shared.info("Update: termination waiting for the recording to save")

        var didFinish = false
        let finish = {
            guard !didFinish else { return }
            didFinish = true
            onSaved()
        }

        stopRecordingAndSave {
            finish()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            guard !didFinish else { return }
            AppLogger.shared.warning("Update: termination timed out waiting for the recording to save")
            finish()
        }

        return .terminateLater
    }
}
