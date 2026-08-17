import AppKit

/// The user's Light/Dark choice (Live tab → Appearance). `.system` is the default and the only
/// value that leaves `NSApp.appearance` unset, which is what lets the app keep tracking macOS's
/// own Light/Dark switch (including the automatic sunset/sunrise "Auto" setting) instead of
/// pinning itself the first time the app launches.
enum AppAppearance: String, CaseIterable {
    case system
    case light
    case dark

    var displayName: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// Glyph shown on the cycling Theme pill, so the current stage reads at a glance rather than
    /// only from the word next to it.
    var symbolName: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        }
    }

    /// Next stage in the cycle. Ordered System → Light → Dark → System so the default sits at the
    /// top of the loop and is always one step from wherever you are.
    var next: AppAppearance {
        let all = AppAppearance.allCases
        let index = all.firstIndex(of: self) ?? 0
        return all[(index + 1) % all.count]
    }

    /// `nil` for `.system` — assigning `nil` to `NSApp.appearance` is how AppKit is told "inherit
    /// from the system", not a no-op.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    /// Setting `NSApp.appearance` cascades to every window and view, which fires
    /// `viewDidChangeEffectiveAppearance` throughout the tree. That's the single mechanism the rest
    /// of this file relies on, so an in-app switch and a system-wide switch take the same path and
    /// there's no second code path to keep in sync.
    func apply() {
        NSApp.appearance = nsAppearance
    }
}

extension NSView {
    /// Runs `body` with this view's `effectiveAppearance` installed as the current drawing
    /// appearance.
    ///
    /// Reading `.cgColor` off a dynamic `NSColor` resolves it against whatever appearance is
    /// current *at that moment* and returns a plain, frozen `CGColor`. `NSApp`'s appearance is not
    /// automatically current outside of a draw cycle, so a `layer?.backgroundColor = …cgColor`
    /// assignment made from `init` or an update method can easily resolve against the wrong
    /// appearance — and, because `CALayer` colors are frozen values rather than dynamic ones, it
    /// then stays wrong forever. Wrapping the assignment here fixes the first half; overriding
    /// `viewDidChangeEffectiveAppearance` to re-run it fixes the second.
    func resolvingEffectiveAppearance(_ body: () -> Void) {
        effectiveAppearance.performAsCurrentDrawingAppearance(body)
    }
}

/// Layer-backed container whose fill and border are declared as `NSColor`s and re-resolved on every
/// appearance change, instead of being written once into the layer as frozen `CGColor`s.
///
/// This exists because `CALayer` has no dynamic-color support at all: the ~15 sites across the app
/// that did `layer?.backgroundColor = NSColor.something.cgColor` in a view's initializer painted
/// themselves for whichever appearance happened to be current at construction and never updated.
/// Use this anywhere a plain `NSView` was being used purely as a colored rectangle.
class ThemedView: AutoLayoutView {
    var fillColor: NSColor? {
        didSet { applyThemedColors() }
    }

    var strokeColor: NSColor? {
        didSet { applyThemedColors() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    convenience init(fill: NSColor? = nil, stroke: NSColor? = nil) {
        self.init(frame: .zero)
        fillColor = fill
        strokeColor = stroke
        applyThemedColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyThemedColors()
    }

    func applyThemedColors() {
        resolvingEffectiveAppearance {
            layer?.backgroundColor = (fillColor ?? .clear).cgColor
            if let strokeColor {
                layer?.borderColor = strokeColor.cgColor
            }
        }
    }
}
