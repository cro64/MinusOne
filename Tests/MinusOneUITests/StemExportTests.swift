import AVFoundation
import XCTest
@testable import MinusOne

/// Pure-logic cover for stem export. Unlike `MinusOneUITests`, nothing here launches the app —
/// these run under plain `swift test`.
final class StemExportTests: XCTestCase {
    private func clip(
        title: String = "Clip",
        duration: Double = 100,
        ready: Double = 100,
        failed: Bool = false,
        stems: [String: String] = ["vocals": "vocals.caf"]
    ) -> PracticeClip {
        PracticeClip(
            title: title,
            durationSeconds: duration,
            sourceHash: "hash",
            sourceFileName: "source.wav",
            waveformPeaks: [],
            stemFileNames: stems,
            readyDurationSeconds: ready,
            processingFailed: failed
        )
    }

    func testStemsAreNotExportableWhileSeparationIsStillRunning() {
        XCTAssertFalse(clip(duration: 100, ready: 40).canExportStems)
    }

    func testStemsAreExportableOnceSeparationFinishes() {
        XCTAssertTrue(clip(duration: 100, ready: 100).canExportStems)
    }

    func testStemsAreNotExportableWhenProcessingFailed() {
        XCTAssertFalse(clip(failed: true).canExportStems)
    }

    /// A clip can read as fully processed before any writer has been registered — a zero-length
    /// clip satisfies `readyDurationSeconds >= durationSeconds` with an empty stem map.
    func testStemsAreNotExportableWithNoStemFilesOnDisk() {
        XCTAssertFalse(clip(stems: [:]).canExportStems)
    }

    // MARK: - Suggested file names

    func testSuggestedNameJoinsClipTitleAndStemWithTheFormatExtension() {
        XCTAssertEqual(
            StemExportNaming.suggestedFileName(clipTitle: "Blue Monday", stem: .bass, format: .wav),
            "Blue Monday — Bass.wav"
        )
    }

    /// A clip title is user-entered and free-form, so it can carry the two characters HFS+ won't
    /// take in a file name. Left in, the save panel silently rejects the name.
    func testSuggestedNameStripsPathSeparatorsFromTheClipTitle() {
        XCTAssertEqual(
            StemExportNaming.suggestedFileName(clipTitle: "AC/DC: Live", stem: .drums, format: .wav),
            "AC-DC- Live — Drums.wav"
        )
    }

    func testSuggestedNameFallsBackWhenTheTitleIsBlank() {
        XCTAssertEqual(
            StemExportNaming.suggestedFileName(clipTitle: "   ", stem: .vocals, format: .aiff),
            "Vocals.aiff"
        )
    }

    // MARK: - Format switching in the save panel

    func testChangingFormatRewritesTheExtension() {
        XCTAssertEqual(
            StemExportNaming.replacingExtension(in: "Blue Monday — Bass.wav", with: .m4a),
            "Blue Monday — Bass.m4a"
        )
    }

    /// A title like "Take 2.5" leaves a trailing component that looks like an extension but isn't.
    /// Replacing blindly would turn it into "Take 2.m4a" and lose the rest of the name.
    func testChangingFormatOnlyReplacesAKnownAudioExtension() {
        XCTAssertEqual(
            StemExportNaming.replacingExtension(in: "Take 2.5 — Bass.wav", with: .m4a),
            "Take 2.5 — Bass.m4a"
        )
    }

    // MARK: - Transcoding

