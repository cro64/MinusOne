import AppKit

/// Standard sidebar + detail layout for the Practice window.
final class PracticeSplitViewController: NSSplitViewController {
    /// Kept so `toggleSidebar()` can flip it back — dragging the divider all the way to the
    /// leading edge collapses this item (that's `canCollapse = true` below working as intended),
    /// but a collapsed divider has no width left to grab, so without an explicit toggle a user who
    /// drags it shut has no way to get the library list back.
    private let sidebarItem: NSSplitViewItem

    init(sidebar: NSViewController, detail: NSViewController) {
        // A plain item, not `NSSplitViewItem(sidebarWithViewController:)`. The sidebar variant is
        // built for a pane that runs the full height of the window under the title bar, so with
        // `.fullSizeContentView` it insets its content by the title bar height regardless of where
        // the split view is actually placed — measured at 24pt of dead space under Practice's
        // Import/Record row, which sits above this split view. `ClipSidebarViewController` paints its
        // own background instead.
        let sidebarItem = NSSplitViewItem(viewController: sidebar)
        sidebarItem.minimumThickness = 220
        sidebarItem.maximumThickness = 360
        sidebarItem.canCollapse = true
        sidebarItem.holdingPriority = .init(260)
        self.sidebarItem = sidebarItem

        let detailItem = NSSplitViewItem(viewController: detail)

        super.init(nibName: nil, bundle: nil)

        addSplitViewItem(sidebarItem)
        addSplitViewItem(detailItem)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Restores a divider-collapsed sidebar, or hides it the same way dragging the divider shut
    /// does. `.animator()` so a click reads as a slide, matching what dragging the divider looks
    /// like, rather than the pane snapping open instantly.
    func toggleSidebar() {
        sidebarItem.animator().isCollapsed.toggle()
    }

    var isSidebarCollapsed: Bool { sidebarItem.isCollapsed }
}
