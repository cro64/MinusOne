import AVFoundation
import XCTest
@testable import MinusOne

/// Coverage tests for the compressed-import path. These pass on the current implementation for
/// AAC and ALAC (measured: no mid-file short reads on either), and are here as the regression
/// net for the loop-termination change — the mix sidecar is the shared normalisation reference,
/// so a truncation here scales all five lanes wrongly and nothing downstream would notice.
final class SidecarDecodeLoopTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidecarDecode-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Written and closed inside its own scope: `AVAudioFile` flushes on deallocation, and a
    /// still-live writer makes the read-back open fail with `ExtAudioFileOpenURL` (measured).
    private func writeAudio(
        named name: String,
        seconds: Double,
        channels: Int,
        formatID: AudioFormatID
    ) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try autoreleasepool {
            let settings: [String: Any] = [
                AVFormatIDKey: formatID,
                AVSampleRateKey: 44_100.0,
                AVNumberOfChannelsKey: channels
            ]
            let file = try AVAudioFile(forWriting: url, settings: settings)
            let frames = AVAudioFrameCount(44_100 * seconds)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames))
            buffer.frameLength = frames
            for channel in 0..<Int(file.processingFormat.channelCount) {
                for frame in 0..<Int(frames) {
                    buffer.floatChannelData![channel][frame] = sinf(Float(frame) * 0.05) * 0.8
                }
            }
            try file.write(from: buffer)
        }
        return url
    }

    private func assertSidecarCoversWholeFile(_ source: URL, seconds: Double, line: UInt = #line) throws {
        let destination = folder.appendingPathComponent("\(UUID().uuidString).peaks")
        try WaveformPeakGenerator.writeSidecar(from: source, to: destination)
        let reader = try PeakSidecarReader(contentsOf: destination)
        XCTAssertEqual(reader.availableDuration, seconds, accuracy: 0.1,
                       "sidecar covers \(reader.availableDuration)s of a \(seconds)s file", line: line)
    }

    func testAnAacFileIsCoveredEndToEnd() throws {
        let url = try writeAudio(named: "mono.m4a", seconds: 12.3, channels: 1, formatID: kAudioFormatMPEG4AAC)
        try assertSidecarCoversWholeFile(url, seconds: 12.3)
    }

    /// Stereo goes through the vDSP downmix, and 12.3s is not a whole number of 65,536-frame
    /// chunks — so the last read is short and the loop must not mistake that for a failure.
    func testAStereoAacFileIsCoveredEndToEnd() throws {
        let url = try writeAudio(named: "stereo.m4a", seconds: 12.3, channels: 2, formatID: kAudioFormatMPEG4AAC)
        try assertSidecarCoversWholeFile(url, seconds: 12.3)
    }

    func testAnAppleLosslessFileIsCoveredEndToEnd() throws {
        let url = try writeAudio(named: "alac.m4a", seconds: 7.7, channels: 2, formatID: kAudioFormatAppleLossless)
        try assertSidecarCoversWholeFile(url, seconds: 7.7)
    }

    /// The PCM path Phase 1 shipped, restated here so this suite fails if the loop change breaks
    /// the format every other suite's fixtures use.
    func testAPcmFileIsCoveredEndToEnd() throws {
        let url = try writeAudio(named: "pcm.caf", seconds: 5, channels: 2, formatID: kAudioFormatLinearPCM)
        try assertSidecarCoversWholeFile(url, seconds: 5)
    }

    /// Shorter than one chunk, so the very first read is short. Must still produce a sidecar.
    func testAFileShorterThanOneChunkIsCovered() throws {
        let url = try writeAudio(named: "tiny.caf", seconds: 0.4, channels: 1, formatID: kAudioFormatLinearPCM)
        try assertSidecarCoversWholeFile(url, seconds: 0.4)
    }
}
