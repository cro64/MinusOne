import AppKit

/// The window's starting size and its true floor, kept apart.
///
/// They used to be one value: `minSize` was set to the default because AppKit re-fits the window
/// from the installed tab's constraints, so lowering the floor shrank Practice rather than merely
/// permitting a smaller window (measured: at 860×560, Practice opened at 860×560). Phase 2 sets
/// the content size explicitly after the Practice tab is installed, which is what lets the floor
/// be a floor.
enum WindowSizing {
    /// Spec §8: 1120 wide leaves ~680pt of lane canvas at a 260pt sidebar; 760 tall carries the
    /// ruler, four 72pt lanes, the scroll indicator, transport and tempo.
    static let defaultContent = NSSize(width: 1120, height: 760)
    static let minimum = NSSize(width: 900, height: 600)
}

/// The title bar's leading slot holds either the back button or the sidebar toggle, never both:
/// the back button only appears on takeover pages, where the split view the toggle acts on is not
/// on screen. Extracted as a pure rule so it can be tested without building a window.
enum HeaderChrome {
    static func showsSidebarToggle(showsBack: Bool, onPractice: Bool) -> Bool {
        !showsBack && onPractice
    }
}

/// Owns the desktop window: a Live / Practice segmented switch in a content-area header, and the
/// two tabs' content. Live embeds `LiveTabViewController`, a full-width window-filling view (REDESIGN.md
/// §3); Practice embeds the existing sidebar + deck split view, reused as-is per REDESIGN.md §1.
///
/// MinusOne is a regular app (Dock icon, Cmd-Tab entry) at all times; closing this window (red
/// traffic light / ⌘W) hides it without quitting — Live/Recording keep running. Only Quit in the
/// menu bar popover or the app menu fully quits.
final class MainWindowController: NSWindowController, NSWindowDelegate {
    enum Tab: Int {
        case live = 0
        case practice = 1
    }

    /// What the window is currently showing. `Tab` alone was enough while the two tabs were the
    /// only content, but onboarding and now the Record page are *takeovers*: they hide the
    /// Live/Practice switch and own the whole content area. Tracking them here rather than as ad
    /// hoc booleans is what keeps `updateLiveStatus` — which fires on every engine status change,
    /// from outside any of this — from re-showing tab chrome on top of a takeover page.
    private enum Page: Equatable {
        case tab(Tab)
        case onboarding
        case record
    }

    private let preferences: Preferences
    private let audioEngine: AudioEngine

    private let liveViewController: LiveTabViewController
    private let practiceSplitViewController: PracticeSplitViewController
    private let practiceTabViewController: PracticeTabViewController
    private let sidebar: ClipSidebarViewController
    private let deck: PracticeDeckViewController
    private let importService: ClipImportService

    /// Height reserved at the top of the content for the header. With `.fullSizeContentView` the
    /// traffic lights float over the content rather than sitting in a strip of their own, so this
    /// has to stay tall enough to clear them — they occupy roughly the top 20pt.
    static let headerHeight: CGFloat = 38

    /// Leading inset for the header's `<`. `headerRow`'s leading edge is not free space — with
    /// `.fullSizeContentView` the traffic lights float inside it. Measured on a window built with
    /// this exact style mask: close/miniaturize/zoom are 14×14 at x=9/32/55, so the cluster ends at
    /// x=69, and vertically they sit 9pt from the top, which a 24pt button centered in a 38pt
    /// header overlaps. 80 clears the zoom button by 11pt. It does *not* line up with the 24pt
    /// content padding below — nothing can, on this edge.
    private static let backButtonLeadingInset: CGFloat = 80
    /// In full screen the traffic lights are gone, so the leading slot can line up with the
    /// content's own padding instead of clearing them.
    private static let fullScreenLeadingInset: CGFloat = WindowUI.Metrics.padding
    private var leadingSlotConstraints: [NSLayoutConstraint] = []

    /// Holds the window at its current size against the tabs' own constraints. AppKit sizes a
    /// window from its content's constraints, and only priorities *below* 500 (stay-put) lose to
    /// them — Live's 980pt width preference (800) and the cards' 750 hugging both win, so a tab
    /// swap resized the window: to 980 at launch, and in full screen to a 980pt page inside a
    /// screen-sized window. These sit above every tab constraint and are re-pointed at the window's
    /// real size on each resize, so they never fight the user, full screen or `setContentSize`.
    private lazy var sizeLock: (width: NSLayoutConstraint, height: NSLayoutConstraint) = {
        let width = contentContainer.widthAnchor.constraint(equalToConstant: WindowSizing.defaultContent.width)
        let height = contentContainer.heightAnchor.constraint(equalToConstant: WindowSizing.defaultContent.height)
        width.priority = .init(900)
        height.priority = .init(900)
        return (width, height)
    }()

