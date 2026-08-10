import AppKit

/// Full-width Live tab content (REDESIGN.md §3) hosted directly in the desktop window's content
/// container. This used to be `SettingsPopoverViewController`, a fixed-size floating-popover-style
/// view (`NSVisualEffectView` with `.behindWindow` blending) that `MainWindowController` wrapped
/// unmodified — correct for the menu bar's own popover, wrong here, and the reason the Live tab
/// rendered as a tiny, incorrectly-blended box instead of filling the window. The menu bar now has
/// its own minimal `MenuBarPopoverViewController`, so this class is free to be a real
/// window-filling, opaque-background view at `PopoverUI.Metrics.Regular` scale, pinned to all four
/// edges of its container. The model-gating and capture-scope logic below is unchanged from the
/// popover version — it's the one place that logic lives now, not a fork of it.
final class LiveTabViewController: NSViewController {
    private let preferences: Preferences
    private let audioEngine: AudioEngine

    private let statusHeaderContainer = NSView()
    private let statusHeader = StatusHeaderView()
    private let liveToggle = NSSwitch()
    private let intensitySlider = DragValueSlider(value: 100, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let makeupSlider = DragValueSlider(value: 4.5, minValue: 0, maxValue: 12, target: nil, action: nil)
    private let sliderValueOverlay = PopoverUI.valueLabel()
    private let captureScopePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private var appChecklist: NSView?
    private let permissionButton = PopoverUI.linkButton(title: "Open Microphone Settings…")

    // REDESIGN.md §5: the Neural model is required for Live to do anything. When it isn't
    // installed, `processingBody` swaps the Intensity/Gain rows for a persistent gate + download
    // CTA — never a toggle that silently does nothing. `AudioEngine.isNeuralSeparationAvailable`
    // is the single shared source of truth also used by Practice's separation engine.
    private let processingBody = NSView()
    private var cachedProcessingRowsView: NSView?
    private var cachedModelGateView: NSView?
    private let modelGateStatusLabel = NSTextField(labelWithString: "")
    private let modelGateProgress = NSProgressIndicator()
    private let modelGateDownloadButton = NSButton(title: "", target: nil, action: nil)
    private var isDownloadingModel = false
    private var modelGateDownloadTask: Task<Void, Never>?

    private var currentStatus: AudioEngineStatus = .idle
    private var activeOverlaySlider: NSSlider?

    var onSettingsChanged: (() -> Void)?

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
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        view = root

        configureControls()
        configureContent(in: root)

        permissionButton.isHidden = true
        updateCaptureScopeUI()
        refreshStatusHeader()
        updateModelGate()
    }

    private func configureContent(in root: NSView) {
        var sections: [NSView] = [statusHeaderContainer]
        statusHeaderContainer.translatesAutoresizingMaskIntoConstraints = false

        let header = PopoverUI.sectionHeader("Processing")
        processingBody.translatesAutoresizingMaskIntoConstraints = false
        sections.append(regularSection(header: header, body: processingBody))

        sections.append(permissionButton)

        var captureSection: NSView?
        if #available(macOS 14.2, *) {
            let checklist = AppCaptureChecklistView(preferences: preferences, audioEngine: audioEngine)
            appChecklist = checklist
            let captureRows: [NSView] = [
                regularFormRow(label: "Scope", control: captureScopePopUp),
                checklist
            ]
            let section = regularSection(title: "Capture", rows: captureRows)
            captureSection = section
            sections.append(section)
        }

        let content = PopoverUI.verticalStack(sections, spacing: PopoverUI.Metrics.Regular.sectionSpacing)
        content.setCustomSpacing(12, after: statusHeaderContainer)
        content.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(content)

