import AppKit

/// Time ticks above the lane stack.
///
/// m:ss by default. With a `beatGrid` set, the ruler draws bars and beats instead — the draggable
/// downbeat is a later task. Until a beat grid exists with confidence behind it there is nothing
/// honest to draw but clock time, which is why `beatGrid == nil` is the fallback, not a special case.
final class TimelineRulerView: NSView {
    var viewport: Viewport {
        didSet { if viewport != oldValue { needsDisplay = true } }
    }

    /// The musical grid, when one has been detected with enough confidence or set by hand.
    ///
    /// `nil` is a first-class state, not a degraded one: spec §6 suppresses the grid entirely below
    /// the confidence threshold, and this view falls back to the clock-time ruler unchanged.
    var beatGrid: BeatGrid? {
        didSet { if beatGrid != oldValue { needsDisplay = true } }
    }

    /// Minimum gap between labelled ticks. Sized for the widest label the ladder can produce
    /// ("10:05.4" at 9pt) plus air, so labels never touch whatever the zoom.
    private static let minimumLabelSpacing: CGFloat = 60
    private static let labelFontSize: CGFloat = 9

    /// Minimum gap between labelled bar numbers. Smaller than `minimumLabelSpacing` because a bar
    /// number is two or three digits, not a full "10:05.4" timestamp.
    private static let minimumBarLabelSpacing: CGFloat = 30
    /// Below this, beat ticks are a smear and only bars are drawn.
    private static let minimumBeatTickSpacing: CGFloat = 6

    /// How close a pointer must be to the marker to grab it.
    static let downbeatGrabRadius: CGFloat = 8

    /// Human-sized intervals only. A computed "nice number" would happily choose 3.7 seconds; a
    /// ruler nobody can read the spacing of is worse than a coarse one.
    private static let intervalLadder: [Double] = [
        0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600
    ]

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

    /// The coarsest interval that is still fine enough to fill the ruler.
    ///
    /// Falls back to the ladder's coarsest entry when even that crowds — which needs under
    /// 0.017 px/s, i.e. a clip over eleven hours long at any realistic ruler width. At that point
    /// label spacing is not the interesting problem.
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
        var whole = Int(time)
        // Rounded, not truncated: `(4.3 - 4) * 10` is 2.999999999999998 in IEEE754, so truncating
        // labels 4.3s as "0:04.2". Measured: that is wrong for 792 of the first 2000 tenth-second
        // ticks.
        var tenths = Int(((time - Double(whole)) * 10).rounded())
        if tenths >= 10 {
            // The rounding carried — 59.97 is "1:00.0", never "0:59.10".
            whole += 1
            tenths = 0
        }
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

    /// How many bars between labels: 1, 2, 4, 8 … so the labelled bars stay musically meaningful
    /// rather than landing on arbitrary numbers.
    static func barStride(pixelsPerBar: CGFloat) -> Int {
        guard pixelsPerBar > 0 else { return 1024 }
        var stride = 1
        while CGFloat(stride) * pixelsPerBar < minimumBarLabelSpacing && stride < 1024 {
            stride *= 2
        }
        return stride
    }

    func beatTickTimes() -> [Double] {
        guard let beatGrid, bounds.width > 0 else { return [] }
        let pixelsPerBeat = CGFloat(beatGrid.beatDuration) * viewport.pixelsPerSecond
        guard pixelsPerBeat >= Self.minimumBeatTickSpacing else { return [] }
        return beatGrid.beatTimes(from: viewport.startTime, to: viewport.endTime)
    }

    func barLabels() -> [(time: Double, bar: Int)] {
        guard let beatGrid, bounds.width > 0 else { return [] }
        let pixelsPerBar = CGFloat(beatGrid.barDuration) * viewport.pixelsPerSecond
        let stride = Self.barStride(pixelsPerBar: pixelsPerBar)
        // `(bar - 1) % stride`, not `bar % stride`: bars are 1-based, so the latter labels 2, 4, 8
        // and never bar 1, where musicians count phrases from 1, 5, 9. (The old `|| stride == 1`
        // disjunct was dead — `x % 1` is always 0 — and hid nothing.) The modulo is floored so the
        // sequence stays on the same phase through bar 0 and below, where a clip with a pickup
        // starts.
        return beatGrid.downbeatTimes(from: viewport.startTime, to: viewport.endTime)
            .map { (time: $0, bar: beatGrid.position(at: $0).bar) }
            .filter { (($0.bar - 1) % stride + stride) % stride == 0 }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard bounds.width > 0 else { return }
        let scale = window?.backingScaleFactor ?? 2
        if beatGrid == nil {
            drawTimeRuler(scale: scale)
        } else {
            drawBeatRuler(scale: scale)
        }
    }

    private func drawTimeRuler(scale: CGFloat) {
        let interval = Self.tickInterval(pixelsPerSecond: viewport.pixelsPerSecond)
        let tickColor = NSColor.tertiaryLabelColor
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: Self.labelFontSize),
            .foregroundColor: NSColor.secondaryLabelColor
        ]

        tickColor.setFill()
        for time in tickTimes() {
            let x = TimelineMetrics.devicePixelAligned(viewport.x(forTime: time), scale: scale)
            NSRect(x: x, y: bounds.height - 6, width: 1, height: 6).fill()
            Self.label(forTime: time, interval: interval)
                .draw(at: NSPoint(x: x + 3, y: 1), withAttributes: attributes)
        }
    }

    private func drawBeatRuler(scale: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: Self.labelFontSize),
            .foregroundColor: NSColor.secondaryLabelColor
        ]

        // Beats first, so bar lines paint over them where they coincide.
        NSColor.quaternaryLabelColor.setFill()
        for time in beatTickTimes() {
            let x = TimelineMetrics.devicePixelAligned(viewport.x(forTime: time), scale: scale)
            NSRect(x: x, y: bounds.height - 4, width: 1, height: 4).fill()
        }

        NSColor.tertiaryLabelColor.setFill()
        for label in barLabels() {
            let x = TimelineMetrics.devicePixelAligned(viewport.x(forTime: label.time), scale: scale)
            NSRect(x: x, y: bounds.height - 8, width: 1, height: 8).fill()
            "\(label.bar)".draw(at: NSPoint(x: x + 3, y: 1), withAttributes: attributes)
        }

        // The downbeat marker: a full-height accent tick, so it reads as draggable rather than as
        // another bar line.
        if let beatGrid {
            let x = TimelineMetrics.devicePixelAligned(viewport.x(forTime: beatGrid.downbeatOffsetSeconds), scale: scale)
            NSColor.brandAccent.setFill()
            NSRect(x: x - 1, y: 0, width: 3, height: bounds.height).fill()
        }
    }
}
