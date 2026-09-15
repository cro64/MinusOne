import AppKit

enum RecordingUpdateAlert {
    /// Returns true for Stop & Install, false for Later.
    static func run() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Finish recording before updating?"
        alert.informativeText = "MinusOne restarts to install the update. Stop & Install saves your recording to the library first."
        alert.addButton(withTitle: "Stop & Install")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
}
