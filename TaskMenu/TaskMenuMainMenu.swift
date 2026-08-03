import AppKit

/// `NSApplication.mainMenu` for TaskMenu.
///
/// TaskMenu is `LSUIElement`, so this menu is never *drawn*: an accessory
/// activation policy has no menu bar. It still has to exist. AppKit implements
/// Cut/Copy/Paste/Delete/Select All/Undo/Redo by matching the key equivalents of
/// the *main menu* during the key-equivalent pass of `NSApplication.sendEvent`
/// and dispatching the matched item's action to the first responder. With
/// `mainMenu == nil` there is nothing to match, so every one of those shortcuts
/// was silently dropped in every text input in the app.
///
/// This menu is not a discovery surface — users never see it. Anything that
/// needs to be discoverable belongs in the popover, the Settings window, or the
/// status item's right-click menu.
@MainActor
enum TaskMenuMainMenu {
    /// Name used for the application menu and its Quit item.
    static var applicationName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? ProcessInfo.processInfo.processName
    }

    /// Creates no windows, changes no activation policy, and starts no work, so
    /// it is safe to call in every UI mode.
    static func install(into application: NSApplication) {
        application.mainMenu = make(applicationName: applicationName)
    }

    /// Pure factory, so tests can build and inspect the menu without `NSApp`.
    static func make(applicationName: String) -> NSMenu {
        let mainMenu = NSMenu(title: "MainMenu")

        // AppKit unconditionally treats main-menu item 0 as the application
        // menu. If File or Edit were first, its items would be absorbed into the
        // application menu, so the app menu must exist even though this app
        // never draws a menu bar.
        mainMenu.addItem(topLevelItem(
            title: applicationName,
            submenu: makeApplicationMenu(applicationName: applicationName)
        ))
        mainMenu.addItem(topLevelItem(title: "File", submenu: makeFileMenu()))
        mainMenu.addItem(topLevelItem(title: "Edit", submenu: makeEditMenu()))

        return mainMenu
    }

    private static func makeApplicationMenu(applicationName: String) -> NSMenu {
        let menu = NSMenu(title: applicationName)

        menu.addItem(firstResponderItem(
            title: "Settings…",
            action: #selector(TaskMenuAppDelegate.showSettingsWindow(_:)),
            keyEquivalent: ","
        ))
        menu.addItem(.separator())
        menu.addItem(firstResponderItem(
            title: "Quit \(applicationName)",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))

        return menu
    }

    private static func makeFileMenu() -> NSMenu {
        let menu = NSMenu(title: "File")

        // A custom selector rather than `newDocument:`, which would resolve to
        // `NSDocumentController` instead of the task list.
        menu.addItem(firstResponderItem(
            title: "New Task",
            action: #selector(TaskListAppKitViewController.focusQuickAdd(_:)),
            keyEquivalent: "n"
        ))

        return menu
    }

    private static func makeEditMenu() -> NSMenu {
        // `autoenablesItems` intentionally stays at its default `true`. AppKit
        // then computes each item's enabled state through menu-item validation
        // against the current first responder, which is what greys Copy out with
        // no selection and Filter Tasks out away from the task list page.
        // Setting it to `false` — the pattern this app's popup and context menus
        // use — would be wrong here.
        let menu = NSMenu(title: "Edit")

        menu.addItem(firstResponderItem(title: "Undo", action: undoAction, keyEquivalent: "z"))
        menu.addItem(firstResponderItem(
            title: "Redo",
            action: redoAction,
            keyEquivalent: "z",
            modifiers: [.command, .shift]
        ))
        menu.addItem(.separator())
        menu.addItem(firstResponderItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        menu.addItem(firstResponderItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        menu.addItem(firstResponderItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        // No key equivalent: Delete must not hijack Backspace in text fields.
        menu.addItem(firstResponderItem(title: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(firstResponderItem(
            title: "Select All",
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a"
        ))
        menu.addItem(.separator())
        // A custom selector rather than `performFindPanelAction:`, which would
        // resolve to the text finder instead of the task list's filter field.
        menu.addItem(firstResponderItem(
            title: "Filter Tasks",
            action: #selector(TaskListAppKitViewController.focusFilterField(_:)),
            keyEquivalent: "f"
        ))

        return menu
    }

    /// `undo:` and `redo:` are AppKit action methods with no Swift-visible
    /// declaration. `UndoManager` only declares `undo()` and `redo()`, whose
    /// selectors have no colon, so `#selector(UndoManager.undo)` would build the
    /// wrong selector and match nothing. They must be constructed from a string,
    /// exactly as the standard AppKit MainMenu template wires Undo/Redo to First
    /// Responder. The extra parentheses avoid the deprecation warning that
    /// `Selector("undo:")` emits on a bare string literal.
    private static let undoAction = Selector(("undo:"))
    private static let redoAction = Selector(("redo:"))

    private static func topLevelItem(title: String, submenu: NSMenu) -> NSMenuItem {
        // The menu bar draws `NSMenuItem.title`, not `NSMenu.title`. Keep the
        // two in sync so title lookups and accessibility agree.
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    /// Builds an item that dispatches through the responder chain.
    ///
    /// `target = nil` is the entire mechanism: on a key-equivalent match AppKit
    /// calls `NSApp.sendAction(item.action, to: nil, from: item)`, and
    /// `targetForAction` walks the key window's responder chain — the
    /// `NSTextField` field editor, the notes `NSTextView`, then (because
    /// `NSViewController` is inserted into the chain) the task list controller —
    /// before reaching `NSApp` and its delegate. That is how one menu serves
    /// every text input with no wiring, how `terminate:` finds `NSApp`, and how
    /// `showSettingsWindow:` finds `TaskMenuAppDelegate`. Never give these items
    /// a concrete target.
    private static func firstResponderItem(
        title: String,
        action: Selector,
        keyEquivalent: String,
        modifiers: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.keyEquivalentModifierMask = modifiers
        item.target = nil
        return item
    }
}
