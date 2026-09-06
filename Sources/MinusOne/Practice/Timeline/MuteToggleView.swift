import AppKit

/// A stem's mute switch: a soft-tinted coral track with a white knob that slides to whichever
/// side reflects the current state — left when audible, right when muted. There is no separate
/// icon for solo, because there is no separate solo state: a plain click toggles this stem's own
/// mute; Cmd-click isolates it (mutes every other stem, unmutes this one) — the old solo gesture,
/// folded into the mute control instead of a second visible button. See
/// `StemMixerController.isolateStem(_:)` for why one flag is enough to represent both.
final class MuteToggleView: NSView {
    var onMuteToggled: ((Bool) -> Void)?
    var onIsolateRequested: (() -> Void)?

    private(set) var isMuted = false

    private static let width: CGFloat = 34
    private static let height: CGFloat = 18
    private static let knobInset: CGFloat = 2

    init(label: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.height))
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: Self.width).isActive = true
        heightAnchor.constraint(equalToConstant: Self.height).isActive = true
        toolTip = "\(label) — ⌘-click to hear only this stem"
        setAccessibilityLabel(label)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

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
        let track = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        NSColor.brandAccent.withAlphaComponent(0.16).setFill()
        track.fill()

        let knobDiameter = bounds.height - Self.knobInset * 2
        let knobX = isMuted ? bounds.width - Self.knobInset - knobDiameter : Self.knobInset
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
