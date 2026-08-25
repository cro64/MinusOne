import AVFoundation
import XCTest
@testable import MinusOne

final class PeakSidecarGenerationTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PeakGen-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Writes a stereo WAV of a full-scale sine so the generated peaks have a known magnitude.
    @discardableResult
    private func writeTone(named name: String, seconds: Double, amplitude: Float = 1.0) throws -> URL {
        let url = directory.appendingPathComponent(name)
        let fileFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 2, interleaved: true)!
        let file = try AVAudioFile(forWriting: url, settings: fileFormat.settings)
        // The buffer takes the file's *processing* format, which AVAudioFile always reports as
        // non-interleaved. Allocating it from the interleaved format instead would make
        // `floatChannelData[1]` an out-of-bounds read rather than a second channel plane.
        let frameCount = AVAudioFrameCount(seconds * 44_100)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        let channels = buffer.floatChannelData!
        for frame in 0..<Int(frameCount) {
            let value = amplitude * sinf(2 * .pi * 440 * Float(frame) / 44_100)
            channels[0][frame] = value
            channels[1][frame] = value
        }
        try file.write(from: buffer)
        return url
    }

    func testItProducesRoughlyOneColumnPerTwoHundredFiftySixFrames() throws {
        let source = try writeTone(named: "tone.wav", seconds: 2)
        let destination = directory.appendingPathComponent("tone.peaks")
        try WaveformPeakGenerator.writeSidecar(from: source, to: destination)

        let reader = try PeakSidecarReader(contentsOf: destination)
        let expected = Int((2.0 * 44_100 / 256).rounded())
        // Within one column either way: the trailing partial column depends on whether the frame
        // count divides evenly by 256.
        XCTAssertLessThanOrEqual(abs(reader.columnCount - expected), 1)
        XCTAssertEqual(reader.availableDuration, 2.0, accuracy: 0.05)
    }

    func testAFullScaleToneReachesFullMagnitude() throws {
        let source = try writeTone(named: "loud.wav", seconds: 1)
        let destination = directory.appendingPathComponent("loud.peaks")
        try WaveformPeakGenerator.writeSidecar(from: source, to: destination)

        let reader = try PeakSidecarReader(contentsOf: destination)
        let loudest = (0..<reader.columnCount).map { reader.column(at: $0).magnitude }.max() ?? 0
        XCTAssertEqual(loudest, 1.0, accuracy: 0.02)
    }

    func testAQuietToneStaysProportionallyQuiet() throws {
        let source = try writeTone(named: "quiet.wav", seconds: 1, amplitude: 0.1)
        let destination = directory.appendingPathComponent("quiet.peaks")
        try WaveformPeakGenerator.writeSidecar(from: source, to: destination)

        let reader = try PeakSidecarReader(contentsOf: destination)
        let loudest = (0..<reader.columnCount).map { reader.column(at: $0).magnitude }.max() ?? 0
        XCTAssertEqual(loudest, 0.1, accuracy: 0.02)
    }

    func testTheHeaderCarriesTheSourceSampleRate() throws {
        let source = try writeTone(named: "rate.wav", seconds: 0.5)
        let destination = directory.appendingPathComponent("rate.peaks")
        try WaveformPeakGenerator.writeSidecar(from: source, to: destination)
        XCTAssertEqual(try PeakSidecarReader(contentsOf: destination).header.sampleRate, 44_100)
    }

    /// Writes a tone whose two channels differ, so the downmix itself is observable.
    @discardableResult
    private func writeAsymmetricTone(named name: String, seconds: Double, left: Float, right: Float) throws -> URL {
        let url = directory.appendingPathComponent(name)
        let fileFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 2, interleaved: true)!
        let file = try AVAudioFile(forWriting: url, settings: fileFormat.settings)
        let frameCount = AVAudioFrameCount(seconds * 44_100)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        let channels = buffer.floatChannelData!
        for frame in 0..<Int(frameCount) {
            channels[0][frame] = left
            channels[1][frame] = right
        }
        try file.write(from: buffer)
        return url
    }

    /// Pins `(L + R) * 0.5` specifically. Every other test in this suite uses identical channels,
    /// where a downmix that simply copied the left channel would be indistinguishable from the
    /// correct one — and the convention matters beyond this file: separation writes stem sidecars
    /// the same way, and stems are normalised against the mix, so a mismatch would draw every
    /// stem lane at the wrong height.
    func testTheDownmixAveragesTheTwoChannelsRatherThanTakingOne() throws {
        let source = try writeAsymmetricTone(named: "asymmetric.wav", seconds: 0.5, left: 1.0, right: 0.0)
        let destination = directory.appendingPathComponent("asymmetric.peaks")
        try WaveformPeakGenerator.writeSidecar(from: source, to: destination)

        let reader = try PeakSidecarReader(contentsOf: destination)
        let loudest = (0..<reader.columnCount).map { reader.column(at: $0).magnitude }.max() ?? 0
        XCTAssertEqual(loudest, 0.5, accuracy: 0.02, "expected (1.0 + 0.0) * 0.5 — a left-channel-only downmix would give 1.0")
    }
}

final class ClipImportSidecarTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImportSidecar-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func writeTone(named name: String, seconds: Double) throws -> URL {
        let url = directory.appendingPathComponent(name)
        let fileFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 2, interleaved: true)!
        let file = try AVAudioFile(forWriting: url, settings: fileFormat.settings)
        // The buffer takes the file's *processing* format, which AVAudioFile always reports as
        // non-interleaved. Allocating it from the interleaved format instead would make
        // `floatChannelData[1]` an out-of-bounds read rather than a second channel plane.
        let frameCount = AVAudioFrameCount(seconds * 44_100)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        let channels = buffer.floatChannelData!
        for frame in 0..<Int(frameCount) {
            let value = sinf(2 * .pi * 220 * Float(frame) / 44_100)
            channels[0][frame] = value
            channels[1][frame] = value
        }
        try file.write(from: buffer)
        return url
    }

    func testItWritesAReadableMixSidecarAndReportsItsName() throws {
        let source = try writeTone(named: "source.wav", seconds: 1)
        let peaksFolder = directory.appendingPathComponent("peaks", isDirectory: true)

        let names = try ClipImportService.writeMixSidecar(sourceURL: source, peaksFolder: peaksFolder)

        XCTAssertEqual(names, ["mix": "mix.peaks"])
        let reader = try PeakSidecarReader(contentsOf: peaksFolder.appendingPathComponent("mix.peaks"))
        XCTAssertGreaterThan(reader.columnCount, 100)
        XCTAssertEqual(reader.availableDuration, 1.0, accuracy: 0.05)
    }

    func testItCreatesThePeaksFolderIfItIsMissing() throws {
        let source = try writeTone(named: "source2.wav", seconds: 0.5)
        let peaksFolder = directory.appendingPathComponent("nested/peaks", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: peaksFolder.path))

        _ = try ClipImportService.writeMixSidecar(sourceURL: source, peaksFolder: peaksFolder)

        XCTAssertTrue(FileManager.default.fileExists(atPath: peaksFolder.appendingPathComponent("mix.peaks").path))
    }
}
