import Foundation

/// Generates peak sidecars for clips that predate the format, from audio already on disk.
///
/// No re-separation and no data loss: the stem files are already there, so this is a decode pass.
/// Clips whose separation never finished get a mix sidecar and nothing else, which is enough for
/// the deck to draw a waveform.
enum PeakSidecarMigrator {
    /// Tracks that have audio on disk but no readable sidecar yet.
    static func missingTracks(for clip: PracticeClip, libraryStore: ClipLibraryStore) -> [PeakTrack] {
        PeakTrack.all.filter { track in
            guard sourceURL(for: track, clip: clip, libraryStore: libraryStore) != nil else { return false }
            let url = libraryStore.peakFileURL(clipID: clip.id, track: track)
            guard FileManager.default.fileExists(atPath: url.path) else { return true }
            return (try? PeakSidecarReader(contentsOf: url)) == nil
        }
    }

    /// Writes every missing sidecar and returns the clip with `peakFileNames` filled in.
    ///
    /// Deliberately non-throwing: a track whose audio is absent is skipped rather than failing the
    /// whole migration, and peaks are derived data that can always be regenerated on the next open.
    /// Safe to interrupt — each sidecar is rewritten from scratch, so a torn file is replaced.
    @discardableResult
    static func backfill(clip: PracticeClip, libraryStore: ClipLibraryStore) -> PracticeClip {
        var updated = clip
        guard let peaksFolder = try? libraryStore.ensurePeaksFolder(forClipID: clip.id) else { return updated }

        for track in PeakTrack.all {
            guard let audioURL = sourceURL(for: track, clip: clip, libraryStore: libraryStore) else { continue }
            let destination = peaksFolder.appendingPathComponent(track.fileName)

            if updated.peakFileNames[track.key] != nil,
               (try? PeakSidecarReader(contentsOf: destination)) != nil {
                continue
            }
            do {
                try WaveformPeakGenerator.writeSidecar(from: audioURL, to: destination)
                updated.peakFileNames[track.key] = track.fileName
            } catch {
                AppLogger.shared.warning("Peak backfill failed for \(track.key): \(error.localizedDescription)")
            }
        }
        return updated
    }

    /// The audio a track's peaks are generated from: the copied source for the mix, the separated
    /// file for a stem. Returns `nil` when that audio isn't on disk.
    private static func sourceURL(
        for track: PeakTrack,
        clip: PracticeClip,
        libraryStore: ClipLibraryStore
    ) -> URL? {
        let fileName: String
        switch track {
        case .mix:
            fileName = clip.sourceFileName
        case .stem(let stem):
            guard let stemFileName = clip.stemFileNames[stem.rawValue] else { return nil }
            fileName = stemFileName
        }
        let url = libraryStore.stemFileURL(clipID: clip.id, fileName: fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
