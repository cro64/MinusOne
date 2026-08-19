import AppKit

final class MenuBarController: NSObject {

    private let preferences: Preferences
    private let audioEngine: AudioEngine
    private let importService: ClipImportService
    private let statusItem: NSStatusItem
    private let settingsViewController: MenuBarPopoverViewController
    private let settingsPanel: NSPanel

    private var currentStatus: AudioEngineStatus = .idle
    private var isFilterActive = false
    /// Mirrors the shared recorder's state rather than owning it. Kept as a plain stored bool
    /// because `updateIcon()` reads it and isn't gated on macOS 14.2; `AppDelegate` pushes every
    /// change here through `updateRecordingState(_:)`, including recordings the window started.
    private var isRecording = false
    private var recorderBox: Any?
    private var dismissMonitor: Any?
    private var localDismissMonitor: Any?
    private var appearanceObserver: NSObjectProtocol?

    var onOpenPracticeMode: (() -> Void)?
    var onClipRecorded: ((PracticeClip) -> Void)?

    init(preferences: Preferences, audioEngine: AudioEngine, importService: ClipImportService) {
        self.preferences = preferences
        self.audioEngine = audioEngine
        self.importService = importService
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        settingsViewController = MenuBarPopoverViewController()
        settingsPanel = Self.makeSettingsPanel()
        super.init()
        _ = settingsViewController.view
        settingsPanel.contentView = settingsViewController.view
        configureStatusItem()
        configureSettingsCallbacks()
        appearanceObserver = DistributedNotificationCenter.default.addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateIcon()
        }
    }

    deinit {
        if let appearanceObserver {
            DistributedNotificationCenter.default.removeObserver(appearanceObserver)
        }
        stopDismissMonitors()
    }

    func updateStatus(_ status: AudioEngineStatus) {
        currentStatus = status
        isFilterActive = audioEngine.isVocalReductionActive
        if let button = statusItem.button, !isRecording {
            var text = status.displayText
            if let backend = audioEngine.activeCaptureBackend {
                text += " — \(backend.displayName)"
            }
            button.toolTip = text
        }
        updateIcon()
        settingsViewController.updateStatusDisplay(status, isFilterActive: isFilterActive)
    }

    // MARK: - Record toggle

    /// Injected by `AppDelegate` at launch — the menu bar no longer builds its own recorder.
    @available(macOS 14.2, *)
    func attachRecorder(_ recorder: ClipRecorder) {
        recorderBox = recorder
    }

    /// Called by `AppDelegate` for every recording start/stop, wherever it originated, so the icon
    /// and the popover's toggle stay truthful about a take the window kicked off.
    func updateRecordingState(_ recording: Bool) {
        guard isRecording != recording else { return }
        isRecording = recording
        updateIcon()
        settingsViewController.updateRecordingState(recording)
    }

    @available(macOS 14.2, *)
    private var recorder: ClipRecorder? {
        recorderBox as? ClipRecorder
    }

    private func performRecordToggle() {
        guard #available(macOS 14.2, *) else { return }
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    @available(macOS 14.2, *)
    private func startRecording() {
        guard let recorder else { return }
        // Same source the record page uses — a mic take started from the menu bar shouldn't
        // silently fall back to system audio.
        recorder.startRecording(source: preferences.recordingSource) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                // `isRecording`/`updateIcon` are driven by the shared recorder's state callback,
                // which has already fired by the time this completion runs.
                break
            case .failure(let error):
                AppLogger.shared.error("Menu bar record failed to start: \(error.localizedDescription)")
                self.settingsViewController.updateRecordingState(false)
            }
        }
    }

    @available(macOS 14.2, *)
    private func stopRecording() {
        guard let url = recorder?.stopRecording() else { return }
        importService.importFile(
            at: url,
            onImported: { [weak self] clip in self?.onClipRecorded?(clip) },
            onProgress: { [weak self] clip in self?.onClipRecorded?(clip) },
            onFailure: { error in
                AppLogger.shared.error("Menu bar recorded clip failed to import: \(error.localizedDescription)")
            }
        )
    }

    /// Live is either off or Neural now — there's no fallback processing path (REDESIGN.md §5).
    /// If onboarding hasn't run, or the model isn't installed, this routes into the window's Live
    /// tab (where the model-required gate + download CTA live) instead of silently toggling a
    /// pipeline that has nothing to do.
    func performToggleWithOnboarding() {
        guard preferences.hasCompletedOnboarding, audioEngine.isNeuralSeparationAvailable else {
            closeSettings()
            onOpenPracticeMode?()
            return
        }
        audioEngine.toggleReduction()
        updateStatus(audioEngine.status)
    }

    private static func makeSettingsPanel() -> NSPanel {
        let size = PopoverUI.Metrics.menuSize(contentHeight: 200)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        return panel
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        updateIcon()
    }

    private func configureSettingsCallbacks() {
        settingsViewController.onToggleLive = { [weak self] in
            self?.performToggleWithOnboarding()
        }
        settingsViewController.onToggleRecord = { [weak self] in
            self?.performRecordToggle()
        }
        settingsViewController.onQuit = { [weak self] in
            self?.closeSettings()
            NSApp.terminate(nil)
        }
        settingsViewController.onOpenWindow = { [weak self] in
            self?.closeSettings()
            self?.onOpenPracticeMode?()
        }
        settingsViewController.onPreferredSizeChange = { [weak self] size in
            guard let self else { return }
            self.settingsPanel.setContentSize(size)
            if self.settingsPanel.isVisible, let button = self.statusItem.button {
                self.positionSettingsPanel(relativeTo: button)
            }
        }
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }

        let size: CGFloat = 18

        if isRecording {
            // Solid coral dot always wins over whatever Live is doing underneath (REDESIGN.md §2).
            button.image = MinusOneIcon.recordingDot(size: size)
            button.toolTip = "Recording — \(liveStatusPhrase())"
            button.contentTintColor = nil
            return
        }

        let color: NSColor
        let usesTemplate: Bool

        if case .error = currentStatus {
            color = .systemRed
            usesTemplate = false
        } else if case .permissionRequired = currentStatus {
            color = .systemOrange
            usesTemplate = false
        } else if case .warmingUp = currentStatus {
            color = .systemCyan
            usesTemplate = false
        } else if isFilterActive {
            color = .brandAccent
            usesTemplate = false
        } else {
            // Black mask + template → AppKit tints for light/dark menu bar.
            color = .black
            usesTemplate = true
        }

        let image = MinusOneIcon.waveform(size: size, color: color, isActive: isFilterActive)
        image.isTemplate = usesTemplate
        button.image = image
        button.contentTintColor = nil
    }

    private func liveStatusPhrase() -> String {
        switch currentStatus {
        case .error:
            return "Error"
        case .permissionRequired:
            return "Permission needed"
        case .warmingUp:
            return "Warming up"
        default:
            return isFilterActive ? "Live on" : "Live off"
        }
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            performToggleWithOnboarding()
            return
        }

        toggleSettings(on: sender)
    }

    private func toggleSettings(on button: NSStatusBarButton) {
        if settingsPanel.isVisible {
            closeSettings()
            return
        }

        _ = settingsViewController.view
        settingsViewController.updateStatusDisplay(currentStatus, isFilterActive: isFilterActive)
        settingsViewController.updateRecordingState(isRecording)
        settingsViewController.sizeToFitContent()

        positionSettingsPanel(relativeTo: button)
        settingsPanel.orderFront(nil)
        startDismissMonitors()
    }

    private func positionSettingsPanel(relativeTo button: NSStatusBarButton) {
        guard let buttonWindow = button.window else { return }

        let buttonRect = button.convert(button.bounds, to: nil)
        let screenRect = buttonWindow.convertToScreen(buttonRect)
        let size = settingsPanel.frame.size
        let gap: CGFloat = 4

        var origin = NSPoint(
            x: screenRect.maxX + gap,
            y: screenRect.maxY - size.height
        )

        let screen = buttonWindow.screen ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            if origin.x + size.width > visible.maxX {
                origin.x = screenRect.minX - size.width - gap
            }
            origin.y = min(origin.y, visible.maxY - size.height)
            origin.y = max(origin.y, visible.minY)
        }

        settingsPanel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private func closeSettings() {
        guard settingsPanel.isVisible else {
            stopDismissMonitors()
            return
        }
        settingsPanel.orderOut(nil)
        stopDismissMonitors()
    }

    private func startDismissMonitors() {
        stopDismissMonitors()

        dismissMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closeSettings()
        }

        localDismissMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, self.settingsPanel.isVisible else { return event }
            if self.isSettingsRelated(event.window) {
                return event
            }
            if let button = self.statusItem.button, event.window == button.window {
                return event
            }
            self.closeSettings()
            return event
        }
    }

    private func stopDismissMonitors() {
        if let dismissMonitor {
            NSEvent.removeMonitor(dismissMonitor)
            self.dismissMonitor = nil
        }
        if let localDismissMonitor {
            NSEvent.removeMonitor(localDismissMonitor)
            self.localDismissMonitor = nil
        }
    }

    private func isSettingsRelated(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        if window == settingsPanel { return true }
        // Nested pop-up menus (Mode / Model / Apps) live in their own windows.
        return window.level.rawValue >= NSWindow.Level.popUpMenu.rawValue
    }
}
