import XCTest
@testable import MinusOne

final class PeakSidecarTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PeakSidecarTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func url(_ name: String = "track.peaks") -> URL {
        directory.appendingPathComponent(name)
    }

    func testHeaderRoundTrips() throws {
        let header = PeakSidecar.Header(sampleRate: 44_100, framesPerColumn: 256)
        let decoded = try PeakSidecar.decodeHeader(PeakSidecar.encodeHeader(header))
        XCTAssertEqual(decoded, header)
    }

    func testHeaderIsExactlyTwentyBytes() {
        let data = PeakSidecar.encodeHeader(.init(sampleRate: 44_100, framesPerColumn: 256))
        XCTAssertEqual(data.count, PeakSidecar.headerByteCount)
        XCTAssertEqual(data.count, 20)
    }

    func testAFileWithTheWrongMagicIsRejected() throws {
        var data = PeakSidecar.encodeHeader(.init(sampleRate: 44_100, framesPerColumn: 256))
        data[0] = 0x00
        try data.write(to: url())
        XCTAssertThrowsError(try PeakSidecarReader(contentsOf: url()))
    }

    func testAFileShorterThanTheHeaderIsRejected() throws {
        try Data([0x4D, 0x31]).write(to: url())
        XCTAssertThrowsError(try PeakSidecarReader(contentsOf: url()))
    }

    /// The property the whole progressive-separation story rests on.
    func testColumnCountComesFromFileSizeNotAHeaderField() throws {
        var data = PeakSidecar.encodeHeader(.init(sampleRate: 44_100, framesPerColumn: 256))
        for index in 0..<7 {
            data.append(PeakSidecar.encodeColumn(
                PeakColumn(minimum: -Float(index) / 10, maximum: Float(index) / 10, rms: Float(index) / 20)
            ))
        }
        try data.write(to: url())
        XCTAssertEqual(try PeakSidecarReader(contentsOf: url()).columnCount, 7)
    }

    func testTrailingPartialColumnBytesAreIgnored() throws {
        var data = PeakSidecar.encodeHeader(.init(sampleRate: 44_100, framesPerColumn: 256))
        data.append(PeakSidecar.encodeColumn(PeakColumn(minimum: -0.5, maximum: 0.5, rms: 0.25)))
        data.append(contentsOf: [0x01, 0x02, 0x03])   // a torn write
        try data.write(to: url())
        XCTAssertEqual(try PeakSidecarReader(contentsOf: url()).columnCount, 1)
    }

    func testColumnValuesSurviveTheInt16RoundTrip() throws {
        var data = PeakSidecar.encodeHeader(.init(sampleRate: 44_100, framesPerColumn: 256))
        data.append(PeakSidecar.encodeColumn(PeakColumn(minimum: -0.75, maximum: 0.5, rms: 0.25)))
        try data.write(to: url())
        let column = try PeakSidecarReader(contentsOf: url()).column(at: 0)
        XCTAssertEqual(column.minimum, -0.75, accuracy: 1e-4)
        XCTAssertEqual(column.maximum, 0.5, accuracy: 1e-4)
        XCTAssertEqual(column.rms, 0.25, accuracy: 1e-4)
    }

    /// Reading past the written region must be silent, not a crash — the unseparated tail relies
    /// on exactly this.
    func testReadingOutOfRangeReturnsSilence() throws {
        var data = PeakSidecar.encodeHeader(.init(sampleRate: 44_100, framesPerColumn: 256))
        data.append(PeakSidecar.encodeColumn(PeakColumn(minimum: -1, maximum: 1, rms: 0.5)))
        try data.write(to: url())
        let reader = try PeakSidecarReader(contentsOf: url())
        XCTAssertEqual(reader.column(at: 5), .silent)
        XCTAssertEqual(reader.column(at: -1), .silent)
    }

    func testAvailableDurationFollowsTheColumnCount() throws {
        var data = PeakSidecar.encodeHeader(.init(sampleRate: 44_100, framesPerColumn: 256))
        for _ in 0..<172 {
            data.append(PeakSidecar.encodeColumn(PeakColumn(minimum: -0.1, maximum: 0.1, rms: 0.05)))
        }
        try data.write(to: url())
        XCTAssertEqual(try PeakSidecarReader(contentsOf: url()).availableDuration, 1.0, accuracy: 0.01)
    }
}

