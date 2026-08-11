import AppKit

/// Minimal menu bar popover per REDESIGN.md §2: status line, Live/Record toggles, and the two
/// exits (open the window, quit). Everything else — Intensity/Gain/Capture — lives in the
/// desktop window's Live tab (`LiveTabViewController`), not here.
final class MenuBarPopoverViewController: NSViewController {
    private let statusHeaderContainer = NSView()
    private let statusHeader = StatusHeaderView()
    private let liveToggle = NSSwitch()
    private let recordToggle = NSSwitch()
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
        liveToggle.target = self
        liveToggle.action = #selector(liveToggleChanged)
        liveToggle.translatesAutoresizingMaskIntoConstraints = false

        recordToggle.target = self
        recordToggle.action = #selector(recordToggleChanged)
        recordToggle.translatesAutoresizingMaskIntoConstraints = false
        if #unavailable(macOS 14.2) {
            recordToggle.isEnabled = false
            recordToggle.toolTip = "System audio recording requires macOS 14.2 or later."
        }
    }

    private func configureContent(in effectView: NSVisualEffectView) {
        statusHeaderContainer.translatesAutoresizingMaskIntoConstraints = false

        let toggleRows = PopoverUI.verticalStack(
            [
                PopoverUI.formRow(label: "Live", control: liveToggle),
                PopoverUI.formRow(label: "Record", control: recordToggle)
            ],
            spacing: PopoverUI.Metrics.rowSpacing
        )

        let openButton = PopoverUI.nativeLinkButton(title: "Open MinusOne…", target: self, action: #selector(openWindow))
        let quitButton = PopoverUI.nativeLinkButton(title: "Quit", target: self, action: #selector(quit))

        let topSeparator = PopoverUI.nativeSeparator()
        let footerSeparator = PopoverUI.nativeSeparator()
        let footer = PopoverUI.verticalStack([footerSeparator, openButton, quitButton], spacing: PopoverUI.Metrics.rowSpacing)
        footer.alignment = .leading

        let sections: [NSView] = [statusHeaderContainer, topSeparator, toggleRows, footer]
        let content = PopoverUI.verticalStack(sections, spacing: PopoverUI.Metrics.sectionSpacing)
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

    private func setSwitchState(_ toggle: NSSwitch, on: Bool) {
        guard toggle.state != (on ? .on : .off) else { return }
        toggle.state = on ? .on : .off
    }

    private func refreshStatusHeader() {
        let (title, indicatorColor, errorDetail) = statusCopy(for: currentStatus, isFilterActive: isFilterActive)

        if statusHeader.superview !== statusHeaderContainer {
            statusHeaderContainer.subviews.forEach { $0.removeFromSuperview() }
            statusHeader.translatesAutoresizingMaskIntoConstraints = false
            statusHeaderContainer.addSubview(statusHeader)
            NSLayoutConstraint.activate([
                statusHeader.leadingAnchor.constraint(equalTo: statusHeaderContainer.leadingAnchor),
                statusHeader.trailingAnchor.constraint(equalTo: statusHeaderContainer.trailingAnchor),
                statusHeader.topAnchor.constraint(equalTo: statusHeaderContainer.topAnchor),
                statusHeader.bottomAnchor.constraint(equalTo: statusHeaderContainer.bottomAnchor)
            ])
        }
        statusHeader.update(title: title, indicatorColor: indicatorColor, errorDetail: errorDetail)
    }

    private func statusCopy(for status: AudioEngineStatus, isFilterActive: Bool) -> (String, NSColor, String?) {
        switch status {
        case .active where isFilterActive:
            return ("On", .brandAccentDeep, nil)
        case .warmingUp:
            return ("Warming up", .systemCyan, nil)
        case .permissionRequired:
            return ("Permission needed", .systemOrange, nil)
        case .error(let message):
            return ("Error", .systemRed, message)
        default:
            return isFilterActive
                ? ("On", .brandAccentDeep, nil)
                : ("Off", .tertiaryLabelColor, nil)
        }
    }

    @objc private func liveToggleChanged() {
        onToggleLive?()
    }

    @objc private func recordToggleChanged() {
        onToggleRecord?()
    }

    @objc private func openWindow() {
        onOpenWindow?()
    }

    @objc private func quit() {
        onQuit?()
    }
}
