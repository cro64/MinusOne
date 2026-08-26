import Foundation

/// Holds the peak sidecars for one clip and serves re-binned columns for a time range.
///
/// Sidecars grow while separation runs, so this is reopened rather than treated as immutable —
/// `reload()` is the single point where new audio becomes visible to the views, and `version` is
/// the signal their render caches key off.
final class PeakStore {
    private let peaksFolder: URL
    private var readers: [PeakTrack: PeakSidecarReader] = [:]
    private var columnCounts: [PeakTrack: Int] = [:]

    /// Bumped whenever a track's column count changes. Lane views include it in their cache key, so
    /// progressive separation invalidates their bitmaps without any view watching the filesystem.
    private(set) var version = 0

    /// Shared across every lane, taken from the mix — see spec §5. Per-lane normalisation would
    /// draw a whisper-quiet stem at the same height as the drums, and lanes you cannot compare
    /// defeat the point of stacking them. Never zero, so callers can divide freely.
    private(set) var normalizationReference: Float = 1

    init(peaksFolder: URL) {
        self.peaksFolder = peaksFolder
        openReaders()
        recomputeNormalization()
    }

    /// Re-opens every sidecar, picking up whatever separation has appended.
    func reload() {
        let previousCounts = columnCounts
        openReaders()
        if columnCounts != previousCounts {
            version += 1
            recomputeNormalization()
        }
    }

    func hasTrack(_ track: PeakTrack) -> Bool { readers[track] != nil }

    /// How much of this track has peaks on disk — less than the clip while separation runs.
    func availableDuration(for track: PeakTrack) -> Double {
        readers[track]?.availableDuration ?? 0
    }

    /// Re-binned columns covering `startTime..<endTime`, exactly `count` of them.
    ///
    /// The requested span is mapped to source indices *before* clamping, and out-of-range indices
    /// read as silence. That is what makes the unseparated tail render as silence rather than the
    /// available audio being stretched across the full width.
    func columns(for track: PeakTrack, from startTime: Double, to endTime: Double, count: Int) -> [PeakColumn] {
        guard count > 0 else { return [] }
        guard let reader = readers[track] else { return Array(repeating: .silent, count: count) }

        let columnsPerSecond = reader.columnsPerSecond
        let first = Int((startTime * columnsPerSecond).rounded(.down))
        let last = Int((endTime * columnsPerSecond).rounded(.up))
        let sourceCount = max(1, last - first)

        let source = reader.columns(from: first, count: sourceCount)
        return PeakBinning.rebin(targetCount: count, sourceCount: sourceCount) { source[$0] }
    }

    // MARK: - Internals

    private func openReaders() {
        readers.removeAll()
        columnCounts.removeAll()
        for track in PeakTrack.all {
            let url = peaksFolder.appendingPathComponent(track.fileName)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                let reader = try PeakSidecarReader(contentsOf: url)
                readers[track] = reader
                columnCounts[track] = reader.columnCount
            } catch {
                // A sidecar that won't open is a missing sidecar: the track reads as silence and
                // the migrator can regenerate it. Never fatal — peaks are derived data.
                AppLogger.shared.warning("Peak sidecar unreadable at \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    private func recomputeNormalization() {
        guard let reader = readers[.mix] else { normalizationReference = 1; return }
        var maximum: Float = 0
        for column in reader.columns(from: 0, count: reader.columnCount) {
            maximum = max(maximum, column.magnitude)
        }
        normalizationReference = maximum > 0 ? maximum : 1
    }
}
