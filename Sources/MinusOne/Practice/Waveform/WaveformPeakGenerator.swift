import AVFoundation
import Accelerate

/// Generates downsampled min/max peak pairs from an audio file for waveform rendering.
/// Used both for the instant raw-waveform-on-import and the persisted sidebar thumbnail.
enum WaveformPeakGenerator {
    enum GeneratorError: Error, LocalizedError {
        case emptyFile

        var errorDescription: String? {
            switch self {
            case .emptyFile: return "Audio file contains no frames."
            }
        }
    }

    /// Returns an interleaved [min0, max0, min1, max1, ...] array of length `targetColumns * 2`.
    static func generatePeaks(url: URL, targetColumns: Int) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let totalFrames = Int(file.length)
        guard totalFrames > 0, targetColumns > 0 else { throw GeneratorError.emptyFile }

        let framesPerColumn = max(1, totalFrames / targetColumns)
        var peaks = [Float](repeating: 0, count: targetColumns * 2)

        let chunkCapacity: AVAudioFrameCount = 65_536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkCapacity) else {
            throw GeneratorError.emptyFile
        }

        let channelCount = Int(format.channelCount)
        var framesRead = 0
        var monoScratch = [Float](repeating: 0, count: Int(chunkCapacity))

        while true {
            buffer.frameLength = 0
            try file.read(into: buffer, frameCount: chunkCapacity)
            let n = Int(buffer.frameLength)
            if n == 0 { break }
            guard let channelData = buffer.floatChannelData else { break }

            if channelCount == 1 {
                monoScratch.withUnsafeMutableBufferPointer { dest in
                    dest.baseAddress!.update(from: channelData[0], count: n)
                }
            } else {
                monoScratch.withUnsafeMutableBufferPointer { dest in
                    vDSP_vadd(channelData[0], 1, channelData[1], 1, dest.baseAddress!, 1, vDSP_Length(n))
                    var scale: Float = 0.5
                    vDSP_vsmul(dest.baseAddress!, 1, &scale, dest.baseAddress!, 1, vDSP_Length(n))
                }
            }

            for frame in 0..<n {
                let globalFrame = framesRead + frame
                let column = min(targetColumns - 1, globalFrame / framesPerColumn)
                let sample = monoScratch[frame]
                if sample < peaks[column * 2] { peaks[column * 2] = sample }
                if sample > peaks[column * 2 + 1] { peaks[column * 2 + 1] = sample }
            }
            framesRead += n
            if n < Int(chunkCapacity) { break }
        }

        return peaks
    }

    /// Streams an audio file into a peak sidecar.
    ///
    /// Used for the mix track at import, and to backfill sidecars for clips that predate the
    /// format. Stems written during separation do not come through here — `OfflineSeparationEngine`
    /// already holds those samples in memory and feeds `PeakSidecarWriter` directly rather than
    /// decoding the file it just wrote.
    static func writeSidecar(
        from sourceURL: URL,
        to destinationURL: URL,
        framesPerColumn: Int = PeakSidecar.defaultFramesPerColumn
    ) throws {
        let file = try AVAudioFile(forReading: sourceURL)
        let format = file.processingFormat
        guard file.length > 0 else { throw GeneratorError.emptyFile }

        let writer = try PeakSidecarWriter(
            url: destinationURL,
            sampleRate: format.sampleRate,
            framesPerColumn: framesPerColumn
        )

        let chunkCapacity: AVAudioFrameCount = 65_536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkCapacity) else {
            throw GeneratorError.emptyFile
        }
        let channelCount = Int(format.channelCount)
        var monoScratch = [Float](repeating: 0, count: Int(chunkCapacity))

        while true {
            buffer.frameLength = 0
            try file.read(into: buffer, frameCount: chunkCapacity)
            let frames = Int(buffer.frameLength)
            if frames == 0 { break }
            guard let channelData = buffer.floatChannelData else { break }

            // Same mono downmix the thumbnail generator uses, so the two agree.
            monoScratch.withUnsafeMutableBufferPointer { dest in
                if channelCount == 1 {
                    dest.baseAddress!.update(from: channelData[0], count: frames)
                } else {
                    vDSP_vadd(channelData[0], 1, channelData[1], 1, dest.baseAddress!, 1, vDSP_Length(frames))
                    var scale: Float = 0.5
                    vDSP_vsmul(dest.baseAddress!, 1, &scale, dest.baseAddress!, 1, vDSP_Length(frames))
                }
            }

            try writer.append(monoScratch[0..<frames])
            if frames < Int(chunkCapacity) { break }
        }

        try writer.finish()
    }
}
