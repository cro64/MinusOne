import AppKit

/// Arm/record/stop UI for capturing system audio into Practice Mode, shown as a popover off the
/// window toolbar's Record button. The recorder itself is owned by the caller (not this
/// controller) so a recording keeps running if the popover is dismissed and reopened.
@available(macOS 14.2, *)
final class RecordingPanelController: NSViewController {
    private static let panelWidth: CGFloat = 340

    private let recorder: SystemAudioRecorder
    private let onFinished: (URL) -> Void

    // Idle state
    private let modeTag = StatusTagView(text: "NOT RECORDING", color: .systemRed)
    private let sourceDot = DotView(color: .secondaryLabelColor)
    private let sourceStatusLabel = NSTextField(labelWithString: "System audio access granted")
    private let settingsButton = FlatButton(title: "Open System Settings…", kind: .secondary)
    private let autoStopToggle = ToggleSwitchView()
    private let minutesField = RecordingPanelController.makeTimeField()
    private let secondsField = RecordingPanelController.makeTimeField()
    private let armButton = FlatButton(title: "●  Start recording", kind: .primary)

    // Recording state
    private let recDot = DotView(color: .brandAccentDeep)
    private let elapsedLabel = NSTextField(labelWithString: "0:00")
    private let liveWaveform = LiveWaveformView()
    private let elapsedMetaLabel = NSTextField(labelWithString: "elapsed 0:00")
    private let targetMetaLabel = NSTextField(labelWithString: "auto-stop off")
    private let stopButton = FlatButton(title: "■  Stop now", kind: .secondary)

    private var idleContainer: NSStackView!
    private var recordingContainer: NSStackView!
    private var sourceRow: NSView!

    private var autoStopEnabled = false
    private var autoStopSeconds: Double?

    init(recorder: SystemAudioRecorder, onFinished: @escaping (URL) -> Void) {
        self.recorder = recorder
        self.onFinished = onFinished
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = ThemedView(frame: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 200))
        // `ThemedView` inherits `AutoLayoutView`'s `false` default, which is right for the
        // constraint-laid-out containers it's normally used for but wrong here: this is a popover's
        // root view, and `NSPopover` takes its content size from this frame.
        root.translatesAutoresizingMaskIntoConstraints = true
        root.fillColor = .windowBackgroundColor
        view = root

        let idle = buildIdleContainer()
        let recording = buildRecordingContainer()
        idleContainer = idle
        recordingContainer = recording

