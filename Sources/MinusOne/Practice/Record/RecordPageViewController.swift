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
///
/// Composed as a single centered "stage" rather than a settings-style grid of bordered cards: the
/// source picker is one dropdown chip (not an "Input source" card — a row of pills would've broken
/// down past two or three devices), auto-stop is one compact toggle+time chip, and start/stop share
/// one circular transport control instead of a wide rectangular CTA that becomes a different button
/// once recording starts.
@available(macOS 14.2, *)
final class RecordPageViewController: NSViewController {
    /// Diameter of the circular transport control — the one button that means "start" idle and
    /// "stop" while recording, so both states read as the same control rather than two.
    private static let transportDiameter: CGFloat = 88

    private let recorder: ClipRecorder
    private let preferences: Preferences
    private let onFinished: (URL) -> Void

    // Idle state
    private let sourceChipButton = FlatButton(title: "", kind: .secondary)
    private let sourceDot = DotView(color: .secondaryLabelColor)
    private let sourceStatusLabel = NSTextField(labelWithString: "")
    /// The dot + status line, kept as a property so the whole row can be hidden. It carries only
    /// problems (a denied mic, a failed start), so most of the time there is nothing to show.
    private var sourceStatusRow: NSView?
    /// Input devices in the order they're offered in the source menu, so a selected item maps back
    /// to a device without parsing its title.
    private var sourceDevices: [AudioDevice] = []
    private let settingsButton = FlatButton(title: "Open System Settings…", kind: .secondary)
    private let autoStopToggle = ToggleSwitchView()
    private let minutesField = RecordPageViewController.makeTimeField()
    private let secondsField = RecordPageViewController.makeTimeField()
    private let armButton = FlatButton(title: "", kind: .primary)
    private let idleTitleLabel = NSTextField(labelWithString: "Record system audio")
    private let idleSubtitleLabel = NSTextField(labelWithString: "")

    // Recording state
    private let recDot = DotView(color: .brandAccentDeep)
    private let elapsedLabel = NSTextField(labelWithString: "0:00")
    private let liveWaveform = LiveWaveformView()
    private let elapsedMetaLabel = NSTextField(labelWithString: "elapsed 0:00")
    private let targetMetaLabel = NSTextField(labelWithString: "auto-stop off")
    private let stopButton = FlatButton(title: "", kind: .primary)

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
        // own content (a centered column of small controls) collapses the window.
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

        sourceChipButton.target = self
        sourceChipButton.action = #selector(sourceChipClicked)
        sourceChipButton.cornerStyle = .capsule
        sourceChipButton.pointSize = 11
        sourceChipButton.heightAnchor.constraint(equalToConstant: 26).isActive = true

        idleTitleLabel.font = .systemFont(ofSize: 22, weight: .black)
        idleTitleLabel.textColor = .labelColor
        idleTitleLabel.alignment = .center
        idleSubtitleLabel.font = .systemFont(ofSize: 13)
        idleSubtitleLabel.textColor = .secondaryLabelColor
        idleSubtitleLabel.alignment = .center
        let titles = Layout.verticalStack([idleTitleLabel, idleSubtitleLabel], spacing: 4)
        titles.alignment = .centerX

        armButton.target = self
        armButton.action = #selector(armClicked)
        armButton.cornerStyle = .capsule
        armButton.imagePosition = .imageOnly
        armButton.imageScaling = .scaleProportionallyDown
        armButton.setIcon("circle.fill", pointSize: 26, label: "Start recording")
        armButton.constrainSize(width: Self.transportDiameter, height: Self.transportDiameter)

        sourceDot.constrainSize(width: 7, height: 7)
        sourceStatusLabel.font = .systemFont(ofSize: 11)
        sourceStatusLabel.textColor = .secondaryLabelColor
        sourceStatusLabel.alignment = .center
        sourceStatusLabel.lineBreakMode = .byWordWrapping
        sourceStatusLabel.maximumNumberOfLines = 2

        settingsButton.target = self
        settingsButton.action = #selector(openSettingsClicked)
        settingsButton.isHidden = true

        let statusRow = Layout.horizontalStack([sourceDot, sourceStatusLabel], spacing: 6)
        sourceStatusRow = statusRow

