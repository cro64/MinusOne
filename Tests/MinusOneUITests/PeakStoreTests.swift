import XCTest
@testable import MinusOne

final class PeakStoreTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("PeakStore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Writes `seconds` of constant-magnitude peaks for one track.
    private func writeTrack(_ track: PeakTrack, seconds: Double, magnitude: Float) throws {
        let writer = try PeakSidecarWriter(url: folder.appendingPathComponent(track.fileName), sampleRate: 44_100)
        let sampleCount = Int(seconds * 44_100)
        try writer.append([Float](repeating: magnitude, count: sampleCount))
        try writer.finish()
    }

    func testATrackWithNoSidecarReadsAsSilence() throws {
        try writeTrack(.mix, seconds: 1, magnitude: 0.5)
        let store = PeakStore(peaksFolder: folder)
        XCTAssertFalse(store.hasTrack(.stem(.vocals)))
        let columns = store.columns(for: .stem(.vocals), from: 0, to: 1, count: 10)
        XCTAssertEqual(columns, Array(repeating: .silent, count: 10))
    }

    func testItReturnsExactlyTheRequestedColumnCount() throws {
        try writeTrack(.mix, seconds: 4, magnitude: 0.5)
        let store = PeakStore(peaksFolder: folder)
        XCTAssertEqual(store.columns(for: .mix, from: 0, to: 4, count: 226).count, 226)
        XCTAssertEqual(store.columns(for: .mix, from: 1, to: 1.2, count: 40).count, 40)
    }

    /// Normalisation comes from the mix, so a quiet stem stays visibly quieter than a loud one
    /// instead of each being stretched to full height.
    func testNormalisationReferenceComesFromTheMix() throws {
        try writeTrack(.mix, seconds: 1, magnitude: 0.9)
        try writeTrack(.stem(.bass), seconds: 1, magnitude: 0.2)
        let store = PeakStore(peaksFolder: folder)
        XCTAssertEqual(store.normalizationReference, 0.9, accuracy: 1e-3)
    }

    func testTheNormalisationReferenceIsNeverZero() {
        let store = PeakStore(peaksFolder: folder)
        XCTAssertGreaterThan(store.normalizationReference, 0)
    }

    /// The unseparated tail: asking beyond what has been written yields silence rather than
    /// stretching the available audio across the whole width.
    func testTimeBeyondTheWrittenRegionIsSilent() throws {
        try writeTrack(.stem(.drums), seconds: 2, magnitude: 0.8)
        let store = PeakStore(peaksFolder: folder)
        let columns = store.columns(for: .stem(.drums), from: 5, to: 6, count: 8)
        XCTAssertEqual(columns, Array(repeating: .silent, count: 8))
    }

    func testAHalfWrittenTrackKeepsItsEarlyColumnsLoud() throws {
        try writeTrack(.stem(.drums), seconds: 2, magnitude: 0.8)
        let store = PeakStore(peaksFolder: folder)
        let columns = store.columns(for: .stem(.drums), from: 0, to: 2, count: 16)
        XCTAssertTrue(columns.allSatisfy { $0.magnitude > 0.5 })
    }

    func testAvailableDurationTracksWhatIsOnDisk() throws {
        try writeTrack(.mix, seconds: 3, magnitude: 0.4)
        let store = PeakStore(peaksFolder: folder)
        XCTAssertEqual(store.availableDuration(for: .mix), 3.0, accuracy: 0.05)
        XCTAssertEqual(store.availableDuration(for: .stem(.other)), 0)
    }

    /// The cache-invalidation signal Phase 2's lane views key off.
    func testReloadBumpsTheVersionWhenATrackGrows() throws {
        try writeTrack(.mix, seconds: 1, magnitude: 0.4)
        let store = PeakStore(peaksFolder: folder)
        let before = store.version

        try writeTrack(.mix, seconds: 3, magnitude: 0.4)
        store.reload()
        XCTAssertGreaterThan(store.version, before)
    }

    func testReloadDoesNotBumpTheVersionWhenNothingChanged() throws {
        try writeTrack(.mix, seconds: 1, magnitude: 0.4)
        let store = PeakStore(peaksFolder: folder)
        let before = store.version
        store.reload()
        XCTAssertEqual(store.version, before)
    }
}
