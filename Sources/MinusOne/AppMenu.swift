import AppKit

/// The application's main menu.
///
/// MinusOne is an `LSUIElement` app that started life as a menu bar popover, so it never had one —
/// and without a main menu **no standard editing shortcut works anywhere in the app**: ⌘A, ⌘C, ⌘V,
/// ⌘X and ⌘Z are not built into `NSTextView`, they are key equivalents that `NSApplication`
/// resolves against `mainMenu` before the event ever reaches the first responder. That is why
/// Select All did nothing while renaming a clip.
///
/// The menu bar itself only appears while the window is open (`AppDelegate` flips the activation
/// policy to `.regular` for that), which is also the only time these commands have anywhere to go.
enum AppMenu {
    static func install(into app: NSApplication = .shared) {
        let appName = ProcessInfo.processInfo.processName

        let mainMenu = NSMenu()
        mainMenu.addItem(submenu(titled: appName, items: [
            item("About \(appName)", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("Hide \(appName)", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            // Same door as the popover's Quit link: closing the window leaves Live and any
            // recording running, quitting does not.
            item("Quit \(appName)", #selector(NSApplication.terminate(_:)), "q")
        ]))

        mainMenu.addItem(submenu(titled: "Edit", items: [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Delete", #selector(NSText.delete(_:))),
            item("Select All", #selector(NSText.selectAll(_:)), "a")
        ]))

        let windowMenu = submenu(titled: "Window", items: [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
            .separator(),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
            item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)))
        ])
        mainMenu.addItem(windowMenu)

        app.mainMenu = mainMenu
        app.windowsMenu = windowMenu.submenu
    }

    private static func submenu(titled title: String, items: [NSMenuItem]) -> NSMenuItem {
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        items.forEach { menu.addItem($0) }
        holder.submenu = menu
        return holder
    }

    /// Target stays `nil` on purpose: that's what sends the action down the responder chain, so
    /// Copy/Paste/Select All land on whatever text is being edited at the time.
    private static func item(
        _ title: String,
        _ action: Selector,
        _ keyEquivalent: String = "",
        _ modifiers: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        if !keyEquivalent.isEmpty {
            item.keyEquivalentModifierMask = modifiers
        }
        return item
    }
}
