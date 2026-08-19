import AppKit

/// Arm/record/stop UI for capturing system audio into Practice Mode, as a full page in the desktop
/// window rather than the 340pt `NSPopover` it used to be (`RecordingPanelController`). Recording is
/// a session — you start it, watch it, and come back to it — which a `.transient` popover actively
/// fights: any click outside dismissed the only view of a take in progress.
///
/// The recorder is owned by `AppDelegate` and shared with the menu bar, so this page neither builds
/// one nor subscribes to it: `MainWindowController` pushes `updateProgress`/`recordingStateChanged`
/// in. That keeps the recorder's single-assignment callbacks claimed in exactly one place, and
/// means the page can be entered, left and re-entered mid-recording without stealing them.
@available(macOS 14.2, *)
final class RecordPageViewController: NSViewController {
    /// Width of the page's primary actions. Full-bleed would mean a ~930pt-wide button; this is
    /// wide enough to read as the page's main CTA without becoming a banner.
    private static let actionWidth: CGFloat = 260

    private let recorder: ClipRecorder
    private let preferences: Preferences
    private let onFinished: (URL) -> Void

    // Idle state
    private let modeTag = StatusTagView(text: "NOT RECORDING", color: .systemRed)
    private let sourceDot = DotView(color: .secondaryLabelColor)
    private let sourcePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let sourceStatusLabel = NSTextField(labelWithString: "")
    /// Input devices in the order they were put into `sourcePopUp`, so a selected index maps back
    /// to a device without parsing the menu item's title.
    private var sourceDevices: [AudioDevice] = []
    private let settingsButton = FlatButton(title: "Open System Settings…", kind: .secondary)
    private let autoStopToggle = ToggleSwitchView()
    private let minutesField = RecordPageViewController.makeTimeField()
    private let secondsField = RecordPageViewController.makeTimeField()
    private let armButton = FlatButton(title: "●  Start recording", kind: .primary)
    private let idleTitleLabel = NSTextField(labelWithString: "Record system audio")
    private let idleSubtitleLabel = NSTextField(labelWithString: "")

    // Recording state
    private let recDot = DotView(color: .brandAccentDeep)
    private let elapsedLabel = NSTextField(labelWithString: "0:00")
    private let liveWaveform = LiveWaveformView()
    private let elapsedMetaLabel = NSTextField(labelWithString: "elapsed 0:00")
    private let targetMetaLabel = NSTextField(labelWithString: "auto-stop off")
    private let stopButton = FlatButton(title: "■  Stop now", kind: .secondary)

    /// The two states are built once and swapped through this container, rather than being kept as
    /// hidden siblings the way the popover did it. At popover scale a hidden sibling cost nothing;
    /// at page scale each state wants to fill the window, so leaving both installed means two sets
    /// of fill constraints on one container. This is the same swap `LiveTabViewController` uses for
    /// its model gate.
    private let stateContainer = AutoLayoutView()
    private var cachedIdleView: NSView?
    private var cachedRecordingView: NSView?

    private var autoStopEnabled = false
    private var autoStopSeconds: Double?

    init(recorder: ClipRecorder, preferences: Preferences, onFinished: @escaping (URL) -> Void) {
        self.recorder = recorder
        self.preferences = preferences
        self.onFinished = onFinished
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = ThemedView(fill: .windowBackgroundColor)
        view = root

        let pad = WindowUI.Metrics.padding
        Layout.pin(stateContainer, to: root, insets: NSEdgeInsets(top: pad, left: pad, bottom: pad, right: pad))

        // Same breakable width preference the Live tab carries, for the same measured reason: AppKit
        // refits the window to the installed content's intrinsic width, and without this the page's
        // own content (a 260pt button and a card of small labels) collapses the window.
        preferredSize(root.widthAnchor, 980).isActive = true

        refreshState(recording: recorder.isRecording)
    }