        let pad = PopoverUI.Metrics.Regular.padding
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: pad),
            content.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -pad),
            content.topAnchor.constraint(equalTo: root.topAnchor, constant: pad),
            content.widthAnchor.constraint(equalToConstant: 420),
            statusHeaderContainer.widthAnchor.constraint(equalTo: content.widthAnchor)
        ])

        // `content`'s stack alignment is `.leading`, so arranged subviews are only leading-pinned,
        // not stretched to its width — without an explicit width here `AppCaptureChecklistView`
        // (which has a fixed height but no intrinsic width of its own) is left horizontally
        // ambiguous, and Auto Layout resolves that ambiguity to a near-zero/garbage width that
        // renders squashed up and overlapping the row above it.
        if let captureSection {
            captureSection.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
    }

    func reloadFromPreferences() {
        guard isViewLoaded, captureScopePopUp.numberOfItems > 0 else { return }

        if let scopeIndex = CaptureScope.allCases.firstIndex(of: preferences.captureScope) {
            setPopUpSelection(captureScopePopUp, index: scopeIndex, action: #selector(captureScopeChanged))
        }

        intensitySlider.floatValue = preferences.targetIntensity * 100
        makeupSlider.floatValue = preferences.makeupGainDecibels
        updateCaptureScopeUI()
        refreshControlStates()
        updateModelGate()
        if #available(macOS 14.2, *) {
            (appChecklist as? AppCaptureChecklistView)?.reload()
        }
    }

    func updateStatusDisplay(_ status: AudioEngineStatus, isFilterActive: Bool) {
        currentStatus = status
        refreshStatusHeader(isFilterActive: isFilterActive)
        updatePermissionButton(for: status)
        setSwitchState(liveToggle, on: isFilterActive)
    }

    func updatePermissionButton(for status: AudioEngineStatus) {
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
    }

    private func configureControls() {
        liveToggle.controlSize = .large
        liveToggle.target = self
        liveToggle.action = #selector(liveToggleChanged)
        liveToggle.translatesAutoresizingMaskIntoConstraints = false

        PopoverUI.configureSlider(intensitySlider)
        intensitySlider.trackFillColor = .brandAccent
        intensitySlider.target = self
        intensitySlider.action = #selector(intensityChanged)
        intensitySlider.onDragBegan = { [weak self] in
            self?.beginSliderOverlay(for: self?.intensitySlider)
        }
        intensitySlider.onDragEnded = { [weak self] in
            self?.endSliderOverlay()
        }

        PopoverUI.configureSlider(makeupSlider)
        makeupSlider.trackFillColor = .brandAccent
        makeupSlider.target = self
        makeupSlider.action = #selector(makeupGainChanged)
        makeupSlider.onDragBegan = { [weak self] in
            self?.beginSliderOverlay(for: self?.makeupSlider)
        }
        makeupSlider.onDragEnded = { [weak self] in
            self?.endSliderOverlay()
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

    // MARK: - Regular-scale layout helpers

    private func regularSection(title: String, rows: [NSView]) -> NSView {
        regularSection(header: PopoverUI.sectionHeader(title), rows: rows)
    }

    private func regularSection(header: NSView, body: NSView) -> NSView {
        PopoverUI.verticalStack([header, body], spacing: 10)
    }

    private func regularSection(header: NSView, rows: [NSView]) -> NSView {
        let rowsStack = PopoverUI.verticalStack(rows, spacing: PopoverUI.Metrics.Regular.rowSpacing)
        let section = PopoverUI.verticalStack([header, rowsStack], spacing: 10)
        // `.leading`-aligned stacks only pin the leading edge of arranged subviews, they don't
        // stretch them — chain explicit width-equal constraints down so any row without its own
        // intrinsic width (e.g. AppCaptureChecklistView) doesn't end up horizontally ambiguous.
        rowsStack.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
        for row in rows {
            row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
        }
        return section
    }

    private func regularFormRow(label: String, control: NSView) -> NSView {
        let title = PopoverUI.fieldLabel(label)
        control.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [title, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            title.widthAnchor.constraint(equalToConstant: PopoverUI.Metrics.Regular.labelWidth),
            row.heightAnchor.constraint(equalToConstant: 24)
        ])
        return row
    }

    private func statusRow() -> NSView {
        statusHeader.translatesAutoresizingMaskIntoConstraints = false
        liveToggle.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [statusHeader, NSView(), liveToggle])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    private func refreshStatusHeader(isFilterActive: Bool? = nil) {
        let active = isFilterActive ?? audioEngine.isVocalReductionActive
        let (title, indicatorColor, errorDetail) = statusCopy(for: currentStatus, isFilterActive: active)

        if statusHeaderContainer.subviews.isEmpty {
            let row = statusRow()
            statusHeaderContainer.addSubview(row)
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: statusHeaderContainer.leadingAnchor),
                row.trailingAnchor.constraint(equalTo: statusHeaderContainer.trailingAnchor),
                row.topAnchor.constraint(equalTo: statusHeaderContainer.topAnchor),
                row.bottomAnchor.constraint(equalTo: statusHeaderContainer.bottomAnchor)
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
        case .passthrough, .idle:
            return ("Off", .tertiaryLabelColor, nil)
        default:
            return isFilterActive
                ? ("On", .brandAccentDeep, nil)
                : ("Off", .tertiaryLabelColor, nil)
        }
    }

    private func refreshControlStates() {
        // Neural is the only path now; controls are always active (model-required gating is
        // handled separately by `updateModelGate`).
        intensitySlider.isEnabled = true
        makeupSlider.isEnabled = true
        intensitySlider.alphaValue = 1
        makeupSlider.alphaValue = 1

        let processTapAvailable = audioEngine.activeCaptureBackend != .blackHole
        captureScopePopUp.isEnabled = processTapAvailable || audioEngine.activeCaptureBackend == nil
        captureScopePopUp.alphaValue = captureScopePopUp.isEnabled ? 1 : 0.45
        captureScopePopUp.toolTip = captureScopePopUp.isEnabled
            ? preferences.captureScope.detailText
            : "App selection requires Process Tap (macOS 14.2+). BlackHole captures all audio."
    }

    // MARK: - Model-required gate (REDESIGN.md §5)

    private func updateModelGate() {
        guard isViewLoaded else { return }

        let available = audioEngine.isNeuralSeparationAvailable
        let target = available ? processingRowsView() : modelRequiredView()

        if target.superview !== processingBody {
            processingBody.subviews.forEach { $0.removeFromSuperview() }
            target.translatesAutoresizingMaskIntoConstraints = false
            processingBody.addSubview(target)
            NSLayoutConstraint.activate([
                target.leadingAnchor.constraint(equalTo: processingBody.leadingAnchor),
                target.trailingAnchor.constraint(equalTo: processingBody.trailingAnchor),
                target.topAnchor.constraint(equalTo: processingBody.topAnchor),
                target.bottomAnchor.constraint(equalTo: processingBody.bottomAnchor)
            ])
        }
    }

    private func processingRowsView() -> NSView {
        if let existing = cachedProcessingRowsView { return existing }
        let view = PopoverUI.verticalStack(
            [
                regularFormRow(label: "Intensity", control: intensitySlider),
                regularFormRow(label: "Gain", control: makeupSlider)
            ],
            spacing: PopoverUI.Metrics.Regular.rowSpacing
        )
        cachedProcessingRowsView = view
        return view
    }

    private func modelRequiredView() -> NSView {
        if let existing = cachedModelGateView { return existing }

        let message = NSTextField(wrappingLabelWithString: "Vocal reduction needs the Neural model.")
        message.font = .systemFont(ofSize: NSFont.systemFontSize)
        message.textColor = .secondaryLabelColor

        modelGateDownloadButton.title = "Download Neural Model (\(SeparationModelVariant.balanced.approximateDownloadSizeText))"
        modelGateDownloadButton.bezelStyle = .rounded
        modelGateDownloadButton.target = self
        modelGateDownloadButton.action = #selector(downloadModelClicked)

        modelGateStatusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        modelGateStatusLabel.textColor = .secondaryLabelColor
        modelGateStatusLabel.isHidden = true

        modelGateProgress.style = .bar
        modelGateProgress.isIndeterminate = false
        modelGateProgress.minValue = 0
        modelGateProgress.maxValue = 1
        modelGateProgress.doubleValue = 0
        modelGateProgress.isHidden = true
        modelGateProgress.translatesAutoresizingMaskIntoConstraints = false
        modelGateProgress.heightAnchor.constraint(equalToConstant: 12).isActive = true

        let view = PopoverUI.verticalStack(
            [message, modelGateDownloadButton, modelGateStatusLabel, modelGateProgress],
            spacing: 8
        )
        cachedModelGateView = view
        return view
    }

    @objc private func downloadModelClicked() {
        guard !isDownloadingModel else { return }
        isDownloadingModel = true
        modelGateDownloadButton.isEnabled = false
        modelGateStatusLabel.isHidden = false
        modelGateStatusLabel.textColor = .secondaryLabelColor
        modelGateStatusLabel.stringValue = "Starting download…"
        modelGateProgress.isHidden = false
        modelGateProgress.doubleValue = 0

        let variant = SeparationModelVariant.balanced
        modelGateDownloadTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await ModelDownloadService.install(variant) { [weak self] fraction, message in
                    self?.modelGateProgress.doubleValue = fraction
                    self?.modelGateStatusLabel.stringValue = message
                }
                await MainActor.run {
                    self.preferences.separationModelVariant = variant
                    self.isDownloadingModel = false
                    self.modelGateDownloadTask = nil
                    self.updateModelGate()
                    self.refreshControlStates()
                    self.onSettingsChanged?()
                }
            } catch {
                await MainActor.run {
                    self.isDownloadingModel = false
                    self.modelGateDownloadTask = nil
                    self.modelGateDownloadButton.isEnabled = true
                    self.modelGateStatusLabel.textColor = .systemRed
                    self.modelGateStatusLabel.stringValue = error.localizedDescription
                    AppLogger.shared.error("Live tab model download failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func updateCaptureScopeUI() {
        let selectedApps = preferences.captureScope == .selectedApps
        if #available(macOS 14.2, *) {
            (appChecklist as? AppCaptureChecklistView)?.isEnabled = selectedApps
        }
        // REDESIGN.md §3: the checklist is Custom-only — hidden, not just dimmed, for other scopes.
        appChecklist?.isHidden = !selectedApps
        appChecklist?.alphaValue = selectedApps ? 1 : 0.45
        appChecklist?.toolTip = selectedApps
            ? "Choose which apps get vocal reduction"
            : "Set Scope to Custom first"
        captureScopePopUp.toolTip = preferences.captureScope.detailText
        if #available(macOS 14.2, *) {
            (appChecklist as? AppCaptureChecklistView)?.reload()
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

    private func setSwitchState(_ toggle: NSSwitch, on: Bool) {
        guard toggle.state != (on ? .on : .off) else { return }
        toggle.state = on ? .on : .off
    }

    @objc private func liveToggleChanged() {
        audioEngine.toggleReduction()
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
}
