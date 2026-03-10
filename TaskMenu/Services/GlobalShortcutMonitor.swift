@preconcurrency import AppKit
import Foundation

@MainActor
protocol GlobalShortcutMonitoring: AnyObject {
    func setHandler(_ handler: @escaping @MainActor () -> Void)
    func setEnabled(_ enabled: Bool)
    func invalidate()
}

@MainActor
final class GlobalShortcutMonitor: GlobalShortcutMonitoring {
    private enum Shortcut {
        static let keyCode: UInt16 = 17
        static let requiredModifiers: NSEvent.ModifierFlags = [.command, .shift]
        static let disallowedModifiers: NSEvent.ModifierFlags = [.control, .option]
    }

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var terminationObserver: NSObjectProtocol?
    private var handler: (@MainActor () -> Void)?

    init() {
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.invalidate()
            }
        }
    }

    deinit {
        MainActor.assumeIsolated {
            invalidate()
        }
    }

    func setHandler(_ handler: @escaping @MainActor () -> Void) {
        self.handler = handler
    }

    func setEnabled(_ enabled: Bool) {
        if enabled {
            registerMonitorsIfNeeded()
        } else {
            removeMonitors()
        }
    }

    func invalidate() {
        removeMonitors()
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
            self.terminationObserver = nil
        }
        handler = nil
    }

    private func registerMonitorsIfNeeded() {
        guard globalMonitor == nil, localMonitor == nil else { return }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard Self.matchesShortcut(event) else { return }
            Task { @MainActor [weak self] in
                self?.handler?()
            }
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard Self.matchesShortcut(event) else { return event }
            Task { @MainActor [weak self] in
                self?.handler?()
            }
            return nil
        }
    }

    private func removeMonitors() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }

        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
    }

    nonisolated private static func matchesShortcut(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, !event.isARepeat, event.keyCode == Shortcut.keyCode else {
            return false
        }

        let modifiers = event.modifierFlags.intersection([.command, .shift, .control, .option])
        guard modifiers.isSuperset(of: Shortcut.requiredModifiers) else {
            return false
        }

        return modifiers.intersection(Shortcut.disallowedModifiers).isEmpty
    }
}
