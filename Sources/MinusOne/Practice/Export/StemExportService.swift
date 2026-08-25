import AVFoundation

enum StemExportError: LocalizedError {
    case sourceUnreadable(URL)
    case conversionFailed(String)

    var errorDescription: String? {
        switch self {
        case .sourceUnreadable(let url):
            return "Couldn't read the separated stem at \(url.lastPathComponent)."
        case .conversionFailed(let detail):
            return detail
        }
    }
}

/// Transcodes a separated stem out of the library and into something portable.
///
/// Separation already wrote every stem to the clip's folder as Float32 CAF, so exporting never
/// re-runs the model — it's a read-convert-write over a file that's already there.
enum StemExportService {
    /// Blocking. Callers run this off the main thread; a few seconds of audio converts in well
    /// under a second, but the file is arbitrarily long.
    static func export(source: URL, to destination: URL, format: StemExportFormat) throws {
        let input: AVAudioFile
        do {
            input = try AVAudioFile(forReading: source)
        } catch {
            throw StemExportError.sourceUnreadable(source)
        }

        let settings = format.settings(
            sampleRate: input.fileFormat.sampleRate,
            channelCount: input.fileFormat.channelCount
        )

        // `AVAudioFile(forWriting:)` truncates, but only if it can open the path at all — a stale
        // file from a previous export of the same name is replaced by the save panel before we
        // get here.
        let output = try AVAudioFile(forWriting: destination, settings: settings)

        let readFormat = input.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: readFormat, frameCapacity: chunkFrames) else {
            throw StemExportError.conversionFailed("Couldn't allocate an export buffer.")
        }

        while input.framePosition < input.length {
            try input.read(into: buffer, frameCount: chunkFrames)
            if buffer.frameLength == 0 { break }
            try output.write(from: buffer)
        }
    }

    /// ~0.2 s at 44.1 kHz. Small enough that a long clip never holds the whole file in memory,
    /// large enough that the write loop isn't syscall-bound.
    private static let chunkFrames: AVAudioFrameCount = 8192
}
