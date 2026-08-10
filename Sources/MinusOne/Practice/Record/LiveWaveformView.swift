import AppKit

/// Live-recording waveform: a thin scrolling polyline (not the deck's filled-bar style) with an
/// optional draggable auto-stop marker. The visible time axis is 0...autoStopSeconds when an
/// auto-stop is set (so the marker's position is meaningful), or 0...elapsed otherwise (so the
/// whole take so far is always visible).
final class LiveWaveformView: NSView {
    /// Matches `SystemAudioRecorder`'s peak-bucket cadence.
    static let bucketDurationSeconds: Double = 0.1

    var peaks: [Float] = [] { didSet { needsDisplay = true } }
    var elapsedSeconds: Double = 0 { didSet { needsDisplay = true } }
    var autoStopSeconds: Double? { didSet { needsDisplay = true } }
    var onDragAutoStop: ((Double) -> Void)?

    private var isDraggingMarker = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    private var windowSeconds: Double {
        max(1, autoStopSeconds ?? max(elapsedSeconds, 5))
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.clear(bounds)

        RecordingTheme.background.setFill()
        bounds.fill()

        let progressFraction = min(1, elapsedSeconds / windowSeconds)
        let progressRect = NSRect(x: 0, y: 0, width: bounds.width * progressFraction, height: bounds.height)
        RecordingTheme.red.withAlphaComponent(0.06).setFill()
        progressRect.fill()

        drawWaveformLine()

        if let autoStopSeconds {
            let x = bounds.width * CGFloat(autoStopSeconds / windowSeconds)
            drawMarker(atX: x)
        }
    }

    private func drawWaveformLine() {
        guard peaks.count >= 4 else { return }
        let columnCount = peaks.count / 2
        let midY = bounds.height / 2

        let path = NSBezierPath()
        for column in 0..<columnCount {
            let time = Double(column) * Self.bucketDurationSeconds
            let x = bounds.width * CGFloat(time / windowSeconds)
            if x > bounds.width { break }

            let magnitude = max(abs(peaks[column * 2]), abs(peaks[column * 2 + 1]))
            let y = midY - CGFloat(magnitude) * midY * 1.4
            let point = NSPoint(x: x, y: y)
            if column == 0 {
                path.move(to: point)
            } else {
                path.line(to: point)
            }
        }
        path.lineWidth = 1.2
        RecordingTheme.teal.setStroke()
        path.stroke()
    }

    private func drawMarker(atX x: CGFloat) {
        NSColor.brandAccentDeep.setStroke()
        let line = NSBezierPath()
        line.lineWidth = 1
        line.move(to: NSPoint(x: x, y: 0))
        line.line(to: NSPoint(x: x, y: bounds.height))
        line.stroke()

        let knobDiameter: CGFloat = 9
        let knob = NSBezierPath(ovalIn: NSRect(x: x - knobDiameter / 2, y: bounds.height - knobDiameter - 2, width: knobDiameter, height: knobDiameter))
        NSColor.brandAccentDeep.setFill()
        knob.fill()
        RecordingTheme.panel.setStroke()
        knob.lineWidth = 2
        knob.stroke()
    }

    // MARK: - Drag to adjust

    override func mouseDown(with event: NSEvent) {
        guard let autoStopSeconds else { return }
        let point = convert(event.locationInWindow, from: nil)
        let markerX = bounds.width * CGFloat(autoStopSeconds / windowSeconds)
        isDraggingMarker = abs(point.x - markerX) < 12
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDraggingMarker, bounds.width > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        let fraction = min(1, max(0.02, point.x / bounds.width))
        onDragAutoStop?(fraction * windowSeconds)
    }

    override func mouseUp(with event: NSEvent) {
        isDraggingMarker = false
    }
}
