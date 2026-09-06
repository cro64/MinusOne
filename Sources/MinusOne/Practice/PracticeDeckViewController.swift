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
    /// Clips whose peak backfill is already running. `show(clip:)` can be called twice in a row
    /// for the same clip (the import path selects the row *and* shows it), and two concurrent
    /// `PeakSidecarWriter`s on one path interleave their columns into a file whose length still
    /// looks complete.
    private var backfillsInFlight: Set<UUID> = []

    private let emptyStateView = PracticeEmptyStateView()
    /// Editable in place — clicking the clip's title here is one of the two ways to rename it
    /// (the other is the sidebar row's double-click / Rename… menu).
    private let titleLabel = ClickToEditTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let timeline = DeckTimelineView()
    private let preferences = Preferences()
    private let heroWaveformView = HeroWaveformView(frame: .zero)
    private let heroResizeHandle = HeroResizeHandleView(frame: .zero)
    private var heroContainer: NSStackView?
    private lazy var heroHeightConstraint = heroWaveformView.heightAnchor.constraint(equalToConstant: CGFloat(preferences.heroWaveformHeight))
    private let heroToggleButton = FlatButton(title: "", kind: .secondary, target: nil, action: nil)
    private let toolbar = TimelineToolbarView()
    private var tapTempo = TapTempo()
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

        heroToggleButton.setButtonType(.pushOnPushOff)
        heroToggleButton.imagePosition = .imageOnly
        heroToggleButton.imageScaling = .scaleProportionallyDown
        heroToggleButton.setIcon("waveform", pointSize: 11, label: "Show hero waveform")
        heroToggleButton.cornerStyle = .capsule
        heroToggleButton.layer?.borderWidth = 0
        heroToggleButton.constrainSize(width: 20, height: 20)
        heroToggleButton.target = self
        heroToggleButton.action = #selector(toggleHeroWaveform)

        heroWaveformView.translatesAutoresizingMaskIntoConstraints = false
        heroResizeHandle.translatesAutoresizingMaskIntoConstraints = false
        heroResizeHandle.onDrag = { [weak self] delta in self?.heroResizeHandleDragged(byDeltaY: delta) }
        heroHeightConstraint.isActive = true
        // 4pt, not a rounder 8: `HeroWaveformView.maximumHeight` (53) was sized against the deck's
        // real measured layout at `WindowSizing.minimum` with this handle at exactly this height —
        // see that constant's doc comment, which also covers why the budget now accounts for
        // `statusLabel` being visible, not just hidden. Widening this strip without also lowering
        // `maximumHeight` reopens that margin.
        heroResizeHandle.heightAnchor.constraint(equalToConstant: 4).isActive = true

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

        // Back/play/forward read as one cluster, distinct from Loop — which is a mode, not a
        // transport action, and shouldn't look like a fourth button in the same group. The gap
        // before Loop (`controlBarSpacing`, 8pt) is wider than this cluster's own 4pt, which is
        // what makes the cluster read as one unit rather than four buttons in a row.
        let playbackCluster = Layout.horizontalStack([skipBackButton, playPauseButton, skipForwardButton], spacing: 4)
        // Required, not the stack's own default: `controlBar`'s slack is meant to be absorbed by
        // `Layout.flexibleSpacer()` alone. Without this, a nested stack like this one is a
        // candidate to absorb it instead — measured once at ~343pt, which shoved a sibling control
        // that far off its intended position with nothing on screen to explain why.
        playbackCluster.setHuggingPriority(.required, for: .horizontal)

        tempoSlider.isContinuous = true
        tempoSlider.target = self
        tempoSlider.action = #selector(tempoChanged)
        let tempoLabel = SharedUI.fieldLabel("Speed")
        // Tighter than `WindowUI.Metrics.rowSpacing` (8pt) and `controlBarSpacing` (8pt) both — see
        // `controlBarSpacing`'s comment on `controlBar` below for why this cluster's own fields must
        // stay more tightly grouped than the gap separating the cluster from its neighbours.
        let speedCluster = Layout.horizontalStack([tempoLabel, tempoSlider, tempoValueLabel], spacing: 5)
        // Same reason as `playbackCluster`'s hugging priority above: left at the default, this
        // nested stack could absorb `controlBar`'s slack instead of `Layout.flexibleSpacer()`.
        speedCluster.setHuggingPriority(.required, for: .horizontal)
        // Fixed, not `greaterThanOrEqualToConstant` — a small control paired with BPM/Tap in the
        // control bar, not a row that owns the deck's full width the way it used to.
        tempoSlider.widthAnchor.constraint(equalToConstant: 96).isActive = true

        // One control bar: playback transport on the left, BPM/Tap + Speed on the right, so the
        // deck's two tempo concepts (the musical grid and the playback rate) sit next to each other
        // instead of on opposite ends of the deck. Replaces what used to be two separate rows (the
        // transport, and a full-width "Tempo" slider) plus the toolbar's own row above the ruler.
        //
        // This is the gap *between* `controlBar`'s six arranged views, so it must stay >= every
        // internal gap inside those views (`playbackCluster`'s 4pt, `toolbar`'s 5pt, `speedCluster`'s
        // 5pt) or the clusters stop reading as distinct groups. `WindowUI.Metrics.rowSpacing` (8pt),
        // not `sectionSpacing` (16pt): `controlBar` no longer stretches to the pane's full width (see
        // the `.leading`-stack comment below), so 16pt is no longer forced open by a flexible spacer
        // soaking up the whole pane's slack — it would just be 16pt of dead air the bar doesn't need.
        let controlBarSpacing: CGFloat = 8
        let controlBar = Layout.horizontalStack(
            [playbackCluster, loopButton, timeLabel, Layout.flexibleSpacer(), toolbar, speedCluster],
            spacing: controlBarSpacing
        )

        let titleRow = Layout.horizontalStack([titleLabel, heroToggleButton], spacing: 8)
        let heroStack = Layout.verticalStack([heroWaveformView, heroResizeHandle], spacing: 0)
        heroContainer = heroStack

        let content = Layout.verticalStack(
            [titleRow, statusLabel, heroStack, timeline, controlBar],
            spacing: WindowUI.Metrics.sectionSpacing
        )
        content.setCustomSpacing(4, after: titleRow)
        content.setCustomSpacing(4, after: statusLabel)

        // `.leading`-aligned stacks pin their arranged subviews' leading edge and nothing else —
        // the same trap `WindowUI.section` documents. `DeckTimelineView` is a plain NSView, which to
        // this stack is an opaque box that gets its fitting width, so `timeline` needs an explicit
        // equal-width constraint below or its lane canvas (`bounds.width - headerWidth`) draws every
        // waveform into a sliver. Measured before this chain (with the old mixer rows, which had the
        // same shape): tempo slider 556.5pt, every stem fader stuck at 140pt — exactly its
        // `greaterThanOrEqualToConstant` floor, in a 671pt-wide pane.
        //
        // `controlBar` deliberately does NOT get the same treatment. An earlier version forced it to
        // `content`'s full width with `Layout.flexibleSpacer()` absorbing the slack — which reads
        // fine on paper, but at any window wider than the bar's own fitting width it puts the whole
        // gap in one place: the playback cluster hugs the left edge, BPM/Tap/Speed hug the right, and
        // a single wide gash of empty space sits between them, while every visible gap in the bar
        // stays at its tight fixed spacing regardless of how much room the window actually has. Left
        // unconstrained, `controlBar` instead sits at its own comfortable fitting width, pinned only
        // by its leading edge (inherited from `content`'s `.leading` alignment) — the same width at
        // every window size, with no window-width-dependent gap to look wrong. It still has to fit
        // within what `WindowSizing.minimum` gives the deck pane (632pt); see
        // `WindowSizingTests.testTheControlBarFitsTheMinimumWindowWidth`, which measures the real
        // fitting width against that budget rather than asserting a literal.
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
        heroStack.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        heroWaveformView.widthAnchor.constraint(equalTo: heroStack.widthAnchor).isActive = true
        heroResizeHandle.widthAnchor.constraint(equalTo: heroStack.widthAnchor).isActive = true
        titleRow.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor).isActive = true

        let pad = WindowUI.Metrics.padding
        Layout.pin(content, to: view, edges: [.top, .leading, .trailing], insets: NSEdgeInsets(top: pad, left: pad, bottom: 0, right: pad))
        contentStack = content
        applyHeroWaveformVisibility()
    }

    private func setupBindings() {
        timeline.onSeek = { [weak self] time in
            self?.playbackEngine.seek(toSeconds: time)
        }
        heroWaveformView.onSeek = { [weak self] time in
            self?.playbackEngine.seek(toSeconds: time)
        }
        heroWaveformView.onVisibleRangePanned = { [weak self] startTime in
            self?.timeline.scrollVisibleWindow(toStartTime: startTime)
        }
        timeline.onViewportChanged = { [weak self] viewport in
            self?.heroWaveformView.visibleRange = viewport.startTime...viewport.endTime
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
        timeline.mixerState = { [weak self] stem in
            guard let mixer = self?.playbackEngine.mixer else { return (1, false, false) }
            return (mixer.volume(for: stem), mixer.isMuted(stem), mixer.isSoloed(stem))
        }
        playbackEngine.onPlayheadUpdate = { [weak self] time in
            self?.updatePlayhead(time)
        }
        playbackEngine.onPlaybackFinished = { [weak self] in
            self?.showPlayGlyph(true)
        }
        timeline.onBeatGridEdited = { [weak self] grid in
            self?.persistEditedBeatGrid(grid)
        }
        toolbar.onBPMEdited = { [weak self] bpm in
            guard let self else { return }
            let grid = BeatGrid(bpm: bpm, downbeatOffsetSeconds: self.timeline.beatGrid?.downbeatOffsetSeconds ?? 0)
            self.timeline.beatGrid = grid
            self.persistEditedBeatGrid(grid)
        }
        toolbar.onTapped = { [weak self] in
            guard let self, let bpm = self.tapTempo.tap(at: Date().timeIntervalSinceReferenceDate) else { return }
            let grid = BeatGrid(bpm: bpm, downbeatOffsetSeconds: self.timeline.beatGrid?.downbeatOffsetSeconds ?? 0)
            self.timeline.beatGrid = grid
            // `grid.bpm`, not the raw tap result — see `BeatGrid.init`'s 1...400 clamp. Showing the
            // raw number would leave the field disagreeing with the grid, the ruler and the
            // persisted clip.
            self.toolbar.setBPM(grid.bpm)
            self.persistEditedBeatGrid(grid)
        }
    }

    // MARK: - Clip lifecycle

    func show(clip: PracticeClip) {
        self.clip = clip
        isEngineLoaded = false
        lastReloadedReadySeconds = 0
        showEmptyState(false)
        clearLoop()

        let store = PeakStore(peaksFolder: libraryStore.peaksFolder(forClipID: clip.id))
        timeline.show(clipDuration: clip.durationSeconds, peakStore: store)
        heroWaveformView.show(clipDuration: clip.durationSeconds, peakStore: store)
        heroWaveformView.visibleRange = timeline.viewport.startTime...timeline.viewport.endTime
        applyBeatGrid(from: clip)
        updateTimelineHeight()
        backfillPeaksIfNeeded(for: clip)

        refreshForCurrentClip()
        loadPlaybackIfPossible()
    }

    /// Spec §9: clips that predate the sidecar format get theirs generated from the audio already
    /// on disk, on first open, in the background — never eagerly for the whole library, so the cost
    /// is spread and never blocks. Spec §9 also flags that this path must run beat detection: it is
    /// the other place an existing clip's audio is read from disk, since `detectBeatGrid`'s only
    /// other trigger is a separation run finishing, which an already-separated legacy clip will
    /// never do again.
    private func backfillPeaksIfNeeded(for clip: PracticeClip) {
        guard !PeakSidecarMigrator.missingTracks(for: clip, libraryStore: libraryStore).isEmpty else { return }
        guard !backfillsInFlight.contains(clip.id) else { return }
        backfillsInFlight.insert(clip.id)
        let libraryStore = self.libraryStore
        DispatchQueue.global(qos: .utility).async {
            let peaksUpdated = PeakSidecarMigrator.backfill(clip: clip, libraryStore: libraryStore)
            let separationEngine = OfflineSeparationEngine(libraryStore: libraryStore)
            let updated = separationEngine.detectBeatGrid(for: separationEngine.withCurrentBeatGrid(peaksUpdated))
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.backfillsInFlight.remove(updated.id)
                guard self.clip?.id == updated.id else { return }
                // Re-read rather than writing back the snapshot this closure captured: the decode
                // above takes seconds, `ClipLibraryStore.update` is a whole-record replace, and
                // separation's flush loop may have advanced `readyDurationSeconds` and
                // `stemFileNames` in the meantime. Only the peak file names and (when nothing else
                // has since claimed the grid) the beat grid are ours to contribute.
                guard var current = libraryStore.clip(withID: updated.id) else { return }
                current.peakFileNames = updated.peakFileNames
                if !current.isBeatGridUserSet {
                    current.bpm = updated.bpm
                    current.downbeatOffsetSeconds = updated.downbeatOffsetSeconds
                    current.beatConfidence = updated.beatConfidence
                }
                libraryStore.update(current)
                self.clip = current
                self.timeline.refreshPeaks()
                self.heroWaveformView.refreshPeaks()
                self.applyBeatGrid(from: current)
                self.updateTimelineHeight()
            }
        }
    }

    /// Builds the timeline's grid from what the clip stores, or clears it when there is none.
    ///
    /// A clip carries `bpm` only when detection cleared the confidence threshold or the user set it
    /// by hand, so `nil` here is the honest "no grid" state spec §6 requires — not a default.
    private func applyBeatGrid(from clip: PracticeClip) {
        guard let bpm = clip.bpm else {
            timeline.beatGrid = nil
            toolbar.setBPM(nil)
            return
        }
        timeline.beatGrid = BeatGrid(bpm: bpm, downbeatOffsetSeconds: clip.downbeatOffsetSeconds ?? 0)
        toolbar.setBPM(bpm)
    }

    /// The one place any beat-grid edit — a downbeat drag, a typed BPM, or a tap — gets persisted.
    /// Spec §6: an explicit flag, never a magic confidence value; a hand-set grid is marked so
    /// detection never overwrites it, and its stale confidence is dropped since it no longer
    /// describes a detection.
    private func persistEditedBeatGrid(_ grid: BeatGrid) {
        guard var clip else { return }
        clip.bpm = grid.bpm
        clip.downbeatOffsetSeconds = grid.downbeatOffsetSeconds
        clip.beatConfidence = nil
        clip.isBeatGridUserSet = true
        self.clip = clip
        self.libraryStore.update(clip)
    }

    /// Drops the loop when the deck moves to a different clip.
    ///
    /// A loop belongs to the clip it was drawn on. `PracticePlaybackEngine.tearDown()` resets the
    /// players, the playhead and `isPlaying`, but deliberately not `loopRangeSeconds` or
    /// `isLoopEnabled` — and `DeckTimelineView.show(clipDuration:peakStore:)` clears the drawn band.
    /// Without this the engine would keep wrapping at a time the new clip does not show: draw a loop
    /// at 2:00 on a long clip, switch to a 30-second one, and playback still jumps with nothing on
    /// screen to explain it.
    ///
    /// Deliberately here rather than in the engine's own teardown: `reload(clip:libraryStore:)` also
    /// tears down, and it runs on *every* separation tick, so clearing there would wipe a loop the
    /// user drew moments earlier while their clip was still separating.
    private func clearLoop() {
        // isLoopEnabled's didSet reads loopRangeSeconds to compute the pre-change playhead — it
        // must still see the real range, so this flips before setLoopRange(nil) clears it. Doing it
        // the other way around (as this once did) hands didSet a nil range while the loop is still
        // conceptually active, so filePosition falls back to the unwrapped elapsed sample time —
        // after several loop iterations a large, effectively garbage position — and
        // rescheduleForLoopChange then reschedules the outgoing clip's own files there.
        playbackEngine.isLoopEnabled = false
        playbackEngine.setLoopRange(nil)
        loopButton.state = .off
        loopButton.refreshStyle()
    }

    /// One lane before separation has produced a stem, four after — see `DeckTimelineView.tracks`.
    ///
    /// Called from exactly the three places that can change the track set, each time immediately
    /// after the call that changes it: `show(clip:)`'s `timeline.show`, the backfill's
    /// `refreshPeaks`, and `updateClip`'s `refreshPeaks`. Deliberately *not* called from
    /// `refreshForCurrentClip()`, which also runs on every separation tick before the peaks have
    /// been reloaded — it would measure a stale track count and then be corrected a line later.
    private func updateTimelineHeight() {
        timelineHeightConstraint.constant = DeckTimelineView.height(forLaneCount: max(1, timeline.tracks.count))
    }

    private func applyHeroWaveformVisibility() {
        let enabled = preferences.heroWaveformEnabled
        heroContainer?.isHidden = !enabled
        heroToggleButton.state = enabled ? .on : .off
        heroToggleButton.refreshStyle()
    }

    @objc private func toggleHeroWaveform() {
        preferences.heroWaveformEnabled = heroToggleButton.state == .on
        applyHeroWaveformVisibility()
    }

    private func heroResizeHandleDragged(byDeltaY deltaY: CGFloat) {
        let proposed = heroHeightConstraint.constant + deltaY
        let clamped = min(max(proposed, HeroWaveformView.minimumHeight), HeroWaveformView.maximumHeight)
        heroHeightConstraint.constant = clamped
        preferences.heroWaveformHeight = Double(clamped)
    }

    func updateClip(_ updated: PracticeClip) {
        guard clip?.id == updated.id else { return }
        clip = updated
        refreshForCurrentClip()
        // Separation has appended to the sidecars. The lane set may grow; the viewport must not
        // move — spec §7.
        timeline.refreshPeaks()
        heroWaveformView.refreshPeaks()
        applyBeatGrid(from: updated)
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
        heroWaveformView.playheadTime = time
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

    /// The hero waveform, for Task 8's layout test.
    var heroWaveformViewForTesting: HeroWaveformView { heroWaveformView }

    /// The hero height constraint, for Task 8's layout test to override with maximum height.
    var heroHeightConstraintForTesting: NSLayoutConstraint { heroHeightConstraint }

    /// The status label above the timeline, so a window-sizing test can make it visible with real
    /// content the way `refreshForCurrentClip()` does whenever a clip is still separating — the
    /// state the fixed-height layout budget must actually account for.
    var statusLabelForTesting: NSTextField { statusLabel }

    /// The BPM/Tap toolbar, for the same reason.
    var toolbarForTesting: TimelineToolbarView { toolbar }

    /// The playback-speed slider, so a test can confirm it stays a small fixed-width control
    /// rather than stretching across the deck the way it used to.
    var speedSliderForTesting: NSSlider { tempoSlider }

    /// The deck's playback engine, for tests that need to drive mixer state directly.
    var playbackEngineForTesting: PracticePlaybackEngine { playbackEngine }

    /// The Loop toggle's visible state — the half of the loop that the user actually sees.
    var isLoopButtonOnForTesting: Bool { loopButton.state == .on }

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
