import AppKit

/// Scrolling before/after level meter for the Live tab's hero card — the one place in the app that
/// shows vocal reduction actually happening. Two mirrored envelopes share a baseline: the outer
/// neutral one is the delayed dry signal (what you would have heard), the inner coral one is the
/// mixed output (what you do hear). The gap between them *is* the vocal being removed.
///
/// Drawing follows `LiveWaveformView`'s approach (bucketed peaks → `NSBezierPath`) but is a separate
/// view rather than a reuse: that one is bound to `SystemAudioRecorder`'s 0.1s recording buckets and
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
    }

    private struct Sample {
        var dry: Float
        var wet: Float
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

    /// Appends one bucket. Pass `nil` when no pipeline is running so the trace decays to the
    /// baseline instead of freezing at its last reading.
    func append(levels: (dry: Float, wet: Float)?) {
        let targetDry = levels.map { normalized($0.dry) } ?? 0
        let targetWet = levels.map { normalized($0.wet) } ?? 0

        // Fast attack / slow release, the usual meter ballistics — without the slow release a peak
        // meter at this refresh rate reads as noise rather than as a signal envelope.
        smoothedDry = ballistic(current: smoothedDry, target: targetDry)
        smoothedWet = ballistic(current: smoothedWet, target: targetWet)

        samples.append(Sample(dry: smoothedDry, wet: smoothedWet))
        if samples.count > Metrics.sampleCapacity {
            samples.removeFirst(samples.count - Metrics.sampleCapacity)
        }
        needsDisplay = true
    }

    func reset() {
        samples.removeAll(keepingCapacity: true)
        smoothedDry = 0
        smoothedWet = 0
        needsDisplay = true
    }

    private func ballistic(current: Float, target: Float) -> Float {
        let coefficient: Float = target > current ? 0.6 : 0.12
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
            // Dry first so the wet envelope paints inside it; the exposed neutral margin is the
            // reduction the user is being shown.
            fillEnvelope(
                using: { $0.dry },
                midY: midY,
                color: NSColor.labelColor.withAlphaComponent(0.18)
            )
            fillEnvelope(
                using: { $0.wet },
                midY: midY,
                color: .brandAccent
            )
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

    private func x(for index: Int) -> CGFloat {
        // Pinned to the full capacity, not to `samples.count`, so a partially-filled buffer scrolls
        // in from the left instead of stretching to fill the width and then snapping.
        bounds.width * CGFloat(index) / CGFloat(Metrics.sampleCapacity - 1)
    }

    private func drawLegend() {
        guard caption == nil else { return }

        let entries: [(String, NSColor)] = [
            ("Before", NSColor.labelColor.withAlphaComponent(0.18)),
            ("After", .brandAccent)
        ]
        var originX = Metrics.legendInset

        for (title, color) in entries {
            let swatch = NSRect(x: originX, y: bounds.maxY - Metrics.legendInset - 8, width: 8, height: 8)
            color.setFill()
            NSBezierPath(roundedRect: swatch, xRadius: 2, yRadius: 2).fill()

            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
            let text = NSAttributedString(string: title, attributes: attributes)
            let textOrigin = NSPoint(x: swatch.maxX + 4, y: swatch.minY - 3)
            text.draw(at: textOrigin)

            originX = textOrigin.x + text.size().width + 12
        }
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
