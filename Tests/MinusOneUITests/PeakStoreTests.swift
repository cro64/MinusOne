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

    /// The case the whole design turns on: one request covering both written and unwritten audio.
    ///
    /// If the source range were clamped to what exists before re-binning, the 2 seconds of real
    /// audio would be stretched across all 16 columns and every one of them would read loud. The
    /// unclamped mapping instead puts real data in the first half and silence in the second,
    /// which is what makes a clip's not-yet-separated tail render as an empty lane rather than a
    /// smeared copy of its beginning.
    func testARequestSpanningTheWrittenBoundaryIsLoudThenSilent() throws {
        try writeTrack(.stem(.drums), seconds: 2, magnitude: 0.8)
        let store = PeakStore(peaksFolder: folder)

        // Written region is 0..2s; ask for 0..4s so the back half has nothing behind it.
        let columns = store.columns(for: .stem(.drums), from: 0, to: 4, count: 16)
        XCTAssertEqual(columns.count, 16)

        for (index, column) in columns.prefix(8).enumerated() {
            XCTAssertGreaterThan(column.magnitude, 0.5, "column \(index) covers written audio and should be loud")
        }
        for (offset, column) in columns.suffix(8).enumerated() {
            XCTAssertEqual(column, .silent, "column \(offset + 8) covers unwritten audio and should be silent")
        }
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

final class SeparationDownmixTests: XCTestCase {
    func testItAveragesTheTwoChannels() {
        let left: [Float] = [1.0, 0.5, 0.0, -1.0]
        let right: [Float] = [0.0, 0.5, 1.0, -1.0]
        let mono = OfflineSeparationEngine.monoDownmix(left: left, right: right, range: 0..<4)
        XCTAssertEqual(mono, [0.5, 0.5, 0.5, -1.0])
    }

    /// The flush loop hands it a window part-way through the buffers, not the whole thing.
    func testItReadsOnlyTheRequestedRange() {
        let left: [Float] = [0, 0, 1.0, 1.0, 0, 0]
        let right: [Float] = [0, 0, 1.0, 1.0, 0, 0]
        let mono = OfflineSeparationEngine.monoDownmix(left: left, right: right, range: 2..<4)
        XCTAssertEqual(mono, [1.0, 1.0])
    }

    func testAnEmptyRangeProducesNoSamples() {
        let mono = OfflineSeparationEngine.monoDownmix(left: [1, 2], right: [3, 4], range: 1..<1)
        XCTAssertTrue(mono.isEmpty)
    }

    /// Matches `WaveformPeakGenerator`'s downmix, so the mix and stem sidecars are comparable and
    /// the shared normalisation reference means what it says.
    func testItMatchesTheGeneratorsDownmixConvention() {
        let left: [Float] = [0.8, -0.4]
        let right: [Float] = [0.2, -0.6]
        let mono = OfflineSeparationEngine.monoDownmix(left: left, right: right, range: 0..<2)
        XCTAssertEqual(mono[0], (0.8 + 0.2) * 0.5, accuracy: 1e-6)
        XCTAssertEqual(mono[1], (-0.4 + -0.6) * 0.5, accuracy: 1e-6)
    }
}
