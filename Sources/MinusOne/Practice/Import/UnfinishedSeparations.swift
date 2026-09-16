import Foundation

/// Selects clips that were imported but never finished separating — e.g. the app quit mid-run
/// (`RecordingTerminationGuard` rescues the recording itself, but separation of that rescued take
/// never resumes on its own) — so a later launch can pick the work back up.
enum UnfinishedSeparations {
    /// Clips that are not fully processed, not marked failed, and have a source file to
    /// reprocess from. A failed clip is left for the user to re-import explicitly rather than
    /// being silently retried forever; a clip with no source file name has nothing to resume from.
    static func needingResume(_ clips: [PracticeClip]) -> [PracticeClip] {
        clips.filter { clip in
            !clip.isFullyProcessed && !clip.processingFailed && !clip.sourceFileName.isEmpty
        }
    }
}
