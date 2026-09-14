import AppKit
import XCTest
@testable import MinusOne

/// The sidebar header's two library actions. `loadView()` is called directly rather than
/// going through a window: the header is pure Auto Layout with no audio or file dependencies
/// beyond the store's root folder.
final class ClipSidebarHeaderTests: XCTestCase {
    private var root: URL!
    private var sidebar: ClipSidebarViewController!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipSidebarHeader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        sidebar = ClipSidebarViewController(libraryStore: ClipLibraryStore(rootURL: root))
        sidebar.loadView()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testTheActionsKeepTheirNamesAfterLosingTheirTitles() {
        XCTAssertEqual(sidebar.importButton.title, "", "the header buttons are icon-only")
        XCTAssertEqual(sidebar.recordButton.title, "")
        // `setIcon` routes one label into both the accessibility name and the tooltip, which is
        // the only thing carrying the meaning once the visible title is gone.
        XCTAssertEqual(sidebar.importButton.toolTip, "Import")
        XCTAssertEqual(sidebar.importButton.accessibilityLabel(), "Import")
        XCTAssertEqual(sidebar.recordButton.toolTip, "Record")
        XCTAssertEqual(sidebar.recordButton.accessibilityLabel(), "Record")
    }

    func testRecordIsTheOnlyAccentInTheHeader() {
        // Ghost's default tint is the coral accent; Import is deliberately pulled off it so the
        // pane spends the accent exactly once.
        sidebar.recordButton.refreshStyle()
        sidebar.importButton.refreshStyle()
        XCTAssertEqual(sidebar.recordButton.contentTintColor, .brandAccent)
        XCTAssertEqual(sidebar.importButton.contentTintColor, .secondaryLabelColor)
    }

    func testTheHeaderFitsTheNarrowestSidebar() {
        // 220pt is `PracticeSplitViewController`'s `minimumThickness`. The search field has to
        // remain usable there, not just at the 260pt default.
        sidebar.view.frame = NSRect(x: 0, y: 0, width: 220, height: 500)
        sidebar.view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThanOrEqual(
            sidebar.searchFieldForTesting.frame.width, 120,
            "the search field collapsed to \(sidebar.searchFieldForTesting.frame.width)pt at the minimum sidebar width"
        )
    }

    func testTheActionsReportClicks() {
        var imported = 0
        var recorded = 0
        sidebar.onImportClicked = { imported += 1 }
        sidebar.onRecordClicked = { recorded += 1 }

        sidebar.importButton.performClick(nil)
        sidebar.recordButton.performClick(nil)

        XCTAssertEqual(imported, 1)
        XCTAssertEqual(recorded, 1)
    }

    func testTheElapsedReadoutTakesOverTheSearchFieldWhileRecording() {
        XCTAssertTrue(sidebar.elapsedButtonForTesting.isHidden, "no readout before a take starts")
        XCTAssertFalse(sidebar.searchFieldForTesting.isHidden)

        sidebar.setRecordingState(true)

        XCTAssertFalse(sidebar.elapsedButtonForTesting.isHidden)
        XCTAssertTrue(sidebar.searchFieldForTesting.isHidden, "the readout replaces the field rather than adding a row")
        // Seeded rather than blank, so the first frame isn't an empty control.
        XCTAssertEqual(sidebar.elapsedButtonForTesting.title, "●  0:00")
        XCTAssertEqual(sidebar.recordButton.toolTip, "Stop")
    }

    /// The header's four controls (import/record icon buttons, search field, elapsed readout) must
    /// share one height — otherwise the scroll view pinned to the header's bottom shifts the whole
    /// clip list when recording starts or stops.
    func testTheHeaderHeightDoesNotChangeWhileRecording() {
        sidebar.view.frame = NSRect(x: 0, y: 0, width: 260, height: 500)
        sidebar.view.layoutSubtreeIfNeeded()
        let idleTop = sidebar.scrollViewForTesting.frame.maxY

        sidebar.setRecordingState(true)
        sidebar.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(
            sidebar.scrollViewForTesting.frame.maxY, idleTop,
            "the clip list shifted when recording started"
        )

        sidebar.setRecordingState(false)
        sidebar.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(
            sidebar.scrollViewForTesting.frame.maxY, idleTop,
            "the clip list shifted when recording stopped"
        )
    }

    func testTheSearchQuerySurvivesARecording() {
        sidebar.searchFieldForTesting.stringValue = "leaves"
        sidebar.setRecordingState(true)
        sidebar.updateRecordingElapsed(24)
        XCTAssertEqual(sidebar.elapsedButtonForTesting.title, "●  0:24")

        sidebar.setRecordingState(false)

        XCTAssertFalse(sidebar.searchFieldForTesting.isHidden)
        XCTAssertTrue(sidebar.elapsedButtonForTesting.isHidden)
        XCTAssertEqual(
            sidebar.searchFieldForTesting.stringValue, "leaves",
            "the query was cleared by the swap"
        )
        XCTAssertEqual(sidebar.recordButton.toolTip, "Record")
    }
}
