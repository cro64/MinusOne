import AppKit
import XCTest
@testable import MinusOne

final class AppMenuTests: XCTestCase {
    func testCheckForUpdatesComesRightAfterAbout() throws {
        let updates = UpdateController(driver: FakeUpdater())
        let appMenu = try XCTUnwrap(AppMenu.makeMainMenu(appName: "MinusOne", updates: updates).items.first?.submenu)

        XCTAssertEqual(appMenu.items[0].title, "About MinusOne")
        let check = appMenu.items[1]
        XCTAssertEqual(check.title, "Check for Updates…")
        XCTAssertEqual(check.action, #selector(UpdateController.checkForUpdates(_:)))
        XCTAssertTrue(check.target === updates, "the item must target the update controller, which also validates it")
        XCTAssertTrue(appMenu.items[2].isSeparatorItem)
    }

    func testWithoutAnUpdaterThereIsNoItem() throws {
        let appMenu = try XCTUnwrap(AppMenu.makeMainMenu(appName: "MinusOne", updates: nil).items.first?.submenu)
        XCTAssertFalse(appMenu.items.contains { $0.title == "Check for Updates…" })
    }
}
