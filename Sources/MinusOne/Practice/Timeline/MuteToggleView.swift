import AppKit

/// A stem's on/off switch, where on means the stem is playing: a solid coral track with the knob on
/// the right while it plays, and a grey track with the knob on the left once muted — the same colours
/// and knob sides as `ToggleSwitchView`, so "coral" means "on" everywhere in the app. There is no
/// separate icon for solo, because there is no separate solo state: a plain click toggles this stem's
/// own mute; Cmd-click isolates it (mutes every other stem, unmutes this one) — the old solo gesture,
/// folded into this control instead of a second visible button. See
/// `StemMixerController.isolateStem(_:)` for why one flag is enough to represent both.
///
/// The state it holds is still `isMuted`, because that is the engine's vocabulary; only what it draws
/// and tells VoiceOver is phrased as "playing".
final class MuteToggleView: NSView {
    var onMuteToggled: ((Bool) -> Void)?
    var onIsolateRequested: (() -> Void)?

    private(set) var isMuted = false

    private static let width: CGFloat = 34
    private static let height: CGFloat = 18
    private static let knobInset: CGFloat = 2

    /// `label` is the stem's name. It is the accessibility label as it stands: the switch is a checkbox
    /// that is checked while the stem plays, so "Drums, checked" is right where "Mute Drums, checked"
    /// would say the opposite of what is happening.
    init(label: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.height))
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: Self.width).isActive = true
        heightAnchor.constraint(equalToConstant: Self.height).isActive = true
        toolTip = "\(label) — click to mute or unmute, ⌘-click to hear only this stem"
        setAccessibilityLabel(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    /// The muted track is `flatDivider`, which inverts between appearances, so a theme switch has to
    /// repaint — the same guard `ToggleSwitchView` carries. Not unit-tested: `needsDisplay` doesn't
    /// report redraw requests reliably outside a real on-screen window (measured across windowless,
    /// undisplayed and displayed hosts), so the check is switching the theme and looking.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // A checkbox that is checked while the stem plays, matching the picture. `ToggleSwitchView` reports
    // itself the same way.
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .checkBox }
    override func accessibilityValue() -> Any? { !isMuted }

    /// Externally-driven update (the engine owns the real state after an isolate touches every
    /// lane) — mirrors `LaneHeaderView.setMuted(_:)`'s existing "the header is told, not asked"
    /// contract. Deliberately does not fire `onMuteToggled` — that closure reports a *request*
    /// this view originated, not every state change it's told about.
    func setMuted(_ muted: Bool) {
        guard isMuted != muted else { return }
        isMuted = muted
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let isPlaying = !isMuted
        let track = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        // On is playing: solid coral with the knob right, like `ToggleSwitchView` on. Off is muted:
        // neutral grey with the knob left. This once drew muted as the coral "on" state, which lit up
        // exactly the stems that were silent.
        (isPlaying ? NSColor.brandAccent : NSColor.flatDivider).setFill()
        track.fill()

        let knobDiameter = bounds.height - Self.knobInset * 2
        let knobX = isPlaying ? bounds.width - Self.knobInset - knobDiameter : Self.knobInset
        let knobRect = NSRect(x: knobX, y: Self.knobInset, width: knobDiameter, height: knobDiameter)
        NSColor.white.setFill()
        NSBezierPath(ovalIn: knobRect).fill()
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            simulateCmdClickForTesting()
        } else {
            simulateClickForTesting()
        }
    }

    // MARK: - Test seams

    // Matches this file's own reasoning for why `setMuted(_:)` doesn't fire callbacks: a real
    // click is a request this view originates, so it's driven directly rather than through a
    // synthesized `NSEvent`, which would exercise AppKit's event dispatch more than this view's
    // own logic.
    func simulateClickForTesting() {
        let newValue = !isMuted
        setMuted(newValue)
        onMuteToggled?(newValue)
    }

    func simulateCmdClickForTesting() {
        onIsolateRequested?()
    }
}
