import AppKit

@MainActor
final class StatusBarController: NSObject {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let contextMenu = NSMenu()
    private let menuPresentationRefreshTrigger: MenuPresentationRefreshTrigger
    private let appState: AppState
    private let appStateObserver = TaskMenuAppStateObserver()
    /// Lives for the process, like the controller itself; a `deinit` that
    /// removes it would need main-actor access the compiler will not grant.
    private var dayChangeObserver: (any NSObjectProtocol)?
    private var outsideClickMonitors: [Any] = []

    init(appState: AppState) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        popover = NSPopover()
        menuPresentationRefreshTrigger = MenuPresentationRefreshTrigger(appState: appState)
        self.appState = appState
        super.init()

        configureStatusItem()
        configurePopover(appState: appState)
        configureContextMenu()
        updateStatusItemTitle()
        observeAppState()
        observeDayChanges()
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }

        let image = NSImage(named: "MenuBarIcon")
            ?? NSImage(systemSymbolName: "checklist", accessibilityDescription: "TaskMenu")
        image?.isTemplate = true

        button.image = image
        button.imageHugsTitle = true
        button.toolTip = "TaskMenu"
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    /// Re-renders the pending count whenever the state it depends on changes.
    /// The count itself is kept fresh by `AppState` (background sweep and
    /// periodic loop); this only draws it.
    private func observeAppState() {
        appStateObserver.observe { [appState] in
            _ = appState.menuBarPendingCount
        } onChange: { [weak self] in
            self?.updateStatusItemTitle()
        }
    }

    /// A "Due today" count rolls over at midnight without waiting for the
    /// next periodic tick.
    private func observeDayChanges() {
        dayChangeObserver = NotificationCenter.default.addObserver(
            forName: .NSCalendarDayChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.updateStatusItemTitle()
            }
        }
    }

    private func updateStatusItemTitle() {
        guard let button = statusItem.button else { return }
        let title = MenuBarCounterPresentation.title(forPendingCount: appState.menuBarPendingCount)
        MenuBarCounterPresentation.apply(title: title, to: button)
        statusItem.length = MenuBarCounterPresentation.statusItemLength(forTitle: title)
    }

    private func configurePopover(appState: AppState) {
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = TaskPopoverViewController(
            appState: appState,
            onRequestClose: { [weak self] in
                self?.popover.performClose(nil)
                self?.stopOutsideClickMonitoring()
            }
        )
    }

    private func configureContextMenu() {
        contextMenu.autoenablesItems = false

        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        contextMenu.addItem(settingsItem)

        contextMenu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit TaskMenu",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        contextMenu.addItem(quitItem)
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if StatusItemClickRouting.shouldShowContextMenu(
            eventType: event?.type,
            modifierFlags: event?.modifierFlags ?? []
        ) {
            showContextMenu(from: sender)
        } else {
            togglePopover(from: sender)
        }
    }

    private func togglePopover(from button: NSStatusBarButton) {
        if popover.isShown {
            closePopover()
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            setStatusItemHighlighted(true)
            startOutsideClickMonitoring()
        }
    }

    private func showContextMenu(from button: NSStatusBarButton) {
        closePopover()

        statusItem.menu = contextMenu
        button.performClick(nil)
        statusItem.menu = nil
    }

    private func startOutsideClickMonitoring() {
        stopOutsideClickMonitoring()

        let eventMask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]

        if let localMonitor = NSEvent.addLocalMonitorForEvents(matching: eventMask, handler: { [weak self] event in
            MainActor.assumeIsolated {
                self?.closePopoverIfLocalClickIsOutside(event)
            }
            return event
        }) {
            outsideClickMonitors.append(localMonitor)
        }

        if let globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: eventMask, handler: { [weak self] _ in
            Task { @MainActor in
                self?.closePopoverFromOutsideClick()
            }
        }) {
            outsideClickMonitors.append(globalMonitor)
        }
    }

    private func stopOutsideClickMonitoring() {
        for monitor in outsideClickMonitors {
            NSEvent.removeMonitor(monitor)
        }
        outsideClickMonitors = []
    }

    private func closePopoverIfLocalClickIsOutside(_ event: NSEvent) {
        guard PopoverClickHandling.shouldClosePopover(
            eventWindow: event.window,
            popoverWindow: popover.contentViewController?.view.window,
            statusItemWindow: statusItem.button?.window
        ) else {
            return
        }

        closePopoverFromOutsideClick()
    }

    private func closePopoverFromOutsideClick() {
        guard popover.isShown else {
            stopOutsideClickMonitoring()
            setStatusItemHighlighted(false)
            return
        }

        closePopover()
    }

    private func closePopover() {
        popover.performClose(nil)
        stopOutsideClickMonitoring()
        setStatusItemHighlighted(false)
    }

    private func setStatusItemHighlighted(_ isHighlighted: Bool) {
        StatusItemHighlighting.apply(isHighlighted, to: statusItem.button)
    }

    @objc private func openSettings() {
        closePopover()
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(#selector(TaskMenuAppDelegate.showSettingsWindow(_:)), to: NSApp.delegate, from: nil)
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}

extension StatusBarController: NSPopoverDelegate {
    func popoverDidShow(_ notification: Notification) {
        setStatusItemHighlighted(true)
        menuPresentationRefreshTrigger.menuDidOpen()
    }

    func popoverDidClose(_ notification: Notification) {
        stopOutsideClickMonitoring()
        setStatusItemHighlighted(false)
    }
}

@MainActor
final class MenuPresentationRefreshTrigger {
    private let refresh: @MainActor () async -> Void

    init(appState: AppState) {
        refresh = { [appState] in
            await appState.refreshForMenuPresentation()
        }
    }

    init(refresh: @escaping @MainActor () async -> Void) {
        self.refresh = refresh
    }

    @discardableResult
    func menuDidOpen() -> Task<Void, Never> {
        Task { @MainActor in
            await refresh()
        }
    }
}

enum StatusItemClickRouting {
    /// Right-clicks and Control+left-clicks (the standard secondary-click
    /// equivalent) open the context menu; plain left-clicks toggle the popover.
    static func shouldShowContextMenu(
        eventType: NSEvent.EventType?,
        modifierFlags: NSEvent.ModifierFlags
    ) -> Bool {
        if eventType == .rightMouseUp { return true }
        return eventType == .leftMouseUp && modifierFlags.contains(.control)
    }
}

enum PopoverClickHandling {
    static func shouldClosePopover(
        eventWindow: NSWindow?,
        popoverWindow: NSWindow?,
        statusItemWindow: NSWindow?
    ) -> Bool {
        guard let eventWindow else { return true }
        if let popoverWindow, eventWindow === popoverWindow { return false }
        if let statusItemWindow, eventWindow === statusItemWindow { return false }
        return true
    }
}

@MainActor
enum StatusItemHighlighting {
    static func apply(_ isHighlighted: Bool, to button: NSButton?) {
        button?.highlight(isHighlighted)
    }
}

/// Renders the pending count next to the status item icon: title + image
/// when there is something to show, icon only otherwise. No animation —
/// nothing here should move, with or without Reduce Motion.
@MainActor
enum MenuBarCounterPresentation {
    /// nil when nothing should be shown (count <= 0).
    static func title(forPendingCount count: Int) -> String? {
        count > 0 ? String(count) : nil
    }

    static func apply(title: String?, to button: NSButton) {
        if let title {
            button.title = title
            button.imagePosition = .imageLeading
        } else {
            button.title = ""
            button.imagePosition = .imageOnly
        }
    }

    static func statusItemLength(forTitle title: String?) -> CGFloat {
        title == nil ? NSStatusItem.squareLength : NSStatusItem.variableLength
    }
}
