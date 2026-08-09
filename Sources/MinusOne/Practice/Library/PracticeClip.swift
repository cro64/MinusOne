import Foundation

/// A single imported/recorded clip in the Practice Mode library.
struct PracticeClip: Codable, Identifiable, Equatable {
    let id: UUID
    var title: String
    var durationSeconds: Double
    var createdAt: Date
    /// SHA256 of the source audio bytes — keys cache-hit lookup so re-imports skip reprocessing.
    var sourceHash: String
    /// File name (relative to the clip's folder) of the copied original source audio.
    var sourceFileName: String
    /// Downsampled min/max peak pairs (interleaved: min0, max0, min1, max1, ...) for the sidebar thumbnail and detail waveform.
    var waveformPeaks: [Float]
    /// File names (relative to the clip's folder) for each separated stem, once available.
    var stemFileNames: [String: String]
    /// How much of the clip (from the start) has finished separation and is playable.
    var readyDurationSeconds: Double
    var processingFailed: Bool

    init(
        id: UUID = UUID(),
        title: String,
        durationSeconds: Double,
        createdAt: Date = Date(),
        sourceHash: String,
        sourceFileName: String,
        waveformPeaks: [Float],
        stemFileNames: [String: String] = [:],
        readyDurationSeconds: Double = 0,
        processingFailed: Bool = false
    ) {
        self.id = id
        self.title = title
        self.durationSeconds = durationSeconds
        self.createdAt = createdAt
        self.sourceHash = sourceHash
        self.sourceFileName = sourceFileName
        self.waveformPeaks = waveformPeaks
        self.stemFileNames = stemFileNames
        self.readyDurationSeconds = readyDurationSeconds
        self.processingFailed = processingFailed
    }

    var isFullyProcessed: Bool {
        readyDurationSeconds >= durationSeconds - 0.05
    }
}