    /// Writes a real Float32 CAF shaped like `OfflineSeparationEngine`'s stem output.
    private func makeSourceStem(frames: AVAudioFrameCount = 4410, sampleRate: Double = 44100) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("stem-\(UUID().uuidString).caf")
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 2,
            interleaved: true
        )!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        // `AVAudioFile.processingFormat` is always deinterleaved Float32 even when the file's own
        // settings are interleaved, and `write(from:)` rejects any other format with a bare -50.
        // Same split `OfflineSeparationEngine` keeps between its target and file formats.
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)!
        buffer.frameLength = frames
        let channels = buffer.floatChannelData!
        for frame in 0..<Int(frames) {
            let value = sin(Float(frame) * 0.05) * 0.5
            channels[0][frame] = value
            channels[1][frame] = value
        }
        try file.write(from: buffer)
        return url
    }

    func testExportingToWAVPreservesSampleRateChannelsAndLength() throws {
        let source = try makeSourceStem()
        let destination = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("out-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: destination) }

        try StemExportService.export(source: source, to: destination, format: .wav)

        let result = try AVAudioFile(forReading: destination)
        XCTAssertEqual(result.fileFormat.sampleRate, 44100)
        XCTAssertEqual(result.fileFormat.channelCount, 2)
        XCTAssertEqual(result.length, 4410)
    }

    /// The point of exporting at all: the on-disk stem is Float32, and a 16-bit file is a quarter
    /// the size and openable everywhere.
    func testExportingToWAVWritesSixteenBitIntegerSamples() throws {
        let source = try makeSourceStem()
        let destination = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("out-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: destination) }

        try StemExportService.export(source: source, to: destination, format: .wav)

        // The file has to outlive the read: `streamDescription` is a pointer owned by the
        // format, which is owned by the file, so dereferencing it off a temporary reads freed
        // memory and reports zeroes.
        let result = try AVAudioFile(forReading: destination)
        let description = result.fileFormat.streamDescription.pointee
        XCTAssertEqual(description.mBitsPerChannel, 16)
        XCTAssertEqual(description.mFormatFlags & kAudioFormatFlagIsFloat, 0)
    }

    func testExportingToM4AProducesAReadableFileOfTheSameDuration() throws {
        let source = try makeSourceStem()
        let destination = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("out-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: destination) }

        try StemExportService.export(source: source, to: destination, format: .m4a)

        let result = try AVAudioFile(forReading: destination)
        // AAC pads to whole packets, so the length only matches approximately.
        let seconds = Double(result.length) / result.fileFormat.sampleRate
        XCTAssertEqual(seconds, 0.1, accuracy: 0.05)
    }

    func testExportingAMissingSourceThrows() {
        let missing = URL(fileURLWithPath: "/nonexistent/vocals.caf")
        let destination = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("out-\(UUID().uuidString).wav")
        XCTAssertThrowsError(try StemExportService.export(source: missing, to: destination, format: .wav))
    }

    // MARK: - Save panel wiring

    func testPanelOpensWithTheSuggestedNameAndMatchingContentType() {
        let export = StemExportPanel(clipTitle: "Blue Monday", stem: .vocals, format: .wav)
        XCTAssertEqual(export.panel.nameFieldStringValue, "Blue Monday — Vocals.wav")
        XCTAssertEqual(export.panel.allowedContentTypes, [.wav])
    }

    /// The panel appends the extension from `allowedContentTypes` itself, so the popup has to move
    /// both together — change only the name and the panel silently re-appends the old extension.
    func testSelectingAFormatMovesBothTheNameAndTheContentType() {
        let export = StemExportPanel(clipTitle: "Blue Monday", stem: .vocals, format: .wav)

        export.selectFormat(.m4a)

        XCTAssertEqual(export.format, .m4a)
        XCTAssertEqual(export.panel.nameFieldStringValue, "Blue Monday — Vocals.m4a")
        XCTAssertEqual(export.panel.allowedContentTypes, [.mpeg4Audio])
    }

    /// Someone who renames the file in the panel and then switches format should keep their name.
    func testSelectingAFormatKeepsAnEditedFileName() {
        let export = StemExportPanel(clipTitle: "Blue Monday", stem: .vocals, format: .wav)
        export.panel.nameFieldStringValue = "for the band.wav"

        export.selectFormat(.aiff)

        XCTAssertEqual(export.panel.nameFieldStringValue, "for the band.aiff")
    }
}