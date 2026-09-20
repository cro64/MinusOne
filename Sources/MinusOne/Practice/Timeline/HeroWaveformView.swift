// Sources/MinusOne/Practice/Timeline/HeroWaveformView.swift
import AppKit

/// Whole-track composite waveform above the deck timeline: one silhouette, colored per bar by
/// blending the 4 stems' relative loudness (`HeroWaveformBlend`), sized by the mix's own peaks.
/// Bars are cached exactly like `StemLaneView`'s — the minimap overlay (Task 3) and interaction
/// (Task 4) are added on top of this file without touching the cache.
final class HeroWaveformView: NSView {
    /// Resize-handle clamp. The original 80 was sized against a margin measured with `statusLabel`
    /// (`PracticeDeckViewController`'s "Separating in the background…" line) hidden — but that label
    /// is visible for as long as a clip is still separating, a common state, not an edge case, and
    /// once `WindowSizingTests` measured the real deck with it visible, 80 overflowed
    /// `WindowSizing.minimum.height` (600pt) by 15pt. 53 is `WindowSizingTests
    /// .testTheDeckStillFitsTheMinimumWindowHeightWithTheHeroAtItsMaximumAndStatusVisible`'s measured
    /// safe ceiling: it leaves ~12pt of real margin at the minimum window height with the status
    /// label visible (measured need 588pt against the 600pt floor), rather than a hand-estimated one.
    static let minimumHeight: CGFloat = 32
    static let maximumHeight: CGFloat = 53
    /// How much taller the deck may make the hero on a big window, on top of the saved height.
    static let maximumExtraHeight: CGFloat = 150

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
        // Both hold absolute seconds, not a fraction of the clip — mirrors
        // `DeckTimelineView.show(clipDuration:peakStore:)`'s identical reset of its own overlay:
        // without this, a playhead or hover position left over from the previous clip could sit at
        // a nonsensical spot (or even past the end) of the new one until the engine happens to emit
        // a fresh tick or the pointer moves again.
        playheadTime = nil
        hoverTime = nil
        loopRange = nil
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

    /// The deck's loop, in clip seconds. Drawn as the same band `PlayheadOverlayView` draws across the
    /// lanes, so a loop set on either view reads identically on both, and previewed here while a loop
    /// is being dragged on the hero.
    var loopRange: ClosedRange<Double>? {
        didSet { if loopRange != oldValue { needsDisplay = true } }
    }

