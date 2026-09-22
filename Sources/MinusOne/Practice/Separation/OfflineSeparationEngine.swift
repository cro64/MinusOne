import AVFoundation
import Accelerate

/// Drives full-quality, non-realtime 4-stem separation over an entire clip using proper
/// Hann-window overlap-add (unlike the live path's causal hop-splice crossfade).
///
/// Processes one clip at a time on a serial background queue. Within a clip, CoreML inference for
/// several windows runs concurrently (one model instance per window, see `loadModelPool`), but
/// everything downstream of inference — accumulating into the output buffers, normalizing, writing
/// to disk, and reporting progress — stays strictly serial and in original window order, so this
/// produces the same output the fully-serial version did. As each analysis window's contribution
/// to the output becomes final (no later window can still touch it), that newly finalized prefix
/// is normalized, written to the stem files on disk, and reported via `onUpdate` — this is what
/// lets the deck start playback on the first few seconds while the rest of the clip keeps
/// processing in the background.
final class OfflineSeparationEngine {
    enum SeparationError: Error, LocalizedError {
        case silentAudio
        case emptyAudio

        var errorDescription: String? {
            switch self {
            case .silentAudio: return "This clip appears to be silent — nothing to separate."
            case .emptyAudio: return "This audio file has no playable frames."
            }
        }
    }

    private let queue = DispatchQueue(label: "com.minusone.app.practice-offline-separation", qos: .utility)
    private let libraryStore: ClipLibraryStore
    private var modelPool: [AudioSeparationModel] = []

    init(libraryStore: ClipLibraryStore) {
        self.libraryStore = libraryStore
    }

