import AppKit

/// Playhead, loop band and hover cursor, drawn over the whole lane stack.
///
/// One overlay rather than one per lane, for two reasons. The loop is a property of the timeline,
/// not of a lane — spec §7 — and drawing it as a single band across every lane is what says so.
/// And this is the only view that redraws while playback runs: because it is layer-backed, its
/// redraw composites over the lanes' own layers instead of forcing them to re-rasterise.
final class PlayheadOverlayView: NSView {
    var viewport: Viewport {
        didSet { if viewport != oldValue { needsDisplay = true } }
    }

    var playheadTime: Double? {
        didSet {
            guard playheadTime != oldValue else { return }
            // Only the strips the line left and arrived at — a 60 fps tick has no business
            // invalidating 680 × 300 points of overlay.
            if let oldValue { setNeedsDisplay(invalidationRect(forTime: oldValue)) }
            if let playheadTime { setNeedsDisplay(invalidationRect(forTime: playheadTime)) }
        }
    }

    var loopRange: ClosedRange<Double>? {
        didSet { if loopRange != oldValue { needsDisplay = true } }
    }

    /// Where the pointer is over the lanes, or `nil` when it is elsewhere.
    var hoverTime: Double? {
        didSet {
            guard hoverTime != oldValue else { return }
            if let oldValue { setNeedsDisplay(invalidationRect(forTime: oldValue)) }
            if let hoverTime { setNeedsDisplay(invalidationRect(forTime: hoverTime)) }
        }
    }

    private static let playheadWidth: CGFloat = 1.5

    override init(frame frameRect: NSRect) {
        viewport = Viewport(clipDuration: 1, widthPoints: 0)
        super.init(frame: frameRect)
        wantsLayer = true
    }

    convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    /// Paint, not a control: clicks, drags and scrolls belong to the lanes underneath and to the
    /// container that owns the viewport.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    func playheadX() -> CGFloat? {
        guard let playheadTime else { return nil }
        return viewport.x(forTime: playheadTime)
    }

    func loopRect() -> NSRect? {
        guard let loopRange else { return nil }
        let start = viewport.x(forTime: loopRange.lowerBound)
        let end = viewport.x(forTime: loopRange.upperBound)
        return NSRect(x: start, y: 0, width: max(1, end - start), height: bounds.height)
    }

    /// Where the hover cursor is drawn, snapped to the device pixel grid.
    ///
    /// Exposed like `playheadX()` and `loopRect()` rather than computed inline in `draw(_:)`, so
    /// the snap is testable without rendering a bitmap.
    func hoverX() -> CGFloat? {
        // Suppressed under the playhead: two 1pt lines a fraction of a point apart read as one
        // thick smudge rather than two cursors. Exact equality is deliberate — these come from
        // independent sources (mouse position and the playback clock), so this fires only when the
        // container has genuinely set them to the same instant.
        guard let hoverTime, hoverTime != playheadTime else { return nil }
        return TimelineMetrics.devicePixelAligned(
            viewport.x(forTime: hoverTime),
            scale: window?.backingScaleFactor ?? 2
        )
    }

    /// The strip a marker at `time` occupies, with a point of slack either side for the line's
    /// own width and for antialiasing.
    func invalidationRect(forTime time: Double) -> NSRect {
        let x = viewport.x(forTime: time)
        return NSRect(x: x - 3, y: 0, width: 6, height: bounds.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext, bounds.width > 0 else { return }

        if let loopRect = loopRect() {
            NSColor.brandAccent.withAlphaComponent(0.14).setFill()
            loopRect.fill()
        }

        if let hoverX = hoverX() {
            NSColor.tertiaryLabelColor.setFill()
            NSRect(x: hoverX, y: 0, width: 1, height: bounds.height).fill()
        }

        if let x = playheadX() {
            // Deliberately not snapped to the device pixel grid, unlike the bars and the hover
            // line: this moves every frame during playback, and half-pixel positioning is what
            // makes that motion read as smooth rather than stepping a pixel at a time.
            // Resolved here rather than stored: `labelColor` inverts between appearances, and a
            // cached `CGColor` is the exact failure `LiveWaveformView.swift:33` records.
            context.setStrokeColor(NSColor.labelColor.cgColor)
            context.setLineWidth(Self.playheadWidth)
            context.move(to: CGPoint(x: x, y: 0))
            context.addLine(to: CGPoint(x: x, y: bounds.height))
            context.strokePath()
        }
    }
}
