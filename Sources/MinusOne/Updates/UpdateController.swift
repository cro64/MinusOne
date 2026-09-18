import AppKit

/// What the app needs from the updater. `SparkleUpdater` is the real one; tests use a fake, because
/// Sparkle's appcast items and update states can't be built outside a real update session.
protocol UpdaterDriving: AnyObject {
    var canCheckForUpdates: Bool { get }
    func checkForUpdates()
}

/// Installing an update quits and relaunches the app. `ClipRecorder` doesn't finish a take on quit,
/// so a relaunch mid-recording would lose it.
enum UpdateRelaunchPolicy {
    enum Decision: Equatable {
        case proceed
        case askToStopRecording
    }

    static func decision(isRecording: Bool) -> Decision {
        isRecording ? .askToStopRecording : .proceed
    }
}

/// The app's side of in-app updates: which version is waiting (the menu bar badge and popover item
/// follow it), whether "Check for Updates…" is available, and whether a relaunch has to wait for a
/// recording. Knows nothing about Sparkle — `SparkleUpdater` forwards Sparkle's callbacks here.
final class UpdateController: NSObject, NSMenuItemValidation {
    private let driver: UpdaterDriving

    /// The version a scheduled check found and left for the user to notice. Nil when nothing waits.
    private(set) var pendingVersion: String? {
        didSet {
            guard pendingVersion != oldValue else { return }
            onPendingVersionChanged?(pendingVersion)
        }
    }

    var onPendingVersionChanged: ((String?) -> Void)?
    var isRecording: () -> Bool = { false }
    /// Shows the "Finish recording before updating?" alert. True means Stop & Install.
    var askToStopRecording: () -> Bool = { false }
    /// Stops the recording and calls `completion` once the take is in the library.
    var stopRecordingAndSave: (_ completion: @escaping () -> Void) -> Void = { $0() }

    init(driver: UpdaterDriving) {
        self.driver = driver
        super.init()
    }

    @objc func checkForUpdates(_ sender: Any?) {
        switch UpdateRelaunchPolicy.decision(isRecording: isRecording()) {
        case .proceed:
            driver.checkForUpdates()
        case .askToStopRecording:
            if askToStopRecording() {
                AppLogger.shared.info("Update: stopping the recording before opening the updater")
                stopRecordingAndSave { [driver] in driver.checkForUpdates() }
            } else {
                AppLogger.shared.info("Update: opening the updater postponed while recording")
            }
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(checkForUpdates(_:)) else { return true }
        return driver.canCheckForUpdates
    }

    // MARK: - Sparkle events

    /// `updateFound` badges on every discovery (including ones Sparkle is about to show itself), so
    /// this is what makes the call: when Sparkle is putting its own window on screen the badge would
    /// be redundant, so it's cleared here; otherwise (a gentle reminder) it's (re)set.
    func updateWillBeShown(version: String, sparkleShowsIt: Bool) {
        AppLogger.shared.info("Update available: \(version) (\(sparkleShowsIt ? "shown now" : "badged"))")
        pendingVersion = sparkleShowsIt ? nil : version
    }

    /// Sparkle's gentle-reminder callbacks only fire for a *new* scheduled update. An update that was
    /// already downloaded in an earlier session resumes through a different path, so the badge is also
    /// set from the updater-level "found a valid update" callback.
    func updateFound(version: String) {
        AppLogger.shared.info("Update available: \(version) (found)")
        pendingVersion = version
    }

    func userLookedAtUpdate() {
        pendingVersion = nil
    }

    func updateSessionFinished() {
        pendingVersion = nil
    }

    /// Returns true when Sparkle must hold the relaunch. `install` resumes it.
    func shouldPostponeRelaunch(install: @escaping () -> Void) -> Bool {
        switch UpdateRelaunchPolicy.decision(isRecording: isRecording()) {
        case .proceed:
            return false
        case .askToStopRecording:
            if askToStopRecording() {
                AppLogger.shared.info("Update: stopping the recording before installing")
                stopRecordingAndSave { install() }
            } else {
                AppLogger.shared.info("Update: install postponed while recording")
            }
            return true
        }
    }
}
