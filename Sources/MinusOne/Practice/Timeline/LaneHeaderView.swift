import AppKit

/// One lane's controls: name, fader, mute (Cmd-click to isolate), export.
///
/// This is `MixerRowView` rebuilt for a 132×72 box — the same callbacks reaching the same
/// `StemMixerController`, stacked vertically instead of strung across the deck's full width.
/// Spec §3: a lane *is* a mixer row, which is why the separate "Stems" section goes away.
final class LaneHeaderView: NSView {
    var onVolumeChanged: ((Float) -> Void)?
    var onMuteToggled: ((Bool) -> Void)?
    var onIsolateRequested: (() -> Void)?
    var onExportRequested: (() -> Void)?

    private let nameLabel: NSTextField
    private let slider: NSSlider
    private let muteToggle: MuteToggleView
    private let exportButton: FlatButton

    init(stem: SeparationStem) {
        nameLabel = SharedUI.fieldLabel(stem.displayName)
        slider = NSSlider(value: 1, minValue: 0, maxValue: 1, target: nil, action: nil)
        muteToggle = MuteToggleView(label: stem.displayName)
        exportButton = Self.laneIconButton(symbolName: "square.and.arrow.up", label: "Export \(stem.displayName)", target: nil, action: nil)
        super.init(frame: .zero)

        // The text variant, not the fill: as an 11pt label the raw stem hues measure 2.7:1
        // (Drums), 3.7:1 (Bass) and 4.2:1 (Other) against a light card. The fader below takes the
        // canonical `identityColor` — as an area of fill it has no such problem.
        nameLabel.textColor = stem.identityTextColor
        nameLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        nameLabel.lineBreakMode = .byTruncatingTail

        slider.isContinuous = true
        slider.controlSize = .small
        slider.trackFillColor = stem.identityColor
        slider.target = self
        slider.action = #selector(sliderChanged(_:))

        muteToggle.onMuteToggled = { [weak self] in self?.onMuteToggled?($0) }
        muteToggle.onIsolateRequested = { [weak self] in self?.onIsolateRequested?() }

        exportButton.setButtonType(.momentaryPushIn)
        exportButton.reflectsState = false
        exportButton.target = self
        exportButton.action = #selector(exportClicked)
        exportButton.isEnabled = false

        // Name + the mute switch on top, fader + the export action below — two roomy rows instead
        // of three cramped ones, and the mute switch no longer carries a permanent border (see
        // `laneIconButton`), so an inert lane reads as a name and a fader, not boxed controls.
        let topRow = Layout.horizontalStack([nameLabel, Layout.flexibleSpacer(), muteToggle], spacing: 4)
        let bottomRow = Layout.horizontalStack([slider, exportButton], spacing: 6)
        let stack = Layout.verticalStack([topRow, bottomRow], spacing: 8)
        Layout.pin(stack, to: self, insets: NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8))
        // `.leading`-aligned stacks pin their children's leading edge only — see `WindowUI.section`
        // for the same trap. Without this, `bottomRow`'s slider (the widest thing here) would claim
        // only its own fitting width instead of the header's, and `topRow` would do the same.
        topRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        bottomRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// A borderless icon button for the lane header — export still uses this. Dropping the border
    /// (kept only as `FlatButton.engagedFillColorOverride`'s solid fill, which still shows when a
    /// toggle is on) leaves a lane with nothing engaged reading as a name and a fader, with icons
    /// that light up rather than a row of boxes.
    ///
    /// `cornerStyle = .capsule` makes a 20×20 button's engaged fill a circle rather than a rounded
    /// square — `FlatButton.layout()` re-derives the radius from the bounds on every layout pass,
    /// so this is set once here rather than fought on every resize. Momentary buttons (export) set
    /// `reflectsState = false` themselves after construction, same as `WindowUI.transportButton`
    /// documents — a plain click leaves `state == .on` regardless of button type.
    private static func laneIconButton(
        symbolName: String,
        label: String,
        target: AnyObject?,
        action: Selector?
    ) -> FlatButton {
        let button = FlatButton(title: "", kind: .secondary, target: target, action: action)
        button.setButtonType(.pushOnPushOff)
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.setIcon(symbolName, pointSize: 11, label: label)
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.cornerStyle = .capsule
        button.layer?.borderWidth = 0
        button.constrainSize(width: 20, height: 20)
        return button
    }

    func setVolume(_ volume: Float) {
        slider.doubleValue = Double(volume)
    }

    func setMuted(_ muted: Bool) {
        muteToggle.setMuted(muted)
    }

    /// Disabled until separation has written the whole stem, exactly as the old mixer row was.
    func setExportEnabled(_ enabled: Bool) {
        exportButton.isEnabled = enabled
    }

    // MARK: - Actions

    @objc private func sliderChanged(_ sender: NSSlider) {
        onVolumeChanged?(Float(sender.doubleValue))
    }

    @objc private func exportClicked() {
        onExportRequested?()
    }

    // MARK: - Test seams

    // Driving `NSControl` actions through synthesised events proves less about this view than
    // calling what the event would call, and costs a window to do it in.
    var nameColorForTesting: NSColor? { nameLabel.textColor }
    var isMutedForTesting: Bool { muteToggle.isMuted }
    var volumeForTesting: Float { Float(slider.doubleValue) }
    var isExportEnabledForTesting: Bool { exportButton.isEnabled }

    func setVolumeForTesting(_ volume: Float) {
        slider.doubleValue = Double(volume)
        sliderChanged(slider)
    }

    func toggleMuteForTesting() {
        muteToggle.simulateClickForTesting()
    }

    func isolateForTesting() {
        muteToggle.simulateCmdClickForTesting()
    }
}
