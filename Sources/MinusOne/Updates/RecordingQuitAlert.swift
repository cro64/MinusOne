import AppKit

enum RecordingQuitAlert {
    /// Returns true for Stop & Quit, false for Cancel.
    static func run() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Stop recording and quit?"
        alert.addButton(withTitle: "Stop & Quit")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
}
