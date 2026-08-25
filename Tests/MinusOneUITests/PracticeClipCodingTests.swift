import XCTest
@testable import MinusOne

/// Guards the on-disk `index.json` migration. A clip written by a build that predates peak
/// sidecars must still decode, or opening the app wipes the user's library.
final class PracticeClipCodingTests: XCTestCase {
    /// Exactly the shape `PracticeClip` encoded before this change.
    private let legacyJSON = """
    [{
      "id": "6C3D9E1A-0000-4000-8000-000000000001",
      "title": "Old Clip",
      "durationSeconds": 123.5,
      "createdAt": "2026-01-02T03:04:05Z",
      "sourceHash": "abc123",
      "sourceFileName": "source.wav",
      "waveformPeaks": [-0.5, 0.5, -0.25, 0.25],
      "stemFileNames": {"vocals": "vocals.caf"},
      "readyDurationSeconds": 123.5,
      "processingFailed": false
    }]
    """

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    func testLegacyClipsWithoutPeakFieldsStillDecode() throws {
        let clips = try decoder().decode([PracticeClip].self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(clips.count, 1)
        XCTAssertEqual(clips[0].title, "Old Clip")
    }

    func testLegacyClipsGetSafeDefaultsForTheNewFields() throws {
        let clip = try decoder().decode([PracticeClip].self, from: Data(legacyJSON.utf8))[0]
        XCTAssertEqual(clip.peakFileNames, [:])
        XCTAssertNil(clip.bpm)
        XCTAssertNil(clip.downbeatOffsetSeconds)
        XCTAssertNil(clip.beatConfidence)
        XCTAssertFalse(clip.isBeatGridUserSet)
    }

    func testNewFieldsSurviveAnEncodeDecodeRoundTrip() throws {
        var clip = PracticeClip(
            title: "New Clip",
            durationSeconds: 10,
            sourceHash: "h",
            sourceFileName: "source.wav",
            waveformPeaks: []
        )
        clip.peakFileNames = ["mix": "mix.peaks", "vocals": "vocals.peaks"]
        clip.bpm = 128
        clip.downbeatOffsetSeconds = 0.42
        clip.beatConfidence = 0.87
        clip.isBeatGridUserSet = true

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let restored = try decoder().decode(PracticeClip.self, from: encoder.encode(clip))

        XCTAssertEqual(restored.peakFileNames, clip.peakFileNames)
        XCTAssertEqual(restored.bpm, 128)
        XCTAssertEqual(restored.downbeatOffsetSeconds, 0.42)
        XCTAssertEqual(restored.beatConfidence, 0.87)
        XCTAssertTrue(restored.isBeatGridUserSet)
    }
}
