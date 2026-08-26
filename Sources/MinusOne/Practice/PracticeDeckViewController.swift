import AppKit

/// Detail pane: the multi-lane timeline, transport and tempo for the selected clip.
///
/// The stems mixer is no longer a section of its own — each lane's header carries that stem's
/// fader, mute, solo and export, because a lane *is* a mixer row (spec §3).
final class PracticeDeckViewController: NSViewController, NSTextFieldDelegate {
    private let libraryStore: ClipLibraryStore
    private let playbackEngine: PracticePlaybackEngine

    private var clip: PracticeClip?
    private var isEngineLoaded = false
    private var lastReloadedReadySeconds: Double = 0

    private let emptyStateView = PracticeEmptyStateView()
    /// Editable in place — clicking the clip's title here is one of the two ways to rename it
    /// (the other is the sidebar row's double-click / Rename… menu).
    private let titleLabel = ClickToEditTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let timeline = DeckTimelineView()
    private var peakStore: PeakStore?
    private lazy var timelineHeightConstraint = timeline.heightAnchor.constraint(
        equalToConstant: DeckTimelineView.height(forLaneCount: 4)
    )
    private let playPauseButton = WindowUI.transportButton(symbolName: "play.fill", label: "Play", target: nil, action: nil)
    private let loopButton = WindowUI.transportToggleButton(symbolName: "repeat", label: "Loop", target: nil, action: nil)
    private let skipBackButton = WindowUI.transportButton(symbolName: "backward.fill", label: "Back \(Int(PracticeDeckViewController.skipSeconds)) seconds", target: nil, action: nil)
    private let skipForwardButton = WindowUI.transportButton(symbolName: "forward.fill", label: "Forward \(Int(PracticeDeckViewController.skipSeconds)) seconds", target: nil, action: nil)
    /// How far the back/forward glyphs jump per click. Short on purpose: this is a practice
    /// transport, so it's for nudging back over the bar you just fluffed, not for scanning a track.
    private static let skipSeconds: Double = 5
    private let timeLabel = SharedUI.valueLabel(initialValue: "0:00 / 0:00")
    private let tempoSlider = NSSlider(value: 100, minValue: 50, maxValue: 100, target: nil, action: nil)
    private let tempoValueLabel = NSTextField(labelWithString: "100%")
    private var contentStack: NSStackView?
    private var titleBeforeEditing = ""
    private var outsideClickMonitor: Any?
    private lazy var titleWidthConstraint = titleLabel.widthAnchor.constraint(equalToConstant: 0)

    /// Fired after a rename made here has been persisted, so the sidebar row re-titles too.
    var onClipRenamed: ((PracticeClip) -> Void)?

    init(libraryStore: ClipLibraryStore, playbackEngine: PracticePlaybackEngine) {
        self.libraryStore = libraryStore
        self.playbackEngine = playbackEngine
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
        }
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
        // Left non-editable until it is actually clicked (see `ClickToEditTextField`). Leaving it
        // permanently editable made it the window's first key view, so opening a clip put the
        // title straight into edit mode — boxed, focused, with an insertion point nobody asked
        // for (measured: `currentEditor() != nil` before any click).
        titleLabel.isBordered = false
        titleLabel.drawsBackground = false
        titleLabel.delegate = self
        titleLabel.cell?.usesSingleLineMode = true
        titleLabel.cell?.wraps = false
        titleLabel.cell?.isScrollable = true
        titleLabel.toolTip = "Click to rename"

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.isHidden = true

        timeline.translatesAutoresizingMaskIntoConstraints = false
        timelineHeightConstraint.isActive = true

        playPauseButton.target = self
        playPauseButton.action = #selector(togglePlayPause)

        skipBackButton.target = self
        skipBackButton.action = #selector(skipBackward)
        skipForwardButton.target = self
        skipForwardButton.action = #selector(skipForward)

        loopButton.target = self
        loopButton.action = #selector(toggleLoop)

        timeLabel.isHidden = false
        timeLabel.stringValue = "0:00 / 0:00"

