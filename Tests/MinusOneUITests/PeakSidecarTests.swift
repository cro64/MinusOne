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