    /// Whether the visible-range box is narrow enough to be worth drawing. Every clip opens at
    /// `visibleRange == 0...clipDuration` (`Viewport.init` sets `visibleDuration = clipDuration`), so
    /// the box spans the whole band at the deck's default zoom — drawing it there reads as a stray
    /// border around the entire hero rather than a "here's what's zoomed in" cue.
    ///
    /// Also `beginDrag(atX:)`'s hit-test. A box that isn't drawn can't be grabbed: at the default zoom
    /// there is nothing visible to pan, so the whole band is free for drawing a loop.
    func isVisibleRangeBoxDrawn() -> Bool {
        guard let visibleRange else { return false }
        return visibleRange.upperBound - visibleRange.lowerBound < clipDuration - 1e-6
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

        // Under the zoom box and the playhead, in `PlayheadOverlayView`'s exact fill, so the band reads
        // as the same loop on both views.
        if let loopRange, clipDuration > 0 {
            let start = x(forTime: loopRange.lowerBound)
            let end = x(forTime: loopRange.upperBound)
            NSColor.brandAccent.withAlphaComponent(0.14).setFill()
            NSRect(x: start, y: 0, width: max(1, end - start), height: bounds.height).fill()
        }

        if isVisibleRangeBoxDrawn(), let rangeRect = visibleRangeRect() {
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
    /// Factor, then the time under the pointer — not a canvas x, since the hero's whole-track
    /// coordinate space has a different points-per-second ratio than the deck timeline's zoomed
    /// canvas it drives (see `DeckTimelineView.zoom(by:aroundTime:)`).
    var onZoom: ((Double, Double) -> Void)?

    var onLoopRangeChanged: ((ClosedRange<Double>) -> Void)?

    /// Snaps a loop dragged on the hero — start time, end time, bypass snapping. Supplied by the deck
    /// from `DeckTimelineView.snappedLoopRange(fromTime:toTime:bypassSnapping:)`: the beat grid lives
    /// on the timeline, and a loop must land in the same place whichever view it was drawn on.
    /// Handed times already clamped to the clip. With none set, the loop is exactly where it was drawn.
    var loopRangeResolver: ((Double, Double, Bool) -> ClosedRange<Double>)?

    /// A movement under this many points is a click, not a loop — `DeckTimelineView`'s own threshold,
    /// so a click on the hero and a click on the lanes tolerate the same pointer jitter.
    private static let dragThreshold: CGFloat = 3

    private enum DragMode {
        case panningVisibleRange(anchorOffset: Double)
        /// Pressed anywhere a drawn box isn't — which at the default zoom, where no box is drawn, is
        /// the whole band. Undecided until release: within `dragThreshold` of `startX` it was a click
        /// and seeks; past it, the gesture drew a loop.
        case pressed(startX: CGFloat)
    }
    private var dragMode: DragMode?

    /// The loop as it stood when a press began, so a click — including a drag that wandered out and
    /// came back — restores it instead of keeping a stray preview.
    private var loopBeforeDrag: ClosedRange<Double>?

    /// Whether `continueDrag(toX:)` actually ran during the current `.panningVisibleRange` gesture, so
    /// a plain click inside a drawn box still seeks on release rather than panning by nothing. Only
    /// meaningful while `dragMode` is `.panningVisibleRange`.
    private var hasDraggedDuringGesture = false

    func beginDrag(atX x: CGFloat) {
        if isVisibleRangeBoxDrawn(), let rect = visibleRangeRect(), rect.contains(NSPoint(x: x, y: rect.midY)) {
            let boxStartTime = time(forX: rect.minX)
            dragMode = .panningVisibleRange(anchorOffset: time(forX: x) - boxStartTime)
            hasDraggedDuringGesture = false
        } else {
            // No seek yet: a press here is only a click once it's released without having moved.
            dragMode = .pressed(startX: x)
            loopBeforeDrag = loopRange
        }
    }

    func continueDrag(toX x: CGFloat, bypassSnapping: Bool = false) {
        switch dragMode {
        case .panningVisibleRange(let anchorOffset):
            hasDraggedDuringGesture = true
            onVisibleRangePanned?(clampedStart(time(forX: x) - anchorOffset))
        case .pressed(let startX):
            guard abs(x - startX) >= Self.dragThreshold else { return }
            // Previewed already snapped, so the band does not jump on release.
            loopRange = resolvedLoop(from: startX, to: x, bypassSnapping: bypassSnapping)
        case nil:
            break
        }
    }

    /// Decides a `.pressed` gesture by where it ends, as `DeckTimelineView.endCanvasDrag` does: within
    /// the threshold it was a click, even if the pointer wandered out and back in between.
    ///
    /// For `.panningVisibleRange`, a release that never dragged was a click inside the box. No seek has
    /// fired for it yet, so this is where its one seek happens.
    func endDrag(atX x: CGFloat, bypassSnapping: Bool = false) {
        defer {
            dragMode = nil
            hasDraggedDuringGesture = false
            loopBeforeDrag = nil
        }
        switch dragMode {
        case .panningVisibleRange:
            if !hasDraggedDuringGesture { seekAndRecenter(toTime: time(forX: x)) }
        case .pressed(let startX):
            guard abs(x - startX) >= Self.dragThreshold else {
                loopRange = loopBeforeDrag
                seekAndRecenter(toTime: time(forX: x))
                return
            }
            let loop = resolvedLoop(from: startX, to: x, bypassSnapping: bypassSnapping)
            loopRange = loop
            onLoopRangeChanged?(loop)
        case nil:
            break
        }
    }

    /// `mouseDragged` and `mouseUp` keep arriving after the pointer leaves the view, and `time(forX:)`
    /// extrapolates past both ends, so both edges are clamped to the clip here — before the resolver,
    /// the band, or the engine can see an out-of-clip time.
    private func resolvedLoop(from startX: CGFloat, to endX: CGFloat, bypassSnapping: Bool) -> ClosedRange<Double> {
        let a = min(max(0, time(forX: startX)), clipDuration)
        let b = min(max(0, time(forX: endX)), clipDuration)
        if let loopRangeResolver { return loopRangeResolver(a, b, bypassSnapping) }
        return min(a, b)...max(a, b)
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

    /// Converts a gesture's pixel anchor to a time before firing `onZoom` — separated from the
    /// `scrollWheel`/`magnify` overrides so it's callable directly in tests without synthesizing an
    /// `NSEvent`, matching this file's other gesture methods.
    func zoomGesture(byFactor factor: Double, atX x: CGFloat) {
        onZoom?(factor, time(forX: x))
    }

    // MARK: - Mouse events

    override func mouseDown(with event: NSEvent) {
        beginDrag(atX: convert(event.locationInWindow, from: nil).x)
    }

    /// ⌥ is read live, not latched at press, so pressing or releasing it mid-drag takes effect
    /// immediately — `DeckTimelineView.mouseDragged(with:)`'s rule.
    override func mouseDragged(with event: NSEvent) {
        continueDrag(
            toX: convert(event.locationInWindow, from: nil).x,
            bypassSnapping: event.modifierFlags.contains(.option)
        )
    }

    override func mouseUp(with event: NSEvent) {
        endDrag(
            atX: convert(event.locationInWindow, from: nil).x,
            bypassSnapping: event.modifierFlags.contains(.option)
        )
    }

    override func mouseMoved(with event: NSEvent) {
        hoverTime = time(forX: convert(event.locationInWindow, from: nil).x)
    }

    override func mouseExited(with event: NSEvent) {
        hoverTime = nil
    }

    /// ⌘+scroll zooms, mirroring `DeckTimelineView.scrollWheel(with:)`'s exact factor formula so the
    /// two feel identical regardless of which one the pointer happens to be over. Plain scroll is
    /// left alone — panning is already covered by dragging the visible-range box.
    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.command) else { return }
        let factor = pow(1.01, Double(event.scrollingDeltaY))
        zoomGesture(byFactor: factor, atX: convert(event.locationInWindow, from: nil).x)
    }

    override func magnify(with event: NSEvent) {
        zoomGesture(byFactor: 1 + event.magnification, atX: convert(event.locationInWindow, from: nil).x)
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
