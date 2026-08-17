import AppKit

/// Owns the desktop window: a Live / Practice segmented switch in a content-area header, and the
/// two tabs' content. Live embeds `LiveTabViewController`, a full-width window-filling view (REDESIGN.md
/// §3); Practice embeds the existing sidebar + deck split view, reused as-is per REDESIGN.md §1.
///
/// Activation policy (REDESIGN.md §1): opening the window promotes the app to `.regular` with a
/// Dock icon; closing (red traffic light / ⌘W) demotes back to `.accessory` without quitting —
/// Live/Recording keep running. Only Quit in the menu bar popover fully quits.
final class MainWindowController: NSWindowController, NSWindowDelegate {
    enum Tab: Int {
        case live = 0
        case practice = 1
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
    private static let headerHeight: CGFloat = 38

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
    private var currentTab: Tab = .live
    private var onboardingViewController: OnboardingViewController?

    private var systemAudioRecorderBox: Any?
    private var recordingPopover: NSPopover?

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
        practiceTabViewController = PracticeTabViewController(splitViewController: practiceSplitViewController)

        let defaultContentSize = NSSize(width: 980, height: 640)
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
        // Matches the window's starting content size rather than a smaller arbitrary floor. Live's
        // card grid does now reflow, so *it* could take a lower floor — but this value is also what
        // the Practice tab lands on when its view is installed (AppKit re-fits the window from the
        // installed tab's constraints), so lowering it shrinks Practice's window rather than merely
        // permitting a smaller one. Measured: at 860×560 here, Practice opens at 860×560.
        window.minSize = defaultContentSize
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

        configureHeader()
        configureLiveTab()
        configurePracticeTab()

        sidebar.onSelectClip = { [weak self] clip in self?.deck.show(clip: clip) }
        sidebar.onDropFiles = { [weak self] urls in
            urls.forEach { self?.handleImport(url: $0) }
        }
        sidebar.reloadClips()

        if !presentOnboardingIfNeeded() {
            showTab(.live)
        }
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
        liveStatusDot.isHidden = currentTab != .practice
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
        segmentedControl.isHidden = true
        liveStatusDot.isHidden = true
        window?.toolbar = nil

        setContent(onboarding)
        return true
    }

    private func finishOnboarding() {
        onboardingViewController = nil
        segmentedControl.isHidden = false
        liveViewController.reloadFromPreferences()
        showTab(.live)
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
        NSLayoutConstraint.activate([
            // Trailing-aligned, matching the padding the tab content below uses, so the switch
            // lines up with the right edge of the Live tab's card grid.
            cluster.trailingAnchor.constraint(equalTo: headerRow.trailingAnchor, constant: -WindowUI.Metrics.padding),
            cluster.centerYAnchor.constraint(equalTo: headerRow.centerYAnchor)
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
        segmentedControl.selectedSegment = tab.rawValue
        liveStatusDot.isHidden = tab != .practice

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

        let importActionButton = practiceTabViewController.importActionButton
        let recordActionButton = practiceTabViewController.recordActionButton

        importActionButton.target = self
        importActionButton.action = #selector(importButtonClicked)
        recordActionButton.target = self
        recordActionButton.action = #selector(recordButtonClicked(_:))
        if #unavailable(macOS 14.2) {
            recordActionButton.isEnabled = false
            recordActionButton.toolTip = "Recording system audio requires macOS 14.2 or later"
        }

    }

    @objc private func importButtonClicked() {
        importService.presentOpenPanel(in: window) { [weak self] url in
            guard let self, let url else { return }
            self.handleImport(url: url)
        }
    }

    @available(macOS 14.2, *)
    private var systemAudioRecorder: SystemAudioRecorder {
        if let existing = systemAudioRecorderBox as? SystemAudioRecorder { return existing }
        let recorder = SystemAudioRecorder()
        systemAudioRecorderBox = recorder
        return recorder
    }

    @objc private func recordButtonClicked(_ sender: Any) {
        guard #available(macOS 14.2, *) else { return }
        let anchorView = (sender as? NSView) ?? practiceTabViewController.recordActionButton

        let panel = RecordingPanelController(recorder: systemAudioRecorder) { [weak self] url in
            self?.handleImport(url: url)
            self?.recordingPopover?.performClose(nil)
        }
        let popover = NSPopover()
        popover.contentViewController = panel
        popover.behavior = .transient
        // Previously pinned to `.darkAqua`. That predated the app having any appearance story at
        // all; now that it does, a hard-coded dark popover is the one surface that would ignore
        // both the system setting and the user's own Light/Dark choice. Left unset so it inherits.
        popover.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .maxY)
        recordingPopover = popover
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
