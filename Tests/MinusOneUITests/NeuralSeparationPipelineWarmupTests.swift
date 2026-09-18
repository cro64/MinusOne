import XCTest
@testable import MinusOne

/// Minimal stand-in for a real CoreML model — returns silence immediately so these tests exercise
/// the pipeline's warm-up bookkeeping without needing a real model file or real inference latency.
private final class FakeSeparationModel: AudioSeparationModel {
    let variant: SeparationModelVariant = .balanced
    let name = "Fake"
    let modelSampleRate: Double
    let preferredWindowSeconds: Double

    init(sampleRate: Double, windowSeconds: Double) {
        modelSampleRate = sampleRate
        preferredWindowSeconds = windowSeconds
    }

    func separateAllStems(
        left: UnsafePointer<Float>,
        right: UnsafePointer<Float>,
        frameCount: Int,
        sampleRate: Double
    ) throws -> [SeparationStem: StemChannels] {
        let silence = StemChannels(left: Array(repeating: 0, count: frameCount), right: Array(repeating: 0, count: frameCount))
        return Dictionary(uniqueKeysWithValues: SeparationStem.allCases.map { ($0, silence) })
    }
}

final class NeuralSeparationPipelineWarmupTests: XCTestCase {
    private let sampleRate = 48_000.0
    private let windowSeconds = 1.0
    private let hopSeconds = 0.5

    private func makePipeline() -> NeuralSeparationPipeline {
        NeuralSeparationPipeline(
            model: FakeSeparationModel(sampleRate: sampleRate, windowSeconds: windowSeconds),
            sampleRate: sampleRate,
            windowSeconds: windowSeconds,
            hopSeconds: hopSeconds,
            makeupGainDecibels: 4.5,
            rampDurationMilliseconds: 50
        )
    }

    func testEstimatedWarmupSecondsMatchesDelayPlusWindow() {
        let pipeline = makePipeline()
        // delaySamples == windowSamples in the pipeline's own construction, so the estimate is
        // exactly 2x the configured window length.
        XCTAssertEqual(pipeline.estimatedWarmupSeconds, windowSeconds * 2, accuracy: 0.001)
    }

    func testRemainingWarmupSecondsIsNilBeforeStart() {
        let pipeline = makePipeline()
        XCTAssertNil(pipeline.remainingWarmupSeconds)
    }

    func testRemainingWarmupSecondsIsCloseToEstimateRightAfterStart() {
        let pipeline = makePipeline()
        pipeline.start()
        defer { pipeline.stop() }

        guard let remaining = pipeline.remainingWarmupSeconds else {
            XCTFail("expected remainingWarmupSeconds while warming up")
            return
        }
        XCTAssertEqual(remaining, pipeline.estimatedWarmupSeconds, accuracy: 0.2)
    }

    func testRemainingWarmupSecondsCountsDown() {
        let pipeline = makePipeline()
        pipeline.start()
        defer { pipeline.stop() }

        let first = pipeline.remainingWarmupSeconds
        Thread.sleep(forTimeInterval: 0.15)
        let second = pipeline.remainingWarmupSeconds

        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertLessThan(second ?? .infinity, first ?? 0)
    }

    func testRemainingWarmupSecondsIsNilAfterStop() {
        let pipeline = makePipeline()
        pipeline.start()
        pipeline.stop()
        XCTAssertNil(pipeline.remainingWarmupSeconds)
    }
}
