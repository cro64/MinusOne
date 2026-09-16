import AppKit
import XCTest
@testable import MinusOne

final class MenuBarPopoverUpdateItemTests: XCTestCase {
    private func loadedPopover() -> MenuBarPopoverViewController {
        let popover = MenuBarPopoverViewController()
        _ = popover.view
        return popover
    }

    func testWithNoUpdateTheFooterIsUnchanged() {
        XCTAssertEqual(loadedPopover().footerTitlesForTesting, ["Open MinusOne…", "Quit"])
    }

    func testAWaitingUpdateAppearsAboveOpenMinusOne() {
        let popover = loadedPopover()
        popover.setPendingUpdateVersion("0.8.0")
        XCTAssertEqual(popover.footerTitlesForTesting, ["Update to 0.8.0…", "Open MinusOne…", "Quit"])
    }

    func testClearingTheUpdateRemovesTheItem() {
        let popover = loadedPopover()
        popover.setPendingUpdateVersion("0.8.0")
        popover.setPendingUpdateVersion(nil)
        XCTAssertEqual(popover.footerTitlesForTesting, ["Open MinusOne…", "Quit"])
    }

    /// The updater can report before the popover has ever been opened.
    func testAnUpdateSetBeforeTheViewLoadsStillShows() {
        let popover = MenuBarPopoverViewController()
        popover.setPendingUpdateVersion("0.8.0")
        _ = popover.view
        XCTAssertEqual(popover.footerTitlesForTesting.first, "Update to 0.8.0…")
    }

    func testClickingTheItemReportsIt() {
        let popover = loadedPopover()
        var clicks = 0
        popover.onUpdateClicked = { clicks += 1 }
        popover.setPendingUpdateVersion("0.8.0")
        popover.simulateUpdateClickForTesting()
        XCTAssertEqual(clicks, 1)
    }
}
