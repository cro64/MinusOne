import AppKit

extension NSColor {
    /// Brand coral, `#E8475A` (`srgb 0.910, 0.278, 0.353`). Replaces `.controlAccentColor`
    /// app-wide per the design system in REDESIGN.md §6.
    static let brandAccent = NSColor(srgbRed: 0.910, green: 0.278, blue: 0.353, alpha: 1.0)

    /// Deepened accent, `#A93347` (`srgb 0.663, 0.200, 0.278`), for small-scale legibility —
    /// status text and small dots/indicators, where the full-saturation coral is harder to read
    /// at small sizes. `brandAccent` stays reserved for large fills (buttons, icon fills, slider
    /// tracks).
    static let brandAccentDeep = NSColor(srgbRed: 0.663, green: 0.200, blue: 0.278, alpha: 1.0)

    /// Amber `#D98C3F` — Drums identity color, REDESIGN.md §4/§6 stem palette.
    static let stemDrums = NSColor(srgbRed: 0.851, green: 0.549, blue: 0.247, alpha: 1.0)
    /// Teal `#3F8FA8` — Bass identity color.
    static let stemBass = NSColor(srgbRed: 0.247, green: 0.561, blue: 0.659, alpha: 1.0)
    /// Plum `#8A6FB0` — Other identity color.
    static let stemOther = NSColor(srgbRed: 0.541, green: 0.435, blue: 0.690, alpha: 1.0)

    /// Approximates the Modernist design system's `--color-divider` token
    /// (`color-mix(in srgb, #201e1d 40%, transparent)`) with a dynamic system color instead of a
    /// literal fixed hex — `#201e1d` is near-black and would be effectively invisible against a
    /// dark-mode surface. `labelColor` already adapts per-appearance, so tinting its alpha keeps
    /// the "40%-strength foreground" relationship the token describes in both light and dark.
    static let flatDivider = NSColor.labelColor.withAlphaComponent(0.4)
}

extension SeparationStem {
    /// Fixed per-stem identity color (REDESIGN.md §4), reused for the mixer row, slider fill,
    /// and label everywhere a stem is represented. Vocals deliberately reuses the brand accent.
    var identityColor: NSColor {
        switch self {
        case .vocals: return .brandAccent
        case .drums: return .stemDrums
        case .bass: return .stemBass
        case .other: return .stemOther
        }
    }
}
