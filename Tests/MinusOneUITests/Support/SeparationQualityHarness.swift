import Accelerate
import AVFoundation
import XCTest
@testable import MinusOne

/// Shared plumbing for `SeparationQualityRegressionTests` (synthetic, fast) and
/// `SeparationQualityBenchmarkTests` (real MUSDB18 tracks, slow) — driving
/// `OfflineSeparationEngine` synchronously and scoring its output with SI-SDR, so both suites
/// measure quality the same way and can't quietly drift apart.
enum SeparationQualityHarness {
    enum HarnessError: Error, LocalizedError {
        case timedOut
        case neverReportedCompletion

        var errorDescription: String? {
            switch self {
            case .timedOut: return "Offline separation timed out"
            case .neverReportedCompletion: return "Offline separation finished without reporting completion"
            }
        }
    }

    /// Runs `OfflineSeparationEngine.process` to completion (or failure) and returns the finished
    /// clip. Uses `XCTWaiter` directly rather than `XCTestCase.wait(for:)` so this isn't tied to a
    /// specific test case instance and both suites can call it the same way.
    static func runSeparation(
        engine: OfflineSeparationEngine,
        clip: PracticeClip,
        sourceURL: URL,
        timeout: TimeInterval
    ) throws -> PracticeClip {
        let expectation = XCTestExpectation(description: "offline separation completes")
        var finished: PracticeClip?
        var failure: Error?

        engine.process(
            clip: clip,
            sourceURL: sourceURL,
            onUpdate: { updated in
                if updated.isFullyProcessed {
                    finished = updated
                    expectation.fulfill()
                }
            },
            onFailure: { _, error in
                failure = error
                expectation.fulfill()
            }
        )

        guard XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed else {
            throw HarnessError.timedOut
        }
        if let failure { throw failure }
        guard let finished else { throw HarnessError.neverReportedCompletion }
        return finished
    }

    // MARK: - WAV I/O

    static func writeStereo(left: [Float], right: [Float], to url: URL, sampleRate: Double) throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 2,
            interleaved: false
        ))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frameCount = AVAudioFrameCount(left.count)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        left.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: left.count) }
        right.withUnsafeBufferPointer { buffer.floatChannelData![1].update(from: $0.baseAddress!, count: right.count) }
        try file.write(from: buffer)
    }

    static func readStereo(_ url: URL) throws -> (left: [Float], right: [Float]) {
        let file = try AVAudioFile(forReading: url)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let count = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        let left = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: count))
        let right = channelCount > 1
            ? Array(UnsafeBufferPointer(start: buffer.floatChannelData![1], count: count))
            : left
        return (left, right)
    }

    static func duration(of url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.processingFormat.sampleRate
    }

    // MARK: - SI-SDR

    /// Same formula as `Scripts/evaluate_separation.py`'s `si_sdr` — kept in lockstep intentionally
    /// so the in-process checks and the Python-scored deep pass report comparable numbers.
    static func siSDR(
        reference: (left: [Float], right: [Float]),
        estimate: (left: [Float], right: [Float]),
        eps: Float = 1e-10
    ) -> Double {
        let n = min(reference.left.count, estimate.left.count)
        var ref = [Float](repeating: 0, count: n * 2)
        var est = [Float](repeating: 0, count: n * 2)
        ref.replaceSubrange(0..<n, with: reference.left.prefix(n))
        ref.replaceSubrange(n..<(2 * n), with: reference.right.prefix(n))
        est.replaceSubrange(0..<n, with: estimate.left.prefix(n))
        est.replaceSubrange(n..<(2 * n), with: estimate.right.prefix(n))

        var refEnergy: Float = 0
        vDSP_dotpr(ref, 1, ref, 1, &refEnergy, vDSP_Length(ref.count))
        refEnergy += eps

        var crossTerm: Float = 0
        vDSP_dotpr(est, 1, ref, 1, &crossTerm, vDSP_Length(ref.count))
        let alpha = crossTerm / refEnergy

        var projection = ref
        var alphaVar = alpha
        vDSP_vsmul(ref, 1, &alphaVar, &projection, 1, vDSP_Length(ref.count))

        // Sign is irrelevant: `noise` only ever feeds a sum-of-squares below, so vDSP_vsub's
        // argument order (notoriously reversed from naive A-B intuition) can't affect the result.
        var noise = [Float](repeating: 0, count: ref.count)
        vDSP_vsub(projection, 1, est, 1, &noise, 1, vDSP_Length(ref.count))

        var projectionEnergy: Float = 0
        vDSP_dotpr(projection, 1, projection, 1, &projectionEnergy, vDSP_Length(ref.count))
        var noiseEnergy: Float = 0
        vDSP_dotpr(noise, 1, noise, 1, &noiseEnergy, vDSP_Length(ref.count))

        return 10 * log10(Double(projectionEnergy + eps) / Double(noiseEnergy + eps))
    }
}