    func windowDidResize(_ notification: Notification) {
        guard let size = window?.contentView?.frame.size, size.width > 0 else { return }
        sizeLock.width.constant = size.width
        sizeLock.height.constant = size.height
    }

    private let contentContainer = ThemedView(fill: .windowBackgroundColor)
    private let contentRootViewController = NSViewController()
    /// Top strip of the content view holding the theme/status/tab cluster. Deliberately *not* a
    /// title bar accessory and deliberately unpainted: it shares `contentContainer`'s background,
    /// so there is no chrome band separating it from the tab content below.
    private let headerRow = AutoLayoutView()
    /// Everything below `headerRow` — the swappable Live/Practice content.
    private let tabContentContainer = AutoLayoutView()
    private var currentContentViewController: NSViewController?
    private let segmentedControl = FlatSegmentedControl(titles: ["Live", "Practice"])
    private let liveStatusDot = ThemedView(fill: .tertiaryLabelColor)
    /// Icon-only round button that cycles System → Light → Dark. Lives in the title bar to the left
    /// of the Live/Practice switch rather than inside a tab, since the theme applies to the whole
    /// app and shouldn't be reachable from only one of the two tabs.
    private let appearanceButton = FlatButton(title: "", kind: .ghost)
    /// Leading-edge `<`. Only visible on takeover pages, where there's no tab switch to leave by.
    private let backButton = FlatButton(title: "", kind: .ghost)
    /// The one way to bring the library sidebar back after dragging its divider shut collapses it
    /// — a collapsed divider has no width left to grab, so this is not just a convenience. It
    /// lives up here rather than beside the deck's title because it is window chrome, not a clip
    /// action: it has to outlive the pane it hides.
    private let sidebarToggleButton = FlatButton(title: "", kind: .ghost, target: nil, action: nil)
    private var currentPage: Page = .tab(.live)
    /// The tab to return to when a takeover page is dismissed.
    private var currentTab: Tab = .live
    private var onboardingViewController: OnboardingViewController?

    private var clipRecorderBox: Any?
    private var recordPageViewControllerBox: Any?

    var onWindowClosed: (() -> Void)?

    init(
        preferences: Preferences,
        audioEngine: AudioEngine,
        libraryStore: ClipLibraryStore,
        importService: ClipImportService,
        playbackEngine: PracticePlaybackEngine
    ) {
        self.preferences = preferences
        self.audioEngine = audioEngine
        self.importService = importService
        liveViewController = LiveTabViewController(preferences: preferences, audioEngine: audioEngine)
        sidebar = ClipSidebarViewController(libraryStore: libraryStore)
        deck = PracticeDeckViewController(libraryStore: libraryStore, playbackEngine: playbackEngine)
        practiceSplitViewController = PracticeSplitViewController(sidebar: sidebar, detail: deck)
        practiceTabViewController = PracticeTabViewController(
            splitViewController: practiceSplitViewController,
            sidebar: sidebar
        )

        let defaultContentSize = WindowSizing.defaultContent
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: defaultContentSize),
            // `.fullSizeContentView` so the content view extends up behind the title bar instead of
            // starting below it. Together with `titlebarAppearsTransparent` this removes the thin
            // chrome strip the Live/Practice switch used to sit in — the window becomes one
            // continuous surface with the traffic lights floating over it. `.titled` stays: it is
            // what provides the traffic lights, drag-to-move and the standard resize behaviour, all
            // of which a borderless window would have to reimplement by hand.
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // Title text is hidden (the header carries the Live/Practice switch instead), but the
        // title itself stays set for accessibility and Mission Control.
        window.title = "MinusOne"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // A real floor, not the default size. Four lanes plus chrome need 574pt, so nothing has
        // to compress at 600 — see `TimelineMetrics.laneHeight` for why §8's lane floor is not built.
        window.contentMinSize = WindowSizing.minimum
        window.collectionBehavior.insert(.fullScreenPrimary)
        // Explicit, not just relying on NSWindow's defaults: an ambiguous/false isOpaque or clear
        // backgroundColor is exactly what makes the Dock show through the window at the edges.
        window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor
        window.center()

        super.init(window: window)
        window.delegate = self