    /// Input devices come and go while the app is running, and the page is re-entered rather than
    /// rebuilt, so the menu is refreshed on every appearance rather than only at build time.
    override func viewWillAppear() {
        super.viewWillAppear()
        guard !recorder.isRecording, cachedIdleView != nil else { return }
        reloadSourceMenu()
        updateIdleCopy()
    }

    // MARK: - State

    /// Called by `MainWindowController` when the shared recorder starts or stops, whichever surface
    /// triggered it — including the menu bar's Record toggle while this page is open.
    func recordingStateChanged(_ recording: Bool) {
        guard isViewLoaded else { return }
        refreshState(recording: recording)
    }

    /// Takes the state as an argument rather than re-reading `recorder.isRecording`, so there is one
    /// source of truth per transition — the value the recorder published — instead of a pushed
    /// signal and an independent read that can disagree.
    private func refreshState(recording: Bool) {
        let next = recording ? recordingView() : idleView()
        guard next.superview !== stateContainer else { return }

        stateContainer.subviews.forEach { $0.removeFromSuperview() }
        Layout.pin(next, to: stateContainer)

        if recording {
            updateProgress(peaks: [], elapsed: recorder.elapsedSeconds())
        }
    }

    /// Fed by `MainWindowController` off the shared recorder's ~10Hz progress callback.
    func updateProgress(peaks: [Float], elapsed: Double) {
        guard isViewLoaded else { return }
        if !peaks.isEmpty {
            liveWaveform.peaks = peaks
        }
        liveWaveform.elapsedSeconds = elapsed
        let text = elapsed.formattedAsDuration
        elapsedLabel.stringValue = text
        elapsedMetaLabel.stringValue = "elapsed \(text)"
    }

    // MARK: - Idle state UI

