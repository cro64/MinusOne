import AppKit

/// Time ticks above the lane stack.
///
/// m:ss only in this phase. The bar|beat form and the draggable downbeat are Phase 3, and until a
/// beat grid exists with confidence behind it there is nothing honest to draw but clock time.
final class TimelineRulerView: NSView {
    var viewport: Viewport {
        didSet { if viewport != oldValue { needsDisplay = true } }
    }

    /// Minimum gap between labelled ticks. Sized for the widest label the ladder can produce
    /// ("10:05.4" at 9pt) plus air, so labels never touch whatever the zoom.
    private static let minimumLabelSpacing: CGFloat = 60
    private static let labelFontSize: CGFloat = 9

    /// Human-sized intervals only. A computed "nice number" would happily choose 3.7 seconds; a
    /// ruler nobody can read the spacing of is worse than a coarse one.
    private static let intervalLadder: [Double] = [0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600]

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

    /// The coarsest interval that is still fine enough to fill the ruler, or the finest available
    /// if even that is too coarse.
    static func tickInterval(pixelsPerSecond: CGFloat) -> Double {
        for candidate in intervalLadder where CGFloat(candidate) * pixelsPerSecond >= minimumLabelSpacing {
            return candidate
        }
        return intervalLadder[intervalLadder.count - 1]
    }

    /// Adjacent sub-second ticks would print identical m:ss strings, so those get a tenth.
    static func label(forTime time: Double, interval: Double) -> String {
        guard interval < 1 else { return time.formattedAsDuration }
        guard time.isFinite, time >= 0 else { return "0:00.0" }
        let whole = Int(time)
        let tenths = Int((time - Double(whole)) * 10)
        return String(format: "%d:%02d.%d", whole / 60, whole % 60, tenths)
    }

    func tickTimes() -> [Double] {
        guard bounds.width > 0 else { return [] }
        let interval = Self.tickInterval(pixelsPerSecond: viewport.pixelsPerSecond)
        let first = (viewport.startTime / interval).rounded(.up)
        let last = (viewport.endTime / interval).rounded(.down)
        guard last >= first else { return [] }
        return stride(from: first, through: last, by: 1).map { $0 * interval }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard bounds.width > 0 else { return }

        let interval = Self.tickInterval(pixelsPerSecond: viewport.pixelsPerSecond)
        let tickColor = NSColor.tertiaryLabelColor
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: Self.labelFontSize),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let scale = window?.backingScaleFactor ?? 2

        tickColor.setFill()
        for time in tickTimes() {
            let x = TimelineMetrics.devicePixelAligned(viewport.x(forTime: time), scale: scale)
            NSRect(x: x, y: bounds.height - 6, width: 1, height: 6).fill()
            Self.label(forTime: time, interval: interval)
                .draw(at: NSPoint(x: x + 3, y: 1), withAttributes: attributes)
        }
    }
}
