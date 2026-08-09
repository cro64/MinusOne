import AppKit

/// Standard sidebar + detail layout for the Practice window.
final class PracticeSplitViewController: NSSplitViewController {
    init(sidebar: NSViewController, detail: NSViewController) {
        super.init(nibName: nil, bundle: nil)

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
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
