import AppKit

/// One lane's controls: name, fader, mute, solo, export.
///
/// This is `MixerRowView` rebuilt for a 132×72 box — the same four callbacks reaching the same
/// `StemMixerController`, stacked vertically instead of strung across the deck's full width.
/// Spec §3: a lane *is* a mixer row, which is why the separate "Stems" section goes away.
final class LaneHeaderView: NSView {
    var onVolumeChanged: ((Float) -> Void)?
    var onMuteToggled: ((Bool) -> Void)?
    var onSoloToggled: (() -> Void)?
    var onExportRequested: (() -> Void)?

    private let nameLabel: NSTextField
    private let slider: NSSlider
    private let soloButton: FlatButton
    private let muteButton: FlatButton
    private let exportButton: FlatButton

    init(stem: SeparationStem) {
        nameLabel = SharedUI.fieldLabel(stem.displayName)
        slider = NSSlider(value: 1, minValue: 0, maxValue: 1, target: nil, action: nil)
        soloButton = Self.laneToggleButton(symbolName: "headphones", label: "Solo \(stem.displayName)", target: nil, action: nil)
        muteButton = Self.laneToggleButton(symbolName: "speaker.slash.fill", label: "Mute \(stem.displayName)", target: nil, action: nil)
        exportButton = WindowUI.rowIconButton(
            symbolName: "square.and.arrow.up",
            label: "Export \(stem.displayName)",
            target: nil,
            action: nil
        )
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

        muteButton.engagedFillColorOverride = .systemRed
        soloButton.target = self
        soloButton.action = #selector(soloClicked)
        muteButton.target = self
        muteButton.action = #selector(muteClicked)
        exportButton.target = self
        exportButton.action = #selector(exportClicked)
        exportButton.isEnabled = false

        let buttons = Layout.horizontalStack([soloButton, muteButton, exportButton], spacing: 4)
        let stack = Layout.verticalStack([nameLabel, slider, buttons], spacing: 3)
        Layout.pin(stack, to: self, insets: NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6))
        exportButton.heightAnchor.constraint(equalTo: muteButton.heightAnchor).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// A latching icon button sized for the lane header's 132pt column.
    ///
    /// Not `WindowUI.toggleControlButton`: `FlatButton` inflates a *titled* button's intrinsic size
    /// by 14.4pt a side, which measured a three-button row at 135×76 against a 132×72 budget. An
    /// empty title skips that padding — the escape `FlatButton.intrinsicContentSize` documents for
    /// the title bar's theme switch — so these are glyphs with tooltips and accessibility labels
    /// rather than "Solo"/"Mute" text.
    ///
    /// Not `WindowUI.rowIconButton` either: that one is momentary, and these are modes that must
    /// stay lit while engaged.
    private static func laneToggleButton(
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
        button.constrainSize(width: 26, height: 20)
        return button
    }

    func setSoloed(_ soloed: Bool) {
        soloButton.state = soloed ? .on : .off
        soloButton.refreshStyle()
    }

    /// Disabled until separation has written the whole stem, exactly as the old mixer row was.
    func setExportEnabled(_ enabled: Bool) {
        exportButton.isEnabled = enabled
    }

    // MARK: - Actions

    @objc private func sliderChanged(_ sender: NSSlider) {
        onVolumeChanged?(Float(sender.doubleValue))
    }

    @objc private func soloClicked() {
        onSoloToggled?()
    }

    @objc private func muteClicked() {
        muteButton.refreshStyle()
        onMuteToggled?(muteButton.state == .on)
    }

    @objc private func exportClicked() {
        onExportRequested?()
    }

    // MARK: - Test seams

    // Driving `NSControl` actions through synthesised events proves less about this view than
    // calling what the event would call, and costs a window to do it in.
    var nameColorForTesting: NSColor? { nameLabel.textColor }
    var isSoloedForTesting: Bool { soloButton.state == .on }
    var isExportEnabledForTesting: Bool { exportButton.isEnabled }

    func setVolumeForTesting(_ volume: Float) {
        slider.doubleValue = Double(volume)
        sliderChanged(slider)
    }

    func toggleMuteForTesting() {
        muteButton.state = muteButton.state == .on ? .off : .on
        muteClicked()
    }

    func toggleSoloForTesting() {
        soloClicked()
    }
}
