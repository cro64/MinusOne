import XCTest
@testable import MinusOne

final class PeakBulkReadTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("PeakBulkRead-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A ramp, so every column differs from its neighbours and an off-by-one in the pointer
    /// arithmetic cannot hide behind constant data.
    @discardableResult
    private func writeRamp(columns: Int) throws -> URL {
        let url = folder.appendingPathComponent("ramp.peaks")
        let writer = try PeakSidecarWriter(url: url, sampleRate: 44_100)
        var samples: [Float] = []
        samples.reserveCapacity(columns * PeakSidecar.defaultFramesPerColumn)
        for column in 0..<columns {
            let magnitude = Float(column % 100) / 100
            samples.append(contentsOf: [Float](repeating: magnitude, count: PeakSidecar.defaultFramesPerColumn))
        }
        try writer.append(samples)
        try writer.finish()
        return url
    }

    /// The bulk path must agree with the scalar path column for column — it is a faster spelling
    /// of the same read, not a different one.
    func testItAgreesWithTheScalarPath() throws {
        let url = try writeRamp(columns: 500)
        let reader = try PeakSidecarReader(contentsOf: url)
        let bulk = reader.columns(from: 0, count: reader.columnCount)
        XCTAssertEqual(bulk.count, reader.columnCount)
        for index in 0..<reader.columnCount {
            XCTAssertEqual(bulk[index], reader.column(at: index), "column \(index) disagrees")
        }
    }

    func testItReadsFromAnOffset() throws {
        let url = try writeRamp(columns: 500)
        let reader = try PeakSidecarReader(contentsOf: url)
        let slice = reader.columns(from: 137, count: 10)
        XCTAssertEqual(slice.count, 10)
        for offset in 0..<10 {
            XCTAssertEqual(slice[offset], reader.column(at: 137 + offset))
        }
    }

    /// The unseparated tail reads past the end of a growing sidecar every frame.
    func testIndicesPastTheEndReadAsSilence() throws {
        let url = try writeRamp(columns: 20)
        let reader = try PeakSidecarReader(contentsOf: url)
        let columns = reader.columns(from: 15, count: 10)
        XCTAssertEqual(columns.count, 10)
        XCTAssertEqual(Array(columns[5...]), Array(repeating: .silent, count: 5))
    }

    func testNegativeStartIndicesReadAsSilence() throws {
        let url = try writeRamp(columns: 20)
        let reader = try PeakSidecarReader(contentsOf: url)
        let columns = reader.columns(from: -3, count: 5)
        XCTAssertEqual(Array(columns[0..<3]), Array(repeating: .silent, count: 3))
        XCTAssertEqual(columns[3], reader.column(at: 0))
    }

    func testAZeroCountReadReturnsNothing() throws {
        let url = try writeRamp(columns: 20)
        let reader = try PeakSidecarReader(contentsOf: url)
        XCTAssertTrue(reader.columns(from: 0, count: 0).isEmpty)
    }

    /// The claim spec §4 makes about re-binning cost, turned into an assertion. 41,343 columns is
    /// the spec's own worked example (a 4-minute clip); 226 is the lane's bar count at the new
    /// 1120pt default window. The bound is deliberately loose — this guards against the
    /// order-of-magnitude regression that would invalidate the no-pyramid decision, not against
    /// machine-to-machine jitter.
    func testAFullZoomOutRebinIsFastEnoughToDoFourTimesPerFrame() throws {
        let url = try writeRamp(columns: 41_343)
        let reader = try PeakSidecarReader(contentsOf: url)

        let started = Date()
        for _ in 0..<10 {
            let source = reader.columns(from: 0, count: reader.columnCount)
            _ = PeakBinning.rebin(targetCount: 226, sourceCount: source.count) { source[$0] }
        }
        let perRebin = Date().timeIntervalSince(started) / 10
        // Two bounds, because they guard different things. This repo has no CI — the mandated
        // `swift test --filter ...` command runs on a developer Mac, in a debug (-Onone) build,
        // whose per-operation cost varies widely machine to machine. Measured on an Apple M4:
        // ~109 µs release, ~8.2-8.3 ms debug (repeated runs).
        //   - Release (0.004s): this is the bound that demonstrates spec §4's re-binning claim,
        //     since the shipped render path runs optimized code.
        //   - Debug (0.1s, ~12x the observed M4 median): this does NOT demonstrate anything about
        //     production performance, and it is not tight enough to catch an ordinary constant-
        //     factor regression. It exists only to catch a catastrophic complexity regression —
        //     e.g. an accidentally quadratic re-bin over 41,343 columns would take seconds, not
        //     tens of milliseconds — while staying unflakeable on any Mac that can plausibly run
        //     this app.
        #if DEBUG
        let bound = 0.1
        #else
        let bound = 0.004
        #endif
        XCTAssertLessThan(perRebin, bound, "a full-clip re-bin took \(perRebin * 1000) ms")
        print("MEASURED full-clip re-bin (41,343 → 226): \(perRebin * 1_000_000) µs")
    }
}
