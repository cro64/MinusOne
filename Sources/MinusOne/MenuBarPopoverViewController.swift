import AppKit

/// Minimal menu bar popover per REDESIGN.md §2: status line, Live/Record toggles, and the two
/// exits (open the window, quit). Everything else — Intensity/Gain/Capture — lives in the
/// desktop window's Live tab (`LiveTabViewController`), not here.
final class MenuBarPopoverViewController: NSViewController {
    private let statusHeaderContainer = NSView()
    private let statusHeader = StatusHeaderView()
    // `ToggleSwitchView`, not `NSSwitch`: the on-state has to be the brand coral (REDESIGN.md §6),
    // and a native switch paints its on-state with the *system* accent color with no tint hook.
    private let liveToggle = ToggleSwitchView()
    private let recordToggle = ToggleSwitchView()
    private var contentStack: NSStackView?

    private var currentStatus: AudioEngineStatus = .idle
    private var isFilterActive = false
    private var isRecording = false

    var onToggleLive: (() -> Void)?
    var onToggleRecord: (() -> Void)?
    var onOpenWindow: (() -> Void)?
    var onQuit: (() -> Void)?
    var onPreferredSizeChange: ((NSSize) -> Void)?

    override func loadView() {
        let provisional = PopoverUI.Metrics.menuSize(contentHeight: 200)
        let (root, effectView) = PopoverUI.makeMenuRoot(size: provisional)
        view = root

        configureControls()
        configureContent(in: effectView)
        refreshStatusHeader()
        sizeToFitContent()
    }

    private func configureControls() {
        liveToggle.setAccessibilityLabel("Live")
        liveToggle.onToggle = { [weak self] _ in self?.onToggleLive?() }
        liveToggle.translatesAutoresizingMaskIntoConstraints = false

        recordToggle.setAccessibilityLabel("Record")
        recordToggle.onToggle = { [weak self] _ in self?.onToggleRecord?() }
        recordToggle.translatesAutoresizingMaskIntoConstraints = false
        if #unavailable(macOS 14.2) {
            recordToggle.isEnabled = false
            recordToggle.toolTip = "System audio recording requires macOS 14.2 or later."
        }
    }

    private func configureContent(in effectView: NSVisualEffectView) {
        statusHeaderContainer.translatesAutoresizingMaskIntoConstraints = false

        let liveRow = PopoverUI.compactFormRow(label: "Live", control: liveToggle)
        let recordRow = PopoverUI.compactFormRow(label: "Record", control: recordToggle)
        let toggleRows = Layout.verticalStack([liveRow, recordRow], spacing: PopoverUI.Metrics.rowSpacing)

        let openButton = PopoverUI.nativeLinkButton(title: "Open MinusOne…", target: self, action: #selector(openWindow))
        let quitButton = PopoverUI.nativeLinkButton(title: "Quit", target: self, action: #selector(quit))

        let topSeparator = PopoverUI.nativeSeparator()
        let footerSeparator = PopoverUI.nativeSeparator()
        let footer = Layout.verticalStack([footerSeparator, openButton, quitButton], spacing: PopoverUI.Metrics.rowSpacing)
        footer.alignment = .leading

        let sections: [NSView] = [statusHeaderContainer, topSeparator, toggleRows, footer]
        let content = Layout.verticalStack(sections, spacing: PopoverUI.Metrics.sectionSpacing)
        content.setCustomSpacing(PopoverUI.Metrics.rowSpacing, after: statusHeaderContainer)
        content.translatesAutoresizingMaskIntoConstraints = false
        contentStack = content
        effectView.addSubview(content)

        let pad = PopoverUI.Metrics.padding
        let contentWidth = PopoverUI.Metrics.contentWidth
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: effectView.leadingAnchor, constant: pad),
            content.trailingAnchor.constraint(equalTo: effectView.trailingAnchor, constant: -pad),
            content.topAnchor.constraint(equalTo: effectView.topAnchor, constant: pad),
            content.widthAnchor.constraint(equalToConstant: contentWidth),
            statusHeaderContainer.heightAnchor.constraint(equalToConstant: PopoverUI.Metrics.rowHeight),
            statusHeaderContainer.widthAnchor.constraint(equalTo: content.widthAnchor),
            topSeparator.widthAnchor.constraint(equalTo: content.widthAnchor),
            // `verticalStack`'s alignment is `.leading`, which only leading-pins arranged
            // subviews rather than stretching them — without these, toggleRows/footer (and each
            // row/button inside them) fall back to their own narrower intrinsic width, leaving a
            // visible empty gutter between them and the popover's right edge.
            toggleRows.widthAnchor.constraint(equalTo: content.widthAnchor),
            liveRow.widthAnchor.constraint(equalTo: toggleRows.widthAnchor),
            recordRow.widthAnchor.constraint(equalTo: toggleRows.widthAnchor),
            footer.widthAnchor.constraint(equalTo: content.widthAnchor),
            footerSeparator.widthAnchor.constraint(equalTo: footer.widthAnchor),
            openButton.widthAnchor.constraint(equalTo: footer.widthAnchor),
            quitButton.widthAnchor.constraint(equalTo: footer.widthAnchor)
        ])
    }

    func sizeToFitContent() {
        guard let contentStack else { return }
        let probe = PopoverUI.Metrics.menuSize(contentHeight: 800)
        view.setFrameSize(probe)
        view.layoutSubtreeIfNeeded()
        contentStack.layoutSubtreeIfNeeded()

        let contentHeight = max(contentStack.fittingSize.height, 1)
        let size = PopoverUI.Metrics.menuSize(contentHeight: contentHeight)
        preferredContentSize = size
        view.setFrameSize(size)
        PopoverUI.updateShadowPath(for: view, size: size)
        onPreferredSizeChange?(size)
    }

    func updateStatusDisplay(_ status: AudioEngineStatus, isFilterActive: Bool) {
        currentStatus = status
        self.isFilterActive = isFilterActive
        refreshStatusHeader()
        setSwitchState(liveToggle, on: isFilterActive)
    }

    func updateRecordingState(_ isRecording: Bool) {
        self.isRecording = isRecording
        setSwitchState(recordToggle, on: isRecording)
    }

    private func setSwitchState(_ toggle: ToggleSwitchView, on: Bool) {
        guard toggle.isOn != on else { return }
        toggle.isOn = on
    }

    private func refreshStatusHeader() {
        if statusHeader.superview !== statusHeaderContainer {
            statusHeaderContainer.subviews.forEach { $0.removeFromSuperview() }
            Layout.pin(statusHeader, to: statusHeaderContainer)
        }
        statusHeader.update(for: currentStatus, isFilterActive: isFilterActive)
    }

    @objc private func openWindow() {
        onOpenWindow?()
    }

    @objc private func quit() {
        onQuit?()
    }
}
