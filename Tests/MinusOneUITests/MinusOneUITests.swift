import XCTest

/// Drives the built `.app` bundle via XCUIApplication, which queries live accessibility
/// element frames per-click rather than relying on screen coordinates captured earlier —
/// this is why it replaces ad-hoc `cliclick`/`osascript` coordinate automation for
/// verifying this app's UI: it can't drift onto another app's window or a stale Space.
///
/// Run with `Scripts/run-ui-tests.sh` (builds `build/MinusOne.app` first, then `swift test`).
/// Requires the test runner process to hold Accessibility permission once, same as any
/// other UI-automation tool on macOS.
final class MinusOneUITests: XCTestCase {
    private var app: XCUIApplication!

    private static var appURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // MinusOneUITests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("build/MinusOne.app")
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard FileManager.default.fileExists(atPath: Self.appURL.path) else {
            throw XCTSkip("build/MinusOne.app not found — run Scripts/build-app.sh first.")
        }
        app = XCUIApplication(url: Self.appURL)
        app.launch()
    }

    override func tearDownWithError() throws {
        app?.terminate()
    }

    /// Menu bar status item -> popover -> "Open MinusOne…" -> main window.
    ///
    /// With multiple displays arranged at different heights, NSStatusItem can report more than
    /// one accessibility element for the same menu bar icon, and `.firstMatch` sometimes picks a
    /// copy with a nonsensical (e.g. negative-y) frame that's never actually hittable. Picking the
    /// first status item with a plausible on-screen frame avoids that flakiness.
    private func openMainWindow() {
        let deadline = Date().addingTimeInterval(5)
        var statusItem: XCUIElement?
        while Date() < deadline {
            if let hittable = app.statusItems.allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable && $0.frame.origin.y >= 0 }) {
                statusItem = hittable
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        guard let statusItem else {
            XCTFail("No hittable menu bar status item found")
            return
        }
        statusItem.click()

        let openButton = app.buttons["Open MinusOne…"]
        XCTAssertTrue(openButton.waitForExistence(timeout: 5), "Popover's Open MinusOne… button never appeared")
        openButton.click()

        XCTAssertTrue(app.windows["MinusOne"].waitForExistence(timeout: 5), "Main window never opened")
    }

    /// REDESIGN.md §1: a two-item Live/Practice segmented control must render in the
    /// window's title bar. This is the bug that shipped broken twice in manual review.
    ///
    /// `NSSegmentedControl` (in its default select-one tracking mode) exposes itself to the
    /// Accessibility API as an `AXRadioGroup` containing `AXRadioButton` children, not as a
    /// monolithic segmented-control role — confirmed against a captured accessibility hierarchy
    /// dump, not assumed. Query for that, not `XCUIElementType.segmentedControl`.
    func testLiveTabTitleBarSwitchExists() {
        openMainWindow()
        let window = app.windows["MinusOne"]
        let segmented = window.radioGroups.firstMatch
        XCTAssertTrue(segmented.waitForExistence(timeout: 5), "Live/Practice segmented control not found in title bar")
        XCTAssertEqual(segmented.radioButtons.count, 2, "Expected exactly 2 segments (Live, Practice)")
        XCTAssertGreaterThan(segmented.frame.width, 0, "Segmented control has zero width — not actually laid out")
        XCTAssertGreaterThan(segmented.frame.height, 0, "Segmented control has zero height — not actually laid out")
    }

    /// REDESIGN.md §3: the Custom-scope app checklist must only be visible when Scope
    /// is "Custom", and — when visible — must not overlap the Scope row above it.
    func testCaptureChecklistOnlyShowsForCustomScope() {
        openMainWindow()
        let window = app.windows["MinusOne"]

        let scopePopup = window.popUpButtons["Scope"].exists
            ? window.popUpButtons["Scope"]
            : window.popUpButtons.firstMatch
        XCTAssertTrue(scopePopup.waitForExistence(timeout: 5), "Scope control not found")

        scopePopup.click()
        app.menuItems["All Apps"].firstMatch.click()
        XCTAssertFalse(
            window.scrollViews.firstMatch.exists && window.checkBoxes.firstMatch.isHittable,
            "App checklist is visible while Scope is All Apps"
        )

        scopePopup.click()
        app.menuItems["Custom"].firstMatch.click()
        let checklistRow = window.staticTexts["Spotify"]
        XCTAssertTrue(checklistRow.waitForExistence(timeout: 5), "App checklist did not appear for Custom scope")

        let scopeFrame = scopePopup.frame
        let checklistFrame = checklistRow.frame
        XCTAssertGreaterThanOrEqual(
            checklistFrame.minY, scopeFrame.maxY,
            "Checklist row overlaps the Scope row above it (top of checklist is above bottom of Scope)"
        )
    }

    /// Diagnostic, not a pass/fail check: dumps exact frame coordinates for the Practice tab's
    /// action row, split view pane, and sidebar content — the same technique that found the real
    /// cause of the titlebar-switch bug in `1096bdb`, instead of guessing again from screenshots.
    ///
    /// Launches its own app instance directly into the Practice tab via
    /// `MINUSONE_UI_TEST_OPEN_WINDOW=practice`, bypassing the menu-bar-click open flow — that
    /// flow's flakiness (see `openMainWindow()` above) is a separate, already-tracked problem and
    /// has nothing to do with what's being diagnosed here.
    func testDumpPracticeTabFrames() throws {
        app.terminate()
        app = XCUIApplication(url: Self.appURL)
        app.launchEnvironment["MINUSONE_UI_TEST_OPEN_WINDOW"] = "practice"
        app.launch()

        let window = app.windows["MinusOne"]
        XCTAssertTrue(window.waitForExistence(timeout: 5), "Main window never opened")

        func dump(_ label: String, _ element: XCUIElement) {
            print("FRAME_DUMP \(label): exists=\(element.exists) hittable=\(element.isHittable) frame=\(element.frame)")
        }

        dump("window", window)
        dump("importButton", app.buttons["Import"])
        dump("recordButton", app.buttons["Record"])
        dump("searchField", window.searchFields.firstMatch)
        dump("emptyStateTitle", window.staticTexts["No clip selected"])
        dump("splitGroup", window.splitGroups.firstMatch)
        dump("outline/table (sidebar)", window.outlines.firstMatch.exists ? window.outlines.firstMatch : window.tables.firstMatch)
    }
}
