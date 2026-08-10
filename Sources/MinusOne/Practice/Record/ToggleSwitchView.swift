import AppKit

/// Small pill toggle matching the recording panel's own look, rather than the system NSSwitch.
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
        (isOn ? RecordingTheme.amberDim : RecordingTheme.hairline).setFill()
        track.fill()

        let knobDiameter = bounds.height - 4
        let knobX = isOn ? bounds.width - knobDiameter - 2 : 2
        let knob = NSBezierPath(ovalIn: NSRect(x: knobX, y: 2, width: knobDiameter, height: knobDiameter))
        (isOn ? RecordingTheme.amber : RecordingTheme.putty).setFill()
        knob.fill()
    }

    override func mouseDown(with event: NSEvent) {
        isOn.toggle()
        onToggle?(isOn)
    }
}
