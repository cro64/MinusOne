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
    /// File names (relative to the clip's `peaks/` folder) for each track's peak sidecar,
    /// keyed by `PeakTrack.key` — "mix", "vocals", "drums", "bass", "other".
    var peakFileNames: [String: String]
    /// Detected tempo, or a value the user supplied. `nil` until detection has run.
    var bpm: Double?
    /// Offset of the first downbeat from the start of the clip, in seconds.
    var downbeatOffsetSeconds: Double?
    /// Detection confidence. Below the display threshold the grid is suppressed entirely —
    /// a wrong grid is worse than no grid.
    var beatConfidence: Double?
    /// Set when the user edits BPM or drags the downbeat. Detection never runs on, nor
    /// overwrites, a clip where this is true.
    ///
    /// A separate flag rather than a magic value in `beatConfidence`: overloading a numeric
    /// confidence with an out-of-band meaning invites mistaking a genuinely confident detection
    /// for a user edit.
    var isBeatGridUserSet: Bool

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
        processingFailed: Bool = false,
        peakFileNames: [String: String] = [:],
        bpm: Double? = nil,
        downbeatOffsetSeconds: Double? = nil,
        beatConfidence: Double? = nil,
        isBeatGridUserSet: Bool = false
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
        self.peakFileNames = peakFileNames
        self.bpm = bpm
        self.downbeatOffsetSeconds = downbeatOffsetSeconds
        self.beatConfidence = beatConfidence
        self.isBeatGridUserSet = isBeatGridUserSet
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, durationSeconds, createdAt, sourceHash, sourceFileName
        case waveformPeaks, stemFileNames, readyDurationSeconds, processingFailed
        case peakFileNames, bpm, downbeatOffsetSeconds, beatConfidence, isBeatGridUserSet
    }

    /// Hand-written rather than synthesised so clips saved before peak sidecars existed still
    /// decode. The synthesised version uses plain `decode` for non-optionals, which would throw
    /// on every pre-existing `index.json` and take the user's whole library with it.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        durationSeconds = try container.decode(Double.self, forKey: .durationSeconds)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        sourceHash = try container.decode(String.self, forKey: .sourceHash)
        sourceFileName = try container.decode(String.self, forKey: .sourceFileName)
        waveformPeaks = try container.decode([Float].self, forKey: .waveformPeaks)
        stemFileNames = try container.decode([String: String].self, forKey: .stemFileNames)
        readyDurationSeconds = try container.decode(Double.self, forKey: .readyDurationSeconds)
        processingFailed = try container.decode(Bool.self, forKey: .processingFailed)

        peakFileNames = try container.decodeIfPresent([String: String].self, forKey: .peakFileNames) ?? [:]
        bpm = try container.decodeIfPresent(Double.self, forKey: .bpm)
        downbeatOffsetSeconds = try container.decodeIfPresent(Double.self, forKey: .downbeatOffsetSeconds)
        beatConfidence = try container.decodeIfPresent(Double.self, forKey: .beatConfidence)
        isBeatGridUserSet = try container.decodeIfPresent(Bool.self, forKey: .isBeatGridUserSet) ?? false
    }

    var isFullyProcessed: Bool {
        readyDurationSeconds >= durationSeconds - 0.05
    }

    /// Whether this clip's stems can be handed to `StemExportService`.
    ///
    /// All four stems are written by one window loop in `OfflineSeparationEngine`, so they're
    /// never at different readiness — there's no per-stem variant of this.
    var canExportStems: Bool {
        isFullyProcessed && !processingFailed && !stemFileNames.isEmpty
    }
}
