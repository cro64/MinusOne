import AppKit

/// Small pill toggle used inline with a label/subtitle row (the row layout doesn't suit
/// `NSSwitch`); on-state fill uses `brandAccent`, the same accent used for every other
/// "engaged" control in the app (REDESIGN.md §6).
final class ToggleSwitchView: NSView {
    var isOn = false {
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

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let track = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        (isOn ? NSColor.brandAccent : RecordingTheme.hairline).setFill()
        track.fill()

        let knobDiameter = bounds.height - 4
        let knobX = isOn ? bounds.width - knobDiameter - 2 : 2
        let knob = NSBezierPath(ovalIn: NSRect(x: knobX, y: 2, width: knobDiameter, height: knobDiameter))
        NSColor.white.setFill()
        knob.fill()
    }

    override func mouseDown(with event: NSEvent) {
        isOn.toggle()
        onToggle?(isOn)
    }
}
