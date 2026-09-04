import AppKit

/// Tempo controls above the ruler: what the grid currently is, and the two ways to correct it.
///
/// Spec §6 is emphatic that manual override is not optional — rubato, live and expressively-timed
/// material will defeat any detector — so this row is not a readout with an edit affordance bolted
/// on. It is the primary way a grid gets set for everything detection cannot handle.
///
/// An absent tempo shows an *empty* field rather than a plausible default: a fabricated 120 would
/// be indistinguishable from a detected one, and the whole confidence gate exists to avoid exactly
/// that kind of confident wrongness.
final class TimelineToolbarView: NSView {
    var onBPMEdited: ((Double) -> Void)?
    var onTapped: (() -> Void)?

    /// The range a typed tempo is accepted in. Wider than the detector's 60–200 search, because a
    /// user typing 52 for a slow ballad knows something the detector's preference window does not.
    private static let acceptedBPM = 20.0...400.0

    private let bpmField = NSTextField(string: "")
    private let tapButton: FlatButton
    private var lastAcceptedBPM: Double?

    override init(frame frameRect: NSRect) {
        tapButton = WindowUI.toggleControlButton(title: "Tap", target: nil, action: nil)
        super.init(frame: frameRect)

        let label = SharedUI.fieldLabel("Tempo")
        bpmField.placeholderString = "—"
        bpmField.alignment = .right
        bpmField.controlSize = .small
        bpmField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        bpmField.target = self
        bpmField.action = #selector(bpmCommitted)
        bpmField.widthAnchor.constraint(equalToConstant: 56).isActive = true

        let unit = SharedUI.fieldLabel("BPM")
        // A momentary press, not a mode: `toggleControlButton` latches, so it is reset on each tap.
        tapButton.setButtonType(.momentaryPushIn)
        tapButton.reflectsState = false
        tapButton.target = self
        tapButton.action = #selector(tapped)

        // Tighter than `WindowUI.Metrics.rowSpacing` (8pt) — this view now sits inside the unified
        // control bar (`PracticeDeckViewController.buildContent`), which has to fit alongside the
        // transport and the speed slider in the 632pt the deck pane gets at `WindowSizing.minimum`;
        // see `WindowSizingTests.testTheControlBarFitsTheMinimumWindowWidth`. A local override
        // rather than lowering `rowSpacing` itself, since that constant is shared elsewhere.
        let row = Layout.horizontalStack([label, bpmField, unit, tapButton], spacing: 4)
        Layout.pin(row, to: self, insets: NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0))
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// `nil` leaves the field empty — see the type comment.
    func setBPM(_ bpm: Double?) {
        lastAcceptedBPM = bpm
        bpmField.stringValue = bpm.map { Self.format($0) } ?? ""
    }

    private static func format(_ bpm: Double) -> String {
        let rounded = (bpm * 10).rounded() / 10
        return rounded == rounded.rounded()
            ? String(Int(rounded))
            : String(format: "%.1f", rounded)
    }

    @objc private func bpmCommitted() {
        guard let value = Double(bpmField.stringValue.trimmingCharacters(in: .whitespaces)),
              value.isFinite,
              Self.acceptedBPM.contains(value)
        else {
            // Put back whatever was there. Leaving a rejected typo on screen would read as an
            // accepted tempo that simply had not taken effect.
            bpmField.stringValue = lastAcceptedBPM.map { Self.format($0) } ?? ""
            return
        }
        lastAcceptedBPM = value
        bpmField.stringValue = Self.format(value)
        onBPMEdited?(value)
    }

    @objc private func tapped() {
        onTapped?()
    }

    // MARK: - Test seams

    var displayedBPMForTesting: String { bpmField.stringValue }

    func commitBPMForTesting(_ text: String) {
        bpmField.stringValue = text
        bpmCommitted()
    }

    func tapForTesting() {
        tapped()
    }
}
