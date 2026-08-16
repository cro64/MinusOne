import AppKit

/// Small pill toggle used inline with a label/subtitle row (the row layout doesn't suit
/// `NSSwitch`); on-state fill uses `brandAccent`, the same accent used for every other
/// "engaged" control in the app (REDESIGN.md §6). Also stands in for `NSSwitch` wherever the
/// on-state has to read as coral — `NSSwitch` paints itself with the *system* accent color and
/// offers no tint hook, so a native switch is the one control that can't honor §6.
final class ToggleSwitchView: NSView {
    var isOn = false {
        didSet { needsDisplay = true }
    }
    var isEnabled = true {
        didSet { needsDisplay = true }
    }
    var onToggle: ((Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 34, height: 19) }

    /// `draw(_:)` reads `flatDivider` and `windowBackgroundColor`, both of which invert between
    /// appearances — without this the off-state track and the disabled wash keep the old pixels.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let track = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        (isOn ? NSColor.brandAccent : NSColor.flatDivider).setFill()
        track.fill()

        let knobDiameter = bounds.height - 4
        let knobX = isOn ? bounds.width - knobDiameter - 2 : 2
        let knob = NSBezierPath(ovalIn: NSRect(x: knobX, y: 2, width: knobDiameter, height: knobDiameter))
        NSColor.white.setFill()
        knob.fill()

        // Disabled reads as a wash over the finished control rather than a second palette, so the
        // on/off shapes stay identical whether or not the toggle can be operated.
        if !isEnabled {
            NSColor.windowBackgroundColor.withAlphaComponent(0.55).setFill()
            track.fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        toggle()
    }

    // MARK: - Keyboard and accessibility
    //
    // `NSSwitch` came with these for free; a hand-drawn `NSView` doesn't, and the menu bar popover
    // is a primary surface, so they're spelled out rather than dropped.

    override var acceptsFirstResponder: Bool { isEnabled }
    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }

    override func keyDown(with event: NSEvent) {
        guard isEnabled, event.charactersIgnoringModifiers == " " else {
            super.keyDown(with: event)
            return
        }
        toggle()
    }

    private func toggle() {
        isOn.toggle()
        onToggle?(isOn)
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .checkBox }
    override func accessibilityValue() -> Any? { isOn }
    override func isAccessibilityEnabled() -> Bool { isEnabled }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        toggle()
        return true
    }
}
