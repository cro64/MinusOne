import AppKit

/// Full-width Live tab content (REDESIGN.md §3) hosted directly in the desktop window's content
/// container. This used to be `SettingsPopoverViewController`, a fixed-size floating-popover-style
/// view (`NSVisualEffectView` with `.behindWindow` blending) that `MainWindowController` wrapped
/// unmodified — correct for the menu bar's own popover, wrong here, and the reason the Live tab
/// rendered as a tiny, incorrectly-blended box instead of filling the window. The menu bar now has
/// its own minimal `MenuBarPopoverViewController`, so this class is free to be a real
/// window-filling, opaque-background view at `WindowUI.Metrics` scale, pinned to all four
/// edges of its container. The model-gating and capture-scope logic below is unchanged from the
/// popover version — it's the one place that logic lives now, not a fork of it.
final class LiveTabViewController: NSViewController {
    private let preferences: Preferences
    private let audioEngine: AudioEngine

    private let statusHeaderContainer = NSView()
    private let statusHeader = StatusHeaderView(scale: .hero)
    private let liveToggle = NSSwitch()
    private let levelMeter = LiveLevelMeterView()
    private let outputSummaryLabel = NSTextField(labelWithString: "")
    private var meterTimer: Timer?
    private let intensitySlider = DragValueSlider(value: 100, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let makeupSlider = DragValueSlider(value: 4.5, minValue: 0, maxValue: 12, target: nil, action: nil)
    private let sliderValueOverlay = SharedUI.valueLabel()
    private let captureScopePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private var appChecklist: NSView?
    private let permissionButton = WindowUI.linkButton(title: "Open Microphone Settings…")

    // REDESIGN.md §5: the Neural model is required for Live to do anything. When it isn't
    // installed, `processingBody` swaps the Intensity/Gain rows for a persistent gate + download
    // CTA — never a toggle that silently does nothing. `AudioEngine.isNeuralSeparationAvailable`
    // is the single shared source of truth also used by Practice's separation engine.
    private let processingBody = NSView()
    private var cachedProcessingRowsView: NSView?
    private var cachedModelGateView: NSView?
    private let modelGateStatusLabel = NSTextField(labelWithString: "")
    private let modelGateProgress = NSProgressIndicator()
    private let modelGateDownloadButton = FlatButton(title: "", kind: .primary)
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
        let root = ThemedView(fill: .windowBackgroundColor)
        view = root

        configureControls()
        configureContent(in: root)

        permissionButton.isHidden = true
        updateCaptureScopeUI()
        refreshStatusHeader()
        updateModelGate()
        updateOutputSummary()

        audioEngine.onOutputConfigurationChanged = { [weak self] in
            self?.updateOutputSummary()
        }
    }

    // MARK: - Live meter

    override func viewWillAppear() {
        super.viewWillAppear()
        startMeter()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        stopMeter()
    }

