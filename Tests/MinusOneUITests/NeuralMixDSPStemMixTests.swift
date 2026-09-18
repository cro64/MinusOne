import XCTest
@testable import MinusOne

final class NeuralMixDSPStemMixTests: XCTestCase {
    private let sampleRate = 48_000.0
    private let frameCount = 8

    private func constantStem(_ value: Float) -> (left: [Float], right: [Float]) {
        (Array(repeating: value, count: frameCount), Array(repeating: value, count: frameCount))
    }

    /// Runs `process` repeatedly (each call `frameCount` frames) until the configured ramp window
    /// has elapsed, so per-stem levels have converged to their targets.
    private func processUntilConverged(
        _ dsp: NeuralMixDSP,
        stems: [SeparationStem: (left: [Float], right: [Float])],
        outputLeft: UnsafeMutablePointer<Float>,
        outputRight: UnsafeMutablePointer<Float>
    ) {
        let rampSeconds = Double(dsp.rampDurationMilliseconds.load()) / 1000.0
        let callsNeeded = Int((rampSeconds * sampleRate / Double(frameCount)).rounded(.up)) + 2
        let raw = Array(repeating: Float(0), count: frameCount)
        for _ in 0..<callsNeeded {
            stems.values.forEach { _ in }
            withStemPointers(stems) { stemBuffers in
                raw.withUnsafeBufferPointer { rawLeft in
                    raw.withUnsafeBufferPointer { rawRight in
                        dsp.process(
                            rawLeft: rawLeft.baseAddress!,
                            rawRight: rawRight.baseAddress!,
                            stems: stemBuffers,
                            outputLeft: outputLeft,
                            outputRight: outputRight,
                            frameCount: frameCount,
                            sampleRate: sampleRate
                        )
                    }
                }
            }
        }
    }

    private func withStemPointers(
        _ stems: [SeparationStem: (left: [Float], right: [Float])],
        _ body: ([SeparationStem: (left: UnsafePointer<Float>, right: UnsafePointer<Float>)]) -> Void
    ) {
        func recurse(
            _ remaining: [(SeparationStem, (left: [Float], right: [Float]))],
            _ accumulated: [SeparationStem: (left: UnsafePointer<Float>, right: UnsafePointer<Float>)]
        ) {
            guard let (stem, channels) = remaining.first else {
                body(accumulated)
                return
            }
            channels.left.withUnsafeBufferPointer { leftPtr in
                channels.right.withUnsafeBufferPointer { rightPtr in
                    var next = accumulated
                    next[stem] = (leftPtr.baseAddress!, rightPtr.baseAddress!)
                    recurse(Array(remaining.dropFirst()), next)
                }
            }
        }
        recurse(Array(stems), [:])
    }

    func testMutedVocalsWithOthersAtFullReproducesTodaysDefaultMix() {
        let dsp = NeuralMixDSP(makeupGainDecibels: 0, rampDurationMilliseconds: 30)
        dsp.stemLevels[.vocals]?.store(0)
        dsp.stemLevels[.drums]?.store(1)
        dsp.stemLevels[.bass]?.store(1)
        dsp.stemLevels[.other]?.store(1)

        let stems: [SeparationStem: (left: [Float], right: [Float])] = [
            .vocals: constantStem(1),
            .drums: constantStem(0.2),
            .bass: constantStem(0.3),
            .other: constantStem(0.1)
        ]

        let outputLeft = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
        let outputRight = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
        defer {
            outputLeft.deallocate()
            outputRight.deallocate()
        }

        processUntilConverged(dsp, stems: stems, outputLeft: outputLeft, outputRight: outputRight)

        // Vocals excluded (muted), drums+bass+other summed at full level: 0.2 + 0.3 + 0.1 = 0.6.
        XCTAssertEqual(outputLeft[0], 0.6, accuracy: 0.01)
        XCTAssertEqual(outputRight[0], 0.6, accuracy: 0.01)
    }

    func testAllStemsAtFullLevelSumsAllFour() {
        let dsp = NeuralMixDSP(makeupGainDecibels: 0, rampDurationMilliseconds: 30)
        for stem in SeparationStem.allCases {
            dsp.stemLevels[stem]?.store(1)
        }

        let stems: [SeparationStem: (left: [Float], right: [Float])] = Dictionary(
            uniqueKeysWithValues: SeparationStem.allCases.map { ($0, constantStem(0.1)) }
        )

        let outputLeft = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
        let outputRight = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
        defer {
            outputLeft.deallocate()
            outputRight.deallocate()
        }

        processUntilConverged(dsp, stems: stems, outputLeft: outputLeft, outputRight: outputRight)

        XCTAssertEqual(outputLeft[0], 0.4, accuracy: 0.01)
        XCTAssertEqual(outputRight[0], 0.4, accuracy: 0.01)
    }

