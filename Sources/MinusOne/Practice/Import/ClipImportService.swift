import AVFoundation
import AppKit
import CryptoKit
import UniformTypeIdentifiers

/// Handles bringing a new (or previously-seen) audio file into the Practice library:
/// hashing for cache-hit detection, copying into the library, instant raw-waveform generation,
/// and kicking off background offline separation.
final class ClipImportService {
    static let supportedContentTypes: [UTType] = [.audio, .mp3, .wav, .aiff, .mpeg4Audio]
    private static let waveformColumns = 600

    private let libraryStore: ClipLibraryStore
    private let separationEngine: OfflineSeparationEngine
    private let workQueue = DispatchQueue(label: "com.minusone.app.practice-import", qos: .userInitiated)

    init(libraryStore: ClipLibraryStore, separationEngine: OfflineSeparationEngine) {
        self.libraryStore = libraryStore
        self.separationEngine = separationEngine
    }

    func presentOpenPanel(in window: NSWindow?, completion: @escaping (URL?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.supportedContentTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        if let window {
            panel.beginSheetModal(for: window) { response in
                completion(response == .OK ? panel.url : nil)
            }
        } else {
            let response = panel.runModal()
            completion(response == .OK ? panel.url : nil)
        }
    }

    /// - onImported: fired once the clip exists in the library with its raw waveform (before any ML).
    /// - onProgress: fired as offline separation advances `readyDurationSeconds` (and once, immediately, for a full cache hit).
    /// - onFailure: fired if import or separation fails, with a specific, actionable message.
    func importFile(
        at sourceURL: URL,
        onImported: @escaping (PracticeClip) -> Void,
        onProgress: @escaping (PracticeClip) -> Void,
        onFailure: @escaping (Error) -> Void
    ) {
        workQueue.async { [weak self] in
            guard let self else { return }
            do {
                let hash = try Self.sha256(of: sourceURL)

                if let existing = self.libraryStore.clip(forSourceHash: hash) {
                    DispatchQueue.main.async { onImported(existing) }
                    if existing.isFullyProcessed, !existing.processingFailed {
                        DispatchQueue.main.async { onProgress(existing) }
                        return
                    }
                    // Interrupted previous run (e.g. app quit mid-separation) — reprocess from scratch.
                    let existingSourceURL = self.libraryStore.stemFileURL(clipID: existing.id, fileName: existing.sourceFileName)
                    self.separationEngine.process(
                        clip: existing,
                        sourceURL: existingSourceURL,
                        onUpdate: { updated in DispatchQueue.main.async { onProgress(updated) } },
                        onFailure: { _, error in DispatchQueue.main.async { onFailure(error) } }
                    )
                    return
                }

                let clip = try self.copyAndRegister(sourceURL: sourceURL, hash: hash)
                DispatchQueue.main.async { onImported(clip) }

                let copiedSourceURL = self.libraryStore.stemFileURL(clipID: clip.id, fileName: clip.sourceFileName)
                self.separationEngine.process(
                    clip: clip,
                    sourceURL: copiedSourceURL,
                    onUpdate: { updated in DispatchQueue.main.async { onProgress(updated) } },
                    onFailure: { _, error in DispatchQueue.main.async { onFailure(error) } }
                )
            } catch {
                DispatchQueue.main.async { onFailure(error) }
            }
        }
    }

    private func copyAndRegister(sourceURL: URL, hash: String) throws -> PracticeClip {
        let id = UUID()
        let folder = try libraryStore.ensureFolder(forClipID: id)
        let ext = sourceURL.pathExtension
        let sourceFileName = ext.isEmpty ? "source" : "source.\(ext)"
        let destinationURL = folder.appendingPathComponent(sourceFileName)
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        let sourceData = try Data(contentsOf: sourceURL)
        try sourceData.write(to: destinationURL, options: .atomic)

        let file = try AVAudioFile(forReading: destinationURL)
        let duration = Double(file.length) / file.fileFormat.sampleRate
        let peaks = try WaveformPeakGenerator.generatePeaks(url: destinationURL, targetColumns: Self.waveformColumns)

        // Peak generation must not be able to fail an import: the audio is the product, and a
        // missing sidecar is regenerable by `PeakSidecarMigrator.backfill`, which Phase 2 will
        // invoke when a clip is opened.
        var peakFileNames: [String: String] = [:]
        do {
            peakFileNames = try Self.writeMixSidecar(
                sourceURL: destinationURL,
                peaksFolder: libraryStore.peaksFolder(forClipID: id)
            )
        } catch {
            AppLogger.shared.warning("Mix peak sidecar generation failed: \(error.localizedDescription)")
        }

        let title = sourceURL.deletingPathExtension().lastPathComponent
        let clip = PracticeClip(
            id: id,
            title: title,
            durationSeconds: duration,
            sourceHash: hash,
            sourceFileName: sourceFileName,
            waveformPeaks: peaks,
            peakFileNames: peakFileNames
        )
        libraryStore.add(clip)
        return clip
    }

    /// Writes the mix track's peak sidecar for a clip whose source audio is already in the library.
    ///
    /// The mix sidecar exists from import onwards, before separation has produced a single stem,
    /// so the deck has a full-resolution waveform to draw immediately and `PeakStore` has its
    /// normalisation reference.
    static func writeMixSidecar(sourceURL: URL, peaksFolder: URL) throws -> [String: String] {
        try FileManager.default.createDirectory(at: peaksFolder, withIntermediateDirectories: true)
        let track = PeakTrack.mix
        try WaveformPeakGenerator.writeSidecar(
            from: sourceURL,
            to: peaksFolder.appendingPathComponent(track.fileName)
        )
        return [track.key: track.fileName]
    }

    private static func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
