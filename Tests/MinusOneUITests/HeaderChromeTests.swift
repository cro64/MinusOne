import AppKit
import XCTest
@testable import MinusOne

/// The title bar's leading slot is shared by the back button and the sidebar toggle. They must
/// never both be visible: the back button only appears on takeover pages, where the split view
/// the toggle acts on isn't on screen at all.
///
/// `MainWindowController` builds an `NSWindow` and an `AudioEngine` in `init`, so it is not
/// constructed here (`WindowSizingTests` documents the same avoidance). The rule itself is what
/// matters, and it is exposed as a pure function.
final class HeaderChromeTests: XCTestCase {
    func testTheToggleShowsOnlyOnThePracticeTab() {
        XCTAssertTrue(
            HeaderChrome.showsSidebarToggle(showsBack: false, onPractice: true),
            "the toggle should be visible on the Practice tab"
        )
        XCTAssertFalse(
            HeaderChrome.showsSidebarToggle(showsBack: false, onPractice: false),
            "Live has no split view, so there is nothing to toggle"
        )
    }

    func testTheToggleAndTheBackButtonAreNeverBothVisible() {
        // A takeover page (Record, onboarding) reached from Practice: back wins, toggle goes.
        XCTAssertFalse(HeaderChrome.showsSidebarToggle(showsBack: true, onPractice: true))
    }
}
