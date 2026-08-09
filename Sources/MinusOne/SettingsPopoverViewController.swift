import AppKit

final class SettingsPopoverViewController: NSViewController {
    private let preferences: Preferences
    private let audioEngine: AudioEngine

    private let statusHeaderContainer = NSView()
    private let statusHeader = StatusHeaderView()
    private let intensitySlider = DragValueSlider(value: 100, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let makeupSlider = DragValueSlider(value: 4.5, minValue: 0, maxValue: 12, target: nil, action: nil)
    private let sliderValueOverlay = PopoverUI.valueLabel()
    private let modePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let captureScopePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private var appPickerPopUp: NSPopUpButton?
    private let permissionButton = PopoverUI.linkButton(title: "Open Microphone Settings…")
    private var contentStack: NSStackView?

    private var currentStatus: AudioEngineStatus = .idle
    private var activeOverlaySlider: NSSlider?

    var onSettingsChanged: (() -> Void)?
    var onQuit: (() -> Void)?
    var onOpenPracticeMode: (() -> Void)?
    var onPreferredSizeChange: ((NSSize) -> Void)?

    init(preferences: Preferences, audioEngine: AudioEngine) {
        self.preferences = preferences
        self.audioEngine = audioEngine
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let provisional = PopoverUI.Metrics.menuSize(contentHeight: 200)
        let (root, effectView) = PopoverUI.makeMenuRoot(size: provisional)
        view = root

        configureControls()
        configureContent(in: effectView)

        permissionButton.isHidden = true
        updateCaptureScopeUI()
        refreshStatusHeader()
        sizeToFitContent()
    }

    private func configureContent(in effectView: NSVisualEffectView) {
        var sections: [NSView] = [statusHeaderContainer]
        statusHeaderContainer.translatesAutoresizingMaskIntoConstraints = false

        let processingRows: [NSView] = [
            formRow(label: "Mode", control: modePopUp),
            PopoverUI.sliderRow(label: "Intensity", slider: intensitySlider),
            PopoverUI.sliderRow(label: "Gain", slider: makeupSlider)
        ]
        sections.append(section(title: "Processing", rows: processingRows))

        if #available(macOS 14.2, *) {
            let picker = AppPickerPopUpButton(preferences: preferences, audioEngine: audioEngine)
            appPickerPopUp = picker
            let captureRows: [NSView] = [
                formRow(label: "Scope", control: captureScopePopUp),
                formRow(label: "Apps", control: picker)
            ]
            sections.append(section(title: "Capture", rows: captureRows))
        }

        sections.append(permissionButton)
        sections.append(footer())

        let content = PopoverUI.verticalStack(sections, spacing: PopoverUI.Metrics.sectionSpacing)
        content.setCustomSpacing(6, after: statusHeaderContainer)
        content.translatesAutoresizingMaskIntoConstraints = false
        contentStack = content
        effectView.addSubview(content)

        let pad = PopoverUI.Metrics.padding
        let contentWidth = PopoverUI.Metrics.contentWidth
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: effectView.leadingAnchor, constant: pad),
            content.trailingAnchor.constraint(equalTo: effectView.trailingAnchor, constant: -pad),
            content.topAnchor.constraint(equalTo: effectView.topAnchor, constant: pad),
            // Bottom is not pinned — height comes from content, then the panel is sized to fit.
            content.widthAnchor.constraint(equalToConstant: contentWidth),
            statusHeaderContainer.heightAnchor.constraint(equalToConstant: PopoverUI.Metrics.rowHeight),
            statusHeaderContainer.widthAnchor.constraint(equalTo: content.widthAnchor)
        ])
    }

    /// Sizes the panel to content width + padding, height from laid-out content.
    func sizeToFitContent() {
        guard let contentStack else { return }

        // Give Auto Layout room to measure intrinsic height.
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

    func reloadFromPreferences() {
        guard isViewLoaded, modePopUp.numberOfItems > 0 else { return }

        if let modeIndex = ProcessingMode.allCases.firstIndex(of: preferences.processingMode) {
            setPopUpSelection(modePopUp, index: modeIndex, action: #selector(modeChanged))
        }
        if let scopeIndex = CaptureScope.allCases.firstIndex(of: preferences.captureScope) {
            setPopUpSelection(captureScopePopUp, index: scopeIndex, action: #selector(captureScopeChanged))
        }

        intensitySlider.floatValue = preferences.targetIntensity * 100
        makeupSlider.floatValue = preferences.makeupGainDecibels
        updateCaptureScopeUI()
        refreshControlStates()
        if #available(macOS 14.2, *) {
            (appPickerPopUp as? AppPickerPopUpButton)?.reloadFromPreferences()
        }
    }

    func updateStatusDisplay(_ status: AudioEngineStatus, isFilterActive: Bool) {
        currentStatus = status
        refreshStatusHeader(isFilterActive: isFilterActive)
        updatePermissionButton(for: status)
    }

    func updatePermissionButton(for status: AudioEngineStatus) {
        let wasHidden = permissionButton.isHidden
        switch status {
        case .permissionRequired(.microphone):
            permissionButton.title = "Open Microphone Settings…"
            permissionButton.isHidden = false
        case .permissionRequired(.systemAudioRecording):
            permissionButton.title = "Open System Audio Settings…"
            permissionButton.isHidden = false
        default:
            permissionButton.isHidden = true
        }
        if wasHidden != permissionButton.isHidden {
            sizeToFitContent()
        }
    }

    private func configureControls() {
        PopoverUI.configureSlider(intensitySlider)
        intensitySlider.target = self
        intensitySlider.action = #selector(intensityChanged)
        intensitySlider.onDragBegan = { [weak self] in
            self?.beginSliderOverlay(for: self?.intensitySlider)
        }
        intensitySlider.onDragEnded = { [weak self] in
            self?.endSliderOverlay()
        }

        PopoverUI.configureSlider(makeupSlider)
        makeupSlider.target = self
        makeupSlider.action = #selector(makeupGainChanged)
        makeupSlider.onDragBegan = { [weak self] in
            self?.beginSliderOverlay(for: self?.makeupSlider)
        }
        makeupSlider.onDragEnded = { [weak self] in
            self?.endSliderOverlay()
        }

        PopoverUI.configurePopUp(modePopUp)
        modePopUp.target = self
        modePopUp.action = #selector(modeChanged)
        for mode in ProcessingMode.allCases {
            modePopUp.addItem(withTitle: mode.displayName)
        }

        PopoverUI.configurePopUp(captureScopePopUp)
        captureScopePopUp.target = self
        captureScopePopUp.action = #selector(captureScopeChanged)
        for scope in CaptureScope.allCases {
            captureScopePopUp.addItem(withTitle: scope.displayName)
        }

        permissionButton.target = self
        permissionButton.action = #selector(openPermissionSettings)
    }

    private func section(title: String, rows: [NSView]) -> NSView {
        let header = PopoverUI.sectionHeader(title)
        let rowsStack = PopoverUI.verticalStack(rows, spacing: PopoverUI.Metrics.rowSpacing)
        return PopoverUI.verticalStack([header, rowsStack], spacing: 8)
    }

    private func formRow(label: String, control: NSView) -> NSView {
        PopoverUI.formRow(label: label, control: control)
    }

    private func footer() -> NSView {
        let separator = PopoverUI.separator()

        let practiceButton = NSButton(title: "Open Practice Mode…", target: self, action: #selector(openPracticeMode))
        practiceButton.isBordered = false
        practiceButton.bezelStyle = .inline
        practiceButton.alignment = .center
        practiceButton.font = .systemFont(ofSize: NSFont.systemFontSize)
        practiceButton.translatesAutoresizingMaskIntoConstraints = false

        let quitButton = NSButton(title: "Quit", target: self, action: #selector(quit))
        quitButton.isBordered = false
        quitButton.bezelStyle = .inline
        quitButton.alignment = .center
        quitButton.font = .systemFont(ofSize: NSFont.systemFontSize)
        quitButton.translatesAutoresizingMaskIntoConstraints = false

        let footer = PopoverUI.verticalStack([separator, practiceButton, quitButton], spacing: 8)
        footer.alignment = .leading

        NSLayoutConstraint.activate([
            separator.widthAnchor.constraint(equalTo: footer.widthAnchor),
            practiceButton.widthAnchor.constraint(equalTo: footer.widthAnchor),
            practiceButton.heightAnchor.constraint(equalToConstant: PopoverUI.Metrics.rowHeight),
            quitButton.widthAnchor.constraint(equalTo: footer.widthAnchor),
            quitButton.heightAnchor.constraint(equalToConstant: PopoverUI.Metrics.rowHeight)
        ])
        return footer
    }

    @objc private func openPracticeMode() {
        onOpenPracticeMode?()
    }

    private func refreshStatusHeader(isFilterActive: Bool? = nil) {
        let active = isFilterActive ?? audioEngine.isVocalReductionActive
        let (title, indicatorColor, errorDetail) = statusCopy(for: currentStatus, isFilterActive: active)

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
            return ("On", .controlAccentColor, nil)
        case .warmingUp:
            return ("Warming up", .systemCyan, nil)
        case .monoInput:
            return ("Mono input", .systemYellow, nil)
        case .permissionRequired:
            return ("Permission needed", .systemOrange, nil)
        case .error(let message):
            return ("Error", .systemRed, message)
        case .passthrough, .idle:
            return ("Off", .tertiaryLabelColor, nil)
        default:
            return isFilterActive
                ? ("On", .controlAccentColor, nil)
                : ("Off", .tertiaryLabelColor, nil)
        }
    }

    private func refreshControlStates() {
        let neuralAvailable = audioEngine.isNeuralSeparationAvailable
        let mode = preferences.processingMode

        if let neuralIndex = ProcessingMode.allCases.firstIndex(of: .aiVocalSeparation),
           let item = modePopUp.item(at: neuralIndex) {
            item.isEnabled = true
            item.attributedTitle = NSAttributedString(
                string: ProcessingMode.aiVocalSeparation.displayName,
                attributes: neuralAvailable
                    ? [:]
                    : [.foregroundColor: NSColor.secondaryLabelColor]
            )
            item.toolTip = neuralAvailable
                ? ProcessingMode.aiVocalSeparation.detailText
                : SeparationModelFactory.modelInstallHint
        }

        let reductionEnabled = mode.supportsVocalReduction
        intensitySlider.isEnabled = reductionEnabled
        makeupSlider.isEnabled = reductionEnabled
        intensitySlider.alphaValue = reductionEnabled ? 1 : 0.45
        makeupSlider.alphaValue = reductionEnabled ? 1 : 0.45
        modePopUp.toolTip = mode.detailText

        let processTapAvailable = audioEngine.activeCaptureBackend != .blackHole
        captureScopePopUp.isEnabled = processTapAvailable || audioEngine.activeCaptureBackend == nil
        captureScopePopUp.alphaValue = captureScopePopUp.isEnabled ? 1 : 0.45
        captureScopePopUp.toolTip = captureScopePopUp.isEnabled
            ? preferences.captureScope.detailText
            : "App selection requires Process Tap (macOS 14.2+). BlackHole captures all audio."
    }

    private func updateCaptureScopeUI() {
        let selectedApps = preferences.captureScope == .selectedApps
        appPickerPopUp?.isEnabled = selectedApps
        appPickerPopUp?.alphaValue = selectedApps ? 1 : 0.45
        appPickerPopUp?.toolTip = selectedApps
            ? "Choose which apps get vocal reduction"
            : "Set Scope to Custom first"
        captureScopePopUp.toolTip = preferences.captureScope.detailText
        if #available(macOS 14.2, *) {
            (appPickerPopUp as? AppPickerPopUpButton)?.reloadFromPreferences()
        }
    }

    private func beginSliderOverlay(for slider: NSSlider?) {
        guard let slider else { return }
        activeOverlaySlider = slider
        updateSliderOverlay()
    }

    private func endSliderOverlay() {
        activeOverlaySlider = nil
        sliderValueOverlay.isHidden = true
        sliderValueOverlay.removeFromSuperview()
    }

    private func updateSliderOverlay() {
        guard let slider = activeOverlaySlider else { return }

        let text: String
        if slider === intensitySlider {
            text = "\(Int(intensitySlider.floatValue.rounded()))%"
        } else {
            text = String(format: "%.1f dB", makeupSlider.floatValue)
        }

        sliderValueOverlay.stringValue = " \(text) "
        sliderValueOverlay.sizeToFit()
        var size = sliderValueOverlay.fittingSize
        size.width = max(size.width + 10, 36)
        size.height = max(size.height + 2, 18)
        sliderValueOverlay.frame.size = size

        let knobRect: NSRect
        if let cell = slider.cell as? NSSliderCell {
            knobRect = slider.convert(cell.knobRect(flipped: slider.isFlipped), to: view)
        } else {
            knobRect = slider.convert(slider.bounds, to: view)
        }

        var origin = NSPoint(
            x: knobRect.midX - size.width / 2,
            y: knobRect.maxY + 4
        )
        origin.x = min(max(origin.x, 4), view.bounds.width - size.width - 4)
        origin.y = min(origin.y, view.bounds.height - size.height - 4)
        sliderValueOverlay.frame.origin = origin

        if sliderValueOverlay.superview !== view {
            view.addSubview(sliderValueOverlay, positioned: .above, relativeTo: nil)
        }
        sliderValueOverlay.isHidden = false
    }

    private func setPopUpSelection(_ popUp: NSPopUpButton, index: Int, action: Selector) {
        let previousAction = popUp.action
        let previousTarget = popUp.target
        popUp.action = nil
        popUp.target = nil
        popUp.selectItem(at: index)
        popUp.action = previousAction
        popUp.target = previousTarget
    }

    @objc private func modeChanged() {
        let index = modePopUp.indexOfSelectedItem
        guard index >= 0, index < ProcessingMode.allCases.count else { return }

        let mode = ProcessingMode.allCases[index]
        if mode == .aiVocalSeparation, !audioEngine.isNeuralSeparationAvailable {
            if let revert = ProcessingMode.allCases.firstIndex(of: preferences.processingMode) {
                setPopUpSelection(modePopUp, index: revert, action: #selector(modeChanged))
            }
            return
        }

        audioEngine.setProcessingMode(mode)
        if let actual = ProcessingMode.allCases.firstIndex(of: preferences.processingMode) {
            setPopUpSelection(modePopUp, index: actual, action: #selector(modeChanged))
        }
        refreshControlStates()
        refreshStatusHeader()
        onSettingsChanged?()
    }

    @objc private func captureScopeChanged() {
        let index = captureScopePopUp.indexOfSelectedItem
        guard index >= 0, index < CaptureScope.allCases.count else { return }

        let scope = CaptureScope.allCases[index]
        audioEngine.setCaptureScope(scope)
        if let actual = CaptureScope.allCases.firstIndex(of: preferences.captureScope) {
            setPopUpSelection(captureScopePopUp, index: actual, action: #selector(captureScopeChanged))
        }
        updateCaptureScopeUI()
        onSettingsChanged?()
    }

    @objc private func intensityChanged() {
        updateSliderOverlay()
        audioEngine.setTargetIntensity(intensitySlider.floatValue / 100)
        onSettingsChanged?()
    }

    @objc private func makeupGainChanged() {
        updateSliderOverlay()
        audioEngine.setMakeupGainDecibels(makeupSlider.floatValue)
    }

    @objc private func openPermissionSettings() {
        switch audioEngine.status {
        case .permissionRequired(.systemAudioRecording):
            AudioPermission.openSystemAudioRecordingSettings()
        default:
            AudioPermission.openMicrophoneSettings()
        }
    }

    @objc private func quit() {
        onQuit?()
    }
}
