import AppKit

/// The application's main menu.
///
/// MinusOne started life as an `LSUIElement` menu bar popover with no main menu, and without one
/// **no standard editing shortcut works anywhere in the app**: ⌘A, ⌘C, ⌘V, ⌘X and ⌘Z are not built
/// into `NSTextView`, they are key equivalents that `NSApplication` resolves against `mainMenu`
/// before the event ever reaches the first responder. That is why Select All did nothing while
/// renaming a clip.
///
/// MinusOne is now a regular app (Dock icon, Cmd-Tab entry) with the status item as a companion
/// control, so this menu bar is present for the app's whole lifetime, not just while the main
/// window is open.
enum AppMenu {
    static func install(into app: NSApplication = .shared, updates: UpdateController? = nil) {
        let mainMenu = makeMainMenu(appName: ProcessInfo.processInfo.processName, updates: updates)
        app.mainMenu = mainMenu
        app.windowsMenu = mainMenu.items.first { $0.title == "Window" }?.submenu
    }

    static func makeMainMenu(appName: String, updates: UpdateController?) -> NSMenu {
        var appItems: [NSMenuItem] = [
            item("About \(appName)", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
        ]
        if let updates {
            // Targets the controller directly: it validates the item (disabled while a check runs).
            let check = NSMenuItem(title: "Check for Updates…", action: #selector(UpdateController.checkForUpdates(_:)), keyEquivalent: "")
            check.target = updates
            appItems.append(check)
        }
        appItems += [
            .separator(),
            item("Hide \(appName)", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            // Same door as the popover's Quit link: closing the window leaves Live and any
            // recording running, quitting does not.
            item("Quit \(appName)", #selector(NSApplication.terminate(_:)), "q")
        ]

        let mainMenu = NSMenu()
        mainMenu.addItem(submenu(titled: appName, items: appItems))

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

        mainMenu.addItem(submenu(titled: "Window", items: [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
            .separator(),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
            item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)))
        ]))

        return mainMenu
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