        // As in `RecordingPanelController`: `ThemedView` defaults this to `false`, but a window's
        // content view is sized by AppKit through its frame, not by constraints of its own.
        contentContainer.translatesAutoresizingMaskIntoConstraints = true
        contentRootViewController.view = contentContainer
        window.contentViewController = contentRootViewController
        NSLayoutConstraint.activate([sizeLock.width, sizeLock.height])

        configureHeader()
        configureLiveTab()
        configurePracticeTab()

        sidebar.onSelectClip = { [weak self] clip in self?.deck.show(clip: clip) }
        // Renaming is available on both sides of the split, so each side has to tell the other.
        sidebar.onRenameClip = { [weak self] clip in self?.deck.applyRenamedClip(clip) }
        sidebar.onDeleteClip = { [weak self] id in self?.deck.clipWasDeleted(id: id) }
        deck.onClipRenamed = { [weak self] clip in self?.sidebar.upsertClip(clip) }
        deck.onPlaybackStateChanged = { [weak self] clipID, isPlaying in
            self?.sidebar.setPlayingClip(id: isPlaying ? clipID : nil)
        }
        sidebar.onDropFiles = { [weak self] urls in
            urls.forEach { self?.handleImport(url: $0) }
        }
        sidebar.reloadClips()

        if !presentOnboardingIfNeeded() {
            showTab(.live)
        }

