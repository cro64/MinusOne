import AppKit

/// `NSTitlebarAccessoryViewController`'s clip view reserves title-bar space from the accessory
/// view's `intrinsicContentSize`, not from constraints on an arbitrary child (an `NSStackView`
/// with only constraint-based sizing measured as zero-width at title-bar layout time even with
/// its children fully constrained). Overriding this directly is the documented, reliable fix.
private final class TitlebarAccessoryContainerView: AutoLayoutView {
    var fixedSize: NSSize = .zero {
        didSet { invalidateIntrinsicContentSize() }
    }

    override var intrinsicContentSize: NSSize { fixedSize }
}

/// Owns the desktop window: a Live / Practice segmented switch in the title bar, and the two
/// tabs' content. Live embeds `LiveTabViewController`, a full-width window-filling view (REDESIGN.md
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

    private let contentContainer = NSView()
    private let contentRootViewController = NSViewController()
    private var currentContentViewController: NSViewController?
    private let segmentedControl = FlatSegmentedControl(titles: ["Live", "Practice"])
    private let liveStatusDot = NSView()
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
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        // Title text is hidden (the title bar only carries the Live/Practice switch), but the
        // title itself stays set for accessibility and Mission Control.
        window.title = "MinusOne"
        window.titleVisibility = .hidden
        // Matches the window's starting content size rather than a smaller arbitrary floor — the
        // app has no scroll views in its primary content, so the window must never shrink past
        // the size that content was designed to fit in.
        window.minSize = defaultContentSize
        // Explicit, not just relying on NSWindow's defaults: an ambiguous/false isOpaque or clear
        // backgroundColor is exactly what makes the Dock show through the window at the edges.
        window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor
        window.center()

        super.init(window: window)
        window.delegate = self

        contentContainer.wantsLayer = true
        contentContainer.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        contentRootViewController.view = contentContainer
        window.contentViewController = contentRootViewController

        configureTitleBarAccessory()
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
        liveStatusDot.layer?.backgroundColor = (isFilterActive ? NSColor.brandAccentDeep : NSColor.tertiaryLabelColor).cgColor
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

    // MARK: - Title bar accessory

    private func configureTitleBarAccessory() {
        segmentedControl.selectedSegment = Tab.live.rawValue
        segmentedControl.target = self
        segmentedControl.action = #selector(tabChanged)

        liveStatusDot.wantsLayer = true
        liveStatusDot.layer?.cornerRadius = 4
        liveStatusDot.layer?.backgroundColor = NSColor.tertiaryLabelColor.cgColor
        liveStatusDot.isHidden = true

        let stack = Layout.horizontalStack([liveStatusDot, segmentedControl], spacing: 8)
        // top: 8 (space-2), not 4 — gives the pill toggle some breathing room below the traffic
        // lights instead of sitting flush against the top of the title bar.
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 4, right: 8)

        let segmentedSize = segmentedControl.fittingSize
        let segmentedWidth = max(segmentedSize.width, 120)
        // 26, not 20: a pill this short reads as squat rather than capsule-shaped.
        let segmentedHeight = max(segmentedSize.height, 26)
        let stackWidth = stack.edgeInsets.left + 8 + stack.spacing + segmentedWidth + stack.edgeInsets.right
        let stackHeight = segmentedHeight + stack.edgeInsets.top + stack.edgeInsets.bottom
        liveStatusDot.constrainSize(width: 8, height: 8)
        segmentedControl.constrainSize(width: segmentedWidth, height: segmentedHeight)
        stack.constrainSize(width: stackWidth, height: stackHeight)

        let container = TitlebarAccessoryContainerView()
        container.fixedSize = NSSize(width: stackWidth, height: stackHeight)
        container.setFrameSize(container.fixedSize)
        Layout.pin(stack, to: container)

        let accessoryViewController = NSTitlebarAccessoryViewController()
        accessoryViewController.view = container
        accessoryViewController.layoutAttribute = .right
        window?.addTitlebarAccessoryViewController(accessoryViewController)
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
        Layout.pin(child.view, to: contentContainer)
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

        deck.onImportRequested = { [weak self] in self?.importButtonClicked() }
        deck.onRecordRequested = { [weak self] in
            guard let self else { return }
            self.recordButtonClicked(self.practiceTabViewController.recordActionButton)
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
        popover.appearance = NSAppearance(named: .darkAqua)
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
