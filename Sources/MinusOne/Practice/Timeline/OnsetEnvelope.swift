import Accelerate
import Foundation

/// Spectral flux: how much *new* energy appears in each STFT frame.
///
/// This is the signal every later stage measures, so it is deliberately the dullest possible
/// version — a Hann-windowed magnitude spectrum, a first difference, half-wave rectified, summed
/// across bins. Rectification is what makes it an onset detector rather than an energy-change
/// detector: a note starting counts, a note ending does not.
enum OnsetEnvelope {
    /// Spec §6: 1024-sample window, 512-sample hop → 86.13 frames/second at 44.1kHz.
    static let windowSize = 1024
    static let hopSize = 512

    static func framesPerSecond(sampleRate: Double) -> Double {
        sampleRate / Double(hopSize)
    }

    static func compute(samples: [Float], sampleRate: Double) -> [Float] {
        guard samples.count >= windowSize else { return [] }

        let log2n = vDSP_Length(log2(Float(windowSize)).rounded())
        guard let fft = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(fft) }

        var window = [Float](repeating: 0, count: windowSize)
        vDSP_hann_window(&window, vDSP_Length(windowSize), Int32(vDSP_HANN_NORM))

        let binCount = windowSize / 2
        var previousMagnitudes = [Float](repeating: 0, count: binCount)
        var envelope: [Float] = []
        envelope.reserveCapacity((samples.count - windowSize) / hopSize + 1)

        var real = [Float](repeating: 0, count: binCount)
        var imaginary = [Float](repeating: 0, count: binCount)
        var windowed = [Float](repeating: 0, count: windowSize)
        var magnitudes = [Float](repeating: 0, count: binCount)

        var start = 0
        var isFirstFrame = true
        while start + windowSize <= samples.count {
            samples.withUnsafeBufferPointer { source in
                vDSP_vmul(source.baseAddress! + start, 1, window, 1, &windowed, 1, vDSP_Length(windowSize))
            }

            real.withUnsafeMutableBufferPointer { realPointer in
                imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                    var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imaginaryPointer.baseAddress!)
                    windowed.withUnsafeBufferPointer { input in
                        input.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: binCount) { complex in
                            vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(binCount))
                        }
                    }
                    vDSP_fft_zrip(fft, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(binCount))
                }
            }

            if isFirstFrame {
                // No previous frame to difference against; the first frame contributes nothing
                // rather than the whole spectrum as a spurious onset.
                envelope.append(0)
                isFirstFrame = false
            } else {
                var flux: Float = 0
                for bin in 0..<binCount {
                    let rise = magnitudes[bin] - previousMagnitudes[bin]
                    if rise > 0 { flux += rise }
                }
                envelope.append(flux)
            }
            previousMagnitudes = magnitudes
            start += hopSize
        }
        return envelope
    }
}
