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
    private let modeTag = TagView(text: "NOT RECORDING", color: RecordingTheme.red)
    private let sourceDot = DotView(color: RecordingTheme.teal)
    private let sourceStatusLabel = NSTextField(labelWithString: "System audio access granted")
    private let settingsButton: ThemedButton
    private let autoStopToggle = ToggleSwitchView()
    private let minutesField = RecordingPanelController.makeTimeField()
    private let secondsField = RecordingPanelController.makeTimeField()
    private let armButton: ThemedButton

    // Recording state
    private let recDot = DotView(color: RecordingTheme.red)
    private let elapsedLabel = NSTextField(labelWithString: "0:00")
    private let liveWaveform = LiveWaveformView()
    private let elapsedMetaLabel = NSTextField(labelWithString: "elapsed 0:00")
    private let targetMetaLabel = NSTextField(labelWithString: "auto-stop off")
    private let stopButton: ThemedButton

    private var idleContainer: NSStackView!
    private var recordingContainer: NSStackView!
    private var sourceRow: NSView!

    private var autoStopEnabled = false
    private var autoStopSeconds: Double?

    init(recorder: SystemAudioRecorder, onFinished: @escaping (URL) -> Void) {
        self.recorder = recorder
        self.onFinished = onFinished
        settingsButton = ThemedButton(title: "Open System Settings…", style: .outlined(border: RecordingTheme.redDim, foreground: RecordingTheme.cream))
        armButton = ThemedButton(title: "●  Start recording", style: .filled(background: RecordingTheme.red, foreground: RecordingTheme.background))
        stopButton = ThemedButton(title: "■  Stop now", style: .outlined(border: RecordingTheme.hairline, foreground: RecordingTheme.cream))
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 200))
        root.wantsLayer = true
        root.layer?.backgroundColor = RecordingTheme.panel.cgColor
        view = root

        let idle = buildIdleContainer()
        let recording = buildRecordingContainer()
        idleContainer = idle
        recordingContainer = recording

        let content = NSStackView(views: [idle, recording])
        content.orientation = .vertical
        content.alignment = .leading
        content.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(content)

        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            content.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
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
        title.font = RecordingTheme.sans(15, weight: .semibold)
        title.textColor = RecordingTheme.cream

        let subtitle = NSTextField(labelWithString: "MinusOne · practice mode")
        subtitle.font = RecordingTheme.mono(11)
        subtitle.textColor = RecordingTheme.putty

        let titles = NSStackView(views: [title, subtitle])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 4

        let header = rowStack([titles, spacer(), modeTag])

        sourceDot.widthAnchor.constraint(equalToConstant: 5).isActive = true
        sourceDot.heightAnchor.constraint(equalToConstant: 5).isActive = true
        sourceStatusLabel.font = RecordingTheme.mono(10, weight: .medium)
        sourceStatusLabel.textColor = RecordingTheme.teal
        let sourceLabel = NSTextField(labelWithString: "Input source")
        sourceLabel.font = RecordingTheme.sans(13)
        sourceLabel.textColor = RecordingTheme.putty
        let sourceStatus = rowStack([sourceDot, sourceStatusLabel], spacing: 6)
        let source = rowStack([sourceLabel, spacer(), sourceStatus])
        sourceRow = borderedBox(source)

        settingsButton.target = self
        settingsButton.action = #selector(openSettingsClicked)
        settingsButton.isHidden = true

        let timerLabel = NSTextField(labelWithString: "Auto-stop timer")
        timerLabel.font = RecordingTheme.sans(13)
        timerLabel.textColor = RecordingTheme.cream
        let timerSub = NSTextField(labelWithString: "Recording stops and processing begins automatically")
        timerSub.font = RecordingTheme.mono(10)
        timerSub.textColor = RecordingTheme.putty
        timerSub.maximumNumberOfLines = 2
        timerSub.lineBreakMode = .byWordWrapping
        timerSub.preferredMaxLayoutWidth = 190
        let timerTitles = NSStackView(views: [timerLabel, timerSub])
        timerTitles.orientation = .vertical
        timerTitles.alignment = .leading
        timerTitles.spacing = 2

        autoStopToggle.translatesAutoresizingMaskIntoConstraints = false
        autoStopToggle.onToggle = { [weak self] isOn in self?.autoStopToggleChanged(isOn) }
        let timerRow1 = rowStack([timerTitles, spacer(), autoStopToggle])

        let colon = NSTextField(labelWithString: ":")
        colon.font = RecordingTheme.mono(14)
        colon.textColor = RecordingTheme.putty
        let unit = NSTextField(labelWithString: "min : sec")
        unit.font = RecordingTheme.mono(10)
        unit.textColor = RecordingTheme.putty
        minutesField.target = self
        minutesField.action = #selector(timeFieldChanged)
        secondsField.target = self
        secondsField.action = #selector(timeFieldChanged)
        let timerRow2 = rowStack([minutesField, colon, secondsField, unit], spacing: 8)

        let timerStack = NSStackView(views: [timerRow1, timerRow2])
        timerStack.orientation = .vertical
        timerStack.alignment = .leading
        timerStack.spacing = 10
        let timerField = borderedBox(timerStack)

        armButton.target = self
        armButton.action = #selector(armClicked)
        armButton.translatesAutoresizingMaskIntoConstraints = false
        armButton.heightAnchor.constraint(equalToConstant: 40).isActive = true

        let stack = NSStackView(views: [header, sourceRow, settingsButton, timerField, armButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.setCustomSpacing(6, after: sourceRow)
        [header, sourceRow, settingsButton, timerField, armButton].forEach {
            $0.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    // MARK: - Recording state UI

    private func buildRecordingContainer() -> NSStackView {
        recDot.widthAnchor.constraint(equalToConstant: 8).isActive = true
        recDot.heightAnchor.constraint(equalToConstant: 8).isActive = true
        recDot.startPulsing()
        let recLabel = NSTextField(labelWithString: "RECORDING")
        recLabel.font = RecordingTheme.mono(11, weight: .medium)
        recLabel.textColor = RecordingTheme.red
        let recIndicator = rowStack([recDot, recLabel], spacing: 8)

        elapsedLabel.font = RecordingTheme.mono(20, weight: .medium)
        elapsedLabel.textColor = RecordingTheme.cream

        let recHead = rowStack([recIndicator, spacer(), elapsedLabel])

        liveWaveform.translatesAutoresizingMaskIntoConstraints = false
        liveWaveform.heightAnchor.constraint(equalToConstant: 68).isActive = true
        liveWaveform.wantsLayer = true
        liveWaveform.layer?.borderWidth = 1
        liveWaveform.layer?.borderColor = RecordingTheme.hairline.cgColor
        liveWaveform.layer?.cornerRadius = 3
        liveWaveform.onDragAutoStop = { [weak self] seconds in
            self?.setAutoStop(seconds: seconds)
        }

        elapsedMetaLabel.font = RecordingTheme.mono(10)
        elapsedMetaLabel.textColor = RecordingTheme.putty
        targetMetaLabel.font = RecordingTheme.mono(10)
        targetMetaLabel.textColor = RecordingTheme.amber
        let metaRow = rowStack([elapsedMetaLabel, spacer(), targetMetaLabel])

        stopButton.target = self
        stopButton.action = #selector(stopClicked)
        stopButton.translatesAutoresizingMaskIntoConstraints = false
        stopButton.heightAnchor.constraint(equalToConstant: 40).isActive = true

        let stack = NSStackView(views: [recHead, liveWaveform, metaRow, stopButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
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
        minutesField.textColor = isOn ? RecordingTheme.cream : RecordingTheme.putty
        secondsField.textColor = isOn ? RecordingTheme.cream : RecordingTheme.putty
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
        sourceDot.color = RecordingTheme.red
        sourceStatusLabel.textColor = RecordingTheme.red
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

    private func rowStack(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = spacing
        return stack
    }

    private func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.init(1), for: .horizontal)
        return view
    }

    private func borderedBox(_ content: NSView) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.borderWidth = 1
        container.layer?.borderColor = RecordingTheme.hairline.cgColor
        container.layer?.cornerRadius = 4
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            content.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12)
        ])
        return container
    }

    private static func makeTimeField() -> NSTextField {
        let field = NSTextField(string: "00")
        field.font = RecordingTheme.mono(14)
        field.textColor = RecordingTheme.putty
        field.alignment = .center
        field.isBordered = false
        field.drawsBackground = true
        field.backgroundColor = RecordingTheme.background
        field.wantsLayer = true
        field.layer?.cornerRadius = 3
        field.layer?.borderWidth = 1
        field.layer?.borderColor = RecordingTheme.hairline.cgColor
        field.isEnabled = false
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 44).isActive = true
        field.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return field
    }
}

/// Small filled circle — used for the permission-status dot and the pulsing recording dot.
private final class DotView: NSView {
    var color: NSColor {
        didSet { layer?.backgroundColor = color.cgColor }
    }

    init(color: NSColor) {
        self.color = color
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = color.cgColor
        layer?.cornerRadius = 3
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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
