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
    /// fully unchanged, with nothing thrown into the separation flow.
    ///
    /// Gives the clip a distinguishable pre-existing grid (as if an earlier detection had already
    /// run) rather than leaving `bpm` at its default `nil`, so the assertion is not vacuous: the
    /// original `XCTAssertNil(updated.bpm)` on a clip whose `bpm` started `nil` would hold before
    /// `detectBeatGrid` even runs, so it never proved anything.
    ///
    /// What this pins is the *composite* behaviour — no mutation without a readable drums file —
    /// not any single guard in isolation. `detectBeatGrid` has three deliberately redundant layers:
    /// the `stemFileNames` lookup, the `fileExists` check, and the `catch` around `AVAudioFile`.
    /// That redundancy is the intended design — detection must never be able to fail separation —
    /// so this test is written against the chain's net effect rather than contrived to isolate one
    /// link. With `stemFileNames` empty it is the first layer that returns; the empty-file-name
    /// case below exercises the other two.
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

    /// A recorded drums file name that is present but empty, which is the case the docstring above
    /// used to describe from reasoning alone. It is worth an actual test because the path is
    /// counter-intuitive: `stemFileURL` appends an empty component and so resolves back to the
    /// clip's stem *directory*, which exists, so `fileExists` reports true and the
    /// `stemFileNames` and `fileExists` layers both wave it through. Only the `catch` around
    /// `AVAudioFile(forReading:)` stops it.
    ///
    /// Verified directly rather than reasoned: for a temporary directory D,
    /// `D.appendingPathComponent("")` standardises to D, `fileExists(atPath:)` on it returns true,
    /// and `AVAudioFile(forReading:)` throws `com.apple.coreaudio.avfaudio error 2003334207`.
    func testAClipWhoseDrumsFileNameIsEmptyIsAlsoLeftAlone() throws {
        var clip = try clipWithDrums(bpm: 120)
        clip.bpm = 87
        clip.downbeatOffsetSeconds = 0.42
        clip.beatConfidence = 3.5
        clip.stemFileNames = [SeparationStem.drums.rawValue: ""]

        // The premise: this really does reach the layers past the `stemFileNames` lookup.
        let url = libraryStore.stemFileURL(clipID: clip.id, fileName: "")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "an empty file name no longer resolves to the stem directory, so this case "
                      + "returns at `fileExists` and no longer exercises the `AVAudioFile` catch")

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

    /// Spec §6, reached through the separation flush path this time rather than `detectBeatGrid`
    /// directly: `workingClip` is a snapshot taken before separation began, so if the user sets a
    /// tempo mid-separation the *store* holds their edit while the snapshot still doesn't know
    /// about it. Persisting the stale snapshot as-is would silently discard that edit.
    func testItRefreshesTheBeatGridFromTheStoreBeforePersisting() throws {
        let clip = try clipWithDrums(bpm: 120)

        // The store holds a user-set grid — as if the user had edited the tempo mid-separation.
        var userSet = clip
        userSet.bpm = 140
        userSet.downbeatOffsetSeconds = 0.33
        userSet.beatConfidence = 8
        userSet.isBeatGridUserSet = true
        libraryStore.update(userSet)

        // `workingClip` is the pre-edit snapshot: no tempo, not user-set.
        var staleSnapshot = clip
        staleSnapshot.bpm = nil
        staleSnapshot.isBeatGridUserSet = false

        let merged = engine().withCurrentBeatGrid(staleSnapshot)

        XCTAssertEqual(merged.bpm, 140, "the store's user-set tempo was discarded")
        XCTAssertEqual(merged.downbeatOffsetSeconds, 0.33)
        XCTAssertEqual(merged.beatConfidence, 8)
        XCTAssertTrue(merged.isBeatGridUserSet, "a hand-set grid must not be reported as undetected")
        // Everything else stays the snapshot's own — this only refreshes the four beat-grid fields.
        XCTAssertEqual(merged.id, staleSnapshot.id)
        XCTAssertEqual(merged.stemFileNames, staleSnapshot.stemFileNames)
    }
}
