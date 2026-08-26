import AppKit

/// A thumb showing which slice of the clip is on screen, draggable to pan.
///
/// Panning is a gesture on the lanes and the viewport is not an `NSScrollView`, so there is no
/// scroller to inherit. Without this strip a zoomed-in timeline gives no indication that there is
/// more clip either side of what is drawn — spec §8 budgets 12pt for exactly this.
///
/// It reports an absolute start time and changes nothing itself: `DeckTimelineView` remains the
/// only writer of viewport state.
final class TimelineScrollIndicatorView: NSView {
    var viewport: Viewport {
        didSet { if viewport != oldValue { needsDisplay = true } }
    }

    var onScrubToStartTime: ((Double) -> Void)?

    /// Small enough to be honest about a deep zoom, big enough to hit.
    private static let minimumThumbWidth: CGFloat = 24

    /// Distance from the pointer to the thumb's leading edge when the drag began, so grabbing the
    /// thumb by its edge does not snap its centre under the cursor.
    private var grabOffset: CGFloat?

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

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// `nil` when the whole clip is visible — there is nothing to indicate.
    func thumbRect() -> NSRect? {
        guard bounds.width > 0, viewport.visibleDuration < viewport.clipDuration else { return nil }
        let visibleShare = viewport.visibleDuration / viewport.clipDuration
        let width = max(Self.minimumThumbWidth, bounds.width * CGFloat(visibleShare))
        let travel = bounds.width - width
        let progress = viewport.startTime / max(0.001, viewport.clipDuration - viewport.visibleDuration)
        return NSRect(x: travel * CGFloat(min(1, max(0, progress))), y: 2, width: width, height: bounds.height - 4)
    }

    // MARK: - Scrubbing

    /// Split from `mouseDown`/`mouseDragged` so the drag arithmetic can be exercised directly —
    /// synthesising `NSEvent`s in a test proves less and costs more.
    func beginScrub(atX x: CGFloat) {
        guard let thumb = thumbRect() else { return }
        grabOffset = thumb.contains(NSPoint(x: x, y: thumb.midY)) ? x - thumb.minX : thumb.width / 2
    }

    func continueScrub(toX x: CGFloat) {
        guard let grabOffset, let thumb = thumbRect() else { return }
        let travel = bounds.width - thumb.width
        guard travel > 0 else { return }
        let progress = min(1, max(0, (x - grabOffset) / travel))
        let scrollable = viewport.clipDuration - viewport.visibleDuration
        onScrubToStartTime?(Double(progress) * scrollable)
    }

    func endScrub() {
        grabOffset = nil
    }

    override func mouseDown(with event: NSEvent) {
        beginScrub(atX: convert(event.locationInWindow, from: nil).x)
    }

    override func mouseDragged(with event: NSEvent) {
        continueScrub(toX: convert(event.locationInWindow, from: nil).x)
    }

    override func mouseUp(with event: NSEvent) {
        endScrub()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let thumb = thumbRect() else { return }

        NSColor.secondaryLabelColor.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: thumb, xRadius: 3, yRadius: 3).fill()
    }
}
