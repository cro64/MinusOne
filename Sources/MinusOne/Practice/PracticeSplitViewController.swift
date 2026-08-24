import AppKit

/// Standard sidebar + detail layout for the Practice window.
final class PracticeSplitViewController: NSSplitViewController {
    init(sidebar: NSViewController, detail: NSViewController) {
        super.init(nibName: nil, bundle: nil)

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

        let detailItem = NSSplitViewItem(viewController: detail)

        addSplitViewItem(sidebarItem)
        addSplitViewItem(detailItem)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