        let content = Layout.verticalStack([idle, recording], spacing: 8)
        Layout.pin(content, to: root, insets: NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20))

        NSLayoutConstraint.activate([
            idle.widthAnchor.constraint(equalToConstant: Self.panelWidth - 40),
            recording.widthAnchor.constraint(equalToConstant: Self.panelWidth - 40)
        ])

        recorder.onProgress = { [weak self] peaks, elapsed in
            self?.updateProgress(peaks: peaks, elapsed: elapsed)
        }

        refreshState()
    }

    // MARK: - Idle state UI

    private func buildIdleContainer() -> NSStackView {
        let title = NSTextField(labelWithString: "Record system audio")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = .labelColor

        let subtitle = NSTextField(labelWithString: "MinusOne · practice mode")
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor

        let titles = Layout.verticalStack([title, subtitle], spacing: 4)

        let header = Layout.horizontalStack([titles, Layout.flexibleSpacer(), modeTag], spacing: 8)

        sourceDot.constrainSize(width: 5, height: 5)
        sourceStatusLabel.font = .systemFont(ofSize: 10, weight: .medium)
        sourceStatusLabel.textColor = .secondaryLabelColor
        let sourceLabel = NSTextField(labelWithString: "Input source")
        sourceLabel.font = .systemFont(ofSize: 13)
        sourceLabel.textColor = .secondaryLabelColor
        let sourceStatus = Layout.horizontalStack([sourceDot, sourceStatusLabel], spacing: 6)
        let source = Layout.horizontalStack([sourceLabel, Layout.flexibleSpacer(), sourceStatus], spacing: 8)
        sourceRow = borderedBox(source)

        settingsButton.target = self
        settingsButton.action = #selector(openSettingsClicked)
        settingsButton.isHidden = true

        let timerLabel = NSTextField(labelWithString: "Auto-stop timer")
        timerLabel.font = .systemFont(ofSize: 13)
        timerLabel.textColor = .labelColor
        let timerSub = NSTextField(labelWithString: "Recording stops and processing begins automatically")
        timerSub.font = .systemFont(ofSize: 10)
        timerSub.textColor = .secondaryLabelColor
        timerSub.maximumNumberOfLines = 2
        timerSub.lineBreakMode = .byWordWrapping
        timerSub.preferredMaxLayoutWidth = 190
        let timerTitles = Layout.verticalStack([timerLabel, timerSub], spacing: 2)

        autoStopToggle.translatesAutoresizingMaskIntoConstraints = false
        autoStopToggle.onToggle = { [weak self] isOn in self?.autoStopToggleChanged(isOn) }
        let timerRow1 = Layout.horizontalStack([timerTitles, Layout.flexibleSpacer(), autoStopToggle], spacing: 8)

        let colon = NSTextField(labelWithString: ":")
        colon.font = .monospacedDigitSystemFont(ofSize: 14, weight: .regular)
        colon.textColor = .secondaryLabelColor
        let unit = NSTextField(labelWithString: "min : sec")
        unit.font = .systemFont(ofSize: 10)
        unit.textColor = .secondaryLabelColor
        minutesField.target = self
        minutesField.action = #selector(timeFieldChanged)
        secondsField.target = self
        secondsField.action = #selector(timeFieldChanged)
        let timerRow2 = Layout.horizontalStack([minutesField, colon, secondsField, unit], spacing: 8)

        let timerStack = Layout.verticalStack([timerRow1, timerRow2], spacing: 10)
        let timerField = borderedBox(timerStack)

        armButton.target = self
        armButton.action = #selector(armClicked)
        armButton.heightAnchor.constraint(equalToConstant: 40).isActive = true

        let stack = Layout.verticalStack([header, sourceRow, settingsButton, timerField, armButton], spacing: 14)
        stack.setCustomSpacing(6, after: sourceRow)
        [header, sourceRow, settingsButton, timerField, armButton].forEach {
            $0.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    // MARK: - Recording state UI

    private func buildRecordingContainer() -> NSStackView {
        recDot.constrainSize(width: 8, height: 8)
        recDot.startPulsing()
        let recLabel = NSTextField(labelWithString: "RECORDING")
        recLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        recLabel.textColor = .brandAccentDeep
        let recIndicator = Layout.horizontalStack([recDot, recLabel], spacing: 8)

        elapsedLabel.font = .monospacedDigitSystemFont(ofSize: 20, weight: .medium)
        elapsedLabel.textColor = .labelColor

        let recHead = Layout.horizontalStack([recIndicator, Layout.flexibleSpacer(), elapsedLabel], spacing: 8)

        liveWaveform.translatesAutoresizingMaskIntoConstraints = false
        liveWaveform.heightAnchor.constraint(equalToConstant: 68).isActive = true
        liveWaveform.onDragAutoStop = { [weak self] seconds in
            self?.setAutoStop(seconds: seconds)
        }

        elapsedMetaLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        elapsedMetaLabel.textColor = .secondaryLabelColor
        targetMetaLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        targetMetaLabel.textColor = .brandAccentDeep
        let metaRow = Layout.horizontalStack([elapsedMetaLabel, Layout.flexibleSpacer(), targetMetaLabel], spacing: 8)

        stopButton.target = self
        stopButton.action = #selector(stopClicked)
        stopButton.heightAnchor.constraint(equalToConstant: 40).isActive = true

        let stack = Layout.verticalStack([recHead, liveWaveform, metaRow, stopButton], spacing: 10)
        [recHead, liveWaveform, metaRow, stopButton].forEach {
            $0.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    // MARK: - State

    private func refreshState() {
        let recording = recorder.isRecording
        idleContainer.isHidden = recording
        recordingContainer.isHidden = !recording
        if recording {
            updateProgress(peaks: [], elapsed: recorder.elapsedSeconds())
        }
    }

    @objc private func armClicked() {
        armButton.isEnabled = false
        recorder.startRecording { [weak self] result in
            guard let self else { return }
            self.armButton.isEnabled = true
            switch result {
            case .success:
                self.settingsButton.isHidden = true
                self.liveWaveform.autoStopSeconds = self.autoStopSeconds
                if let autoStopSeconds = self.autoStopSeconds {
                    self.recorder.setAutoStop(seconds: autoStopSeconds) { [weak self] in self?.finishRecording() }
                }
                self.refreshState()
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
            refreshState()
            return
        }
        onFinished(url)
        refreshState()
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
            targetMetaLabel.stringValue = "auto-stop at \(total / 60):\(String(format: "%02d", total % 60))"
        } else {
            targetMetaLabel.stringValue = "auto-stop off"
        }
        recorder.setAutoStop(seconds: seconds) { [weak self] in self?.finishRecording() }
    }

    @objc private func openSettingsClicked() {
        AudioPermission.openSystemAudioRecordingSettings()
    }

    private func showError(_ error: Error) {
        let isPermissionIssue = (error as? AudioEngineError)?.isLikelyPermissionDenied ?? false
        sourceDot.color = .systemRed
        sourceStatusLabel.textColor = .systemRed
        sourceStatusLabel.stringValue = isPermissionIssue ? "Permission denied" : "Couldn't start recording"
        sourceStatusLabel.toolTip = error.localizedDescription
        settingsButton.isHidden = !isPermissionIssue
    }

    private func updateProgress(peaks: [Float], elapsed: Double) {
        if !peaks.isEmpty {
            liveWaveform.peaks = peaks
        }
        liveWaveform.elapsedSeconds = elapsed
        let total = Int(elapsed.rounded())
        let text = String(format: "%d:%02d", total / 60, total % 60)
        elapsedLabel.stringValue = text
        elapsedMetaLabel.stringValue = "elapsed \(text)"
    }

    // MARK: - Layout helpers

    private func borderedBox(_ content: NSView) -> NSView {
        let container = ThemedView(stroke: .flatDivider)
        container.layer?.borderWidth = 1
        Layout.pin(content, to: container, insets: NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12))
        return container
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
private final class DividerBorderedTextField: NSTextField {
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
private final class DotView: NSView {
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
private final class StatusTagView: NSTextField {
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
