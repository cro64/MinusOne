import AppKit

extension NSColor {
    /// Builds a color that resolves per-appearance. `bestMatch` (rather than comparing
    /// `appearance.name` directly) is what makes the increased-contrast and vibrant appearance
    /// variants fall on the correct side instead of silently taking the light branch.
    private static func dynamic(_ name: String, light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: NSColor.Name(name)) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }

    /// Wraps a color *derived* from a system color (`labelColor.withAlphaComponent(…)` and
    /// friends) back into a genuinely dynamic color.
    ///
    /// This indirection is load-bearing, and not obviously so. `withAlphaComponent` on a dynamic
    /// system color does **not** return another dynamic color — it resolves against whatever
    /// appearance is current and hands back a plain, fixed color. So the derived tokens only ever
    /// look correct if the expression is re-evaluated inside the right appearance, which is fine
    /// for a `draw(_:)` body but not for anything that *stores* the result (`ThemedView.fillColor`,
    /// `NSTextField.backgroundColor`). Measured: a `ThemedView` built from a plain computed
    /// `cardBackground` kept a white 60% fill in dark mode even though its
    /// `viewDidChangeEffectiveAppearance` fired and re-read the property.
    ///
    /// Re-running the derivation inside the provider — which AppKit calls once per appearance, on
    /// demand — gives a color that resolves correctly however late it's read.
    private static func derived(_ name: String, _ make: @escaping () -> NSColor) -> NSColor {
        NSColor(name: NSColor.Name(name)) { appearance in
            var resolved = NSColor.clear
            appearance.performAsCurrentDrawingAppearance { resolved = make() }
            return resolved
        }
    }

    /// `labelColor` at a given strength, as a dynamic color safe to store. Covers the several
    /// one-off `NSColor.labelColor.withAlphaComponent(…)` washes across the UI.
    static func labelTint(_ alpha: CGFloat) -> NSColor {
        derived("labelTint-\(alpha)") { NSColor.labelColor.withAlphaComponent(alpha) }
    }

    /// `controlBackgroundColor` at a given strength, as a dynamic color safe to store.
    static func controlBackgroundTint(_ alpha: CGFloat) -> NSColor {
        derived("controlBackgroundTint-\(alpha)") { NSColor.controlBackgroundColor.withAlphaComponent(alpha) }
    }

    /// Brand coral, `#E8475A` (`srgb 0.910, 0.278, 0.353`). Replaces `.controlAccentColor`
    /// app-wide per the design system in REDESIGN.md §6.
    ///
    /// Deliberately *not* appearance-dependent: this is the canonical brand color and it's reserved
    /// for large fills (buttons, icon fills, slider tracks, the segmented control's pill), where it
    /// carries enough area to read on either surface. Measured against the real window backgrounds
    /// it lands at 3.2:1 light / 4.4:1 dark, and white-on-coral button titles at 3.8:1 — all above
    /// the 3:1 non-text/large-text threshold, so there's nothing for a dark variant to fix.
    static let brandAccent = NSColor(srgbRed: 0.910, green: 0.278, blue: 0.353, alpha: 1.0)

    /// The accent at small scale — status text and small dots/indicators, where the full-saturation
    /// coral is harder to read. `brandAccent` stays reserved for large fills.
    ///
    /// This is the case REDESIGN.md §6 anticipated with "a defined dark-appearance variant if
    /// contrast needs adjusting": the light value `#A93347` is a deepened coral that measures
    /// 6.5:1 on a light card but only **2.6:1** on a dark one — a clear fail for the small text it
    /// exists to serve. The dark variant lifts rather than deepens (`#F2707E`, 5.9:1 on a dark
    /// card), applying the same "move away from the surface" intent in the opposite direction.
    static let brandAccentDeep = dynamic(
        "brandAccentDeep",
        light: NSColor(srgbRed: 0.663, green: 0.200, blue: 0.278, alpha: 1.0),
        dark: NSColor(srgbRed: 0.949, green: 0.439, blue: 0.494, alpha: 1.0)
    )

    /// Amber `#D98C3F` — Drums identity color, REDESIGN.md §4/§6 stem palette.
    static let stemDrums = NSColor(srgbRed: 0.851, green: 0.549, blue: 0.247, alpha: 1.0)
    /// Teal `#3F8FA8` — Bass identity color.
    static let stemBass = NSColor(srgbRed: 0.247, green: 0.561, blue: 0.659, alpha: 1.0)
    /// Plum `#8A6FB0` — Other identity color.
    static let stemOther = NSColor(srgbRed: 0.541, green: 0.435, blue: 0.690, alpha: 1.0)

    /// Text-legible counterparts to the three stem fills, following exactly the
    /// `brandAccent`/`brandAccentDeep` split that already exists for the vocals identity — see
    /// `SeparationStem.identityTextColor` for why the two roles had to be separated.
    static let stemDrumsText = dynamic(
        "stemDrumsText",
        light: NSColor(srgbRed: 0.576, green: 0.373, blue: 0.169, alpha: 1.0),  // #935F2B
        dark: NSColor(srgbRed: 0.878, green: 0.627, blue: 0.353, alpha: 1.0)    // #E0A05A
    )
    static let stemBassText = dynamic(
        "stemBassText",
        light: NSColor(srgbRed: 0.200, green: 0.451, blue: 0.529, alpha: 1.0),  // #337387
        dark: NSColor(srgbRed: 0.373, green: 0.659, blue: 0.753, alpha: 1.0)    // #5FA8C0
    )
    static let stemOtherText = dynamic(
        "stemOtherText",
        light: NSColor(srgbRed: 0.467, green: 0.376, blue: 0.596, alpha: 1.0),  // #776098
        dark: NSColor(srgbRed: 0.663, green: 0.561, blue: 0.816, alpha: 1.0)    // #A98FD0
    )

    /// Approximates the Modernist design system's `--color-divider` token
    /// (`color-mix(in srgb, #201e1d 40%, transparent)`) with a dynamic system color instead of a
    /// literal fixed hex — `#201e1d` is near-black and would be effectively invisible against a
    /// dark-mode surface. `labelColor` already adapts per-appearance, so tinting its alpha keeps
    /// the "40%-strength foreground" relationship the token describes in both light and dark.
    ///
    /// Wrapped in `derived` rather than written as a bare
    /// `NSColor.labelColor.withAlphaComponent(0.4)`: as a plain `static let` that expression is
    /// evaluated once, against whichever appearance happened to be current, and stays there — with
    /// the app launched in Light this was 40% *black* in dark mode, i.e. an invisible divider.
    static let flatDivider = derived("flatDivider") { NSColor.labelColor.withAlphaComponent(0.4) }

    /// Card surface, one step off the window background. Derived from `controlBackgroundColor`
    /// rather than a literal hex — a fixed light fill would be a bright rectangle on a dark-mode
    /// window, which is exactly what the frozen version produced: a **white** 60% wash.
    static let cardBackground = derived("cardBackground") { NSColor.controlBackgroundColor.withAlphaComponent(0.6) }

    /// Card outline. Deliberately weaker than `flatDivider`: a card border runs the full perimeter,
    /// so at divider strength a grid of them reads as a wireframe rather than as grouped surfaces.
    static let cardBorder = derived("cardBorder") { NSColor.labelColor.withAlphaComponent(0.12) }
}

extension SeparationStem {
    /// Fixed per-stem identity color (REDESIGN.md §4), reused for the mixer row's slider fill and
    /// everywhere a stem is represented as an area of color. Vocals deliberately reuses the brand
    /// accent.
    var identityColor: NSColor {
        switch self {
        case .vocals: return .brandAccent
        case .drums: return .stemDrums
        case .bass: return .stemBass
        case .other: return .stemOther
        }
    }

    /// The identity color at text scale. The stem palette was specced for fills, and used as a
    /// 13pt label color it misses 4.5:1 on a light card by a wide margin — measured at 2.7:1
    /// (Drums), 3.7:1 (Bass), 4.2:1 (Other). Rather than restate the brand hues (which would
    /// change every fill in the app), this mirrors the split REDESIGN.md §6 already drew between
    /// `brandAccent` and `brandAccentDeep`: same hue and saturation, brightness moved away from
    /// whichever surface the text sits on. All four clear 4.5:1 in both appearances.
    var identityTextColor: NSColor {
        switch self {
        case .vocals: return .brandAccentDeep
        case .drums: return .stemDrumsText
        case .bass: return .stemBassText
        case .other: return .stemOtherText
        }
    }
}
