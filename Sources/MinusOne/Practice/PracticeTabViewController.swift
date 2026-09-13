import AppKit

/// Hosts the Practice tab's sidebar+deck split view.
///
/// This wrapper looks redundant now that it carries no chrome of its own, and it is not.
/// `NSSplitViewController` computes its divider/holding-priority layout expecting the normal
/// view-controller lifecycle (`viewWillAppear`/`viewDidAppear`) to fire, and an earlier shape that
/// held `practiceSplitViewController.view` as a plain subview — never adding the controller via
/// `addChild(_:)` anywhere in the app — is what produced the "gap above the button row, content
/// pinned to the bottom of the window" bug. The containment below is the fix; do not inline it.
///
/// The Import/Record row this class used to own now lives in the sidebar's own header, and its
/// sidebar toggle in the window's title bar row. See
/// `docs/superpowers/specs/2026-09-07-practice-action-row-design.md`.
final class PracticeTabViewController: NSViewController {
    private let splitViewController: PracticeSplitViewController
    private let sidebar: ClipSidebarViewController

    init(splitViewController: PracticeSplitViewController, sidebar: ClipSidebarViewController) {
        self.splitViewController = splitViewController
        self.sidebar = sidebar
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = AutoLayoutView()
        view = root
        addChild(splitViewController)
        Layout.pin(splitViewController.view, to: root)
    }

    /// Forwarded to the sidebar, which owns the header these now live in. Kept on this class so
    /// `MainWindowController`'s existing call sites don't have to reach past it.
    func setRecordingState(_ recording: Bool) {
        sidebar.setRecordingState(recording)
    }

    func updateRecordingElapsed(_ seconds: Double) {
        sidebar.updateRecordingElapsed(seconds)
    }
}
