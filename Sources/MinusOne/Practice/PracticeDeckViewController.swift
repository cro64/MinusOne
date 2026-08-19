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
    private let timeLabel = SharedUI.valueLabel(initialValue: "0:00 / 0:00")
    private let tempoSlider = NSSlider(value: 100, minValue: 50, maxValue: 100, target: nil, action: nil)
    private let tempoValueLabel = NSTextField(labelWithString: "100%")
    private var mixerRows: [SeparationStem: MixerRowView] = [:]
    private var contentStack: NSStackView?

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
            emptyStateView.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: WindowUI.Metrics.padding),
            emptyStateView.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -WindowUI.Metrics.padding)
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

        let transportStack = Layout.horizontalStack([playPauseButton, loopButton, timeLabel], spacing: WindowUI.Metrics.rowSpacing)

        tempoSlider.isContinuous = true
        tempoSlider.target = self
        tempoSlider.action = #selector(tempoChanged)
        let tempoLabel = SharedUI.fieldLabel("Tempo")
        tempoLabel.widthAnchor.constraint(equalToConstant: WindowUI.Metrics.labelWidth).isActive = true
        let tempoRow = Layout.horizontalStack([tempoLabel, tempoSlider, tempoValueLabel], spacing: WindowUI.Metrics.rowSpacing)
        tempoSlider.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true

        let mixerHeader = SharedUI.sectionHeader("Stems")
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
        let mixerStack = Layout.verticalStack(mixerViews, spacing: WindowUI.Metrics.rowSpacing)

        let content = Layout.verticalStack(
            [titleLabel, statusLabel, waveformView, transportStack, tempoRow, mixerStack],
            spacing: WindowUI.Metrics.sectionSpacing
        )
        content.setCustomSpacing(4, after: titleLabel)
        content.setCustomSpacing(4, after: statusLabel)

        // `.leading`-aligned stacks pin their arranged subviews' leading edge and nothing else —
        // the same trap `WindowUI.section` documents. `tempoRow` got away with it because it *is* an
        // NSStackView holding a low-hugging NSSlider, so its own arrangement let it fill; each
        // `MixerRowView` is a plain NSView, which to this stack is an opaque box that gets its
        // fitting width. Measured before this chain: tempo slider 556.5pt, every stem fader stuck at
        // 140pt — exactly its `greaterThanOrEqualToConstant` floor, in a 671pt-wide pane.
        waveformView.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        tempoRow.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        mixerStack.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        for row in mixerViews {
            row.widthAnchor.constraint(equalTo: mixerStack.widthAnchor).isActive = true
        }

        let pad = WindowUI.Metrics.padding
        Layout.pin(content, to: view, edges: [.top, .leading, .trailing], insets: NSEdgeInsets(top: pad, left: pad, bottom: 0, right: pad))
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
            statusLabel.stringValue = "Separating in the background… \(clip.readyDurationSeconds.formattedAsDuration) ready of \(clip.durationSeconds.formattedAsDuration)"
            statusLabel.textColor = .secondaryLabelColor
            statusLabel.isHidden = false
        } else {
            statusLabel.isHidden = true
        }

        timeLabel.stringValue = "\(0.0.formattedAsDuration) / \(clip.durationSeconds.formattedAsDuration)"
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
        timeLabel.stringValue = "\(time.formattedAsDuration) / \(clip.durationSeconds.formattedAsDuration)"
    }

    private func refreshMixerButtonStates() {
        for (stem, row) in mixerRows {
            row.setSoloed(playbackEngine.mixer.isSoloed(stem))
        }
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

        let label = SharedUI.fieldLabel(stem.displayName)
        // The text variant, not the fill color: as a 13pt label the raw stem hues measure 2.7:1
        // (Drums), 3.7:1 (Bass) and 4.2:1 (Other) against a light card. The slider below still
        // takes the canonical `identityColor` — as an area of fill it has no such problem.
        label.textColor = stem.identityTextColor
        label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        label.widthAnchor.constraint(equalToConstant: WindowUI.Metrics.labelWidth).isActive = true

        let slider = NSSlider(value: 1, minValue: 0, maxValue: 1, target: nil, action: nil)
        slider.isContinuous = true
        slider.trackFillColor = color
        slider.widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true

        soloButton = WindowUI.toggleControlButton(title: "Solo", target: nil, action: nil)
        muteButton = WindowUI.toggleControlButton(title: "Mute", target: nil, action: nil)
        muteButton.engagedFillColorOverride = .systemRed

        super.init(frame: .zero)

        let row = Layout.horizontalStack([label, slider, soloButton, muteButton], spacing: WindowUI.Metrics.rowSpacing)
        Layout.pin(row, to: self)

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