    private func idleView() -> NSView {
        if let cachedIdleView { return cachedIdleView }

        idleTitleLabel.font = .systemFont(ofSize: 22, weight: .black)
        idleTitleLabel.textColor = .labelColor
        idleSubtitleLabel.font = .systemFont(ofSize: 13)
        idleSubtitleLabel.textColor = .secondaryLabelColor

        let titles = Layout.verticalStack([idleTitleLabel, idleSubtitleLabel], spacing: 4)
        let header = Layout.horizontalStack([titles, Layout.flexibleSpacer(), modeTag], spacing: 8)

        armButton.target = self
        armButton.action = #selector(armClicked)
        armButton.constrainSize(width: Self.actionWidth, height: 44)

        let heroBody = Layout.verticalStack([header, armButton], spacing: WindowUI.Metrics.sectionSpacing)
        heroBody.setCustomSpacing(WindowUI.Metrics.padding, after: header)
        header.widthAnchor.constraint(equalTo: heroBody.widthAnchor).isActive = true
        let heroCard = WindowUI.card(content: heroBody)

        // Same grid as the Live tab: a hero that absorbs the window's slack, and two equal cards
        // beneath it. The first cut of this page stacked full-width rows instead, which is the
        // popover's own layout at 3× the width — a 900pt-wide "Input source" bar with its label and
        // its status dot at opposite ends of the window, and 250pt of dead space below everything.
        let bottomCards = [sourceCard(), WindowUI.card(title: "Auto-stop", rows: autoStopRows())]
        let bottomRow = NSStackView(views: bottomCards)
        bottomRow.orientation = .horizontal
        bottomRow.alignment = .top
        bottomRow.distribution = .fill
        bottomRow.spacing = WindowUI.Metrics.cardSpacing
        bottomRow.translatesAutoresizingMaskIntoConstraints = false
        bottomRow.setContentHuggingPriority(.defaultHigh, for: .vertical)
        // Explicit equal width/height rather than `.fillEqually` — see the same constraint in
        // `LiveTabViewController`, where the distribution measurably lost to intrinsic widths.
        if let first = bottomCards.first {
            for card in bottomCards.dropFirst() {
                card.widthAnchor.constraint(equalTo: first.widthAnchor).isActive = true
                card.heightAnchor.constraint(equalTo: first.heightAnchor).isActive = true
            }
        }

        let content = Layout.verticalStack([heroCard, bottomRow], spacing: WindowUI.Metrics.cardSpacing)
        NSLayoutConstraint.activate([
            heroCard.widthAnchor.constraint(equalTo: content.widthAnchor),
            bottomRow.widthAnchor.constraint(equalTo: content.widthAnchor)
        ])

        // Centered rather than stretched. There genuinely isn't a window's worth of content in
        // "press this to start" — stretching the hero to fill 640pt leaves a ~250pt hole between
        // the title and the CTA, which reads as a layout accident. A short composition centered in
        // the page reads as deliberate. The recording state, which has a waveform worth the space,
        // does fill.
        let wrapper = AutoLayoutView()
        wrapper.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
            content.centerYAnchor.constraint(equalTo: wrapper.centerYAnchor),
            content.topAnchor.constraint(greaterThanOrEqualTo: wrapper.topAnchor)
        ])

        updateIdleCopy()
        cachedIdleView = wrapper
        return wrapper
    }

    private func sourceCard() -> NSView {
        sourceDot.constrainSize(width: 7, height: 7)
        sourceStatusLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        sourceStatusLabel.textColor = .secondaryLabelColor
        sourceStatusLabel.lineBreakMode = .byWordWrapping
        sourceStatusLabel.maximumNumberOfLines = 2

        WindowUI.configurePopUp(sourcePopUp)
        sourcePopUp.target = self
        sourcePopUp.action = #selector(sourceChanged)
        reloadSourceMenu()

        settingsButton.target = self
        settingsButton.action = #selector(openSettingsClicked)
        settingsButton.isHidden = true

        let status = Layout.horizontalStack([sourceDot, sourceStatusLabel, Layout.flexibleSpacer()], spacing: 8)
        return WindowUI.card(title: "Input source", rows: [sourcePopUp, status, settingsButton])
    }

    /// Rebuilds the picker from the devices present *now*. Called on every appearance rather than
    /// once at build time, because mics get plugged in and unplugged while the app is running and a
    /// stale menu would offer a device that no longer exists.
    private func reloadSourceMenu() {
        sourceDevices = CoreAudioDevices.inputDevices()
        sourcePopUp.removeAllItems()
        sourcePopUp.addItem(withTitle: "System audio")
        for device in sourceDevices {
            sourcePopUp.addItem(withTitle: device.name)
        }

        let selected = preferences.recordingSource
        var index = 0
        if case .inputDevice(let uid) = selected {
            if let position = sourceDevices.firstIndex(where: { $0.uid == uid }) {
                index = position + 1
            } else {
                // The saved device is gone. Fall back to system audio rather than leaving a
                // selection pointing at nothing — and persist it, so the next launch doesn't
                // resurrect a device that isn't there.
                preferences.recordingSource = .systemAudio
            }
        }
        sourcePopUp.selectItem(at: index)
        updateSourceStatus()
    }

    /// One line describing what the current selection will actually record, plus the dot's color.
    /// Deliberately not a permission *check* — macOS only reports microphone authorization once
    /// asked, and prompting on mere selection would be a prompt the user didn't ask for. The real
    /// gate is in `ClipRecorder.startRecording`, on the Start button.
    private func updateSourceStatus() {
        let source = preferences.recordingSource
        sourceDot.color = .secondaryLabelColor
        sourceStatusLabel.textColor = .secondaryLabelColor
        sourceStatusLabel.toolTip = nil
        settingsButton.isHidden = true

        switch source {
        case .systemAudio:
            sourceStatusLabel.stringValue = "Records whatever your Mac is playing."
        case .inputDevice:
            if AudioPermission.isMicrophoneDenied {
                sourceDot.color = .systemRed
                sourceStatusLabel.textColor = .systemRed
                sourceStatusLabel.stringValue = "Microphone access is denied."
                settingsButton.isHidden = false
            } else {
                sourceStatusLabel.stringValue = "Records this input directly, not your Mac's output."
            }
        }
    }

    @objc private func sourceChanged() {
        let index = sourcePopUp.indexOfSelectedItem
        if index <= 0 {
            preferences.recordingSource = .systemAudio
        } else if sourceDevices.indices.contains(index - 1) {
            preferences.recordingSource = .inputDevice(uid: sourceDevices[index - 1].uid)
        }
        updateSourceStatus()
        updateIdleCopy()
    }

    /// Keeps the hero's title/subtitle honest about the selected source — "Record system audio"
    /// over a mic selection would be plainly wrong.
    private func updateIdleCopy() {
        let source = preferences.recordingSource
        switch source {
        case .systemAudio:
            idleTitleLabel.stringValue = "Record system audio"
            idleSubtitleLabel.stringValue = "Captured system audio lands in your Practice library."
        case .inputDevice:
            idleTitleLabel.stringValue = "Record \(source.displayName)"
            idleSubtitleLabel.stringValue = "Captured input lands in your Practice library."
        }
    }

    private func autoStopRows() -> [NSView] {
        let timerLabel = NSTextField(labelWithString: "Stop automatically")
        timerLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        timerLabel.textColor = .labelColor
        let timerSub = NSTextField(labelWithString: "Recording stops and processing begins on its own.")
        timerSub.font = .systemFont(ofSize: 11)
        timerSub.textColor = .secondaryLabelColor
        let timerTitles = Layout.verticalStack([timerLabel, timerSub], spacing: 2)

        autoStopToggle.translatesAutoresizingMaskIntoConstraints = false
        autoStopToggle.onToggle = { [weak self] isOn in self?.autoStopToggleChanged(isOn) }
        let toggleRow = Layout.horizontalStack([timerTitles, Layout.flexibleSpacer(), autoStopToggle], spacing: 8)

        let colon = NSTextField(labelWithString: ":")
        colon.font = .monospacedDigitSystemFont(ofSize: 14, weight: .regular)
        colon.textColor = .secondaryLabelColor
        let unit = NSTextField(labelWithString: "min : sec")
        unit.font = .systemFont(ofSize: 11)
        unit.textColor = .secondaryLabelColor
        minutesField.target = self
        minutesField.action = #selector(timeFieldChanged)
        secondsField.target = self
        secondsField.action = #selector(timeFieldChanged)
        let timeRow = Layout.horizontalStack(
            [minutesField, colon, secondsField, unit, Layout.flexibleSpacer()],
            spacing: 8
        )

        return [toggleRow, timeRow]
    }

    // MARK: - Recording state UI

    private func recordingView() -> NSView {
        if let cachedRecordingView { return cachedRecordingView }

        recDot.constrainSize(width: 10, height: 10)
        recDot.startPulsing()
        let recLabel = NSTextField(labelWithString: "RECORDING")
        recLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        recLabel.textColor = .brandAccentDeep
        let recIndicator = Layout.horizontalStack([recDot, recLabel], spacing: 8)

        // 44pt where the popover used 20: at page scale this is the one number you glance at from
        // across the room, the same role the Live tab gives its status header.
        elapsedLabel.font = .monospacedDigitSystemFont(ofSize: 44, weight: .medium)
        elapsedLabel.textColor = .labelColor

        let recHead = Layout.horizontalStack([recIndicator, Layout.flexibleSpacer(), elapsedLabel], spacing: 8)

        liveWaveform.translatesAutoresizingMaskIntoConstraints = false
        liveWaveform.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        // Near-zero vertical hugging so the waveform, not empty card padding, takes the window's
        // slack — the trick `LiveTabViewController` uses for its level meter.
        liveWaveform.setContentHuggingPriority(.init(1), for: .vertical)
        liveWaveform.onDragAutoStop = { [weak self] seconds in
            self?.setAutoStop(seconds: seconds)
        }

        elapsedMetaLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        elapsedMetaLabel.textColor = .secondaryLabelColor
        targetMetaLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        targetMetaLabel.textColor = .brandAccentDeep
        let metaRow = Layout.horizontalStack([elapsedMetaLabel, Layout.flexibleSpacer(), targetMetaLabel], spacing: 8)

        let heroBody = Layout.verticalStack([recHead, liveWaveform, metaRow], spacing: WindowUI.Metrics.rowSpacing)
        for row in [recHead, liveWaveform, metaRow] as [NSView] {
            row.widthAnchor.constraint(equalTo: heroBody.widthAnchor).isActive = true
        }
        let heroCard = WindowUI.card(content: heroBody)
        heroCard.setContentHuggingPriority(.init(1), for: .vertical)

        stopButton.target = self
        stopButton.action = #selector(stopClicked)
        stopButton.constrainSize(width: Self.actionWidth, height: 40)

        let content = Layout.verticalStack([heroCard, stopButton], spacing: WindowUI.Metrics.cardSpacing)
        heroCard.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true

        cachedRecordingView = content
        return content
    }

    // MARK: - Actions

    @objc private func armClicked() {
        armButton.isEnabled = false
        recorder.startRecording(source: preferences.recordingSource) { [weak self] result in
            guard let self else { return }
            self.armButton.isEnabled = true
            switch result {
            case .success:
                self.settingsButton.isHidden = true
                self.liveWaveform.autoStopSeconds = self.autoStopSeconds
                if let autoStopSeconds = self.autoStopSeconds {
                    self.recorder.setAutoStop(seconds: autoStopSeconds) { [weak self] in self?.finishRecording() }
                }
                // `refreshState()` has already run off the recorder's state callback by now.
                self.updateProgress(peaks: [], elapsed: self.recorder.elapsedSeconds())
            case .failure(let error):
                self.showError(error)
            }
        }
    }

    @objc private func stopClicked() {
        finishRecording()
    }

    private func finishRecording() {
        guard let url = recorder.stopRecording() else {
            refreshState(recording: recorder.isRecording)
            return
        }
        onFinished(url)
    }

    @objc private func autoStopToggleChanged(_ isOn: Bool) {
        autoStopEnabled = isOn
        minutesField.isEnabled = isOn
        secondsField.isEnabled = isOn
        minutesField.textColor = isOn ? .labelColor : .secondaryLabelColor
        secondsField.textColor = isOn ? .labelColor : .secondaryLabelColor
        timeFieldChanged()
    }

    @objc private func timeFieldChanged() {
        guard autoStopEnabled else {
            setAutoStop(seconds: nil)
            return
        }
        let minutes = Int(minutesField.stringValue) ?? 0
        let seconds = Int(secondsField.stringValue) ?? 0
        let total = Double(minutes * 60 + seconds)
        setAutoStop(seconds: total > 0 ? total : nil)
    }

    private func setAutoStop(seconds: Double?) {
        autoStopSeconds = seconds
        liveWaveform.autoStopSeconds = seconds
        if let seconds {
            let total = Int(seconds.rounded())
            minutesField.stringValue = String(format: "%02d", total / 60)
            secondsField.stringValue = String(format: "%02d", total % 60)
            targetMetaLabel.stringValue = "auto-stop at \(seconds.formattedAsDuration)"
        } else {
            targetMetaLabel.stringValue = "auto-stop off"
        }
        recorder.setAutoStop(seconds: seconds) { [weak self] in self?.finishRecording() }
    }

    private func showError(_ error: Error) {
        let isMicDenial = (error as? ClipRecorder.RecorderError)?.isMicrophonePermissionIssue ?? false
        let isTapDenial = (error as? AudioEngineError)?.isLikelyPermissionDenied ?? false
        sourceDot.color = .systemRed
        sourceStatusLabel.textColor = .systemRed
        // The recorder's own errors already name the device and say what went wrong; only the
        // CoreAudio-level ones need a generic stand-in.
        sourceStatusLabel.stringValue = error.localizedDescription
        sourceStatusLabel.toolTip = error.localizedDescription
        settingsButton.isHidden = !(isMicDenial || isTapDenial)
    }

    /// Which System Settings pane to open depends on what was actually denied — sending someone to
    /// System Audio Recording when it's the microphone that's blocked is a dead end.
    @objc private func openSettingsClicked() {
        if preferences.recordingSource.isMicrophone {
            AudioPermission.openMicrophoneSettings()
        } else {
            AudioPermission.openSystemAudioRecordingSettings()
        }
    }

    // MARK: - Layout helpers

    /// Breakable size preference — see `LiveTabViewController.preferredSize` for why priority 800
    /// specifically (above the content hugging of the controls inside, below required so the window
    /// stays resizable).
    private func preferredSize(_ anchor: NSLayoutDimension, _ constant: CGFloat) -> NSLayoutConstraint {
        let constraint = anchor.constraint(equalToConstant: constant)
        constraint.priority = NSLayoutConstraint.Priority(800)
        return constraint
    }

    private static func makeTimeField() -> NSTextField {
        let field = DividerBorderedTextField(string: "00")
        field.font = .monospacedDigitSystemFont(ofSize: 14, weight: .regular)
        field.textColor = .secondaryLabelColor
        field.alignment = .center
        field.isBordered = false
        field.drawsBackground = true
        field.backgroundColor = .windowBackgroundColor
        field.isEnabled = false
        field.constrainSize(width: 44, height: 26)
        return field
    }
}