        let content = Layout.verticalStack(
            [sourceChipButton, titles, armButton, autoStopChipRow(), statusRow, settingsButton],
            spacing: WindowUI.Metrics.sectionSpacing
        )
        content.alignment = .centerX
        content.setCustomSpacing(6, after: statusRow)

        // Centered rather than stretched. There genuinely isn't a window's worth of content in
        // "press this to start" — stretching it to fill 900pt would leave dead space between the
        // title and the button. The recording state, which has a waveform worth the space, does
        // fill instead (see `recordingView()`).
        let wrapper = AutoLayoutView()
        wrapper.addSubview(content)
        NSLayoutConstraint.activate([
            content.centerXAnchor.constraint(equalTo: wrapper.centerXAnchor),
            content.centerYAnchor.constraint(equalTo: wrapper.centerYAnchor),
            content.topAnchor.constraint(greaterThanOrEqualTo: wrapper.topAnchor),
            content.leadingAnchor.constraint(greaterThanOrEqualTo: wrapper.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(lessThanOrEqualTo: wrapper.trailingAnchor, constant: -20)
        ])

        reloadSourceMenu()
        updateIdleCopy()
        cachedIdleView = wrapper
        return wrapper
    }

    /// One capsule row: a label, the toggle, and the minute/second fields it governs — replacing
    /// what used to be a full "Auto-stop" card. Worth a sentence, not a quarter of the page.
    private func autoStopChipRow() -> NSView {
        let label = NSTextField(labelWithString: "Auto-stop")
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor

        autoStopToggle.translatesAutoresizingMaskIntoConstraints = false
        autoStopToggle.onToggle = { [weak self] isOn in self?.autoStopToggleChanged(isOn) }

        let colon = NSTextField(labelWithString: ":")
        colon.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        colon.textColor = .secondaryLabelColor

        minutesField.target = self
        minutesField.action = #selector(timeFieldChanged)
        secondsField.target = self
        secondsField.action = #selector(timeFieldChanged)

        let inner = Layout.horizontalStack([label, autoStopToggle, minutesField, colon, secondsField], spacing: 8)
        inner.translatesAutoresizingMaskIntoConstraints = false

        let chip = ThemedView(fill: .clear, stroke: .flatDivider)
        chip.layer?.borderWidth = 1
        chip.heightAnchor.constraint(equalToConstant: 34).isActive = true
        chip.layer?.cornerRadius = 17
        chip.addSubview(inner)
        Layout.pin(inner, to: chip, insets: NSEdgeInsets(top: 6, left: 14, bottom: 6, right: 14))
        return chip
    }

    /// Rebuilds the device list from what's present *now*. Called on every appearance rather than
    /// once at build time, because mics get plugged in and unplugged while the app is running and a
    /// stale menu would offer a device that no longer exists.
    private func reloadSourceMenu() {
        sourceDevices = CoreAudioDevices.inputDevices()
        if case .inputDevice(let uid) = preferences.recordingSource, !sourceDevices.contains(where: { $0.uid == uid }) {
            // The saved device is gone. Fall back to system audio rather than leaving a selection
            // pointing at nothing — and persist it, so the next launch doesn't resurrect a device
            // that isn't there.
            preferences.recordingSource = .systemAudio
        }
        updateSourceChipTitle()
        updateSourceStatus()
    }

    private func updateSourceChipTitle() {
        sourceChipButton.title = "\(preferences.recordingSource.displayName)  ⌄"
    }

    /// A single dropdown chip rather than a row of pills or a boxed "Input source" card — a pill for
    /// every device stops scaling past two or three, and several audio interfaces or mics plugged in
    /// at once is a real case, not an edge case.
    @objc private func sourceChipClicked() {
        let menu = NSMenu()
        let current = preferences.recordingSource

        let systemItem = NSMenuItem(title: "System audio", action: #selector(sourceMenuItemSelected(_:)), keyEquivalent: "")
        systemItem.target = self
        systemItem.state = current.isMicrophone ? .off : .on
        menu.addItem(systemItem)

        if !sourceDevices.isEmpty {
            menu.addItem(.separator())
            for device in sourceDevices {
                let item = NSMenuItem(title: device.name, action: #selector(sourceMenuItemSelected(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = device.uid
                if case .inputDevice(let uid) = current, uid == device.uid {
                    item.state = .on
                }
                menu.addItem(item)
            }
        }

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sourceChipButton.bounds.height + 4), in: sourceChipButton)
    }

