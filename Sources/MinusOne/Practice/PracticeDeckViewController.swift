import AppKit

/// Detail pane: waveform, transport, tempo, and per-stem mixer for the selected clip.
final class PracticeDeckViewController: NSViewController {
    private let libraryStore: ClipLibraryStore
    private let playbackEngine: PracticePlaybackEngine

    private var clip: PracticeClip?
    private var isEngineLoaded = false
    private var lastReloadedReadySeconds: Double = 0

    private let emptyStateView = PracticeEmptyStateView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let waveformView = WaveformView(style: .interactive)
    private let playPauseButton = FlatButton(title: "Play", kind: .secondary)
    private let loopButton = FlatButton(title: "Loop", kind: .secondary)
    private let timeLabel = PopoverUI.valueLabel(initialValue: "0:00 / 0:00")
    private let tempoSlider = NSSlider(value: 100, minValue: 50, maxValue: 100, target: nil, action: nil)
    private let tempoValueLabel = NSTextField(labelWithString: "100%")
    private var mixerRows: [SeparationStem: MixerRowView] = [:]
    private var contentStack: NSStackView?

    /// Wired by the owning window controller to the same actions as the toolbar's Import/Record,
    /// so the empty state's CTAs (REDESIGN.md §4) aren't a second, divergent code path.
    var onImportRequested: (() -> Void)? {
        get { emptyStateView.onImportRequested }
        set { emptyStateView.onImportRequested = newValue }
    }
    var onRecordRequested: (() -> Void)? {
        get { emptyStateView.onRecordRequested }
        set { emptyStateView.onRecordRequested = newValue }
    }