/// `NSTextField` with a `flatDivider` layer border. A subclass only because layer borders are
/// frozen `CGColor`s: a plain `field.layer?.borderColor = …` at build time keeps the appearance it
/// was built under forever.
final class DividerBorderedTextField: NSTextField {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.borderWidth = 1
        applyBorderColor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyBorderColor()
    }

    private func applyBorderColor() {
        resolvingEffectiveAppearance {
            layer?.borderColor = NSColor.flatDivider.cgColor
        }
    }
}

/// Small filled circle — used for the permission-status dot and the pulsing recording dot.
final class DotView: NSView {
    var color: NSColor {
        didSet { applyColor() }
    }

    init(color: NSColor) {
        self.color = color
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 3
        applyColor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColor()
    }

    private func applyColor() {
        resolvingEffectiveAppearance {
            layer?.backgroundColor = color.cgColor
        }
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }

    func startPulsing() {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 1.0
        animation.toValue = 0.35
        animation.duration = 0.7
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer?.add(animation, forKey: "pulse")
    }
}

/// Small bordered status pill — the "Not recording" mode tag. Flat (zero corner radius) to match
/// the rest of the window's chrome instead of `RecordingTheme`'s retired rounded-pill look.
final class StatusTagView: NSTextField {
    private let tagColor: NSColor

    init(text: String, color: NSColor) {
        tagColor = color
        super.init(frame: .zero)
        stringValue = text
        isEditable = false
        isBordered = false
        drawsBackground = false
        alignment = .center
        font = .systemFont(ofSize: 10, weight: .semibold)
        textColor = color
        wantsLayer = true
        layer?.borderWidth = 1
        translatesAutoresizingMaskIntoConstraints = false
        applyBorderColor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// `textColor` holds the `NSColor` and re-resolves itself; the border is a frozen `CGColor` in
    /// a layer and doesn't.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyBorderColor()
    }

    private func applyBorderColor() {
        resolvingEffectiveAppearance {
            layer?.borderColor = tagColor.withAlphaComponent(0.4).cgColor
        }
    }
}
