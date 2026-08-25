import AVFoundation
import UniformTypeIdentifiers

/// A container the save panel can offer for a stem.
///
/// The stems on disk are Float32 CAF at the model's sample rate — right for the engine, wrong for
/// anything downstream. Every case here is something a DAW or a phone will open.
enum StemExportFormat: String, CaseIterable {
    case wav
    case aiff
    case m4a

    static let `default`: StemExportFormat = .wav

    var fileExtension: String { rawValue }

    var displayName: String {
        switch self {
        case .wav: return "WAV · 16-bit"
        case .aiff: return "AIFF · 16-bit"
        case .m4a: return "M4A · AAC"
        }
    }

    var contentType: UTType {
        switch self {
        case .wav: return .wav
        case .aiff: return .aiff
        case .m4a: return .mpeg4Audio
        }
    }

    /// `AVAudioFile` infers the container from the URL's extension, so these settings only have to
    /// describe the encoding.
    func settings(sampleRate: Double, channelCount: UInt32) -> [String: Any] {
        switch self {
        case .wav, .aiff:
            return [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channelCount,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: self == .aiff,
                AVLinearPCMIsNonInterleaved: false
            ]
        case .m4a:
            return [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channelCount
            ]
        }
    }
}

enum StemExportNaming {
    /// "<Clip title> — <Stem>.<ext>", with the two characters a macOS file name can't carry
    /// folded to hyphens. The title is user-entered, so this can't be skipped.
    static func suggestedFileName(
        clipTitle: String,
        stem: SeparationStem,
        format: StemExportFormat
    ) -> String {
        let cleaned = sanitize(clipTitle)
        let base = cleaned.isEmpty ? stem.displayName : "\(cleaned) — \(stem.displayName)"
        return "\(base).\(format.fileExtension)"
    }

    /// Swaps the extension when the save panel's format popup changes.
    ///
    /// Only a known audio extension is replaced: a title like "Take 2.5 — Bass" has a trailing
    /// component that looks like an extension, and `deletingPathExtension` would eat part of the
    /// name.
    static func replacingExtension(in fileName: String, with format: StemExportFormat) -> String {
        let known = Set(StemExportFormat.allCases.map(\.fileExtension) + ["caf"])
        let current = (fileName as NSString).pathExtension.lowercased()
        let base = known.contains(current)
            ? (fileName as NSString).deletingPathExtension
            : fileName
        return "\(base).\(format.fileExtension)"
    }

    private static func sanitize(_ title: String) -> String {
        title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