        // Back/play/forward read as one cluster, then a wider gap before Loop — which is a mode,
        // not a transport action, and shouldn't look like a fourth button in the same group.
        let playbackCluster = Layout.horizontalStack([skipBackButton, playPauseButton, skipForwardButton], spacing: 4)
        // A nested stack hugs its content only if told to: at the default priority this one soaked
        // up the row's slack and shoved Loop 343pt to the right (measured, and only sometimes —
        // exactly the ambiguity `Layout.flexibleSpacer` exists to remove). The spacer gives the
        // slack a defined home at the end of the row instead.
        playbackCluster.setHuggingPriority(.required, for: .horizontal)
        let transportStack = Layout.horizontalStack(
            [playbackCluster, loopButton, timeLabel, Layout.flexibleSpacer()],
            spacing: WindowUI.Metrics.sectionSpacing
        )

        tempoSlider.isContinuous = true
        tempoSlider.target = self
        tempoSlider.action = #selector(tempoChanged)
        let tempoLabel = SharedUI.fieldLabel("Tempo")
        tempoLabel.widthAnchor.constraint(equalToConstant: WindowUI.Metrics.labelWidth).isActive = true
        let tempoRow = Layout.horizontalStack([tempoLabel, tempoSlider, tempoValueLabel], spacing: WindowUI.Metrics.rowSpacing)
        tempoSlider.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true

        let content = Layout.verticalStack(
            [titleLabel, statusLabel, timeline, transportStack, tempoRow],
            spacing: WindowUI.Metrics.sectionSpacing
        )
        content.setCustomSpacing(4, after: titleLabel)
        content.setCustomSpacing(4, after: statusLabel)

