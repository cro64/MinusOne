import AVFoundation
import Accelerate

/// Drives full-quality, non-realtime 4-stem separation over an entire clip using proper
/// Hann-window overlap-add (unlike the live path's causal hop-splice crossfade).
///
/// Processes one clip at a time on a serial background queue. As each analysis window's
/// contribution to the output becomes final (no later window can still touch it), that newly
/// finalized prefix is normalized, written to the stem files on disk, and reported via `onUpdate`
/// — this is what lets the deck start playback on the first few seconds while the rest of the
/// clip keeps processing in the background.
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
    private var cachedModel: AudioSeparationModel?

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
                self.libraryStore.update(failed)
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
        let model = try loadModelIfNeeded()
        let modelSampleRate = model.modelSampleRate
        let windowSampleCount = max(1, Int((model.preferredWindowSeconds * modelSampleRate).rounded()))
        let hop = max(1, windowSampleCount / 2)

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
        if let peaksFolder = try? libraryStore.ensurePeaksFolder(forClipID: clip.id) {
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

        while windowStart < totalSamples {
            let copyCount = min(windowSampleCount, totalSamples - windowStart)
            var winLeft = [Float](repeating: 0, count: windowSampleCount)
            var winRight = [Float](repeating: 0, count: windowSampleCount)
            winLeft.withUnsafeMutableBufferPointer { dst in
                left.withUnsafeBufferPointer { src in
                    dst.baseAddress!.update(from: src.baseAddress! + windowStart, count: copyCount)
                }
            }
            winRight.withUnsafeMutableBufferPointer { dst in
                right.withUnsafeBufferPointer { src in
                    dst.baseAddress!.update(from: src.baseAddress! + windowStart, count: copyCount)
                }
            }

            let stems = try winLeft.withUnsafeBufferPointer { leftPtr -> [SeparationStem: StemChannels] in
                try winRight.withUnsafeBufferPointer { rightPtr in
                    try model.separateAllStems(
                        left: leftPtr.baseAddress!,
                        right: rightPtr.baseAddress!,
                        frameCount: windowSampleCount,
                        sampleRate: modelSampleRate
                    )
                }
            }

            let usableCount = min(windowSampleCount, totalSamples - windowStart)
            for (stem, channels) in stems {
                outputs[stem]!.left.withUnsafeMutableBufferPointer { out in
                    channels.left.withUnsafeBufferPointer { src in
                        for i in 0..<usableCount {
                            out[windowStart + i] += src[i] * hann[i]
                        }
                    }
                }
                outputs[stem]!.right.withUnsafeMutableBufferPointer { out in
                    channels.right.withUnsafeBufferPointer { src in
                        for i in 0..<usableCount {
                            out[windowStart + i] += src[i] * hann[i]
                        }
                    }
                }
            }
            weight.withUnsafeMutableBufferPointer { out in
                for i in 0..<usableCount {
                    out[windowStart + i] += hann[i]
                }
            }

            windowStart += hop
            let finalizedEnd = min(totalSamples, windowStart)

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

                    // Never fatal: a missing sidecar is regenerated by `PeakSidecarMigrator`,
                    // whereas a thrown error here would abandon the separation itself.
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
                libraryStore.update(workingClip)
                onUpdate(workingClip)
            }
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
        libraryStore.update(workingClip)
        onUpdate(workingClip)
    }

    private func loadModelIfNeeded() throws -> AudioSeparationModel {
        if let cachedModel { return cachedModel }
        let model = try SeparationModelFactory.loadModel(variant: .balanced, captureSampleRate: 44_100)
        cachedModel = model
        return model
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