    init(libraryStore: ClipLibraryStore, playbackEngine: PracticePlaybackEngine) {
        self.libraryStore = libraryStore
        self.playbackEngine = playbackEngine
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = AutoLayoutView(frame: NSRect(x: 0, y: 0, width: 700, height: 560))

        emptyStateView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyStateView)
        NSLayoutConstraint.activate([
            emptyStateView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyStateView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            emptyStateView.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: PopoverUI.Metrics.Regular.padding),
            emptyStateView.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -PopoverUI.Metrics.Regular.padding)
        ])

        buildContent()
        setupBindings()
        showEmptyState(true)
    }

    private func buildContent() {
        titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.isHidden = true

        waveformView.translatesAutoresizingMaskIntoConstraints = false
        waveformView.heightAnchor.constraint(equalToConstant: 140).isActive = true

        playPauseButton.target = self
        playPauseButton.action = #selector(togglePlayPause)

        loopButton.setButtonType(.pushOnPushOff)
        loopButton.target = self
        loopButton.action = #selector(toggleLoop)

        timeLabel.isHidden = false
        timeLabel.stringValue = "0:00 / 0:00"

        let transportStack = NSStackView(views: [playPauseButton, loopButton, timeLabel])
        transportStack.orientation = .horizontal
        transportStack.spacing = PopoverUI.Metrics.Regular.rowSpacing
        transportStack.alignment = .centerY

        tempoSlider.isContinuous = true
        tempoSlider.target = self
        tempoSlider.action = #selector(tempoChanged)
        let tempoLabel = PopoverUI.fieldLabel("Tempo")
        tempoLabel.widthAnchor.constraint(equalToConstant: PopoverUI.Metrics.Regular.labelWidth).isActive = true
        let tempoRow = NSStackView(views: [tempoLabel, tempoSlider, tempoValueLabel])
        tempoRow.orientation = .horizontal
        tempoRow.spacing = PopoverUI.Metrics.Regular.rowSpacing
        tempoRow.alignment = .centerY
        tempoSlider.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true

        let mixerHeader = PopoverUI.sectionHeader("Stems")
        var mixerViews: [NSView] = [mixerHeader]
        for stem in SeparationStem.allCases {
            let row = MixerRowView(stem: stem)
            row.onVolumeChanged = { [weak self] value in self?.playbackEngine.setStemVolume(value, for: stem) }
            row.onMuteToggled = { [weak self] muted in self?.playbackEngine.setStemMuted(muted, for: stem) }
            row.onSoloToggled = { [weak self] in
                self?.playbackEngine.toggleStemSolo(stem)
                self?.refreshMixerButtonStates()
            }
            mixerRows[stem] = row
            mixerViews.append(row)
        }
        let mixerStack = PopoverUI.verticalStack(mixerViews, spacing: PopoverUI.Metrics.Regular.rowSpacing)

        let content = PopoverUI.verticalStack(
            [titleLabel, statusLabel, waveformView, transportStack, tempoRow, mixerStack],
            spacing: PopoverUI.Metrics.Regular.sectionSpacing
        )
        content.setCustomSpacing(4, after: titleLabel)
        content.setCustomSpacing(4, after: statusLabel)
        waveformView.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true

        let pad = PopoverUI.Metrics.Regular.padding
        PopoverUI.pin(content, to: view, edges: [.top, .leading, .trailing], insets: NSEdgeInsets(top: pad, left: pad, bottom: 0, right: pad))
        contentStack = content
    }

    private func setupBindings() {
        waveformView.onSeek = { [weak self] fraction in
            guard let self, let clip = self.clip else { return }
            self.playbackEngine.seek(toSeconds: Double(fraction) * clip.durationSeconds)
        }
        waveformView.onLoopRangeChanged = { [weak self] range in
            guard let self, let clip = self.clip else { return }
            let seconds = (Double(range.lowerBound) * clip.durationSeconds)...(Double(range.upperBound) * clip.durationSeconds)
            self.playbackEngine.setLoopRange(seconds)
            self.playbackEngine.isLoopEnabled = true
            self.loopButton.state = .on
            self.loopButton.refreshStyle()
        }
        playbackEngine.onPlayheadUpdate = { [weak self] time in
            self?.updatePlayhead(time)
        }
        playbackEngine.onPlaybackFinished = { [weak self] in
            self?.playPauseButton.title = "Play"
            self?.playPauseButton.isOn = false
        }
    }

    // MARK: - Clip lifecycle

    func show(clip: PracticeClip) {
        self.clip = clip
        isEngineLoaded = false
        lastReloadedReadySeconds = 0
        showEmptyState(false)
        refreshForCurrentClip()
        loadPlaybackIfPossible()
    }

    func updateClip(_ updated: PracticeClip) {
        guard clip?.id == updated.id else { return }
        clip = updated
        refreshForCurrentClip()

        if !isEngineLoaded {
            loadPlaybackIfPossible()
        } else if updated.readyDurationSeconds - lastReloadedReadySeconds > 2 || updated.isFullyProcessed {
            do {
                try playbackEngine.reload(clip: updated, libraryStore: libraryStore)
                lastReloadedReadySeconds = updated.readyDurationSeconds
            } catch {
                AppLogger.shared.warning("Practice deck reload failed: \(error.localizedDescription)")
            }
        }
    }

    private func loadPlaybackIfPossible() {
        guard let clip, clip.readyDurationSeconds > 0, !clip.processingFailed else { return }
        do {
            try playbackEngine.load(clip: clip, libraryStore: libraryStore)
            isEngineLoaded = true
            lastReloadedReadySeconds = clip.readyDurationSeconds
            playPauseButton.isEnabled = true
        } catch {
            AppLogger.shared.warning("Practice deck load failed: \(error.localizedDescription)")
        }
    }

    private func refreshForCurrentClip() {
        guard let clip else { return }
        titleLabel.stringValue = clip.title
        waveformView.peaks = clip.waveformPeaks
        waveformView.readyFraction = clip.durationSeconds > 0 ? CGFloat(clip.readyDurationSeconds / clip.durationSeconds) : 1
        playPauseButton.isEnabled = clip.readyDurationSeconds > 0 && !clip.processingFailed

        if clip.processingFailed {
            statusLabel.stringValue = "Couldn't process this clip — try importing it again."
            statusLabel.textColor = .systemRed
            statusLabel.isHidden = false
        } else if !clip.isFullyProcessed {
            statusLabel.stringValue = "Separating in the background… \(formatDuration(clip.readyDurationSeconds)) ready of \(formatDuration(clip.durationSeconds))"
            statusLabel.textColor = .secondaryLabelColor
            statusLabel.isHidden = false
        } else {
            statusLabel.isHidden = true
        }

        timeLabel.stringValue = "\(formatDuration(0)) / \(formatDuration(clip.durationSeconds))"
    }

    private func showEmptyState(_ empty: Bool) {
        emptyStateView.isHidden = !empty
        contentStack?.isHidden = empty
    }

    // MARK: - Actions

    @objc private func togglePlayPause() {
        if playbackEngine.isPlaying {
            playbackEngine.pause()
            playPauseButton.title = "Play"
            playPauseButton.isOn = false
        } else {
            playbackEngine.play()
            playPauseButton.title = "Pause"
            playPauseButton.isOn = true
        }
    }

    @objc private func toggleLoop() {
        let enabled = loopButton.state == .on
        playbackEngine.isLoopEnabled = enabled
        loopButton.refreshStyle()
    }

    @objc private func tempoChanged() {
        let percent = tempoSlider.doubleValue
        tempoValueLabel.stringValue = "\(Int(percent))%"
        playbackEngine.setTempo(Float(percent / 100))
    }

    private func updatePlayhead(_ time: Double) {
        guard let clip else { return }
        waveformView.playheadFraction = clip.durationSeconds > 0 ? CGFloat(time / clip.durationSeconds) : 0
        timeLabel.stringValue = "\(formatDuration(time)) / \(formatDuration(clip.durationSeconds))"
    }

    private func refreshMixerButtonStates() {
        for (stem, row) in mixerRows {
            row.setSoloed(playbackEngine.mixer.isSoloed(stem))
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// One stem's mixer controls: label, volume fader, mute, solo.
private final class MixerRowView: NSView {
    var onVolumeChanged: ((Float) -> Void)?
    var onMuteToggled: ((Bool) -> Void)?
    var onSoloToggled: (() -> Void)?

    private let soloButton: FlatButton
    private let muteButton: FlatButton

    init(stem: SeparationStem) {
        let color = stem.identityColor

        let label = PopoverUI.fieldLabel(stem.displayName)
        label.textColor = color
        label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        label.widthAnchor.constraint(equalToConstant: PopoverUI.Metrics.Regular.labelWidth).isActive = true

        let slider = NSSlider(value: 1, minValue: 0, maxValue: 1, target: nil, action: nil)
        slider.isContinuous = true
        slider.trackFillColor = color
        slider.widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true

        soloButton = PopoverUI.toggleControlButton(title: "Solo", target: nil, action: nil)
        muteButton = PopoverUI.toggleControlButton(title: "Mute", target: nil, action: nil)
        muteButton.engagedFillColorOverride = .systemRed

        super.init(frame: .zero)

        let row = NSStackView(views: [label, slider, soloButton, muteButton])
        row.orientation = .horizontal
        row.spacing = PopoverUI.Metrics.Regular.rowSpacing
        row.alignment = .centerY
        PopoverUI.pin(row, to: self)

        slider.target = self
        slider.action = #selector(sliderChanged(_:))
        soloButton.target = self
        soloButton.action = #selector(soloClicked)
        muteButton.target = self
        muteButton.action = #selector(muteClicked)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setSoloed(_ soloed: Bool) {
        soloButton.state = soloed ? .on : .off
        soloButton.refreshStyle()
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        onVolumeChanged?(Float(sender.doubleValue))
    }

    @objc private func soloClicked() {
        onSoloToggled?()
    }

    @objc private func muteClicked() {
        let muted = muteButton.state == .on
        muteButton.refreshStyle()
        onMuteToggled?(muted)
    }
}
