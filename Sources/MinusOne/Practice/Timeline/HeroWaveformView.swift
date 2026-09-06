// Sources/MinusOne/Practice/Timeline/HeroWaveformView.swift
import AppKit

/// Whole-track composite waveform above the deck timeline: one silhouette, colored per bar by
/// blending the 4 stems' relative loudness (`HeroWaveformBlend`), sized by the mix's own peaks.
/// Bars are cached exactly like `StemLaneView`'s — the minimap overlay (Task 3) and interaction
/// (Task 4) are added on top of this file without touching the cache.
final class HeroWaveformView: NSView {
    /// Resize-handle clamp. See the design spec's "Resize" section for why 80, not a rounder
    /// number: it is the largest fixed cap that still fits `TimelineMetrics`'s measured 103pt spare
    /// margin at `WindowSizing.minimum` once the resize handle's own 4pt strip and the
    /// section-spacing gap above the hero are both counted (80 + 4 + 16 = 100 ≤ 103).
    static let minimumHeight: CGFloat = 32
    static let maximumHeight: CGFloat = 80

    private var peakStore: PeakStore?
    private(set) var clipDuration: Double = 0

    private(set) var renderCount = 0
    private var cachedImage: NSImage?
    private var cacheKey: RenderCacheKey?

    private struct RenderCacheKey: Equatable {
        let size: NSSize
        let scale: CGFloat
        let peakVersion: Int
        let normalizationReference: Float
        let readyUntil: Double
        let appearanceName: NSAppearance.Name?
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }

    /// Mirrors `DeckTimelineView.show(clipDuration:peakStore:)` — called from the same place, once
    /// per clip.
    func show(clipDuration: Double, peakStore: PeakStore) {
        self.clipDuration = clipDuration
        self.peakStore = peakStore
        invalidatePeaks()
    }

    /// Mirrors `DeckTimelineView.refreshPeaks()` — called alongside it whenever separation appends
    /// more data.
    func refreshPeaks() {
        invalidatePeaks()
    }

    private func invalidatePeaks() {
        cacheKey = nil
        needsDisplay = true
    }

    // MARK: - Geometry — the hero always spans the whole track, never a zoomed window

    func x(forTime time: Double) -> CGFloat {
        guard clipDuration > 0 else { return 0 }
        return CGFloat(time / clipDuration) * bounds.width
    }

    func time(forX x: CGFloat) -> Double {
        guard clipDuration > 0, bounds.width > 0 else { return 0 }
        return Double(x / bounds.width) * clipDuration
    }

