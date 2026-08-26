import CoreGraphics
import Foundation

/// One drawn column of a waveform: the extremes of the samples it covers, plus their RMS.
///
/// RMS is carried alongside the extremes because the peak-envelope-with-solid-RMS-core rendering
/// is the single largest legibility gain available, and it cannot be reconstructed from min/max.
struct PeakColumn: Equatable {
    var minimum: Float
    var maximum: Float
    var rms: Float

    static let silent = PeakColumn(minimum: 0, maximum: 0, rms: 0)

    /// Largest absolute excursion — what normalisation and height mapping key off.
    var magnitude: Float { max(abs(minimum), abs(maximum)) }
}

/// Which track a peak sidecar describes.
///
/// The mix is a case of its own rather than a fifth stem: it exists at import, before separation
/// has produced anything, and it supplies the shared normalisation reference for all four stems.
enum PeakTrack: Hashable {
    case mix
    case stem(SeparationStem)

    static let all: [PeakTrack] = [.mix] + SeparationStem.allCases.map(PeakTrack.stem)

    /// Key used in `PracticeClip.peakFileNames`.
    var key: String {
        switch self {
        case .mix: return "mix"
        case .stem(let stem): return stem.rawValue
        }
    }

    var fileName: String { "\(key).peaks" }
}

/// Maps a linear sample magnitude to a 0...1 share of the lane height.
enum PeakScaling {
    /// Everything at or below this many dB relative to the reference collapses to zero height.
    static let floorDecibels: Float = -60

    /// dB with a −60 dB floor, per spec §5.
    ///
    /// Linear amplitude is why the current deck reads as sparse spikes over a dead middle, and it
    /// is what would make mix-relative normalisation unusable — under a linear map a stem 30 dB
    /// below the mix is a flat line. Here it still gets half the lane while staying honestly
    /// quieter than the drums.
    static func height(magnitude: Float, reference: Float) -> CGFloat {
        guard reference > 0, magnitude > 0 else { return 0 }
        let decibels = 20 * log10(magnitude / reference)
        guard decibels > floorDecibels else { return 0 }
        return CGFloat(min(1, (decibels - floorDecibels) / -floorDecibels))
    }
}