    /// Regression test for a real bug: an earlier version tied makeup gain to `1 - vocalsLevel`, so
    /// the Gain slider did nothing whenever vocals wasn't muted (an Isolate-Vocals mix, or simply
    /// unmuting vocals to listen). Gain must now be a flat boost, applying the same multiplier to
    /// whatever the current stem mix produces — whether or not vocals happens to be muted.
    func testMakeupGainIsAFlatBoostRegardlessOfWhichStemsAreMuted() {
        func outputLevel(makeupGainDecibels: Float, vocalsLevel: Float) -> Float {
            let dsp = NeuralMixDSP(makeupGainDecibels: makeupGainDecibels, rampDurationMilliseconds: 30)
            dsp.stemLevels[.vocals]?.store(vocalsLevel)
            dsp.stemLevels[.drums]?.store(1)
            let stems: [SeparationStem: (left: [Float], right: [Float])] = [
                .vocals: constantStem(0.2),
                .drums: constantStem(0.2)
            ]
            let left = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
            let right = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
            defer {
                left.deallocate()
                right.deallocate()
            }
            processUntilConverged(dsp, stems: stems, outputLeft: left, outputRight: right)
            return left[0]
        }

        // Same 6dB-vs-0dB boost ratio whether vocals is muted (0) or fully present (1) — the whole
        // point of the fix: Gain isn't scaled by how much vocal is being removed anymore.
        let mutedRatio = outputLevel(makeupGainDecibels: 6, vocalsLevel: 0) / outputLevel(makeupGainDecibels: 0, vocalsLevel: 0)
        let unmutedRatio = outputLevel(makeupGainDecibels: 6, vocalsLevel: 1) / outputLevel(makeupGainDecibels: 0, vocalsLevel: 1)

        XCTAssertEqual(mutedRatio, unmutedRatio, accuracy: 0.01)
        XCTAssertGreaterThan(mutedRatio, 1.5) // a real boost, not a no-op
    }

    func testResetZeroesAppliedLevelsAndPeaks() {
        let dsp = NeuralMixDSP(makeupGainDecibels: 0, rampDurationMilliseconds: 30)
        dsp.stemLevels[.drums]?.store(1)
        let stems: [SeparationStem: (left: [Float], right: [Float])] = [.drums: constantStem(1)]
        let outputLeft = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
        let outputRight = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
        defer {
            outputLeft.deallocate()
            outputRight.deallocate()
        }
        processUntilConverged(dsp, stems: stems, outputLeft: outputLeft, outputRight: outputRight)
        XCTAssertGreaterThan(dsp.wetPeak.load(), 0)

        dsp.reset()
        XCTAssertEqual(dsp.wetPeak.load(), 0, accuracy: 0.0001)
        XCTAssertEqual(dsp.dryPeak.load(), 0, accuracy: 0.0001)
    }

    /// Regression test for a real bug: nothing clamped the mixed-and-boosted output, so a loud
    /// 4-stem sum combined with a high Gain setting could exceed full scale (±1.0) and reach the
    /// audio hardware raw, heard as harsh clipping/hiss. A near-worst-case mix (all 4 stems loud,
    /// max 12dB gain) must never produce a sample whose magnitude exceeds 1.0.
    func testLoudMixWithMaxGainNeverExceedsFullScale() {
        let dsp = NeuralMixDSP(makeupGainDecibels: 12, rampDurationMilliseconds: 30)
        for stem in SeparationStem.allCases {
            dsp.stemLevels[stem]?.store(1)
        }
        let stems: [SeparationStem: (left: [Float], right: [Float])] = Dictionary(
            uniqueKeysWithValues: SeparationStem.allCases.map { ($0, constantStem(0.9)) }
        )

        let outputLeft = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
        let outputRight = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
        defer {
            outputLeft.deallocate()
            outputRight.deallocate()
        }

        processUntilConverged(dsp, stems: stems, outputLeft: outputLeft, outputRight: outputRight)

        for frame in 0..<frameCount {
            XCTAssertLessThanOrEqual(abs(outputLeft[frame]), 1.0)
            XCTAssertLessThanOrEqual(abs(outputRight[frame]), 1.0)
        }
    }

    /// The limiter must be transparent (identity) for ordinary, non-loud mixes — it should only
    /// ever engage near full scale, never audibly color normal playback levels.
    func testModerateMixIsUnaffectedByTheLimiter() {
        let dsp = NeuralMixDSP(makeupGainDecibels: 0, rampDurationMilliseconds: 30)
        dsp.stemLevels[.drums]?.store(1)
        let stems: [SeparationStem: (left: [Float], right: [Float])] = [.drums: constantStem(0.3)]

        let outputLeft = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
        let outputRight = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
        defer {
            outputLeft.deallocate()
            outputRight.deallocate()
        }

        processUntilConverged(dsp, stems: stems, outputLeft: outputLeft, outputRight: outputRight)

        XCTAssertEqual(outputLeft[0], 0.3, accuracy: 0.001)
        XCTAssertEqual(outputRight[0], 0.3, accuracy: 0.001)
    }
}