    func renderedBars() -> [TimelineBar] {
        let count = TimelineMetrics.barCount(forWidth: bounds.width)
        guard count > 0, let peakStore else { return [] }
        let mixColumns = peakStore.columns(for: .mix, from: 0, to: clipDuration, count: count)
        return (0..<count).map { index in
            let x = CGFloat(index) * TimelineMetrics.barStep
            return TimelineBar(x: x, time: time(forX: x), column: mixColumns[index])
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard bounds.width > 0, bounds.height > 0 else { return }

        let key = RenderCacheKey(
            size: bounds.size,
            scale: window?.backingScaleFactor ?? 2,
            peakVersion: peakStore?.version ?? 0,
            normalizationReference: peakStore?.normalizationReference ?? 1,
            readyUntil: readyUntil(),
            appearanceName: effectiveAppearance.name
        )
        if cacheKey != key || cachedImage == nil {
            cachedImage = rasterise()
            cacheKey = key
            renderCount += 1
        }
        cachedImage?.draw(in: bounds)
        drawOverlay()
    }

    /// A bar can only be honestly blended once all 4 stems have peaks at its time.
    private func readyUntil() -> Double {
        guard let peakStore else { return 0 }
        return SeparationStem.allCases.map { peakStore.availableDuration(for: .stem($0)) }.min() ?? 0
    }

    private func rasterise() -> NSImage {
        let image = NSImage(size: bounds.size)
        image.lockFocusFlipped(true)
        drawBars()
        image.unlockFocus()
        return image
    }

    private func drawBars() {
        guard let peakStore else { return }
        let bars = renderedBars()
        guard !bars.isEmpty else { return }

        let reference = peakStore.normalizationReference
        let ready = readyUntil()
        let midY = bounds.height / 2
        let scale = window?.backingScaleFactor ?? 2

        var stemMagnitudes: [SeparationStem: [Float]] = [:]
        for stem in SeparationStem.allCases {
            stemMagnitudes[stem] = peakStore.columns(for: .stem(stem), from: 0, to: clipDuration, count: bars.count).map(\.rms)
        }

        for (index, bar) in bars.enumerated() {
            let column = bar.column
            let top = PeakScaling.height(magnitude: abs(column.maximum), reference: reference) * midY
            let bottom = PeakScaling.height(magnitude: abs(column.minimum), reference: reference) * midY
            let core = PeakScaling.height(magnitude: column.rms, reference: reference) * midY
            let x = TimelineMetrics.devicePixelAligned(bar.x, scale: scale)

            let magnitudes = SeparationStem.allCases.reduce(into: [SeparationStem: Float]()) { result, stem in
                result[stem] = stemMagnitudes[stem]?[index] ?? 0
            }
            let envelope = NSRect(x: x, y: midY - top, width: TimelineMetrics.barWidth, height: max(1, top + bottom))

            switch HeroWaveformBlend.barColor(forMagnitudes: magnitudes, reference: reference, isSeparated: bar.time < ready) {
            case .tail:
                HeroWaveformBlend.tailColor.setFill()
                envelope.fill()
            case .blended(let color):
                color.withAlphaComponent(TimelineMetrics.envelopeAlpha).setFill()
                envelope.fill()
                guard core > 0 else { continue }
                color.setFill()
                NSRect(x: x, y: midY - core, width: TimelineMetrics.barWidth, height: max(1, core * 2)).fill()
            }
        }
    }

    // MARK: - Minimap overlay

    var visibleRange: ClosedRange<Double>? {
        didSet { if visibleRange != oldValue { needsDisplay = true } }
    }

    var playheadTime: Double? {
        didSet { if playheadTime != oldValue { needsDisplay = true } }
    }

    /// Where the pointer is over the hero, or `nil` when it is elsewhere.
    var hoverTime: Double? {
        didSet { if hoverTime != oldValue { needsDisplay = true } }
    }

    private static let playheadWidth: CGFloat = 1.5

    func visibleRangeRect() -> NSRect? {
        guard let visibleRange else { return nil }
        let start = x(forTime: visibleRange.lowerBound)
        let end = x(forTime: visibleRange.upperBound)
        return NSRect(x: start, y: 0, width: max(1, end - start), height: bounds.height)
    }

    func playheadX() -> CGFloat? {
        guard let playheadTime else { return nil }
        return x(forTime: playheadTime)
    }

    /// Suppressed under the playhead — see `PlayheadOverlayView.hoverX()`'s identical rule.
    func hoverX() -> CGFloat? {
        guard let hoverTime, hoverTime != playheadTime else { return nil }
        return TimelineMetrics.devicePixelAligned(x(forTime: hoverTime), scale: window?.backingScaleFactor ?? 2)
    }

    func drawOverlay() {
        guard let context = NSGraphicsContext.current?.cgContext, bounds.width > 0 else { return }

        if let rangeRect = visibleRangeRect() {
            NSColor.labelColor.withAlphaComponent(0.05).setFill()
            rangeRect.fill()
            NSColor.labelColor.withAlphaComponent(0.35).setStroke()
            let outline = NSBezierPath(rect: rangeRect.insetBy(dx: 0.5, dy: 0.5))
            outline.lineWidth = 1
            outline.stroke()
        }

        if let hoverX = hoverX() {
            NSColor.tertiaryLabelColor.setFill()
            NSRect(x: hoverX, y: 0, width: 1, height: bounds.height).fill()
        }

        if let x = playheadX() {
            // Not pixel-snapped, like `PlayheadOverlayView`'s own playhead: this moves during
            // playback, and half-pixel positioning is what keeps that motion smooth.
            context.setStrokeColor(NSColor.labelColor.cgColor)
            context.setLineWidth(Self.playheadWidth)
            context.move(to: CGPoint(x: x, y: 0))
            context.addLine(to: CGPoint(x: x, y: bounds.height))
            context.strokePath()
        }
    }

    // MARK: - Interaction

    var onSeek: ((Double) -> Void)?
    var onVisibleRangePanned: ((Double) -> Void)?

    private enum DragMode {
        case panningVisibleRange(anchorOffset: Double)
        case seeking
    }
    private var dragMode: DragMode?

    /// Tracks whether `continueDrag(toX:)` actually ran during the current `.panningVisibleRange`
    /// gesture. At default (fully zoomed out) viewports the visible-range box spans the whole band,
    /// so a plain click almost always lands inside it and takes this branch instead of `.seeking` —
    /// without this flag such a click would pan (a no-op) and never seek. Only meaningful while
    /// `dragMode` is `.panningVisibleRange`; irrelevant for `.seeking`, which always seeks from
    /// `beginDrag(atX:)` itself.
    private var hasDraggedDuringGesture = false

    func beginDrag(atX x: CGFloat) {
        let time = time(forX: x)
        if let rect = visibleRangeRect(), rect.contains(NSPoint(x: x, y: rect.midY)) {
            let boxStartTime = self.time(forX: rect.minX)
            dragMode = .panningVisibleRange(anchorOffset: time - boxStartTime)
            hasDraggedDuringGesture = false
        } else {
            dragMode = .seeking
            seekAndRecenter(toTime: time)
        }
    }

    func continueDrag(toX x: CGFloat) {
        switch dragMode {
        case .panningVisibleRange(let anchorOffset):
            hasDraggedDuringGesture = true
            onVisibleRangePanned?(clampedStart(time(forX: x) - anchorOffset))
        case .seeking:
            seekAndRecenter(toTime: time(forX: x))
        case nil:
            break
        }
    }

    /// For `.seeking`, deliberately does *not* re-process `x` — `continueDrag(toX:)` already ran for
    /// every intermediate position during a real drag (AppKit delivers `mouseDragged` up to the
    /// release point), and for a plain click (no `mouseDragged` at all) `beginDrag(atX:)` already
    /// fired the seek once. Re-processing here would double-fire a click's seek at the same x.
    ///
    /// For `.panningVisibleRange`, the situation is the opposite: that branch never seeks from
    /// `beginDrag(atX:)`, so if `continueDrag(toX:)` never ran either (a plain click that happened to
    /// land inside a visible-range box covering the whole track, e.g. at the deck's default fully
    /// zoomed-out viewport), no seek has fired yet for this gesture at all. This is the one place
    /// that can happen, so it's the one legitimate use of `x` here — a first and only seek, not a
    /// reprocessing of one that already fired.
    func endDrag(atX x: CGFloat) {
        if case .panningVisibleRange = dragMode, !hasDraggedDuringGesture {
            seekAndRecenter(toTime: time(forX: x))
        }
        dragMode = nil
        hasDraggedDuringGesture = false
    }

    private func seekAndRecenter(toTime time: Double) {
        let clamped = min(max(0, time), clipDuration)
        onSeek?(clamped)
        guard let visibleRange else { return }
        let duration = visibleRange.upperBound - visibleRange.lowerBound
        onVisibleRangePanned?(clampedStart(clamped - duration / 2))
    }

    private func clampedStart(_ start: Double) -> Double {
        guard let visibleRange else { return min(max(0, start), clipDuration) }
        let duration = visibleRange.upperBound - visibleRange.lowerBound
        return min(max(0, start), max(0, clipDuration - duration))
    }

    // MARK: - Mouse events

    override func mouseDown(with event: NSEvent) {
        beginDrag(atX: convert(event.locationInWindow, from: nil).x)
    }

    override func mouseDragged(with event: NSEvent) {
        continueDrag(toX: convert(event.locationInWindow, from: nil).x)
    }

    override func mouseUp(with event: NSEvent) {
        endDrag(atX: convert(event.locationInWindow, from: nil).x)
    }

    override func mouseMoved(with event: NSEvent) {
        hoverTime = time(forX: convert(event.locationInWindow, from: nil).x)
    }

    override func mouseExited(with event: NSEvent) {
        hoverTime = nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
    }
}

/// The hero band's bottom-edge drag handle. Draws a short grip line and reports raw vertical drag
/// deltas — clamping to `HeroWaveformView.minimumHeight...maximumHeight` and writing to
/// `Preferences` are the caller's job (`PracticeDeckViewController`), not this view's.
final class HeroResizeHandleView: NSView {
    /// Positive when the user drags down, since AppKit's window coordinate space (this view is not
    /// flipped) has y increasing upward — dragging down means a smaller `locationInWindow.y`, and
    /// dragging down should make the band taller.
    var onDrag: ((CGFloat) -> Void)?

    private var lastY: CGFloat?

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeUpDown)
    }

    override func mouseDown(with event: NSEvent) {
        lastY = event.locationInWindow.y
    }

    override func mouseDragged(with event: NSEvent) {
        guard let lastY else { return }
        let currentY = event.locationInWindow.y
        onDrag?(lastY - currentY)
        self.lastY = currentY
    }

    override func mouseUp(with event: NSEvent) {
        lastY = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let grip = NSRect(x: bounds.midX - 16, y: bounds.midY - 1.5, width: 32, height: 3)
        NSColor.labelColor.withAlphaComponent(0.16).setFill()
        NSBezierPath(roundedRect: grip, xRadius: 1.5, yRadius: 1.5).fill()
    }
}
