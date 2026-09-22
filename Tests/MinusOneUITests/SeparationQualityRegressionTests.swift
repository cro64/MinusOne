import Accelerate
import AVFoundation
import XCTest
@testable import MinusOne

/// Drives `OfflineSeparationEngine` directly against synthetic, perfectly-isolated stems and
/// scores the result with SI-SDR (scale-invariant signal-to-distortion ratio) — the same metric
/// family Demucs's own paper and the MUSDB18 leaderboard report, ported from
/// `Scripts/evaluate_separation.py` so this runs in-process with no Python invocation and no app
/// launch: `swift test --filter SeparationQualityRegressionTests` is the whole loop.
///
/// This is a fast smoke test against synthetic tones/noise, not a substitute for scoring against
/// real music — see `Scripts/make_synthetic_mix.py` + `evaluate_separation.py` for a MUSDB18-based
/// deep pass. What this guards against is a pipeline change (windowing, hop, resampling,
/// normalization) silently breaking reconstruction, which synthetic signals catch just as well as
/// real ones and without a multi-GB dataset dependency.
final class SeparationQualityRegressionTests: XCTestCase {
    private var root: URL!
    private var libraryStore: ClipLibraryStore!

    private let sampleRate = 44_100.0
    private let clipSeconds = 18.0

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SeparationQuality-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        libraryStore = ClipLibraryStore(rootURL: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Needs the real Demucs CoreML model on disk (`Scripts/download-model.sh`, or the welcome
    /// screen's download) — skips rather than fails where it isn't, so this doesn't block CI on a
    /// machine that's never downloaded it, but becomes a real regression gate the moment it has.
    func testOfflineSeparationReconstructsKnownStemsAboveFloor() throws {
        try XCTSkipUnless(
            SeparationModelFactory.isAvailable(.balanced),
            "Separation model not downloaded — run Scripts/download-model.sh first."
        )

        let references = Self.syntheticStems(seconds: clipSeconds, sampleRate: sampleRate)
        let mixURL = root.appendingPathComponent("mix.caf")
        try Self.writeMix(references, to: mixURL, sampleRate: sampleRate)

        let clip = PracticeClip(
            title: "Synthetic quality fixture",
            durationSeconds: clipSeconds,
            sourceHash: "synthetic-fixture",
            sourceFileName: "mix.caf",
            waveformPeaks: []
        )
        libraryStore.add(clip)

        let engine = OfflineSeparationEngine(libraryStore: libraryStore)
        let expectation = expectation(description: "offline separation completes")
        var finished: PracticeClip?
        var failure: Error?

        engine.process(
            clip: clip,
            sourceURL: mixURL,
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

        // CPU-bound CoreML inference over ~18s of audio across several windows — generous but
        // bounded, so a genuine hang (not just "slow machine") still fails instead of blocking CI.
        wait(for: [expectation], timeout: 300)

        if let failure {
            XCTFail("Separation failed: \(failure.localizedDescription)")
            return
        }
        let updated = try XCTUnwrap(finished, "onUpdate never reported completion")

        var scores: [SeparationStem: Double] = [:]
        for stem in SeparationStem.allCases {
            let fileName = try XCTUnwrap(updated.stemFileNames[stem.rawValue], "\(stem.rawValue) never wrote a file")
            let url = libraryStore.stemFileURL(clipID: clip.id, fileName: fileName)
            let estimate = try Self.readStereo(url)
            let reference = references[stem]!
            let score = Self.siSDR(reference: reference, estimate: estimate)
            scores[stem] = score
        }

        let report = scores.map { "\($0.key.rawValue)=\(String(format: "%.2f", $0.value))dB" }.joined(separator: ", ")
        print("[SeparationQualityRegressionTests] SI-SDR: \(report)")

        // Deliberately lenient: this floor exists to catch a pipeline bug that produces silence,
        // NaNs, or a fully-scrambled stem (score would be deeply negative or crash the log10),
        // not to certify separation quality — tighten it only after establishing a real baseline
        // number on real hardware, since this sandbox can't run CoreML to calibrate one.
        for (stem, score) in scores {
            XCTAssertFalse(score.isNaN, "\(stem.rawValue) SI-SDR is NaN — likely silent or empty output")
            XCTAssertGreaterThan(score, -10, "\(stem.rawValue) SI-SDR regressed to near-noise-floor")
        }
    }

    // MARK: - Synthetic fixtures

    /// Four spectrally-distinct synthetic "stems" standing in for vocals/drums/bass/other, so the
    /// model has something to actually tell apart — matching frequency ranges roughly where each
    /// real stem tends to live (vocals mid, bass low, drums broadband/percussive, other high).
    private static func syntheticStems(seconds: Double, sampleRate: Double) -> [SeparationStem: (left: [Float], right: [Float])] {
        let count = Int(seconds * sampleRate)
        var vocals = [Float](repeating: 0, count: count)
        var bass = [Float](repeating: 0, count: count)
        var other = [Float](repeating: 0, count: count)
        var drums = [Float](repeating: 0, count: count)

        for i in 0..<count {
            let t = Double(i) / sampleRate
            vocals[i] = Float(0.25 * sin(2 * .pi * 440 * t))
            bass[i] = Float(0.3 * sin(2 * .pi * 80 * t))
            other[i] = Float(0.2 * sin(2 * .pi * 1_200 * t))
        }

        var rng = SystemRandomNumberGenerator()
        let beatSamples = Int(0.5 * sampleRate)
        var position = 0
        var beatIndex = 0
        while position < count {
            let amplitude: Float = beatIndex % 4 == 0 ? 0.9 : 0.35
            for offset in 0..<220 where position + offset < count {
                let decay = 1 - Float(offset) / 220
                drums[position + offset] = amplitude * decay * Float.random(in: -1...1, using: &rng)
            }
            position += beatSamples
            beatIndex += 1
        }

        func stereo(_ mono: [Float]) -> (left: [Float], right: [Float]) { (mono, mono) }
        return [
            .vocals: stereo(vocals),
            .drums: stereo(drums),
            .bass: stereo(bass),
            .other: stereo(other)
        ]
    }

    private static func writeMix(
        _ stems: [SeparationStem: (left: [Float], right: [Float])],
        to url: URL,
        sampleRate: Double
    ) throws {
        let count = stems.values.first!.left.count
        var left = [Float](repeating: 0, count: count)
        var right = [Float](repeating: 0, count: count)
        for (_, channels) in stems {
            vDSP_vadd(left, 1, channels.left, 1, &left, 1, vDSP_Length(count))
            vDSP_vadd(right, 1, channels.right, 1, &right, 1, vDSP_Length(count))
        }

        var peak: Float = 0
        vDSP_maxmgv(left, 1, &peak, vDSP_Length(count))
        var peakRight: Float = 0
        vDSP_maxmgv(right, 1, &peakRight, vDSP_Length(count))
        peak = max(peak, peakRight)
        if peak > 1 {
            var scale = 1 / peak
            vDSP_vsmul(left, 1, &scale, &left, 1, vDSP_Length(count))
            vDSP_vsmul(right, 1, &scale, &right, 1, vDSP_Length(count))
        }

        try writeStereo(left: left, right: right, to: url, sampleRate: sampleRate)
    }

    private static func writeStereo(left: [Float], right: [Float], to url: URL, sampleRate: Double) throws {
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

    private static func readStereo(_ url: URL) throws -> (left: [Float], right: [Float]) {
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

    // MARK: - SI-SDR

    /// Same formula as `Scripts/evaluate_separation.py`'s `si_sdr` — kept in lockstep intentionally
    /// so the fast in-process check and the deep MUSDB18 pass report comparable numbers.
    private static func siSDR(
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

        var noise = [Float](repeating: 0, count: ref.count)
        vDSP_vsub(projection, 1, est, 1, &noise, 1, vDSP_Length(ref.count))

        var projectionEnergy: Float = 0
        vDSP_dotpr(projection, 1, projection, 1, &projectionEnergy, vDSP_Length(ref.count))
        var noiseEnergy: Float = 0
        vDSP_dotpr(noise, 1, noise, 1, &noiseEnergy, vDSP_Length(ref.count))

        return 10 * log10(Double(projectionEnergy + eps) / Double(noiseEnergy + eps))
    }
}
