import XCTest
@testable import MinusOne

final class PeakBinningTests: XCTestCase {
    private func source(_ count: Int) -> [PeakColumn] {
        (0..<count).map { index in
            let phase = Float(index) * 0.37
            return PeakColumn(minimum: -abs(sinf(phase)), maximum: abs(cosf(phase)), rms: abs(sinf(phase)) * 0.5)
        }
    }

    private func rebin(_ columns: [PeakColumn], to targetCount: Int) -> [PeakColumn] {
        PeakBinning.rebin(targetCount: targetCount, sourceCount: columns.count) { columns[$0] }
    }

    func testItReturnsExactlyTheRequestedNumberOfColumns() {
        XCTAssertEqual(rebin(source(600), to: 200).count, 200)
        XCTAssertEqual(rebin(source(41_343), to: 226).count, 226)
    }

    /// The correctness property: downsampling must never hide a peak.
    func testEveryOutputColumnEnvelopsTheSourceColumnsItCovers() {
        let columns = source(600)
        let result = rebin(columns, to: 200)
        for index in 0..<200 {
            let start = index * 600 / 200
            let end = (index + 1) * 600 / 200
            for source in start..<end {
                XCTAssertLessThanOrEqual(result[index].minimum, columns[source].minimum + 1e-6)
                XCTAssertGreaterThanOrEqual(result[index].maximum, columns[source].maximum - 1e-6)
            }
        }
    }

    /// The evenly-dividing case above cannot catch a boundary bug, because 600/200 = 3 exactly:
    /// the clamp never engages and the test's own arithmetic matches the implementation's. Real
    /// usage is always non-divisor — ~41,343 stored columns binned to whatever pixel width the
    /// lane happens to have — so the enveloping guarantee is pinned here instead.
    func testEnvelopingHoldsWhenTheRatioDoesNotDivideEvenly() {
        let columns = source(600)
        let result = rebin(columns, to: 7)
        XCTAssertEqual(result.count, 7)

        // Every source column must be covered by exactly one output column, and that output
        // column must envelop it. Walking the source side rather than recomputing the
        // implementation's group boundaries is what makes this independent of it.
        for (sourceIndex, sourceColumn) in columns.enumerated() {
            let owner = result[min(6, sourceIndex * 7 / 600)]
            XCTAssertLessThanOrEqual(owner.minimum, sourceColumn.minimum + 1e-6,
                                     "source column \(sourceIndex) has a lower minimum than the column covering it")
            XCTAssertGreaterThanOrEqual(owner.maximum, sourceColumn.maximum - 1e-6,
                                        "source column \(sourceIndex) has a higher maximum than the column covering it")
        }
    }

    func testAnEqualTargetAndSourceCountIsTheIdentity() {
        let columns = source(64)
        let result = rebin(columns, to: 64)
        for index in 0..<64 {
            XCTAssertEqual(result[index].minimum, columns[index].minimum, accuracy: 1e-6)
            XCTAssertEqual(result[index].maximum, columns[index].maximum, accuracy: 1e-6)
        }
    }

    func testUpsamplingDoesNotCrashOrProduceGaps() {
        let result = rebin(source(10), to: 40)
        XCTAssertEqual(result.count, 40)
        XCTAssertFalse(result.contains { $0.maximum.isNaN || $0.minimum.isNaN })
    }

    func testAnEmptySourceProducesSilence() {
        let result = PeakBinning.rebin(targetCount: 12, sourceCount: 0) { _ in .silent }
        XCTAssertEqual(result, Array(repeating: .silent, count: 12))
    }

    func testAZeroTargetProducesNothing() {
        XCTAssertTrue(rebin(source(10), to: 0).isEmpty)
    }

    /// Silence in the source must survive as silence, not be smeared by neighbours — this is the
    /// specific defect that makes the current sidebar thumbnail a solid block.
    func testSilentRegionsStaySilent() {
        var columns = source(600)
        for index in 200..<400 { columns[index] = .silent }
        let result = rebin(columns, to: 60)
        XCTAssertEqual(result[30], .silent)
    }
}
