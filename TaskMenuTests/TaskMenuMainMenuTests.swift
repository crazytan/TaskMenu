import AppKit
import XCTest
@testable import TaskMenu

@MainActor
final class TaskMenuMainMenuTests: XCTestCase {
    private static let fixtureName = "Fixture"

    private func makeMenu() -> NSMenu {
        TaskMenuMainMenu.make(applicationName: Self.fixtureName)
    }

    private func submenu(_ title: String, in menu: NSMenu) throws -> NSMenu {
        try XCTUnwrap(menu.item(withTitle: title)?.submenu, "missing \(title) menu")
    }

    // MARK: - Structure

    func testTopLevelMenusStartWithTheApplicationMenu() throws {
        let menu = makeMenu()

        // AppKit treats item 0 as the application menu, so anything placed
        // before it gets absorbed into it.
        XCTAssertEqual(menu.items.map(\.title), [Self.fixtureName, "File", "Edit"])
        for item in menu.items {
            let submenu = try XCTUnwrap(item.submenu, "\(item.title) has no submenu")
            XCTAssertEqual(submenu.title, item.title)
        }
    }

    func testEditMenuContainsTheStandardTextEditingItems() throws {
        let edit = try submenu("Edit", in: makeMenu())

        XCTAssertEqual(
            edit.items.map { $0.isSeparatorItem ? "-" : $0.title },
            ["Undo", "Redo", "-", "Cut", "Copy", "Paste", "Delete", "-", "Select All", "-", "Filter Tasks"]
        )
    }

    func testFileMenuContainsOnlyNewTask() throws {
        let file = try submenu("File", in: makeMenu())

        XCTAssertEqual(file.items.map(\.title), ["New Task"])
    }

    // MARK: - Dispatch

    func testEditItemsSendTheFirstResponderTextEditingSelectors() throws {
        let edit = try submenu("Edit", in: makeMenu())
        let expected = [
            "Undo": "undo:",
            "Redo": "redo:",
            "Cut": "cut:",
            "Copy": "copy:",
            "Paste": "paste:",
            "Delete": "delete:",
            "Select All": "selectAll:"
        ]

        for (title, selectorName) in expected {
            let action = try XCTUnwrap(edit.item(withTitle: title)?.action, "\(title) has no action")
            XCTAssertEqual(
                NSStringFromSelector(action),
                selectorName,
                "\(title) must send \(selectorName); Undo/Redo are hand-written selector strings"
            )
        }
    }

    func testEveryItemDispatchesThroughTheResponderChain() throws {
        let menu = makeMenu()

        for topLevel in menu.items {
            let submenu = try XCTUnwrap(topLevel.submenu)
            for item in submenu.items where !item.isSeparatorItem {
                XCTAssertNil(
                    item.target,
                    "\(item.title) must keep a nil target so it dispatches to the first responder"
                )
            }
        }
    }

    func testTextEditingSelectorsAreImplementedByTheTextViewsThatReceiveThem() throws {
        let edit = try submenu("Edit", in: makeMenu())

        // Undo/Redo are deliberately excluded: AppKit implements `undo:`/`redo:`
        // outside any public class.
        for title in ["Cut", "Copy", "Paste", "Delete", "Select All"] {
            let action = try XCTUnwrap(edit.item(withTitle: title)?.action)
            XCTAssertTrue(
                NSTextView.instancesRespond(to: action),
                "NSTextView must implement \(NSStringFromSelector(action))"
            )
        }
    }

    func testTaskListShortcutsTargetRealTaskListControllerMethods() throws {
        let menu = makeMenu()
        let newTask = try XCTUnwrap(submenu("File", in: menu).item(withTitle: "New Task")?.action)
        let filterTasks = try XCTUnwrap(submenu("Edit", in: menu).item(withTitle: "Filter Tasks")?.action)

        XCTAssertTrue(TaskListAppKitViewController.instancesRespond(to: newTask))
        XCTAssertTrue(TaskListAppKitViewController.instancesRespond(to: filterTasks))
    }

    func testApplicationMenuQuitsAndOpensSettingsThroughTheResponderChain() throws {
        let app = try submenu(Self.fixtureName, in: makeMenu())

        let quit = try XCTUnwrap(app.item(withTitle: "Quit \(Self.fixtureName)")?.action)
        XCTAssertEqual(NSStringFromSelector(quit), "terminate:")

        let settings = try XCTUnwrap(app.item(withTitle: "Settings…")?.action)
        XCTAssertTrue(TaskMenuAppDelegate.instancesRespond(to: settings))
    }

    // MARK: - Enablement

    func testMenusAutoenableItemsSoValidationDecidesWhatFires() throws {
        let menu = makeMenu()

        // Autoenabling is what routes each item through validation against the
        // current first responder, so Copy greys out with no selection and ⌘N/⌘F
        // grey out away from the task list page.
        for title in ["File", "Edit"] {
            XCTAssertTrue(try submenu(title, in: menu).autoenablesItems, "\(title) must autoenable items")
        }
    }

    // MARK: - Key Equivalents

