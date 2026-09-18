import AppKit

/// Scrolling before/after level meter for the Live tab's hero card — the one place in the app that
/// shows vocal reduction actually happening. A translucent neutral envelope traces the delayed dry
/// signal (what you would have heard); colored bar columns painted inside it are the mixed output
/// (what you do hear), colored the same way Practice's `HeroWaveformView` colors its bars — a
/// weighted blend of the 4 stem identity colors by which instrument is loudest at that instant
/// (`HeroWaveformBlend`, reused as-is since it's pure/stateless). The exposed neutral margin above
/// the bars *is* the vocal being removed; the bar color is what's actually playing.
///
/// Drawing follows `LiveWaveformView`'s approach (bucketed peaks → `NSBezierPath`) but is a separate
/// view rather than a reuse: that one is bound to `ClipRecorder`'s 0.1s recording buckets and
/// carries an auto-stop marker and recording tint that mean nothing here.
final class LiveLevelMeterView: NSView {
    private enum Metrics {
        /// ~8 seconds of history at the controller's 25 Hz poll rate. Comfortably longer than the
        /// pipeline's ~6s warm-up, so the moment reduction kicks in stays on screen.
        static let sampleCapacity = 200
        /// Meter floor. Peaks below this read as silence rather than as a jittering hairline.
        static let decibelFloor: Float = -60
        static let verticalInset: CGFloat = 10
        static let legendInset: CGFloat = 8
        /// Fraction of each bar's slot that's actually filled, matching Practice's discrete-column
        /// look — the rest is the gap between bars.
        static let barFillRatio: CGFloat = 0.7
        /// Peaks are already raw linear amplitudes in 0...1 (full digital scale), the same domain
        /// `PeakScaling.height` expects a `reference` in — so 1.0 (unity) is the correct reference,
        /// not a per-clip loudness figure like `PeakStore.normalizationReference` (there is no clip).
        static let stemColorReference: Float = 1.0
    }

    private struct Sample {
        var dry: Float
        var wet: Float
        /// Raw (smoothed) per-stem magnitudes, kept separately from `dry`/`wet` heights — the color
        /// blend runs on these at *draw* time (see `HeroWaveformBlend`'s own doc comment on why
        /// resolving `NSColor`s at append time would freeze a dynamic system color to whichever
        /// appearance was current then, e.g. `HeroWaveformBlend.silenceColor`).
        var stemMagnitudes: [SeparationStem: Float]
    }

    /// Caption shown centered over a flat baseline when there's nothing to meter. `nil` hides it.
    var caption: String? {
        didSet {
            guard caption != oldValue else { return }
            needsDisplay = true
        }
    }

    private var samples: [Sample] = []
    private var smoothedDry: Float = 0
    private var smoothedWet: Float = 0
    private var smoothedStemMagnitudes: [SeparationStem: Float] = Dictionary(
        uniqueKeysWithValues: SeparationStem.allCases.map { ($0, Float(0)) }
    )

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isOpaque: Bool { false }

    // MARK: - Feeding

    /// Appends one bucket. Pass `nil` for either parameter when no pipeline is running so the trace
    /// decays to the baseline instead of freezing at its last reading.
    func append(levels: (dry: Float, wet: Float)?, stemLevels: [SeparationStem: Float]?) {
        let targetDry = levels.map { normalized($0.dry) } ?? 0
        let targetWet = levels.map { normalized($0.wet) } ?? 0

        // Dry keeps the slow release — it draws as one continuous envelope, where slow release is
        // what makes it read as a smooth trace instead of noise. Wet now draws as discrete bar
        // columns (one per tick, Practice-style), so the same slow release just flattens every
        // neighboring bar to nearly the same height — a fast release lets each bar reflect the
        // music's actual moment-to-moment dynamics instead of an 8-second-smoothed average.
        smoothedDry = ballistic(current: smoothedDry, target: targetDry)
        smoothedWet = ballistic(current: smoothedWet, target: targetWet, releaseCoefficient: 0.4)

        for stem in SeparationStem.allCases {
            let target = stemLevels?[stem] ?? 0
            smoothedStemMagnitudes[stem] = ballistic(current: smoothedStemMagnitudes[stem] ?? 0, target: target)
        }

        samples.append(Sample(dry: smoothedDry, wet: smoothedWet, stemMagnitudes: smoothedStemMagnitudes))
        if samples.count > Metrics.sampleCapacity {
            samples.removeFirst(samples.count - Metrics.sampleCapacity)
        }
        needsDisplay = true
    }

    func reset() {
        samples.removeAll(keepingCapacity: true)
        smoothedDry = 0
        smoothedWet = 0
        for stem in SeparationStem.allCases {
            smoothedStemMagnitudes[stem] = 0
        }
        needsDisplay = true
    }

    private func ballistic(current: Float, target: Float, releaseCoefficient: Float = 0.12) -> Float {
        let coefficient: Float = target > current ? 0.6 : releaseCoefficient
        return current + (target - current) * coefficient
    }

    /// Linear peak → 0...1 on a dB scale. A linear mapping spends almost all its visual range on
    /// the loudest few dB and makes normal-level music look like a flat line.
    private func normalized(_ peak: Float) -> Float {
        guard peak > 0 else { return 0 }
        let decibels = 20 * log10(min(peak, 1))
        guard decibels > Metrics.decibelFloor else { return 0 }
        return (decibels - Metrics.decibelFloor) / -Metrics.decibelFloor
    }

    // MARK: - Drawing

