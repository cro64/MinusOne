import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let preferences = Preferences()
    private lazy var audioEngine = AudioEngine(preferences: preferences)
    private var menuBarController: MenuBarController?
    private var deviceMonitor: DeviceMonitor?
    private var hotKeyController: HotKeyController?
    private var restartAfterWake = false
    private var wasReductionEnabledBeforeSleep = false
    private var deviceRebuildWorkItem: DispatchWorkItem?

    private let practiceLibraryStore = ClipLibraryStore()
    private lazy var practiceSeparationEngine = OfflineSeparationEngine(libraryStore: practiceLibraryStore)
    private lazy var practiceImportService = ClipImportService(libraryStore: practiceLibraryStore, separationEngine: practiceSeparationEngine)
    private lazy var practicePlaybackEngine = PracticePlaybackEngine()
    private var practiceWindowController: PracticeWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if #available(macOS 14.2, *) {
            ProcessTapSession.destroyStaleAggregates()
        }
        audioEngine.recoverOrphanedBlackHoleIfNeeded()

        menuBarController = MenuBarController(
            preferences: preferences,
            audioEngine: audioEngine
        )
        audioEngine.onStatusChanged = { [weak self] status in
            self?.menuBarController?.updateStatus(status)
        }
        menuBarController?.onOpenPracticeMode = { [weak self] in
            self?.openPracticeWindow()
        }

        deviceMonitor = DeviceMonitor(
            onDeviceChange: { [weak self] in
                guard let self else { return }
                deviceRebuildWorkItem?.cancel()
                let item = DispatchWorkItem { [weak self] in
                    guard let self, audioEngine.isRunning else { return }
                    audioEngine.scheduleRebuildForDeviceChange()
                }
                deviceRebuildWorkItem = item
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.75, execute: item)
            },
            onWillSleep: { [weak self] in
                guard let self else { return }
                restartAfterWake = audioEngine.isRunning
                wasReductionEnabledBeforeSleep = audioEngine.isReductionEnabled
                audioEngine.stop(restoreOutput: true)
            },
            onDidWake: { [weak self] in
                guard let self, restartAfterWake else { return }
                restartAfterWake = false
                let shouldRestoreReduction = wasReductionEnabledBeforeSleep
                wasReductionEnabledBeforeSleep = false
                audioEngine.start { [weak self] success in
                    guard let self, success, shouldRestoreReduction else { return }
                    self.audioEngine.enableReduction()
                }
            }
        )
        deviceMonitor?.start()

        hotKeyController = HotKeyController { [weak self] in
            guard let self else { return }
            menuBarController?.performToggleWithOnboarding()
        }
        hotKeyController?.registerDefaultHotKey()

        menuBarController?.updateStatus(.idle)
        AppLogger.shared.info("MinusOne launched")

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            OnboardingController.showIfNeeded(
                preferences: self.preferences,
                captureBackend: CaptureBackend.preferred
            )
        }

        restoreSessionIfNeeded()
    }

    private func openPracticeWindow() {
        if practiceWindowController == nil {
            let controller = PracticeWindowController(
                libraryStore: practiceLibraryStore,
                importService: practiceImportService,
                playbackEngine: practicePlaybackEngine
            )
            controller.onWindowClosed = { [weak self] in
                NSApp.setActivationPolicy(.accessory)
                self?.practiceWindowController = nil
            }
            practiceWindowController = controller
        }
        NSApp.setActivationPolicy(.regular)
        practiceWindowController?.show()
    }

    private func restoreSessionIfNeeded() {
        guard preferences.lastReductionEnabled else { return }

        audioEngine.start { [weak self] success in
            guard let self, success else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.audioEngine.enableReduction()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKeyController?.unregister()
        deviceMonitor?.stop()
        audioEngine.stop(restoreOutput: true)
        AppLogger.shared.info("MinusOne terminated")
    }
}