        // Last, deliberately. AppKit re-fits the window from whatever content is installed, and
        // `showTab`/`presentOnboardingIfNeeded` both swap the content view controller through
        // containment — so setting the size before them lets their fit overwrite it, which is the
        // mechanism that welded `minSize` to the default size in the first place. This is the final
        // word on the opening size; the floor above is what permits shrinking afterwards.
        window.setContentSize(WindowSizing.defaultContent)
        window.center()
        // After the default frame, so a saved size and position win when there is one and the
        // default above is what a first launch gets. AppKit clamps a restored frame to `contentMinSize`.
        window.setFrameAutosaveName("MinusOneMainWindow")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(tab: Tab = .live) {
        showTab(tab)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func updateLiveStatus(_ status: AudioEngineStatus, isFilterActive: Bool) {
        liveViewController.updateStatusDisplay(status, isFilterActive: isFilterActive)
        liveStatusDot.fillColor = isFilterActive ? .brandAccentDeep : .tertiaryLabelColor
        // Gated on the whole page, not just the tab. This fires on every engine status change from
        // outside the navigation, and reading `currentTab` alone would pop the dot back up on top
        // of a takeover page that had deliberately hidden it.
        liveStatusDot.isHidden = currentPage != .tab(.practice)
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        leadingSlotConstraints.forEach { $0.constant = Self.fullScreenLeadingInset }
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        leadingSlotConstraints.forEach { $0.constant = Self.backButtonLeadingInset }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        onboardingViewController?.handleWindowShouldClose() ?? true
    }

    func windowWillClose(_ notification: Notification) {
        onWindowClosed?()
    }

    // MARK: - Onboarding

    /// First launch (REDESIGN.md §5): the window opens directly into onboarding instead of the
    /// Live/Practice tabs, since the Neural model download is now mandatory-framed rather than a
    /// skippable step. Returns `true` if onboarding content was shown.
    @discardableResult
    private func presentOnboardingIfNeeded() -> Bool {
        guard !preferences.hasCompletedOnboarding else { return false }

        let onboarding = OnboardingController.makeViewController(preferences: preferences) { [weak self] _ in
            self?.finishOnboarding()
        }
        onboardingViewController = onboarding
        window?.toolbar = nil

        // No back affordance: onboarding is the one takeover you can't leave without finishing it.
        currentPage = .onboarding
        applyHeaderChrome(showsBack: false)
        setContent(onboarding)
        return true
    }

    private func finishOnboarding() {
        onboardingViewController = nil
        liveViewController.reloadFromPreferences()
        showTab(.live)
    }

    /// Single place that decides which header controls a page gets, so the two takeovers
    /// (onboarding, Record) can't drift apart on what they hide.
    private func applyHeaderChrome(showsBack: Bool) {
        let isTab = !showsBack && currentPage != .onboarding
        let onPractice = currentPage == .tab(.practice)
        backButton.isHidden = !showsBack
        segmentedControl.isHidden = !isTab
        liveStatusDot.isHidden = !onPractice
        sidebarToggleButton.isHidden = !HeaderChrome.showsSidebarToggle(showsBack: showsBack, onPractice: onPractice)
    }

    /// Reflects a clip recorded (or still separating) via the menu bar's Record toggle into the
    /// Practice sidebar immediately, without requiring a reopen of the window.
    func clipImported(_ clip: PracticeClip) {
        sidebar.upsertClip(clip)
    }

    // MARK: - Header

    private func configureHeader() {
        segmentedControl.selectedSegment = Tab.live.rawValue
        segmentedControl.target = self
        segmentedControl.action = #selector(tabChanged)

        liveStatusDot.layer?.cornerRadius = 4
        liveStatusDot.isHidden = true

        configureAppearanceButton()
        configureBackButton()
        configureSidebarToggleButton()

        // Theme switch first, then the dot, then the switch itself. The dot annotates the
        // Live/Practice control (it reports that Live is still running while Practice is showing),
        // so it stays adjacent to it rather than being separated by unrelated chrome.
        let segmentedSize = segmentedControl.fittingSize
        let segmentedWidth = max(segmentedSize.width, 120)
        // 26, not 20: a pill this short reads as squat rather than capsule-shaped.
        let segmentedHeight = max(segmentedSize.height, 26)
        // Square, so `cornerStyle == .capsule` renders it as a circle. Two points shorter than the
        // switch beside it so a bare glyph doesn't out-weigh the labelled control it accompanies.
        liveStatusDot.constrainSize(width: 8, height: 8)
        segmentedControl.constrainSize(width: segmentedWidth, height: segmentedHeight)
        appearanceButton.constrainSize(width: 24, height: 24)

        // No `TitlebarAccessoryContainerView` and no `intrinsicContentSize` override any more: the
        // cluster is an ordinary constraint-laid-out subview now, so the sizing workaround that
        // `NSTitlebarAccessoryViewController`'s clip view required is gone with it.
        let cluster = Layout.horizontalStack([appearanceButton, liveStatusDot, segmentedControl], spacing: 8)
        headerRow.addSubview(cluster)
        headerRow.addSubview(backButton)
        headerRow.addSubview(sidebarToggleButton)
        let backLeading = backButton.leadingAnchor.constraint(equalTo: headerRow.leadingAnchor, constant: Self.backButtonLeadingInset)
        let toggleLeading = sidebarToggleButton.leadingAnchor.constraint(equalTo: headerRow.leadingAnchor, constant: Self.backButtonLeadingInset)
        leadingSlotConstraints = [backLeading, toggleLeading]
        NSLayoutConstraint.activate([
            // Trailing-aligned, matching the padding the tab content below uses, so the switch
            // lines up with the right edge of the Live tab's card grid.
            cluster.trailingAnchor.constraint(equalTo: headerRow.trailingAnchor, constant: -WindowUI.Metrics.padding),
            cluster.centerYAnchor.constraint(equalTo: headerRow.centerYAnchor),
            backLeading,
            backButton.centerYAnchor.constraint(equalTo: headerRow.centerYAnchor),
            // Same slot as `backButton`, which is never visible at the same time. The 80pt inset is
            // load-bearing: with `.fullSizeContentView` the traffic lights float inside `headerRow`
            // (14×14 at x=9/32/55), and 80 clears the zoom button by 11pt.
            toggleLeading,
            sidebarToggleButton.centerYAnchor.constraint(equalTo: headerRow.centerYAnchor)
        ])

        Layout.pin(headerRow, to: contentContainer, edges: [.leading, .trailing, .top])
        headerRow.heightAnchor.constraint(equalToConstant: Self.headerHeight).isActive = true
        Layout.pin(tabContentContainer, to: contentContainer, edges: [.leading, .trailing, .bottom])
        tabContentContainer.topAnchor.constraint(equalTo: headerRow.bottomAnchor).isActive = true
    }

    private func configureAppearanceButton() {
        appearanceButton.cornerStyle = .capsule
        appearanceButton.imagePosition = .imageOnly
        appearanceButton.imageScaling = .scaleProportionallyDown
        // Ghost's default is the coral accent, which would read as a primary action up here. The
        // theme switch is chrome, so it takes the same secondary tint as the title bar's own glyphs.
        appearanceButton.textColorOverride = .secondaryLabelColor
        appearanceButton.setAccessibilityLabel("Theme")
        appearanceButton.target = self
        appearanceButton.action = #selector(appearanceButtonClicked)
        syncAppearanceButton()
    }

    private func syncAppearanceButton() {
        let appearance = preferences.appearance
        appearanceButton.image = NSImage(systemSymbolName: appearance.symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        // The button shows only the current stage, so the next one is named here rather than left
        // to be discovered by clicking.
        appearanceButton.toolTip = "Theme: \(appearance.displayName). Click for \(appearance.next.displayName)."
        appearanceButton.setAccessibilityValue(appearance.displayName)
    }

    /// Same recipe as `appearanceButton` — capsule ghost, secondary tint, 24×24 — so the `<` reads
    /// as title bar chrome rather than as an action inside the page it sits above.
    private func configureBackButton() {
        backButton.cornerStyle = .capsule
        backButton.imagePosition = .imageOnly
        backButton.imageScaling = .scaleProportionallyDown
        backButton.textColorOverride = .secondaryLabelColor
        backButton.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        backButton.setAccessibilityLabel("Back")
        backButton.toolTip = "Back"
        backButton.constrainSize(width: 24, height: 24)
        backButton.isHidden = true
        backButton.target = self
        backButton.action = #selector(backButtonClicked)
    }

    @objc private func backButtonClicked() {
        showTab(currentTab)
    }

    /// Same recipe as `backButton` and `appearanceButton` — capsule ghost, secondary tint, 24×24 —
    /// so it reads as title bar chrome rather than as an action inside the page below it.
    private func configureSidebarToggleButton() {
        sidebarToggleButton.cornerStyle = .capsule
        sidebarToggleButton.imagePosition = .imageOnly
        sidebarToggleButton.imageScaling = .scaleProportionallyDown
        sidebarToggleButton.textColorOverride = .secondaryLabelColor
        sidebarToggleButton.setIcon("sidebar.leading", pointSize: 12, label: "Show/Hide Sidebar")
        sidebarToggleButton.constrainSize(width: 24, height: 24)
        sidebarToggleButton.isHidden = true
        sidebarToggleButton.target = self
        sidebarToggleButton.action = #selector(sidebarToggleClicked)
    }

    @objc private func sidebarToggleClicked() {
        practiceSplitViewController.toggleSidebar()
    }

    /// Escape leaves a takeover page, same as the `<`. Handled here rather than on the page's own
    /// view controller because the window controller is reliably in the responder chain even when
    /// the first responder is the window itself (nothing inside the page focused). Recording is
    /// deliberately not stopped — leaving the page and ending the take are different intentions.
    override func cancelOperation(_ sender: Any?) {
        guard !backButton.isHidden else { return }
        backButtonClicked()
    }

    @objc private func appearanceButtonClicked() {
        let appearance = preferences.appearance.next
        preferences.appearance = appearance
        // Cascades to every window and view, so each `ThemedView`/`FlatButton` repaints itself off
        // the same `viewDidChangeEffectiveAppearance` path a system-wide switch would use.
        appearance.apply()
        syncAppearanceButton()
    }

    @objc private func tabChanged() {
        guard let tab = Tab(rawValue: segmentedControl.selectedSegment) else { return }
        showTab(tab)
    }

    private func showTab(_ tab: Tab) {
        currentTab = tab
        currentPage = .tab(tab)
        segmentedControl.selectedSegment = tab.rawValue
        applyHeaderChrome(showsBack: false)

        switch tab {
        case .live:
            liveViewController.reloadFromPreferences()
            setContent(liveViewController)
        case .practice:
            setContent(practiceTabViewController)
        }
    }

    /// Swaps the window's visible content through real `NSViewController` containment
    /// (`addChild`/`removeFromParent`) instead of a bare subview swap, so the incoming controller
    /// gets a normal `viewWillAppear`/`viewDidAppear` lifecycle. This matters concretely for
    /// `practiceTabViewController`: it hosts an `NSSplitViewController`, which computes its
    /// divider/holding-priority layout expecting that lifecycle to fire — skipping it is what
    /// previously produced a gap above the Practice tab's content with everything else pinned to
    /// the bottom of the window.
    private func setContent(_ child: NSViewController) {
        guard child !== currentContentViewController else { return }

        if let current = currentContentViewController {
            current.view.removeFromSuperview()
            current.removeFromParent()
        }

        contentRootViewController.addChild(child)
        Layout.pin(child.view, to: tabContentContainer)
        currentContentViewController = child
    }

    // MARK: - Live tab

    private func configureLiveTab() {
        _ = liveViewController.view
        liveViewController.reloadFromPreferences()
    }

    // MARK: - Practice tab

    private func configurePracticeTab() {
        _ = practiceTabViewController.view

        sidebar.onImportClicked = { [weak self] in self?.importButtonClicked() }
        sidebar.onRecordClicked = { [weak self] in self?.recordButtonClicked() }
        sidebar.onRecordElapsedClicked = { [weak self] in self?.recordElapsedClicked() }

        if #unavailable(macOS 14.2) {
            sidebar.recordButton.isEnabled = false
            sidebar.recordButton.toolTip = "Recording system audio requires macOS 14.2 or later"
        }
    }

    private func importButtonClicked() {
        importService.presentOpenPanel(in: window) { [weak self] url in
            guard let self, let url else { return }
            self.handleImport(url: url)
        }
    }

    // MARK: - Record page

    /// Injected by `AppDelegate`, which owns the app's one recorder and shares it with the menu bar.
    @available(macOS 14.2, *)
    func attachRecorder(_ recorder: ClipRecorder) {
        clipRecorderBox = recorder
        // The window can be built while a menu-bar recording is already running, so the sidebar
        // header starts from the recorder's state rather than assuming idle.
        practiceTabViewController.setRecordingState(recorder.isRecording)
        if recorder.isRecording {
            practiceTabViewController.updateRecordingElapsed(recorder.elapsedSeconds())
        }
    }

    @available(macOS 14.2, *)
    private var clipRecorder: ClipRecorder? {
        clipRecorderBox as? ClipRecorder
    }

    @available(macOS 14.2, *)
    private var recordPageViewController: RecordPageViewController? {
        if let existing = recordPageViewControllerBox as? RecordPageViewController { return existing }
        guard let clipRecorder else { return nil }
        let page = RecordPageViewController(recorder: clipRecorder, preferences: preferences) { [weak self] url in
            guard let self else { return }
            // Finishing a take — by Stop or by auto-stop — ends the session, so it returns to the
            // library the clip just landed in. This is what the popover's `performClose` did.
            self.showTab(.practice)
            self.handleImport(url: url)
        }
        recordPageViewControllerBox = page
        return page
    }

    /// Forwarded from `AppDelegate` for every recording start/stop, whichever surface caused it.
    func updateRecordingState(_ recording: Bool) {
        practiceTabViewController.setRecordingState(recording)
        if #available(macOS 14.2, *) {
            (recordPageViewControllerBox as? RecordPageViewController)?.recordingStateChanged(recording)
        }
    }