final class PeakSidecarWriterTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PeakSidecarWriterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

    private func ramp(_ count: Int) -> [Float] {
        (0..<count).map { sinf(Float($0) * 0.01) }
    }

    func testTwoWholeColumnsOfSamplesProduceTwoColumns() throws {
        let writer = try PeakSidecarWriter(url: url("a.peaks"), sampleRate: 44_100)
        try writer.append(ramp(512))
        try writer.finish()
        XCTAssertEqual(try PeakSidecarReader(contentsOf: url("a.peaks")).columnCount, 2)
    }

    /// Nothing is emitted for a partial column until `finish()`, so a reader mid-separation sees
    /// only fully-covered columns.
    func testAPartialColumnIsNotEmittedUntilFinish() throws {
        let writer = try PeakSidecarWriter(url: url("b.peaks"), sampleRate: 44_100)
        try writer.append(ramp(300))
        XCTAssertEqual(try PeakSidecarReader(contentsOf: url("b.peaks")).columnCount, 1)
        try writer.finish()
        XCTAssertEqual(try PeakSidecarReader(contentsOf: url("b.peaks")).columnCount, 2)
    }

    /// The alignment guarantee: how the samples are chopped up across appends must not change
    /// a single byte of the output.
    func testRaggedAppendsProduceByteIdenticalOutputToOneBigAppend() throws {
        let samples = ramp(2_000)

        let single = try PeakSidecarWriter(url: url("single.peaks"), sampleRate: 44_100)
        try single.append(samples)
        try single.finish()

        let ragged = try PeakSidecarWriter(url: url("ragged.peaks"), sampleRate: 44_100)
        var offset = 0
        for chunk in [7, 100, 1, 300, 512, 80, 1_000] {
            let end = min(offset + chunk, samples.count)
            guard offset < end else { break }
            try ragged.append(samples[offset..<end])
            offset = end
        }
        if offset < samples.count { try ragged.append(samples[offset...]) }
        try ragged.finish()

        XCTAssertEqual(try Data(contentsOf: url("single.peaks")), try Data(contentsOf: url("ragged.peaks")))
    }

    func testWrittenExtremesSurviveTheRoundTrip() throws {
        var samples = [Float](repeating: 0, count: 256)
        samples[10] = -0.8
        samples[20] = 0.6
        let writer = try PeakSidecarWriter(url: url("c.peaks"), sampleRate: 44_100)
        try writer.append(samples)
        try writer.finish()

        let column = try PeakSidecarReader(contentsOf: url("c.peaks")).column(at: 0)
        XCTAssertEqual(column.minimum, -0.8, accuracy: 1e-3)
        XCTAssertEqual(column.maximum, 0.6, accuracy: 1e-3)
        XCTAssertGreaterThan(column.rms, 0)
        XCTAssertLessThan(column.rms, 0.8)
    }

    func testTheHeaderRecordsTheRateAndColumnSize() throws {
        let writer = try PeakSidecarWriter(url: url("d.peaks"), sampleRate: 48_000, framesPerColumn: 128)
        try writer.append(ramp(128))
        try writer.finish()

        let header = try PeakSidecarReader(contentsOf: url("d.peaks")).header
        XCTAssertEqual(header.sampleRate, 48_000)
        XCTAssertEqual(header.framesPerColumn, 128)
    }

    func testFinishingTwiceIsHarmless() throws {
        let writer = try PeakSidecarWriter(url: url("e.peaks"), sampleRate: 44_100)
        try writer.append(ramp(256))
        try writer.finish()
        XCTAssertNoThrow(try writer.finish())
    }

    /// Pins root-mean-square specifically. 128 samples at 1.0 followed by 128 at 0.0 gives
    /// RMS = sqrt(0.5) ≈ 0.7071, where a plain mean would give 0.5 and taking the maximum would
    /// give 1.0 — all three outcomes are distinguishable, which a constant-amplitude block
    /// could not achieve.
    func testRMSIsRootMeanSquareNotTheMeanOrTheMaximum() throws {
        var samples = [Float](repeating: 1.0, count: 128)
        samples += [Float](repeating: 0.0, count: 128)

        let writer = try PeakSidecarWriter(url: url("rms.peaks"), sampleRate: 44_100)
        try writer.append(samples)
        try writer.finish()

        let column = try PeakSidecarReader(contentsOf: url("rms.peaks")).column(at: 0)
        XCTAssertEqual(column.rms, 0.7071, accuracy: 1e-3)
    }
}