        // `.leading`-aligned stacks pin their arranged subviews' leading edge and nothing else —
        // the same trap `WindowUI.section` documents. `tempoRow` got away with it because it *is* an
        // NSStackView holding a low-hugging NSSlider, so its own arrangement let it fill;
        // `DeckTimelineView` is a plain NSView, which to this stack is an opaque box that gets its
        // fitting width. Measured before this chain (with the old mixer rows, which had the same
        // shape): tempo slider 556.5pt, every stem fader stuck at 140pt — exactly its
        // `greaterThanOrEqualToConstant` floor, in a 671pt-wide pane. The timeline needs the same
        // treatment: its lane canvas is `bounds.width - headerWidth`, so a fitting-width timeline
        // would draw every waveform into a sliver.
        // The title is sized to its own text rather than left to fill the pane. An editable
        // NSTextField reports no intrinsic width (measured: -1, scrollable cell or not), so
        // content hugging can't do this job — the width is measured from the string and kept up
        // to date in `sizeTitleFieldToText`. It matters because the field editor paints its
        // background across the *whole* field: a full-width field turns into a window-wide white
        // box the moment the title is clicked.
        titleWidthConstraint.priority = .defaultHigh
        titleWidthConstraint.isActive = true
        // Required, so a long name truncates at the pane edge instead of running off it.
        titleLabel.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor).isActive = true
        sizeTitleFieldToText(titleLabel.stringValue)
        timeline.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        tempoRow.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true

        let pad = WindowUI.Metrics.padding
        Layout.pin(content, to: view, edges: [.top, .leading, .trailing], insets: NSEdgeInsets(top: pad, left: pad, bottom: 0, right: pad))
        contentStack = content
    }

    private func setupBindings() {
        timeline.onSeek = { [weak self] time in
            self?.playbackEngine.seek(toSeconds: time)
        }
        timeline.onLoopRangeChanged = { [weak self] range in
            guard let self else { return }
            // Trusted to be inside the clip: `DeckTimelineView` clamps a drag's x to the canvas
            // before it becomes a time, and `setLoopRange` stores whatever it is handed.
            self.playbackEngine.setLoopRange(range)
            self.playbackEngine.isLoopEnabled = true
            self.loopButton.state = .on
            self.loopButton.refreshStyle()
            // Jump to the top of the new loop. Without this the playhead stayed wherever it was —
            // so drawing a loop while the clip was playing kept playing straight through the old
            // position until it happened to reach the loop's end, which is the first moment
            // `PracticePlaybackEngine`'s loop check does anything. Unconditional rather than only
            // while playing: a loop drawn while paused should start from its own beginning too.
            self.playbackEngine.seek(toSeconds: range.lowerBound)
        }
        timeline.onStemVolumeChanged = { [weak self] stem, value in
            self?.playbackEngine.setStemVolume(value, for: stem)
        }
        timeline.onStemMuteToggled = { [weak self] stem, muted in
            self?.playbackEngine.setStemMuted(muted, for: stem)
        }
        timeline.onStemSoloToggled = { [weak self] stem in
            self?.playbackEngine.toggleStemSolo(stem)
            self?.refreshMixerButtonStates()
        }
        timeline.onStemExportRequested = { [weak self] stem in
            self?.exportStem(stem)
        }
        playbackEngine.onPlayheadUpdate = { [weak self] time in
            self?.updatePlayhead(time)
        }
        playbackEngine.onPlaybackFinished = { [weak self] in
            self?.showPlayGlyph(true)
        }
    }

    // MARK: - Clip lifecycle

    func show(clip: PracticeClip) {
        self.clip = clip
        isEngineLoaded = false
        lastReloadedReadySeconds = 0
        showEmptyState(false)

        let store = PeakStore(peaksFolder: libraryStore.peaksFolder(forClipID: clip.id))
        peakStore = store
        timeline.show(clipDuration: clip.durationSeconds, peakStore: store)
        backfillPeaksIfNeeded(for: clip)

        refreshForCurrentClip()
        loadPlaybackIfPossible()
    }

    /// Spec §9: clips that predate the sidecar format get theirs generated from the audio already
    /// on disk, on first open, in the background — never eagerly for the whole library, so the cost
    /// is spread and never blocks.
    ///
    /// This is the call site the previous phase shipped without.
    private func backfillPeaksIfNeeded(for clip: PracticeClip) {
        guard !PeakSidecarMigrator.missingTracks(for: clip, libraryStore: libraryStore).isEmpty else { return }
        let libraryStore = self.libraryStore
        DispatchQueue.global(qos: .utility).async {
            let updated = PeakSidecarMigrator.backfill(clip: clip, libraryStore: libraryStore)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.clip?.id == updated.id else { return }
                libraryStore.update(updated)
                self.clip = updated
                self.timeline.refreshPeaks()
                self.updateTimelineHeight()
            }
        }
    }

    /// One lane before separation has produced a stem, four after — see `DeckTimelineView.tracks`.
    private func updateTimelineHeight() {
        timelineHeightConstraint.constant = DeckTimelineView.height(forLaneCount: max(1, timeline.tracks.count))
    }

    func updateClip(_ updated: PracticeClip) {
        guard clip?.id == updated.id else { return }
        clip = updated
        refreshForCurrentClip()
        // Separation has appended to the sidecars. The lane set may grow; the viewport must not
        // move — spec §7.
        timeline.refreshPeaks()
        updateTimelineHeight()

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
            skipBackButton.isEnabled = true
            skipForwardButton.isEnabled = true
        } catch {
            AppLogger.shared.warning("Practice deck load failed: \(error.localizedDescription)")
        }
    }

    private func refreshForCurrentClip() {
        guard let clip else { return }
        // Not while the user is typing in it: background separation ticks call through here every
        // couple of seconds, and each one would otherwise wipe out a half-finished rename.
        if titleLabel.currentEditor() == nil {
            titleLabel.stringValue = clip.title
            sizeTitleFieldToText(clip.title)
        }
        // How much is *playable*, which gates seeking — deliberately not the same as how much has
        // peak data, since peaks can exist for audio the engine has not reloaded yet.
        timeline.readyDuration = clip.readyDurationSeconds
        updateTimelineHeight()
        let playable = clip.readyDurationSeconds > 0 && !clip.processingFailed
        playPauseButton.isEnabled = playable
        skipBackButton.isEnabled = playable
        skipForwardButton.isEnabled = playable

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

        timeline.setExportEnabled(clip.canExportStems)

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
            showPlayGlyph(true)
        } else {
            playbackEngine.play()
            showPlayGlyph(false)
        }
    }

    /// The one place the play/pause glyph is chosen, so the icon can't drift out of step with the
    /// engine the way two separate assignment sites would let it.
    private func showPlayGlyph(_ showPlay: Bool) {
        playPauseButton.setIcon(showPlay ? "play.fill" : "pause.fill", label: showPlay ? "Play" : "Pause")
        playPauseButton.isOn = !showPlay
    }

    @objc private func skipBackward() {
        skip(by: -Self.skipSeconds)
    }

    @objc private func skipForward() {
        skip(by: Self.skipSeconds)
    }

    /// `seek(toSeconds:)` clamps to the clip, and keeps playing if it already was, so a nudge off
    /// either end lands on the boundary rather than stopping.
    private func skip(by seconds: Double) {
        guard clip != nil, isEngineLoaded else { return }
        playbackEngine.seek(toSeconds: playbackEngine.currentTime() + seconds)
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
        timeline.setPlayheadTime(time)
        timeLabel.stringValue = "\(time.formattedAsDuration) / \(clip.durationSeconds.formattedAsDuration)"
    }

    // MARK: - Rename

    /// Width of the title's text plus room for the caret, floored so an empty name still leaves
    /// something to click. Long names hit the required `<= content.width` cap instead.
    private func sizeTitleFieldToText(_ text: String) {
        let font = titleLabel.font ?? .systemFont(ofSize: 18, weight: .semibold)
        let measured = (text as NSString).size(withAttributes: [.font: font]).width
        titleWidthConstraint.constant = max(80, ceil(measured) + 12)
    }

    func controlTextDidChange(_ obj: Notification) {
        // Grows with what's being typed, so the box tracks the name instead of jumping on commit.
        sizeTitleFieldToText(titleLabel.currentEditor()?.string ?? titleLabel.stringValue)
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        titleBeforeEditing = clip?.title ?? titleLabel.stringValue
        // See `control(_:textView:doCommandBy:)`: with completion on, the field editor eats Escape.
        (titleLabel.currentEditor() as? NSTextView)?.isAutomaticTextCompletionEnabled = false
        startWatchingForClicksOutsideTitle()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        stopWatchingForClicksOutsideTitle()
        titleLabel.stopEditing()
        commitTitleEdit()
    }

    /// Persists whatever is in the field now. Idempotent: it compares against the title the edit
    /// started from, so the end-editing notification that follows Return (or Escape) is a no-op.
    private func commitTitleEdit() {
        guard let clip else { return }
        let newTitle = titleLabel.stringValue
        guard newTitle != titleBeforeEditing else { return }
        guard let updated = libraryStore.rename(id: clip.id, to: newTitle) else {
            titleLabel.stringValue = titleBeforeEditing
            return
        }
        self.clip = updated
        titleBeforeEditing = updated.title
        titleLabel.stringValue = updated.title
        sizeTitleFieldToText(updated.title)
        onClipRenamed?(updated)
    }

    /// Clicking a button, a fader or the waveform doesn't move focus on macOS, so without this the
    /// title would stay in edit mode — visibly boxed — while the user carried on using the deck.
    private func startWatchingForClicksOutsideTitle() {
        stopWatchingForClicksOutsideTitle()
        outsideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let window = self.view.window, event.window === window else { return event }
            self.endTitleEditingIfClickIsOutside(event.locationInWindow)
            return event
        }
    }

    /// The deck's own views are private; this is the one the timeline tests need to reach.
    var timelineForTesting: DeckTimelineView { timeline }

    /// Split out from the monitor so the rule can be exercised directly.
    func endTitleEditingIfClickIsOutside(_ locationInWindow: NSPoint) {
        let point = titleLabel.convert(locationInWindow, from: nil)
        guard !titleLabel.bounds.contains(point) else { return }
        endTitleEditing()
    }

    private func stopWatchingForClicksOutsideTitle() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
        }
        outsideClickMonitor = nil
    }

    /// Escape abandons the edit, Return commits it, and both leave editing entirely.
    ///
    /// `complete(_:)` is handled alongside `cancelOperation(_:)` on purpose: the field editor's
    /// automatic text completion claims the first Escape and turns it into a completion request,
    /// so a handler that only watches for `cancelOperation(_:)` never runs and Escape appears to
    /// do nothing. (`controlTextDidBeginEditing` also switches completion off, so this is the
    /// belt to that braces.)
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.cancelOperation(_:)), #selector(NSStandardKeyBindingResponding.complete(_:)):
            titleLabel.stringValue = titleBeforeEditing
            sizeTitleFieldToText(titleBeforeEditing)
            endTitleEditing()
            return true
        case #selector(NSResponder.insertNewline(_:)):
            commitTitleEdit()
            endTitleEditing()
            return true
        default:
            return false
        }
    }

    /// Drops focus so the editing background goes away. Plain `makeFirstResponder(nil)` would do
    /// it, but only when the field still holds focus — calling it otherwise would yank focus from
    /// whatever the user just clicked on.
    private func endTitleEditing() {
        guard let window = view.window, window.firstResponder === titleLabel.currentEditor() else { return }
        window.makeFirstResponder(nil)
    }

    /// A rename that happened in the sidebar. Deliberately *not* routed through `updateClip`:
    /// that one may reload the playback engine, and re-titling a clip has no business
    /// interrupting playback.
    func applyRenamedClip(_ updated: PracticeClip) {
        guard clip?.id == updated.id else { return }
        clip = updated
        if titleLabel.currentEditor() == nil {
            titleLabel.stringValue = updated.title
            sizeTitleFieldToText(updated.title)
        }
    }

    // MARK: - Stem export

    /// Exports the stem exactly as separated — fader, mute, solo and tempo are all playback state
    /// and deliberately don't reach the file. What lands on disk is what the model produced.
    private func exportStem(_ stem: SeparationStem) {
        guard let clip, clip.canExportStems,
              let fileName = clip.stemFileNames[stem.rawValue] else { return }
        let source = libraryStore.stemFileURL(clipID: clip.id, fileName: fileName)

        let preferences = Preferences()
        let export = StemExportPanel(
            clipTitle: clip.title,
            stem: stem,
            format: preferences.stemExportFormat
        )

        let completion: (NSApplication.ModalResponse) -> Void = { response in
            // Referenced so the closure holds `export` until the sheet closes:
            // `NSPopUpButton.target` is unowned, and without this the panel's format popup stops
            // responding the moment `exportStem` returns.
            let format = export.format
            guard response == .OK, let destination = export.panel.url else { return }
            preferences.stemExportFormat = format
            self.performExport(source: source, destination: destination, format: format)
        }

        if let window = view.window {
            export.panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            export.panel.begin(completionHandler: completion)
        }
    }

    private func performExport(source: URL, destination: URL, format: StemExportFormat) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try StemExportService.export(source: source, to: destination, format: format)
            } catch {
                DispatchQueue.main.async { self.presentExportFailure(error) }
            }
        }
    }

    private func presentExportFailure(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Couldn't export that stem"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private func refreshMixerButtonStates() {
        timeline.setSoloedStem(playbackEngine.mixer.soloedStem)
    }

}

/// A title that reads as a label and becomes a text field when clicked.
///
/// The alternative — an always-editable `NSTextField` styled to look like a label — puts the
/// field in the window's key view loop, so it collects focus the moment the window opens and
/// paints its editing background before anyone has asked to rename anything. Refusing first
/// responder until a click arrives is what keeps it a label the rest of the time.
private final class ClickToEditTextField: NSTextField {
    override var acceptsFirstResponder: Bool { isEditable }

    override func mouseDown(with event: NSEvent) {
        if !isEditable {
            isEditable = true
            isSelectable = true
            drawsBackground = true
            backgroundColor = .textBackgroundColor
            focusRingType = .default
            window?.makeFirstResponder(self)
        }
        // Forwarded, not swallowed: this is what puts the insertion point where the user clicked.
        super.mouseDown(with: event)
    }

    /// Back to label chrome. Called when editing ends, whatever ended it.
    func stopEditing() {
        isEditable = false
        isSelectable = false
        drawsBackground = false
        focusRingType = .none
    }
}
