import AppKit
import XCTest
@testable import MinusOne

final class UpdateControllerTests: XCTestCase {
    // MARK: - The quiet badge

    /// A scheduled check that finds an update leaves showing it to us: that's the badge.
    func testAnUpdateSparkleLeavesToUsBecomesPending() {
        let controller = UpdateController(driver: FakeUpdater())
        controller.updateWillBeShown(version: "0.8.0", sparkleShowsIt: false)
        XCTAssertEqual(controller.pendingVersion, "0.8.0")
    }

    /// A check the user started shows Sparkle's window straight away, so there is nothing to badge.
    func testAnUpdateSparkleShowsItselfIsNotPending() {
        let controller = UpdateController(driver: FakeUpdater())
        controller.updateWillBeShown(version: "0.8.0", sparkleShowsIt: true)
        XCTAssertNil(controller.pendingVersion)
    }

    func testLookingAtTheUpdateClearsTheBadge() {
        let controller = UpdateController(driver: FakeUpdater())
        controller.updateWillBeShown(version: "0.8.0", sparkleShowsIt: false)
        controller.userLookedAtUpdate()
        XCTAssertNil(controller.pendingVersion)
    }

    /// Remind Me Later, Skip This Version, closing the window and installing all end the session.
    func testEndingTheSessionClearsTheBadge() {
        let controller = UpdateController(driver: FakeUpdater())
        controller.updateWillBeShown(version: "0.8.0", sparkleShowsIt: false)
        controller.updateSessionFinished()
        XCTAssertNil(controller.pendingVersion)
    }

    func testTheChangeCallbackFiresOnlyWhenTheVersionChanges() {
        let controller = UpdateController(driver: FakeUpdater())
        var reported: [String?] = []
        controller.onPendingVersionChanged = { reported.append($0) }

        controller.updateWillBeShown(version: "0.8.0", sparkleShowsIt: false)
        controller.updateWillBeShown(version: "0.8.0", sparkleShowsIt: false)
        controller.updateSessionFinished()
        controller.updateSessionFinished()

        XCTAssertEqual(reported, ["0.8.0", nil])
    }

    /// An update already downloaded in an earlier session resumes outside the gentle-reminder path
    /// (`updateWillBeShown` never fires for it), so the updater-level "found a valid update" callback
    /// must badge it too.
    func testUpdateFoundBecomesPending() {
        let controller = UpdateController(driver: FakeUpdater())
        controller.updateFound(version: "0.8.0")
        XCTAssertEqual(controller.pendingVersion, "0.8.0")
    }

    func testUpdateFoundFiresTheChangeCallback() {
        let controller = UpdateController(driver: FakeUpdater())
        var reported: [String?] = []
        controller.onPendingVersionChanged = { reported.append($0) }

        controller.updateFound(version: "0.8.0")

        XCTAssertEqual(reported, ["0.8.0"])
    }

    func testLookingAtTheUpdateClearsAFoundBadge() {
        let controller = UpdateController(driver: FakeUpdater())
        controller.updateFound(version: "0.8.0")
        controller.userLookedAtUpdate()
        XCTAssertNil(controller.pendingVersion)
    }

    // MARK: - Checking by hand

    func testCheckForUpdatesAsksTheUpdater() {
        let fake = FakeUpdater()
        let controller = UpdateController(driver: fake)
        controller.checkForUpdates(nil)
        XCTAssertEqual(fake.checkCount, 1)
    }

    func testTheMenuItemIsEnabledOnlyWhenTheUpdaterCanCheck() {
        let fake = FakeUpdater()
        let controller = UpdateController(driver: fake)
        let item = NSMenuItem(title: "Check for Updates…", action: #selector(UpdateController.checkForUpdates(_:)), keyEquivalent: "")

        fake.canCheckForUpdates = true
        XCTAssertTrue(controller.validateMenuItem(item))
        fake.canCheckForUpdates = false
        XCTAssertFalse(controller.validateMenuItem(item), "a check already running must disable the item")
    }

    // MARK: - Relaunching while recording

    func testThePolicyOnlyAsksWhileRecording() {
        XCTAssertEqual(UpdateRelaunchPolicy.decision(isRecording: false), .proceed)
        XCTAssertEqual(UpdateRelaunchPolicy.decision(isRecording: true), .askToStopRecording)
    }

    func testNotRecordingLetsSparkleRelaunchStraightAway() {
        let controller = UpdateController(driver: FakeUpdater())
        controller.isRecording = { false }
        controller.askToStopRecording = {
            XCTFail("asked about a recording that isn't running")
            return true
        }
        var installs = 0

        let postponed = controller.shouldPostponeRelaunch(install: { installs += 1 })

        XCTAssertFalse(postponed)
        XCTAssertEqual(installs, 0, "Sparkle relaunches by itself when not postponed")
    }

    /// Stop & Install: the take must reach the library before the app quits, so Sparkle waits and
    /// the install runs only once saving has finished.
    func testStopAndInstallSavesTheTakeBeforeInstalling() {
        let controller = UpdateController(driver: FakeUpdater())
        controller.isRecording = { true }
        controller.askToStopRecording = { true }
        var events: [String] = []
        var finishSaving: (() -> Void)?
        controller.stopRecordingAndSave = { completion in
            events.append("stop")
            finishSaving = completion
        }

        let postponed = controller.shouldPostponeRelaunch(install: { events.append("install") })

        XCTAssertTrue(postponed, "Sparkle must wait while the take is saved")
        XCTAssertEqual(events, ["stop"], "installed before the take was saved")
        finishSaving?()
        XCTAssertEqual(events, ["stop", "install"])
    }

    func testLaterKeepsRecordingAndDoesNotInstall() {
        let controller = UpdateController(driver: FakeUpdater())
        controller.isRecording = { true }
        controller.askToStopRecording = { false }
        var events: [String] = []
        controller.stopRecordingAndSave = { _ in events.append("stop") }

        let postponed = controller.shouldPostponeRelaunch(install: { events.append("install") })

        XCTAssertTrue(postponed)
        XCTAssertEqual(events, [], "Later must neither stop the recording nor install")
    }
}