    func testShortcutsResolveToTheExpectedItems() {
        let menu = makeMenu()
        let expected: [(String, NSEvent.ModifierFlags, String)] = [
            ("z", .command, "Undo"),
            ("z", [.command, .shift], "Redo"),
            ("x", .command, "Cut"),
            ("c", .command, "Copy"),
            ("v", .command, "Paste"),
            ("a", .command, "Select All"),
            ("f", .command, "Filter Tasks"),
            ("n", .command, "New Task"),
            (",", .command, "Settings…"),
            ("q", .command, "Quit \(Self.fixtureName)")
        ]

        for (key, modifiers, title) in expected {
            XCTAssertEqual(
                Self.item(for: key, modifiers: modifiers, in: menu)?.title,
                title,
                "\(key) + \(modifiers) must resolve to \(title)"
            )
        }
    }

    func testDeleteHasNoKeyEquivalentSoBackspaceKeepsWorking() throws {
        let edit = try submenu("Edit", in: makeMenu())

        XCTAssertEqual(edit.item(withTitle: "Delete")?.keyEquivalent, "")
    }

    /// Mirrors `NSMenu`'s key-equivalent matching so shortcut coverage can be
    /// asserted without synthesizing events.
    private static func item(
        for keyEquivalent: String,
        modifiers: NSEvent.ModifierFlags,
        in menu: NSMenu
    ) -> NSMenuItem? {
        for item in menu.items {
            if let submenu = item.submenu,
               let match = self.item(for: keyEquivalent, modifiers: modifiers, in: submenu) {
                return match
            }
            if !item.keyEquivalent.isEmpty,
               item.keyEquivalent == keyEquivalent,
               item.keyEquivalentModifierMask == modifiers {
                return item
            }
        }
        return nil
    }

    // MARK: - Responder Chain

    /// The menu items carry no target, so ⌘N/⌘F only work if the responder chain
    /// from a focused text field actually reaches the task list controller. That
    /// link is the non-obvious part of the design, so assert it directly.
    func testFocusShortcutsResolveToTheTaskListControllerFromAFocusedTextField() throws {
        let state = AppState()
        let controller = TaskListAppKitViewController(
            appState: state,
            pane: state.primaryPane,
            onOpenSettings: {},
            onRequestClose: {}
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 480),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller

        let filterField = try XCTUnwrap(
            Self.textField(accessibilityLabel: "Filter tasks", in: controller.view),
            "filter field not found"
        )
        XCTAssertTrue(window.makeFirstResponder(filterField))

        for selector in [#selector(TaskListAppKitViewController.focusQuickAdd(_:)),
                         #selector(TaskListAppKitViewController.focusFilterField(_:))] {
            let responder = Self.firstResponder(responding: selector, from: window.firstResponder)
            XCTAssertTrue(
                responder === controller,
                "\(NSStringFromSelector(selector)) must resolve to the task list controller"
            )
        }
    }

    func testFocusShortcutsAreEnabledWhileTheTaskListPageIsShowing() {
        let state = AppState()
        let controller = TaskListAppKitViewController(
            appState: state,
            pane: state.primaryPane,
            onOpenSettings: {},
            onRequestClose: {}
        )
        _ = controller.view

        for selector in [#selector(TaskListAppKitViewController.focusQuickAdd(_:)),
                         #selector(TaskListAppKitViewController.focusFilterField(_:))] {
            let item = NSMenuItem(title: "", action: selector, keyEquivalent: "")
            XCTAssertTrue(
                controller.validateMenuItem(item),
                "\(NSStringFromSelector(selector)) must be enabled on the list page"
            )
        }
        // Items this controller does not own must stay enabled so validation
        // never disables another responder's action.
        let unrelated = NSMenuItem(title: "", action: #selector(NSText.copy(_:)), keyEquivalent: "")
        XCTAssertTrue(controller.validateMenuItem(unrelated))
    }

    private static func firstResponder(responding selector: Selector, from responder: NSResponder?) -> NSResponder? {
        var current = responder
        while let candidate = current {
            if candidate.responds(to: selector) {
                return candidate
            }
            current = candidate.nextResponder
        }
        return nil
    }

    private static func textField(accessibilityLabel label: String, in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.accessibilityLabel() == label {
            return field
        }
        for subview in view.subviews {
            if let found = textField(accessibilityLabel: label, in: subview) {
                return found
            }
        }
        return nil
    }

    // MARK: - Install Site

    func testLaunchInstallsTheMainMenuOnTheRunningApplication() throws {
        // `applicationDidFinishLaunching` installs the menu unconditionally, and
        // the test bundle is hosted in the app, so this reads the real launch
        // path. Assert by containment: AppKit may inject its own items.
        let mainMenu = try XCTUnwrap(NSApplication.shared.mainMenu, "launch must install a main menu")

        XCTAssertNotNil(mainMenu.items.first?.submenu, "item 0 must be the application menu")
        XCTAssertNotNil(mainMenu.item(withTitle: "Edit")?.submenu)
        XCTAssertNotNil(mainMenu.item(withTitle: "File")?.submenu)
    }
}