    /// Forwarded from `AppDelegate` off the recorder's ~10Hz progress callback. Both surfaces are
    /// fed unconditionally — the sidebar header's readout guards on its own visibility, and the
    /// record page's on being loaded — so navigating between them never leaves one stale.
    func updateRecordingProgress(peaks: [Float], elapsed: Double) {
        practiceTabViewController.updateRecordingElapsed(elapsed)
        if #available(macOS 14.2, *) {
            (recordPageViewControllerBox as? RecordPageViewController)?.updateProgress(peaks: peaks, elapsed: elapsed)
        }
    }

    private func recordButtonClicked() {
        guard #available(macOS 14.2, *) else { return }
        guard let clipRecorder else {
            // Only reachable if `attachRecorder` was never called — a wiring mistake, not a state
            // the user can get into. Logged rather than silently swallowed, because the symptom is
            // an inert Record button with nothing else to go on.
            AppLogger.shared.error("Record button clicked with no recorder attached")
            return
        }
        // Doubles as Stop once a take is running: navigating back here doesn't end the recording,
        // so this button is the only stop control on the Practice page.
        if clipRecorder.isRecording {
            if let url = clipRecorder.stopRecording() {
                handleImport(url: url)
            }
            return
        }
        showRecordPage()
    }

    private func recordElapsedClicked() {
        guard #available(macOS 14.2, *) else { return }
        showRecordPage()
    }

    @available(macOS 14.2, *)
    private func showRecordPage() {
        guard let page = recordPageViewController else { return }
        currentPage = .record
        applyHeaderChrome(showsBack: true)
        setContent(page)
    }

    private func handleImport(url: URL) {
        importService.importFile(
            at: url,
            onImported: { [weak self] clip in
                guard let self else { return }
                self.sidebar.upsertClip(clip)
                self.sidebar.selectClip(id: clip.id)
                self.deck.show(clip: clip)
            },
            onProgress: { [weak self] clip in
                guard let self else { return }
                self.sidebar.upsertClip(clip)
                self.deck.updateClip(clip)
            },
            onFailure: { [weak self] error in
                self?.presentImportError(error)
            }
        )
    }

    private func presentImportError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Couldn't import this clip"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}
