import AppKit

/// Decides one hero-waveform bar's color: a weighted blend of the 4 stem identity colors by their
/// relative loudness at that instant, a neutral fallback when everything is silent, or a flat tail
/// gray when the bar predates full separation. Pure and stateless so it is unit-testable without a
/// view, a window, or a `PeakStore`.
enum HeroWaveformBlend: Equatable {
    /// Same tone `StemLaneView` draws its own unseparated tail in.
    static let tailColor = NSColor.tertiaryLabelColor.withAlphaComponent(0.5)
    /// "The mix isn't a fifth instrument" — the same rule `StemLaneView.identityColor` applies to
    /// the mix track's own color governs what a genuinely silent bar renders as here too.
    static let silenceColor = NSColor.secondaryLabelColor

    /// Below this combined weight, four stems' worth of noise-floor magnitude isn't a real blend —
    /// it's silence. `PeakScaling.height` floors any single stem at 0 below -60dB, so a bar with any
    /// real signal in it clears this quickly; only a bar where all 4 stems are near-exactly silent
    /// stays under it.
    static let silenceWeightFloor: Float = 0.05

    enum BarColor: Equatable {
        case blended(NSColor)
        case tail
    }

    /// Each stem's magnitude run through the same dB-floor mapping the bar's own height already
    /// uses, then normalized so the four weights sum to 1. Empty when every stem is at/under the
    /// noise floor.
    static func weights(forMagnitudes magnitudes: [SeparationStem: Float], reference: Float) -> [SeparationStem: Float] {
        var raw: [SeparationStem: Float] = [:]
        for stem in SeparationStem.allCases {
            let magnitude = magnitudes[stem] ?? 0
            raw[stem] = Float(PeakScaling.height(magnitude: magnitude, reference: reference))
        }
        let total = raw.values.reduce(0, +)
        guard total >= silenceWeightFloor else { return [:] }
        return raw.mapValues { $0 / total }
    }

    /// The color a bar should draw in. `isSeparated` gates on whether all 4 stems have peaks at this
    /// bar's time yet — a bar can't be honestly blended from only some of the stems.
    static func barColor(
        forMagnitudes magnitudes: [SeparationStem: Float],
        reference: Float,
        isSeparated: Bool
    ) -> BarColor {
        guard isSeparated else { return .tail }
        let weighted = weights(forMagnitudes: magnitudes, reference: reference)
        guard !weighted.isEmpty else { return .blended(silenceColor) }
        return .blended(blend(weighted))
    }

    /// Plain weighted RGB average — no perceptual/Lab blending. The 4 identity colors are fixed
    /// sRGB values (`DesignColors.swift`), not appearance-dependent, so this needs no per-appearance
    /// resolution.
    private static func blend(_ weights: [SeparationStem: Float]) -> NSColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        for (stem, weight) in weights {
            guard let component = stem.identityColor.usingColorSpace(.sRGB) else { continue }
            r += component.redComponent * CGFloat(weight)
            g += component.greenComponent * CGFloat(weight)
            b += component.blueComponent * CGFloat(weight)
        }
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }
}