    /// Polls `AudioEngine.liveLevels` while the Live tab is on screen. Deliberately driven from the
    /// view and not from the engine, so nothing ticks while Practice is showing or the window is
    /// closed. `.common` run loop mode keeps the meter moving during slider drags and menu tracking.
    private func startMeter() {
        guard meterTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 25.0, repeats: true) { [weak self] _ in
            self?.tickMeter()
        }
        RunLoop.main.add(timer, forMode: .common)
        meterTimer = timer
    }

    private func stopMeter() {
        meterTimer?.invalidate()
        meterTimer = nil
    }

    private func tickMeter() {
        levelMeter.append(levels: audioEngine.liveLevels)
        levelMeter.caption = meterCaption()
    }

    /// `nil` once there's a signal worth showing — the meter draws its legend instead. The card
    /// should never read as an empty box, so every non-running state names itself here.
    private func meterCaption() -> String? {
        switch currentStatus {
        case .error:
            return "Reduction stopped"
        case .permissionRequired:
            return "Permission needed to capture audio"
        case .warmingUp:
            return "Warming up…"
        case .active where audioEngine.isVocalReductionActive:
            return nil
        default:
            return "Turn Live on to see vocals being removed"
        }
    }

    private func updateOutputSummary() {
        guard isViewLoaded else { return }
        guard let device = audioEngine.activeOutputDevice else {
            outputSummaryLabel.stringValue = "No output device"
            return
        }
        let kilohertz = audioEngine.sampleRate / 1000
        let rateText = kilohertz == kilohertz.rounded()
            ? String(format: "%.0f kHz", kilohertz)
            : String(format: "%.1f kHz", kilohertz)
        outputSummaryLabel.stringValue = "\(device.name) · \(rateText)"
    }

    /// A card grid, not the old fixed-width column. The previous layout centered a hard 640pt stack
    /// of ~300pt-tall content in a 980×640 window, so most of the window was empty — the
    /// information architecture had never moved past the menu bar popover it was lifted from. Now:
    /// a full-width status/meter hero on top (which absorbs the vertical slack), and Processing +
    /// Capture side by side beneath it, so the window's real width does work.
    private func configureContent(in root: NSView) {
        let heroCard = WindowUI.card(content: heroContent())

        let header = SharedUI.sectionHeader("Processing")
        processingBody.translatesAutoresizingMaskIntoConstraints = false
        let processingCard = WindowUI.card(header: header, body: processingBody)

        var bottomCards: [NSView] = [processingCard]

        if #available(macOS 14.2, *) {
            let checklist = AppCaptureChecklistView(preferences: preferences, audioEngine: audioEngine)
            appChecklist = checklist
            let captureRows: [NSView] = [
                WindowUI.formRow(label: "Scope", control: captureScopePopUp),
                checklist
            ]
            bottomCards.append(WindowUI.card(title: "Capture", rows: captureRows))
        }


        let bottomRow = NSStackView(views: bottomCards)
        bottomRow.orientation = .horizontal
        bottomRow.alignment = .top
        bottomRow.distribution = .fill
        bottomRow.spacing = WindowUI.Metrics.cardSpacing
        bottomRow.translatesAutoresizingMaskIntoConstraints = false
        // Explicit equal widths rather than `.fillEqually`: measured on the real window, the
        // distribution lost to the intrinsic widths inside the cards and produced a ~2.5:1 split.
        // Equal *heights* too, so the row reads as one band of cards rather than two boxes of
        // different sizes — whichever card's content is tallest sets the height, and the other
        // pads out to match. (`.top` alignment alone only aligned their top edges.)
        if let first = bottomCards.first {
            for card in bottomCards.dropFirst() {
                card.widthAnchor.constraint(equalTo: first.widthAnchor).isActive = true
                card.heightAnchor.constraint(equalTo: first.heightAnchor).isActive = true
            }
        }

        let content = Layout.verticalStack([heroCard, permissionButton, bottomRow], spacing: WindowUI.Metrics.cardSpacing)

        let pad = WindowUI.Metrics.padding
        Layout.pin(content, to: root, insets: NSEdgeInsets(top: pad, left: pad, bottom: pad, right: pad))

        NSLayoutConstraint.activate([
            // Same `.leading`-stacks-don't-stretch-their-children story as `WindowUI.section`: the
            // cards have to be chained to the stack's width explicitly or they collapse toward
            // their intrinsic size instead of tracking the window. (`permissionButton` is left
            // unchained on purpose — it's a link button that should hug its title.)
            heroCard.widthAnchor.constraint(equalTo: content.widthAnchor),
            bottomRow.widthAnchor.constraint(equalTo: content.widthAnchor),
            // The hero takes the slack: the bottom cards hug their content, and everything left
            // over goes to the meter rather than to empty space below the form.
            heroCard.heightAnchor.constraint(greaterThanOrEqualToConstant: 220),
            // ...but not *all* of it. Capture's content collapses to 78pt outright when the
            // checklist is hidden for the All Apps scope, and with the hero hugging at priority 1
            // there's nothing else stopping the row from being squashed. Deliberately below
            // Processing's own ~110pt fitting height (measured) so it acts purely as a backstop:
            // Processing is what sets this row's height, and Capture follows it.
            bottomRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 96),
            // AppKit re-fits the window to this view's fitting size shortly after the tab is
            // installed. Without this, the cards' own intrinsic width wins and the window collapses
            // to 572pt the moment Live appears (measured) — the card grid has no fixed width of its
            // own, which is the point. Breakable rather than required so the window stays
            // resizable; `MainWindowController.minSize` remains the hard floor. Width only: height
            // needs no equivalent, because `heroCard`'s near-zero vertical hugging already means
            // the content exerts no upward pressure on the window's height.
            preferredSize(root.widthAnchor, 980)
        ])
        heroCard.setContentHuggingPriority(.init(1), for: .vertical)
        bottomRow.setContentHuggingPriority(.defaultHigh, for: .vertical)
    }

    /// Breakable size preference. Priority 800 is deliberate: above the 750 content-hugging of the
    /// Scope popup and friends (measured — at 250 or 600 that hugging wins and the window settles
    /// at its floor instead of its design size), and below required, so resizing still works.
    private func preferredSize(_ anchor: NSLayoutDimension, _ constant: CGFloat) -> NSLayoutConstraint {
        let constraint = anchor.constraint(equalToConstant: constant)
        constraint.priority = NSLayoutConstraint.Priority(800)
        return constraint
    }

    /// Status + toggle + output summary + the live before/after meter.
    private func heroContent() -> NSView {
        statusHeaderContainer.translatesAutoresizingMaskIntoConstraints = false

        outputSummaryLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        outputSummaryLabel.textColor = .secondaryLabelColor
        outputSummaryLabel.translatesAutoresizingMaskIntoConstraints = false

        levelMeter.translatesAutoresizingMaskIntoConstraints = false
        levelMeter.setContentHuggingPriority(.init(1), for: .vertical)
        levelMeter.heightAnchor.constraint(greaterThanOrEqualToConstant: 96).isActive = true

        let stack = Layout.verticalStack(
            [statusHeaderContainer, outputSummaryLabel, levelMeter],
            spacing: WindowUI.Metrics.rowSpacing
        )
        stack.setCustomSpacing(WindowUI.Metrics.sectionSpacing, after: outputSummaryLabel)
        for row in [statusHeaderContainer, outputSummaryLabel, levelMeter] as [NSView] {
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    func reloadFromPreferences() {
        guard isViewLoaded, captureScopePopUp.numberOfItems > 0 else { return }

        if let scopeIndex = CaptureScope.allCases.firstIndex(of: preferences.captureScope) {
            setPopUpSelection(captureScopePopUp, index: scopeIndex)
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
        // Previously missing: if the engine falls back from Process Tap to BlackHole while this tab
        // is already visible, the Scope popup stayed enabled with a stale tooltip until the tab was
        // re-shown, because `refreshControlStates` only ran from `reloadFromPreferences`.
        refreshControlStates()
        updateOutputSummary()
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

        WindowUI.configureSlider(intensitySlider)
        intensitySlider.trackFillColor = .brandAccent
        intensitySlider.target = self
        intensitySlider.action = #selector(intensityChanged)
        intensitySlider.onDragBegan = { [weak self] in
            self?.beginSliderOverlay(for: self?.intensitySlider)
        }
        intensitySlider.onDragEnded = { [weak self] in
            self?.endSliderOverlay()
        }

        WindowUI.configureSlider(makeupSlider)
        makeupSlider.trackFillColor = .brandAccent
        makeupSlider.target = self
        makeupSlider.action = #selector(makeupGainChanged)
        makeupSlider.onDragBegan = { [weak self] in
            self?.beginSliderOverlay(for: self?.makeupSlider)
        }
        makeupSlider.onDragEnded = { [weak self] in
            self?.endSliderOverlay()
        }

        WindowUI.configurePopUp(captureScopePopUp)
        captureScopePopUp.target = self
        captureScopePopUp.action = #selector(captureScopeChanged)
        for scope in CaptureScope.allCases {
            captureScopePopUp.addItem(withTitle: scope.displayName)
        }

        permissionButton.target = self
        permissionButton.action = #selector(openPermissionSettings)

    }

    // MARK: - Regular-scale layout helpers

    private func statusRow() -> NSView {
        statusHeader.translatesAutoresizingMaskIntoConstraints = false
        liveToggle.translatesAutoresizingMaskIntoConstraints = false

        // `flexibleSpacer`, not a bare `NSView`: the container now stretches with the window, so the
        // slack has to land in the middle (pushing the toggle to the trailing edge) rather than
        // being distributed across a spacer with default hugging.
        let row = Layout.horizontalStack(
            [statusHeader, Layout.flexibleSpacer(), liveToggle],
            spacing: WindowUI.Metrics.rowSpacing
        )
        row.distribution = .fill
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
        let intensityRow = WindowUI.formRow(label: "Intensity", control: intensitySlider)
        let gainRow = WindowUI.formRow(label: "Gain", control: makeupSlider)
        let view = Layout.verticalStack([intensityRow, gainRow], spacing: WindowUI.Metrics.rowSpacing)
        // Same "`.leading` stacks don't stretch their children" story as `WindowUI.section` —
        // without this the rows (and the sliders inside them) sit at their own minimum width
        // instead of stretching to fill this stack's actual width.
        intensityRow.widthAnchor.constraint(equalTo: view.widthAnchor).isActive = true
        gainRow.widthAnchor.constraint(equalTo: view.widthAnchor).isActive = true
        cachedProcessingRowsView = view
        return view
    }

    private func modelRequiredView() -> NSView {
        if let existing = cachedModelGateView { return existing }

        let message = NSTextField(wrappingLabelWithString: "Vocal reduction needs the Neural model.")
        message.font = .systemFont(ofSize: NSFont.systemFontSize)
        message.textColor = .secondaryLabelColor

        modelGateDownloadButton.title = "Download Neural Model (\(SeparationModelVariant.balanced.approximateDownloadSizeText))"
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

        let view = Layout.verticalStack(
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

    private func setPopUpSelection(_ popUp: NSPopUpButton, index: Int) {
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
            setPopUpSelection(captureScopePopUp, index: actual)
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
