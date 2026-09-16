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

        // AppKit's contract is that `reply(toApplicationShouldTerminate:)` — which `onSaved` is —
        // must come after this method has returned `.terminateLater`. `stopRecordingAndSave` can
        // call its completion synchronously (e.g. when there's nothing to import), which would run
        // `finish()`, and so `onSaved()`, before the `return` below executes. Deferring `finish()`
        // itself by one run-loop turn — rather than deferring the call to `stopRecordingAndSave` —
        // guarantees `.terminateLater` is back with the caller first, however the save completes,
        // without changing when `stopRecordingAndSave` itself is invoked.
        stopRecordingAndSave {
            DispatchQueue.main.async {
                finish()
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            guard !didFinish else { return }
            AppLogger.shared.warning("Update: termination timed out waiting for the recording to save")
            finish()
        }

        return .terminateLater
    }
}