    /// The dry envelope and the baseline are `labelColor`/`flatDivider` derived, so they invert
    /// with the appearance; the meter only repaints on its 25 Hz tick while Live is running, so
    /// without this a switch made with Live off leaves the old envelope on screen.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let midY = bounds.midY
        drawBaseline(atY: midY)

        if samples.count >= 2 {
            // Dry first, as a translucent backdrop wash — the wet bars paint inside it, and the
            // exposed neutral margin above them is the reduction being shown.
            fillEnvelope(
                using: { $0.dry },
                midY: midY,
                color: NSColor.labelColor.withAlphaComponent(0.18)
            )
            drawWetBars(midY: midY)
        }

        drawLegend()
        drawCaption()
    }

    private func drawBaseline(atY y: CGFloat) {
        NSColor.flatDivider.withAlphaComponent(0.25).setStroke()
        let line = NSBezierPath()
        line.lineWidth = 1
        line.move(to: NSPoint(x: 0, y: y))
        line.line(to: NSPoint(x: bounds.width, y: y))
        line.stroke()
    }

    private func fillEnvelope(
        using magnitude: (Sample) -> Float,
        midY: CGFloat,
        color: NSColor
    ) {
        let amplitude = max(0, midY - Metrics.verticalInset)
        let path = NSBezierPath()

        for (index, sample) in samples.enumerated() {
            let point = NSPoint(x: x(for: index), y: midY + CGFloat(magnitude(sample)) * amplitude)
            index == 0 ? path.move(to: point) : path.line(to: point)
        }
        // Mirror back along the bottom half to close the envelope into a single fillable shape.
        for (index, sample) in samples.enumerated().reversed() {
            path.line(to: NSPoint(x: x(for: index), y: midY - CGFloat(magnitude(sample)) * amplitude))
        }

        path.close()
        color.setFill()
        path.fill()
    }

    /// The wet (mixed-output) level, drawn as Practice-style discrete bar columns instead of a
    /// smooth envelope — one per sample, colored by `HeroWaveformBlend`'s weighted stem blend so a
    /// drum-heavy moment reads amber and a bass-heavy one reads teal, matching Practice's hero
    /// waveform. Colors are resolved here at draw time, not cached on `Sample` at append time — see
    /// the `Sample.stemMagnitudes` doc comment for why.
    private func drawWetBars(midY: CGFloat) {
        let amplitude = max(0, midY - Metrics.verticalInset)
        let slotWidth = bounds.width / CGFloat(Metrics.sampleCapacity)
        let barWidth = slotWidth * Metrics.barFillRatio

        for (index, sample) in samples.enumerated() {
            let height = CGFloat(sample.wet) * amplitude
            guard height > 0.5 else { continue }

            let color = resolvedBarColor(for: sample)
            let left = slotWidth * CGFloat(index) + (slotWidth - barWidth) / 2
            let rect = NSRect(x: left, y: midY - height, width: barWidth, height: height * 2)
            color.setFill()
            NSBezierPath(rect: rect).fill()
        }
    }

    private func resolvedBarColor(for sample: Sample) -> NSColor {
        switch HeroWaveformBlend.barColor(
            forMagnitudes: sample.stemMagnitudes,
            reference: Metrics.stemColorReference,
            isSeparated: true
        ) {
        case .blended(let color):
            return color
        case .tail:
            return HeroWaveformBlend.tailColor
        }
    }

    private func x(for index: Int) -> CGFloat {
        // Pinned to the full capacity, not to `samples.count`, so a partially-filled buffer scrolls
        // in from the left instead of stretching to fill the width and then snapping.
        bounds.width * CGFloat(index) / CGFloat(Metrics.sampleCapacity - 1)
    }

    private func drawLegend() {
        guard caption == nil else { return }

        var originX = Metrics.legendInset

        // "Before": one flat neutral swatch, matching the translucent dry wash.
        originX = drawLegendEntry(
            title: "Before",
            originX: originX,
            swatch: { rect in
                NSColor.labelColor.withAlphaComponent(0.18).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
            }
        )

        // "After": a 4-stripe swatch of the stem identity colors — signals at a glance that the
        // bars below are colored by instrument, the same convention Practice's hero waveform uses.
        _ = drawLegendEntry(
            title: "After",
            originX: originX,
            swatch: { rect in
                let stripeWidth = rect.width / CGFloat(SeparationStem.allCases.count)
                for (index, stem) in SeparationStem.allCases.enumerated() {
                    let stripe = NSRect(x: rect.minX + stripeWidth * CGFloat(index), y: rect.minY, width: stripeWidth, height: rect.height)
                    stem.identityColor.setFill()
                    NSBezierPath(rect: stripe).fill()
                }
            }
        )
    }

    /// Draws one legend entry (a swatch + label) and returns the x-origin the next entry should
    /// start at. `swatch` draws into a fixed 8×8 rect — a closure rather than a single `NSColor` so
    /// the "After" entry can paint its multi-stripe swatch through the same layout code.
    private func drawLegendEntry(title: String, originX: CGFloat, swatch: (NSRect) -> Void) -> CGFloat {
        let swatchRect = NSRect(x: originX, y: bounds.maxY - Metrics.legendInset - 8, width: 8, height: 8)
        swatch(swatchRect)

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let text = NSAttributedString(string: title, attributes: attributes)
        let textOrigin = NSPoint(x: swatchRect.maxX + 4, y: swatchRect.minY - 3)
        text.draw(at: textOrigin)

        return textOrigin.x + text.size().width + 12
    }

    private func drawCaption() {
        guard let caption else { return }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.tertiaryLabelColor
        ]
        let text = NSAttributedString(string: caption, attributes: attributes)
        let size = text.size()
        text.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
    }
}
