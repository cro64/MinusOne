import AVFoundation
import XCTest
@testable import MinusOne

final class BeatDetectionWiringTests: XCTestCase {
    private var root: URL!
    private var libraryStore: ClipLibraryStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BeatWiring-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        libraryStore = ClipLibraryStore(rootURL: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A clip with a real drums file on disk at a known tempo.
    private func clipWithDrums(bpm: Double, seconds: Double = 20) throws -> PracticeClip {
        var clip = PracticeClip(
            title: "Test",
            durationSeconds: seconds,
            sourceHash: "hash",
            sourceFileName: "source.caf",
            waveformPeaks: []
        )
        clip.stemFileNames = [SeparationStem.drums.rawValue: "drums.caf"]
        clip.readyDurationSeconds = seconds
        libraryStore.update(clip)

        let url = libraryStore.stemFileURL(clipID: clip.id, fileName: "drums.caf")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 44_100.0,
            AVNumberOfChannelsKey: 1
        ]
        try autoreleasepool {
            let file = try AVAudioFile(forWriting: url, settings: settings)
            let frames = AVAudioFrameCount(44_100 * seconds)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames))
            buffer.frameLength = frames
            let beat = 60 / bpm * 44_100
            var position = 0.5 * 44_100
            var index = 0
            while position < Double(frames) {
                let start = Int(position)
                let amplitude: Float = index % 4 == 0 ? 0.95 : 0.4
                for offset in 0..<220 where start + offset < Int(frames) {
                    buffer.floatChannelData![0][start + offset] = amplitude * (1 - Float(offset) / 220)
                }
                position += beat
                index += 1
            }
            try file.write(from: buffer)
        }
        return clip
    }

    private func engine() -> OfflineSeparationEngine {
        OfflineSeparationEngine(libraryStore: libraryStore)
    }

    func testItWritesADetectedGridOntoTheClip() throws {
        let clip = try clipWithDrums(bpm: 120)
        let updated = engine().detectBeatGrid(for: clip)

        let bpm = try XCTUnwrap(updated.bpm)
        XCTAssertEqual(bpm, 120, accuracy: 3)
        XCTAssertNotNil(updated.downbeatOffsetSeconds)
        XCTAssertNotNil(updated.beatConfidence)
        XCTAssertFalse(updated.isBeatGridUserSet, "detection must not claim to be a user edit")
    }

    /// Spec §6's explicit rule, and the reason `isBeatGridUserSet` is a separate boolean rather
    /// than a magic confidence value.
    func testItRefusesToOverwriteAUserSetGrid() throws {
        var clip = try clipWithDrums(bpm: 120)
        clip.bpm = 97
        clip.downbeatOffsetSeconds = 1.25
        clip.isBeatGridUserSet = true

        let updated = engine().detectBeatGrid(for: clip)
        XCTAssertEqual(updated.bpm, 97)
        XCTAssertEqual(updated.downbeatOffsetSeconds, 1.25)
        XCTAssertTrue(updated.isBeatGridUserSet)
    }

    /// A clip with no drums stem — separation failed, or it was never separated — must come back
    /// untouched rather than throwing into the separation flow.
    ///
    /// Gives the clip a distinguishable pre-existing grid (as if an earlier detection had already
    /// run) rather than leaving `bpm` at its default `nil`, so the assertion actually requires the
    /// "no drums" guard to fire. With the original `XCTAssertNil(updated.bpm)` on a clip whose
    /// `bpm` started `nil`, the test would still pass even if the guard were deleted, as long as
    /// detection failed for any other reason (e.g. the file-exists check below it) — it never
    /// proved the guard mattered. Asserting equality against a non-nil, non-default value means the
    /// test fails if *anything* in the no-drums path mutates the clip, not just if bpm happens to
    /// end up nil.
    func testAClipWithNoDrumsStemIsLeftAlone() throws {
        var clip = try clipWithDrums(bpm: 120)
        clip.bpm = 87
        clip.downbeatOffsetSeconds = 0.42
        clip.beatConfidence = 3.5
        clip.stemFileNames = [:]

        let updated = engine().detectBeatGrid(for: clip)
        XCTAssertEqual(updated.bpm, 87)
        XCTAssertEqual(updated.downbeatOffsetSeconds, 0.42)
        XCTAssertEqual(updated.beatConfidence, 3.5)
    }

    /// Below the threshold nothing is written, so the deck shows no grid rather than a wrong one.
    func testALowConfidenceDetectionIsDiscarded() throws {
        var clip = try clipWithDrums(bpm: 120)
        // Overwrite the drums with noise.
        let url = libraryStore.stemFileURL(clipID: clip.id, fileName: "drums.caf")
        try FileManager.default.removeItem(at: url)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 44_100.0,
            AVNumberOfChannelsKey: 1
        ]
        try autoreleasepool {
            let file = try AVAudioFile(forWriting: url, settings: settings)
            let frames = AVAudioFrameCount(44_100 * 20)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames))
            buffer.frameLength = frames
            var rng = SystemRandomNumberGenerator()
            for index in 0..<Int(frames) {
                buffer.floatChannelData![0][index] = Float.random(in: -0.5...0.5, using: &rng)
            }
            try file.write(from: buffer)
        }
        clip.bpm = nil

        let updated = engine().detectBeatGrid(for: clip)
        XCTAssertNil(updated.bpm, "a low-confidence detection was written anyway")
    }
}
