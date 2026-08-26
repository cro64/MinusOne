import XCTest
@testable import MinusOne

final class PeakScalingTests: XCTestCase {
    func testAMagnitudeEqualToTheReferenceFillsTheLane() {
        XCTAssertEqual(PeakScaling.height(magnitude: 0.8, reference: 0.8), 1.0, accuracy: 1e-6)
    }

    /// The reason mix-relative normalisation is survivable: a stem 30 dB down still reads.
    func testThirtyDecibelsBelowTheReferenceGetsHalfTheLane() {
        let magnitude = Float(1.0) * powf(10, -30.0 / 20.0)
        XCTAssertEqual(PeakScaling.height(magnitude: magnitude, reference: 1), 0.5, accuracy: 1e-4)
    }

    func testAnythingAtOrBelowTheFloorGetsNoHeight() {
        let atFloor = Float(1.0) * powf(10, PeakScaling.floorDecibels / 20.0)
        XCTAssertEqual(PeakScaling.height(magnitude: atFloor, reference: 1), 0, accuracy: 1e-6)
        XCTAssertEqual(PeakScaling.height(magnitude: atFloor / 10, reference: 1), 0, accuracy: 1e-6)
    }

    func testSilenceAndAZeroReferenceProduceNoHeightRatherThanNaN() {
        XCTAssertEqual(PeakScaling.height(magnitude: 0, reference: 1), 0)
        XCTAssertEqual(PeakScaling.height(magnitude: 0.5, reference: 0), 0)
    }

    func testAMagnitudeAboveTheReferenceIsClampedToTheLane() {
        XCTAssertEqual(PeakScaling.height(magnitude: 2, reference: 1), 1.0, accuracy: 1e-6)
    }

    func testColumnMagnitudeTakesTheLargerExcursion() {
        XCTAssertEqual(PeakColumn(minimum: -0.9, maximum: 0.2, rms: 0.4).magnitude, 0.9, accuracy: 1e-6)
        XCTAssertEqual(PeakColumn(minimum: -0.1, maximum: 0.7, rms: 0.4).magnitude, 0.7, accuracy: 1e-6)
    }

    func testEveryTrackHasADistinctFileName() {
        let names = PeakTrack.all.map(\.fileName)
        XCTAssertEqual(names.count, 5)
        XCTAssertEqual(Set(names).count, 5)
        XCTAssertEqual(PeakTrack.mix.fileName, "mix.peaks")
        XCTAssertEqual(PeakTrack.stem(.vocals).fileName, "vocals.peaks")
    }
}
