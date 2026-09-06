import AppKit
import XCTest
@testable import MinusOne

final class HeroWaveformBlendTests: XCTestCase {
    private let reference: Float = 1.0

    func testAllSilentReturnsTheNeutralSilenceColor() {
        let magnitudes: [SeparationStem: Float] = [.vocals: 0, .drums: 0, .bass: 0, .other: 0]
        let color = HeroWaveformBlend.barColor(forMagnitudes: magnitudes, reference: reference, isSeparated: true)
        XCTAssertEqual(color, .blended(HeroWaveformBlend.silenceColor))
    }

    func testWeightsNormalizeToSumOne() {
        let magnitudes: [SeparationStem: Float] = [.vocals: 0.8, .drums: 0.4, .bass: 0.2, .other: 0.1]
        let weights = HeroWaveformBlend.weights(forMagnitudes: magnitudes, reference: reference)
        XCTAssertEqual(weights.values.reduce(0, +), 1.0, accuracy: 1e-6)
    }

    func testOneDominantStemBlendsCloseToItsIdentityColor() throws {
        let magnitudes: [SeparationStem: Float] = [.vocals: 0.9, .drums: 0.02, .bass: 0.02, .other: 0.02]
        guard case .blended(let color) = HeroWaveformBlend.barColor(forMagnitudes: magnitudes, reference: reference, isSeparated: true) else {
            return XCTFail("expected a blended color")
        }
        let resolved = try XCTUnwrap(color.usingColorSpace(.sRGB))
        let expected = try XCTUnwrap(SeparationStem.vocals.identityColor.usingColorSpace(.sRGB))
        XCTAssertEqual(resolved.redComponent, expected.redComponent, accuracy: 0.1)
        XCTAssertEqual(resolved.greenComponent, expected.greenComponent, accuracy: 0.1)
        XCTAssertEqual(resolved.blueComponent, expected.blueComponent, accuracy: 0.1)
    }

    func testAnEvenMixIsNotEqualToAnySingleIdentityColor() throws {
        let magnitudes: [SeparationStem: Float] = [.vocals: 0.5, .drums: 0.5, .bass: 0.5, .other: 0.5]
        guard case .blended(let color) = HeroWaveformBlend.barColor(forMagnitudes: magnitudes, reference: reference, isSeparated: true) else {
            return XCTFail("expected a blended color")
        }
        let resolved = try XCTUnwrap(color.usingColorSpace(.sRGB))
        for stem in SeparationStem.allCases {
            let identity = try XCTUnwrap(stem.identityColor.usingColorSpace(.sRGB))
            let distance = abs(resolved.redComponent - identity.redComponent)
                + abs(resolved.greenComponent - identity.greenComponent)
                + abs(resolved.blueComponent - identity.blueComponent)
            XCTAssertGreaterThan(distance, 0.05, "blended color matched \(stem) too closely")
        }
    }

    func testUnseparatedAlwaysReturnsTailRegardlessOfMagnitudes() {
        let magnitudes: [SeparationStem: Float] = [.vocals: 0.9, .drums: 0.9, .bass: 0.9, .other: 0.9]
        let color = HeroWaveformBlend.barColor(forMagnitudes: magnitudes, reference: reference, isSeparated: false)
        XCTAssertEqual(color, .tail)
    }
}