    func process(
        clip: PracticeClip,
        sourceURL: URL,
        onUpdate: @escaping (PracticeClip) -> Void,
        onFailure: @escaping (PracticeClip, Error) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                try self.runProcessing(clip: clip, sourceURL: sourceURL, onUpdate: onUpdate)
            } catch {
                AppLogger.shared.error("Practice offline separation failed for \(clip.id): \(error.localizedDescription)")
                var failed = clip
                failed.processingFailed = true
                self.libraryStore.updateExisting(failed)
                onFailure(failed, error)
            }
        }
    }

    // MARK: - Processing

    private func runProcessing(
        clip: PracticeClip,
        sourceURL: URL,
        onUpdate: @escaping (PracticeClip) -> Void
    ) throws {
        let pool = try loadModelPool(size: Self.desiredConcurrency())
        let model = pool[0]
        let modelSampleRate = model.modelSampleRate
        let windowSampleCount = max(1, Int((model.preferredWindowSeconds * modelSampleRate).rounded()))
        // 75%, not 50%: fewer overlapping inference calls (1.5x fewer than a 50% hop) for less
        // redundant compute, while still leaving a wide enough crossfade region for the Hann-window
        // overlap-add below to hide seams. Below ~50% the two windows barely overlap and boundary
        // artifacts start to show; above ~85% the crossfade gets too thin to smooth a bad window.
        let hop = max(1, windowSampleCount * 3 / 4)

        let (left, right) = try Self.decodeToModelFormat(sourceURL: sourceURL, sampleRate: modelSampleRate)
        let totalSamples = left.count
        guard totalSamples > 0 else { throw SeparationError.emptyAudio }
        try Self.assertNotSilent(left: left, right: right)

        let clipFolder = try libraryStore.ensureFolder(forClipID: clip.id)
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: modelSampleRate,
            channels: 2,
            interleaved: false
        )!

        // PCM files on disk are always interleaved — settings must reflect that even though the
        // in-memory processing format above is non-interleaved (planar, for CoreML/OLA math).
        let fileFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: modelSampleRate,
            channels: 2,
            interleaved: true
        )!

        var writers: [SeparationStem: AVAudioFile] = [:]
        var fileNames: [String: String] = [:]
        for stem in SeparationStem.allCases {
            let fileName = "\(stem.rawValue).caf"
            let url = clipFolder.appendingPathComponent(fileName)
            writers[stem] = try AVAudioFile(forWriting: url, settings: fileFormat.settings)
            fileNames[stem.rawValue] = fileName
        }

        // Peak sidecars are written from the samples already in memory — no second decode of the
        // stem files this loop is in the middle of writing.
        var peakWriters: [SeparationStem: PeakSidecarWriter] = [:]
        var peakFileNames = clip.peakFileNames        // keeps the mix entry written at import
        do {
            let peaksFolder = try libraryStore.ensurePeaksFolder(forClipID: clip.id)
            for stem in SeparationStem.allCases {
                let track = PeakTrack.stem(stem)
                do {
                    peakWriters[stem] = try PeakSidecarWriter(
                        url: peaksFolder.appendingPathComponent(track.fileName),
                        sampleRate: modelSampleRate
                    )
                    peakFileNames[track.key] = track.fileName
                } catch {
                    AppLogger.shared.warning("Peak sidecar writer failed for \(track.key): \(error.localizedDescription)")
                }
            }
        } catch {
            // Widest-blast-radius peak failure in this function: without the folder, no stem gets a
            // sidecar at all. Separation still proceeds — a missing sidecar is regenerable by
            // `PeakSidecarMigrator.backfill`, which Phase 2 will invoke when a clip is opened.
            AppLogger.shared.warning("Peak sidecar folder unavailable, stem peaks deferred to backfill: \(error.localizedDescription)")
        }

        var outputs: [SeparationStem: (left: [Float], right: [Float])] = Dictionary(
            uniqueKeysWithValues: SeparationStem.allCases.map {
                ($0, (left: [Float](repeating: 0, count: totalSamples), right: [Float](repeating: 0, count: totalSamples)))
            }
        )
        var weight = [Float](repeating: 0, count: totalSamples)
        let hann = Self.hannWindow(length: windowSampleCount)

        var workingClip = clip
        var flushedFrames = 0
        var windowStart = 0

        // Windows within a batch (up to `pool.count` of them, one model instance per slot) run
        // their CoreML calls concurrently via `concurrentPerform` — the actual parallelism.
        // Everything after that (accumulate into `outputs`/`weight`, normalize, write to disk,
        // `onUpdate`) stays a strictly serial loop over the batch in original window order, exactly
        // as it was before batching existed. That's deliberate: it means this produces the same
        // output, in the same order, via the same math as the old fully-serial loop — only *when*
        // each window's CoreML compute happens is different, not the result.
        while windowStart < totalSamples {
            var batchStarts: [Int] = []
            var cursor = windowStart
            while batchStarts.count < pool.count, cursor < totalSamples {
                batchStarts.append(cursor)
                cursor += hop
            }

            var batchResults = [Result<[SeparationStem: StemChannels], Error>?](repeating: nil, count: batchStarts.count)
            batchResults.withUnsafeMutableBufferPointer { results in
                DispatchQueue.concurrentPerform(iterations: batchStarts.count) { slot in
                    let start = batchStarts[slot]
                    let copyCount = min(windowSampleCount, totalSamples - start)
                    var winLeft = [Float](repeating: 0, count: windowSampleCount)
                    var winRight = [Float](repeating: 0, count: windowSampleCount)
                    winLeft.withUnsafeMutableBufferPointer { dst in
                        left.withUnsafeBufferPointer { src in
                            dst.baseAddress!.update(from: src.baseAddress! + start, count: copyCount)
                        }
                    }
                    winRight.withUnsafeMutableBufferPointer { dst in
                        right.withUnsafeBufferPointer { src in
                            dst.baseAddress!.update(from: src.baseAddress! + start, count: copyCount)
                        }
                    }

                    do {
                        // `pool[slot]`, not a shared `model` — each CoreMLSeparationModel instance
                        // owns one mutable input buffer, so two windows sharing an instance across
                        // threads would race on it and corrupt output. Disjoint slots, disjoint
                        // instances, no shared mutable state between concurrent tasks.
                        let stems = try winLeft.withUnsafeBufferPointer { leftPtr -> [SeparationStem: StemChannels] in
                            try winRight.withUnsafeBufferPointer { rightPtr in
                                try pool[slot].separateAllStems(
                                    left: leftPtr.baseAddress!,
                                    right: rightPtr.baseAddress!,
                                    frameCount: windowSampleCount,
                                    sampleRate: modelSampleRate
                                )
                            }
                        }
                        results[slot] = .success(stems)
                    } catch {
                        results[slot] = .failure(error)
                    }
                }
            }

            for (slot, start) in batchStarts.enumerated() {
                let stems: [SeparationStem: StemChannels]
                switch batchResults[slot] {
                case .success(let value):
                    stems = value
                case .failure(let error):
                    throw error
                case .none:
                    continue // concurrentPerform covers every slot; unreachable in practice.
                }

                let usableCount = min(windowSampleCount, totalSamples - start)
                for (stem, channels) in stems {
                    outputs[stem]!.left.withUnsafeMutableBufferPointer { out in
                        channels.left.withUnsafeBufferPointer { src in
                            for i in 0..<usableCount {
                                out[start + i] += src[i] * hann[i]
                            }
                        }
                    }
                    outputs[stem]!.right.withUnsafeMutableBufferPointer { out in
                        channels.right.withUnsafeBufferPointer { src in
                            for i in 0..<usableCount {
                                out[start + i] += src[i] * hann[i]
                            }
                        }
                    }
                }
                weight.withUnsafeMutableBufferPointer { out in
                    for i in 0..<usableCount {
                        out[start + i] += hann[i]
                    }
                }

                let finalizedEnd = min(totalSamples, start + hop)

                if finalizedEnd > flushedFrames {
                    let range = flushedFrames..<finalizedEnd
                    for stem in SeparationStem.allCases {
                        Self.normalize(&outputs[stem]!.left, weight: weight, range: range)
                        Self.normalize(&outputs[stem]!.right, weight: weight, range: range)
                        try Self.appendChunk(
                            writer: writers[stem]!,
                            format: targetFormat,
                            left: outputs[stem]!.left,
                            right: outputs[stem]!.right,
                            range: range
                        )

                        // Never fatal: a missing sidecar is regenerable by `PeakSidecarMigrator.backfill`,
                        // which Phase 2 will invoke when a clip is opened, whereas a thrown error here
                        // would abandon the separation itself.
                        do {
                            try peakWriters[stem]?.append(
                                Self.monoDownmix(left: outputs[stem]!.left, right: outputs[stem]!.right, range: range)
                            )
                        } catch {
                            AppLogger.shared.warning("Peak append failed for \(stem.rawValue): \(error.localizedDescription)")
                        }
                    }
                    flushedFrames = finalizedEnd

                    workingClip.readyDurationSeconds = Double(flushedFrames) / modelSampleRate
                    workingClip.stemFileNames = fileNames
                    workingClip.peakFileNames = peakFileNames
                    // Spec §6: the user can set a tempo or drag the downbeat at any point during
                    // separation. `workingClip` is a snapshot from before separation began, so without
                    // this it would silently overwrite that edit — and leave `isBeatGridUserSet` false,
                    // letting the final `detectBeatGrid` call below clobber it again.
                    workingClip = withCurrentBeatGrid(workingClip)
                    libraryStore.updateExisting(workingClip)
                    onUpdate(workingClip)
                }
            }

            windowStart = cursor
        }

        for (stem, writer) in peakWriters {
            do {
                try writer.finish()
            } catch {
                AppLogger.shared.warning("Peak sidecar finish failed for \(stem.rawValue): \(error.localizedDescription)")
            }
        }

        workingClip.readyDurationSeconds = workingClip.durationSeconds
        workingClip.stemFileNames = fileNames
        workingClip.peakFileNames = peakFileNames
        workingClip.processingFailed = false
        // Detection needs the finished drums file, so it runs here rather than in the flush loop.
        // Already on the separation queue; `detectBeatGrid` cannot throw. Refreshed first so
        // detection sees the current `isBeatGridUserSet`, not the stale snapshot's.
        workingClip = detectBeatGrid(for: withCurrentBeatGrid(workingClip))
        libraryStore.updateExisting(workingClip)
        onUpdate(workingClip)
    }

    /// Refreshes the beat-grid fields from the store before persisting.
    ///
    /// `workingClip` is a snapshot taken before separation began, but the user can set a tempo or
    /// drag the downbeat at any point during it. Writing the snapshot back would silently discard
    /// that edit — and leave `isBeatGridUserSet` false, so detection would overwrite it at the end,
    /// which is exactly what spec §6 forbids.
    ///
    /// Internal rather than private so `BeatDetectionWiringTests` can pin it directly, the same way
    /// `detectBeatGrid` is — driving the real `process()` pipeline in a test would need a loaded
    /// separation model over real audio, which is what that suite deliberately avoids.
    func withCurrentBeatGrid(_ clip: PracticeClip) -> PracticeClip {
        guard let current = libraryStore.clip(withID: clip.id) else { return clip }
        var merged = clip
        merged.bpm = current.bpm
        merged.downbeatOffsetSeconds = current.downbeatOffsetSeconds
        merged.beatConfidence = current.beatConfidence
        merged.isBeatGridUserSet = current.isBeatGridUserSet
        return merged
    }

    /// Detects a beat grid from the clip's drums stem and returns the clip with it applied.
    ///
    /// Runs on the drums rather than the mix (spec §6): an isolated drum track has no harmonic or
    /// vocal energy to mistake for a transient, which is an advantage most detectors do not get.
    ///
    /// Deliberately non-throwing and total: a clip with no drums, an unreadable file, or a
    /// low-confidence result all come back unchanged. Beat detection is a convenience on top of
    /// separation and must never be able to fail it.
    func detectBeatGrid(for clip: PracticeClip) -> PracticeClip {
        // Spec §6: never run on, nor overwrite, a grid the user set by hand.
        guard !clip.isBeatGridUserSet else { return clip }
        guard let fileName = clip.stemFileNames[SeparationStem.drums.rawValue] else { return clip }

        let url = libraryStore.stemFileURL(clipID: clip.id, fileName: fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return clip }

        do {
            guard let detection = try BeatDetector.detect(audioURL: url) else { return clip }
            guard detection.confidence >= BeatDetector.confidenceThreshold else {
                AppLogger.shared.info("Beat detection below threshold for \(clip.title): \(detection.confidence)")
                return clip
            }
            var updated = clip
            updated.bpm = detection.bpm
            updated.downbeatOffsetSeconds = detection.downbeatOffsetSeconds
            updated.beatConfidence = detection.confidence
            return updated
        } catch {
            AppLogger.shared.warning("Beat detection failed for \(clip.title): \(error.localizedDescription)")
            return clip
        }
    }

    /// One `CoreMLSeparationModel` instance per concurrent slot: each instance owns its own input
    /// buffer and scratch pointers (`CoreMLSeparationModel`'s `inputArray`, `modelLeftScratch`,
    /// `modelRightScratch`), so it is NOT safe for two windows to call into one shared instance
    /// concurrently — that's what actually makes the batched loop above safe, not a lock or queue.
    /// Cached and reused across separations for this engine's lifetime, same as the single cached
    /// model before pooling existed.
    ///
    /// Grows to `size` lazily and settles for fewer if a later instance fails to load (memory
    /// pressure from a second ~200MB model is the realistic failure mode) rather than failing the
    /// whole separation over a concurrency nice-to-have — but the first instance failing is fatal,
    /// exactly as before pooling existed.
    private func loadModelPool(size: Int) throws -> [AudioSeparationModel] {
        if modelPool.isEmpty {
            modelPool.append(try SeparationModelFactory.loadModel(variant: .balanced, captureSampleRate: 44_100))
        }
        while modelPool.count < size {
            guard let extra = try? SeparationModelFactory.loadModel(variant: .balanced, captureSampleRate: 44_100) else {
                break
            }
            modelPool.append(extra)
        }
        return modelPool
    }

    /// Concurrent CoreML instances, not CPU threads: any win comes from CoreML/ANE overlapping
    /// work across instances, or CPU-side pre/post-processing (window copy, stem extraction,
    /// resampling) for one window overlapping another's compute — not from more CPU cores. So this
    /// is deliberately small and NOT tied to `ProcessInfo.activeProcessorCount`. Each extra
    /// instance costs a full extra model load in memory, and the Neural Engine is shared hardware
    /// that may simply serialize concurrent submissions rather than overlap them — this needs
    /// measuring on real hardware, not assumed. Override with
    /// MINUSONE_OFFLINE_INFERENCE_CONCURRENCY=<n> to test other values before changing the default.
    private static func desiredConcurrency() -> Int {
        if let raw = ProcessInfo.processInfo.environment["MINUSONE_OFFLINE_INFERENCE_CONCURRENCY"],
           let value = Int(raw), value > 0 {
            return value
        }
        return 2
    }

    // MARK: - Decoding

    private static func decodeToModelFormat(sourceURL: URL, sampleRate: Double) throws -> (left: [Float], right: [Float]) {
        let sourceFile = try AVAudioFile(forReading: sourceURL)
        let sourceFormat = sourceFile.processingFormat
        guard sourceFile.length > 0,
              let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(sourceFile.length))
        else { throw SeparationError.emptyAudio }
        try sourceFile.read(into: sourceBuffer)

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 2,
            interleaved: false
        ) else { throw SeparationError.emptyAudio }

        let resultBuffer: AVAudioPCMBuffer
        if sourceFormat.sampleRate == targetFormat.sampleRate,
           sourceFormat.channelCount == targetFormat.channelCount,
           sourceFormat.commonFormat == targetFormat.commonFormat,
           !sourceFormat.isInterleaved {
            resultBuffer = sourceBuffer
        } else {
            guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
                throw SeparationError.emptyAudio
            }
            let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(sourceBuffer.frameLength) * ratio) + AVAudioFrameCount(sampleRate)
            guard let targetBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
                throw SeparationError.emptyAudio
            }

            var provided = false
            var conversionError: NSError?
            converter.convert(to: targetBuffer, error: &conversionError) { _, outStatus in
                if provided {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                provided = true
                outStatus.pointee = .haveData
                return sourceBuffer
            }
            if let conversionError { throw conversionError }
            resultBuffer = targetBuffer
        }

        let frameCount = Int(resultBuffer.frameLength)
        guard frameCount > 0, let channelData = resultBuffer.floatChannelData else {
            throw SeparationError.emptyAudio
        }
        let channelCount = Int(resultBuffer.format.channelCount)
        let left = Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))
        let right = channelCount > 1
            ? Array(UnsafeBufferPointer(start: channelData[1], count: frameCount))
            : left
        return (left, right)
    }

    private static func assertNotSilent(left: [Float], right: [Float]) throws {
        var peakLeft: Float = 0
        var peakRight: Float = 0
        left.withUnsafeBufferPointer { vDSP_maxmgv($0.baseAddress!, 1, &peakLeft, vDSP_Length($0.count)) }
        right.withUnsafeBufferPointer { vDSP_maxmgv($0.baseAddress!, 1, &peakRight, vDSP_Length($0.count)) }
        guard max(peakLeft, peakRight) > 1e-4 else { throw SeparationError.silentAudio }
    }

    // MARK: - OLA helpers

    private static func hannWindow(length: Int) -> [Float] {
        guard length > 1 else { return [Float](repeating: 1, count: max(length, 1)) }
        var window = [Float](repeating: 0, count: length)
        vDSP_hann_window(&window, vDSP_Length(length), Int32(vDSP_HANN_NORM))
        return window
    }

    private static func normalize(_ samples: inout [Float], weight: [Float], range: Range<Int>) {
        samples.withUnsafeMutableBufferPointer { buffer in
            weight.withUnsafeBufferPointer { w in
                for i in range {
                    let denom = w[i]
                    if denom > 1e-6 {
                        buffer[i] /= denom
                    }
                }
            }
        }
    }

    /// Averages a range of a stem's two channels into mono for peak generation.
    ///
    /// Internal rather than private so tests can pin the convention: it must match
    /// `WaveformPeakGenerator`'s downmix, or the stem sidecars and the mix sidecar would be on
    /// different scales and the shared normalisation reference would be meaningless.
    static func monoDownmix(left: [Float], right: [Float], range: Range<Int>) -> [Float] {
        guard !range.isEmpty else { return [] }
        var mono = [Float](repeating: 0, count: range.count)
        left.withUnsafeBufferPointer { leftPtr in
            right.withUnsafeBufferPointer { rightPtr in
                mono.withUnsafeMutableBufferPointer { out in
                    vDSP_vadd(
                        leftPtr.baseAddress! + range.lowerBound, 1,
                        rightPtr.baseAddress! + range.lowerBound, 1,
                        out.baseAddress!, 1,
                        vDSP_Length(range.count)
                    )
                    var scale: Float = 0.5
                    vDSP_vsmul(out.baseAddress!, 1, &scale, out.baseAddress!, 1, vDSP_Length(range.count))
                }
            }
        }
        return mono
    }

    private static func appendChunk(
        writer: AVAudioFile,
        format: AVAudioFormat,
        left: [Float],
        right: [Float],
        range: Range<Int>
    ) throws {
        let count = range.count
        guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { return }
        buffer.frameLength = AVAudioFrameCount(count)
        guard let channelData = buffer.floatChannelData else { return }
        left.withUnsafeBufferPointer { src in
            channelData[0].update(from: src.baseAddress! + range.lowerBound, count: count)
        }
        right.withUnsafeBufferPointer { src in
            channelData[1].update(from: src.baseAddress! + range.lowerBound, count: count)
        }
        try writer.write(from: buffer)
    }
}