    @objc private func sourceMenuItemSelected(_ sender: NSMenuItem) {
        if let uid = sender.representedObject as? String {
            preferences.recordingSource = .inputDevice(uid: uid)
        } else {
            preferences.recordingSource = .systemAudio
        }
        updateSourceChipTitle()
        updateSourceStatus()
        updateIdleCopy()
    }

    /// Shows what is *wrong* with the current selection, and nothing at all when nothing is. The
    /// chip's own title already says what source is picked; restating "records whatever your Mac is
    /// playing" under a title that says "System audio" is a definition nobody asked for.
    ///
    /// Deliberately not a permission *check* — macOS only reports microphone authorization once
    /// asked, and prompting on mere selection would be a prompt the user didn't ask for. The real
    /// gate is in `ClipRecorder.startRecording`, on the Start button.
    private func updateSourceStatus() {
        sourceStatusLabel.toolTip = nil
        settingsButton.isHidden = true

        guard case .inputDevice = preferences.recordingSource, AudioPermission.isMicrophoneDenied else {
            sourceStatusRow?.isHidden = true
            return
        }

        sourceStatusRow?.isHidden = false
        sourceDot.color = .systemRed
        sourceStatusLabel.textColor = .systemRed
        sourceStatusLabel.stringValue = "Microphone access is denied."
        settingsButton.isHidden = false
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

    // MARK: - Recording state UI

    private func recordingView() -> NSView {
        if let cachedRecordingView { return cachedRecordingView }

        recDot.constrainSize(width: 8, height: 8)
        recDot.startPulsing()
        let recLabel = NSTextField(labelWithString: "RECORDING")
        recLabel.font = .systemFont(ofSize: 11, weight: .bold)
        recLabel.textColor = .brandAccentDeep
        let recIndicator = Layout.horizontalStack([recDot, recLabel], spacing: 6)

        // 52pt where the popover used 20 and the first page pass used 44: at page scale, with the
        // settings cards gone, this is the one number you glance at from across the room.
        elapsedLabel.font = .monospacedDigitSystemFont(ofSize: 52, weight: .bold)
        elapsedLabel.textColor = .labelColor
        elapsedLabel.alignment = .center

        liveWaveform.translatesAutoresizingMaskIntoConstraints = false
        liveWaveform.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        // Near-zero vertical hugging so the waveform, not empty space below the button, takes the
        // window's slack — the trick `LiveTabViewController` uses for its level meter.
        liveWaveform.setContentHuggingPriority(.init(1), for: .vertical)
        liveWaveform.onDragAutoStop = { [weak self] seconds in
            self?.setAutoStop(seconds: seconds)
        }

        stopButton.target = self
        stopButton.action = #selector(stopClicked)
        stopButton.cornerStyle = .capsule
        stopButton.imagePosition = .imageOnly
        stopButton.imageScaling = .scaleProportionallyDown
        stopButton.setIcon("square.fill", pointSize: 22, label: "Stop recording")
        stopButton.constrainSize(width: Self.transportDiameter, height: Self.transportDiameter)

        elapsedMetaLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        elapsedMetaLabel.textColor = .secondaryLabelColor
        targetMetaLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        targetMetaLabel.textColor = .brandAccentDeep
        let metaRow = Layout.horizontalStack([elapsedMetaLabel, Layout.flexibleSpacer(), targetMetaLabel], spacing: 8)

        let content = Layout.verticalStack(
            [recIndicator, elapsedLabel, liveWaveform, metaRow, stopButton],
            spacing: WindowUI.Metrics.rowSpacing
        )
        content.alignment = .centerX
        content.setCustomSpacing(WindowUI.Metrics.sectionSpacing, after: elapsedLabel)
        content.setCustomSpacing(WindowUI.Metrics.rowSpacing, after: liveWaveform)
        content.setCustomSpacing(WindowUI.Metrics.sectionSpacing, after: metaRow)

        // `.centerX`-aligned stacks size arranged views to their own intrinsic width; the waveform
        // and its meta row need the page's full width instead, matched to whatever width the pinned
        // `content` ends up with.
        liveWaveform.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        metaRow.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true

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
        sourceStatusRow?.isHidden = false
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
