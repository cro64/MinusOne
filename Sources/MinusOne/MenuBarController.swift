import AppKit

final class MenuBarController: NSObject {

    private let preferences: Preferences
    private let audioEngine: AudioEngine
    private let statusItem: NSStatusItem
    private let settingsViewController: SettingsPopoverViewController
    private let settingsPanel: NSPanel

    private var currentStatus: AudioEngineStatus = .idle
    private var isFilterActive = false
    private var dismissMonitor: Any?
    private var localDismissMonitor: Any?
    private var appearanceObserver: NSObjectProtocol?

    var onOpenPracticeMode: (() -> Void)?

    init(preferences: Preferences, audioEngine: AudioEngine) {
        self.preferences = preferences
        self.audioEngine = audioEngine
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        settingsViewController = SettingsPopoverViewController(
            preferences: preferences,
            audioEngine: audioEngine
        )
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
        if let button = statusItem.button {
            var text = status.displayText
            if let backend = audioEngine.activeCaptureBackend {
                text += " — \(backend.displayName)"
            }
            if let monoTooltip = status.monoInputTooltip {
                text = monoTooltip
            }
            button.toolTip = text
        }
        updateIcon()
        settingsViewController.updateStatusDisplay(status, isFilterActive: isFilterActive)
    }

    func performToggleWithOnboarding() {
        OnboardingController.showIfNeeded(
            preferences: preferences,
            captureBackend: CaptureBackend.preferred
        )
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
        settingsViewController.onSettingsChanged = { [weak self] in
            self?.updateIcon()
        }
        settingsViewController.onQuit = { [weak self] in
            self?.closeSettings()
            NSApp.terminate(nil)
        }
        settingsViewController.onOpenPracticeMode = { [weak self] in
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
        } else if case .monoInput = currentStatus {
            color = .systemYellow
            usesTemplate = false
        } else if isFilterActive {
            color = .controlAccentColor
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
        settingsViewController.reloadFromPreferences()
        settingsViewController.updateStatusDisplay(currentStatus, isFilterActive: isFilterActive)
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
        settingsViewController.reloadFromPreferences()
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
