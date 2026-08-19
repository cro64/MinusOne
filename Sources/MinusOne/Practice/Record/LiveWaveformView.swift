import AppKit

/// Live-recording waveform: a thin scrolling polyline (not the deck's filled-bar style) with an
/// optional draggable auto-stop marker. The visible time axis is 0...autoStopSeconds when an
/// auto-stop is set (so the marker's position is meaningful), or 0...elapsed otherwise (so the
/// whole take so far is always visible).
final class LiveWaveformView: NSView {
    /// Matches `ClipRecorder`'s peak-bucket cadence.
    static let bucketDurationSeconds: Double = 0.1

    var peaks: [Float] = [] { didSet { needsDisplay = true } }
    var elapsedSeconds: Double = 0 { didSet { needsDisplay = true } }
    var autoStopSeconds: Double? { didSet { needsDisplay = true } }
    var onDragAutoStop: ((Double) -> Void)?

    private var isDraggingMarker = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.borderWidth = 1
        applyBorderColor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The border used to be assigned by `RecordingPanelController` at build time, which froze the
    /// light-mode `flatDivider` into the layer for the life of the view. Owned here so it's
    /// re-resolved, and so `draw(_:)` — which reads `windowBackgroundColor` and `labelColor` — gets
    /// re-run for the new appearance rather than keeping its old pixels.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyBorderColor()
        needsDisplay = true
    }

    private func applyBorderColor() {
        resolvingEffectiveAppearance {
            layer?.borderColor = NSColor.flatDivider.cgColor
        }
    }

    override var isFlipped: Bool { true }

    private var windowSeconds: Double {
        max(1, autoStopSeconds ?? max(elapsedSeconds, 5))
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.clear(bounds)

        NSColor.windowBackgroundColor.setFill()
        bounds.fill()

        // Only meaningful against an auto-stop target. Without one, `windowSeconds` *is* the elapsed
        // time, so the fraction is permanently 1 and the wash covers the whole view — a flat pink
        // field that says nothing. Barely noticeable in a 68pt popover box; at page scale it's the
        // largest thing on screen.
        if let autoStopSeconds, autoStopSeconds > 0 {
            let progressFraction = min(1, elapsedSeconds / windowSeconds)
            let progressRect = NSRect(x: 0, y: 0, width: bounds.width * progressFraction, height: bounds.height)
            NSColor.systemRed.withAlphaComponent(0.06).setFill()
            progressRect.fill()
        }

        drawWaveformLine()

        if let autoStopSeconds {
            let x = bounds.width * CGFloat(autoStopSeconds / windowSeconds)
            drawMarker(atX: x)
        }
    }

    /// Two mirrored polylines around the vertical midline.
    ///
    /// This used to be one line at `midY - magnitude * midY * 1.4`, which a full-scale peak puts
    /// *above* the view's top edge, where nothing clips it. At the 68pt popover height it was
    /// written for, that overspill was ~14pt and read as the line just touching the top; at the
    /// ~380pt this view now gets as a page hero it's ~76pt of waveform drawn over the card's
    /// header. The `0.92` factor keeps a full-scale peak inside the bounds with a margin, and
    /// mirroring gives a tall box something to fill — a single half-height line in a 380pt box
    /// reads as a stray squiggle in an empty field, not as a level.
    private func drawWaveformLine() {
        guard peaks.count >= 4 else { return }
        let columnCount = peaks.count / 2
        let midY = bounds.height / 2

        let top = NSBezierPath()
        let bottom = NSBezierPath()
        for column in 0..<columnCount {
            let time = Double(column) * Self.bucketDurationSeconds
            let x = bounds.width * CGFloat(time / windowSeconds)
            if x > bounds.width { break }

            let magnitude = min(1, max(abs(peaks[column * 2]), abs(peaks[column * 2 + 1])))
            let offset = CGFloat(magnitude) * midY * 0.92
            if column == 0 {
                top.move(to: NSPoint(x: x, y: midY - offset))
                bottom.move(to: NSPoint(x: x, y: midY + offset))
            } else {
                top.line(to: NSPoint(x: x, y: midY - offset))
                bottom.line(to: NSPoint(x: x, y: midY + offset))
            }
        }
        NSColor.secondaryLabelColor.setStroke()
        for path in [top, bottom] {
            path.lineWidth = 1.2
            path.stroke()
        }
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
        NSColor.windowBackgroundColor.setStroke()
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
