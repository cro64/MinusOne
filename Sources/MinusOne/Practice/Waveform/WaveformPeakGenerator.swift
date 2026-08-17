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
}
