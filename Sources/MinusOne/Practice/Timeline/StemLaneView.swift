import AppKit

/// One track's waveform canvas.
///
/// Bars are rasterised into an `NSImage` keyed by everything that can change their appearance, so
/// the playhead moving at 60 fps redraws only `PlayheadOverlayView` and leaves four waveform
/// bitmaps untouched. That is the fix for `WaveformView`'s behaviour, where every
/// `playheadFraction` assignment redrew all 600 bars.
final class StemLaneView: NSView {
    let track: PeakTrack

    /// Fixed for the lane's lifetime — a new clip means a new `PeakStore` and new lanes. It is a
    /// class, so the growing sidecars behind it are picked up by `invalidatePeaks()`.
    let peakStore: PeakStore

    var viewport: Viewport {
        didSet { if viewport != oldValue { needsDisplay = true } }
    }

    /// Bumped every time the bars are actually rasterised. Exposed so the cache can be asserted
    /// rather than assumed — "it redraws less" is not a claim a pixel test can make on its own.
    private(set) var renderCount = 0

    private var cachedImage: NSImage?
    private var cacheKey: RenderCacheKey?

    private struct RenderCacheKey: Equatable {
        let viewport: Viewport
        let size: NSSize
        let peakVersion: Int
        let normalizationReference: Float
        let availableDuration: Double
        let appearanceName: NSAppearance.Name?
    }

    init(track: PeakTrack, peakStore: PeakStore) {
        self.track = track
        self.peakStore = peakStore
        self.viewport = Viewport(clipDuration: 1, widthPoints: 0)
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    /// Colours are resolved inside `draw(_:)`, so a light/dark switch has to drop the bitmap that
    /// baked the old ones. The appearance is in the cache key too; this is what tells AppKit to
    /// come and ask.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// Called when separation has appended to this track's sidecar.
    func invalidatePeaks() {
        cacheKey = nil
        needsDisplay = true
    }

    // MARK: - Geometry

    /// The bars to draw, each positioned by the viewport and nothing else.
    ///
    /// `time(forX:)` then `x(forTime:)` looks circular and is deliberate: it means this view
    /// contains no time↔pixel arithmetic of its own, so a change to the viewport's mapping moves
    /// every lane, the ruler and the playhead together instead of moving three of them.
    func renderedBars() -> [TimelineBar] {
        let count = TimelineMetrics.barCount(forWidth: bounds.width)
        guard count > 0 else { return [] }

        let columns = peakStore.columns(
            for: track,
            from: viewport.startTime,
            to: viewport.endTime,
            count: count
        )
        return (0..<count).map { index in
            let time = viewport.time(forX: CGFloat(index) * TimelineMetrics.barStep)
            return TimelineBar(x: viewport.x(forTime: time), time: time, column: columns[index])
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard bounds.width > 0, bounds.height > 0 else { return }

        let key = RenderCacheKey(
            viewport: viewport,
            size: bounds.size,
            peakVersion: peakStore.version,
            normalizationReference: peakStore.normalizationReference,
            availableDuration: peakStore.availableDuration(for: track),
            appearanceName: effectiveAppearance.name
        )
        if cacheKey != key || cachedImage == nil {
            cachedImage = rasterise()
            cacheKey = key
            renderCount += 1
        }
        cachedImage?.draw(in: bounds)
    }

    /// Renders the bars into a bitmap. Called from `draw(_:)` only, which is what makes the
    /// dynamic colours below resolve against this view's appearance — `NSAppearance.current` is
    /// set for the duration of `draw(_:)` and `lockFocus` does not disturb it.
    private func rasterise() -> NSImage {
        let image = NSImage(size: bounds.size)
        image.lockFocusFlipped(true)
        drawBars()
        image.unlockFocus()
        return image
    }

    private func drawBars() {
        let bars = renderedBars()
        guard !bars.isEmpty else { return }

        let reference = peakStore.normalizationReference
        let readyUntil = peakStore.availableDuration(for: track)
        let midY = bounds.height / 2
        let scale = window?.backingScaleFactor ?? 2

        // Resolved here, never stored: a lane held across a light/dark switch would otherwise keep
        // painting the appearance it was built in.
        let laneColor = identityColor
        let envelopeColor = laneColor.withAlphaComponent(TimelineMetrics.envelopeAlpha)
        let tailColor = NSColor.tertiaryLabelColor.withAlphaComponent(0.5)

        for bar in bars {
            let isReady = bar.time < readyUntil
            let column = bar.column
            let top = PeakScaling.height(magnitude: abs(column.maximum), reference: reference) * midY
            let bottom = PeakScaling.height(magnitude: abs(column.minimum), reference: reference) * midY
            let core = PeakScaling.height(magnitude: column.rms, reference: reference) * midY
            // Whole device pixels, so a bar lands on a pixel boundary instead of being
            // antialiased across two.
            let x = (bar.x * scale).rounded() / scale

            let envelope = NSRect(
                x: x,
                y: midY - top,
                width: TimelineMetrics.barWidth,
                height: max(1, top + bottom)
            )
            (isReady ? envelopeColor : tailColor).setFill()
            envelope.fill()

            guard isReady, core > 0 else { continue }
            laneColor.setFill()
            NSRect(
                x: x,
                y: midY - core,
                width: TimelineMetrics.barWidth,
                height: max(1, core * 2)
            ).fill()
        }
    }

    /// The mix is drawn in a neutral rather than a stem hue — it is not a fifth instrument, and
    /// giving it one of the four identity colours would claim it was.
    private var identityColor: NSColor {
        switch track {
        case .mix: return .secondaryLabelColor
        case .stem(let stem): return stem.identityColor
        }
    }
}
