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

    /// Overridden by Task 3 to draw the visible-range box, playhead and hover cursor over the
    /// cached bars. Empty here so this file's own tests exercise bars in isolation.
    func drawOverlay() {}
}
