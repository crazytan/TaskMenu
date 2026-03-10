import Foundation
@testable import TaskMenu

@MainActor
final class TestGlobalShortcutMonitor: GlobalShortcutMonitoring {
    private(set) var enabledValues: [Bool] = []
    private(set) var invalidateCallCount = 0
    private(set) var handlerSetCount = 0
    private var handler: (@MainActor () -> Void)?

    func setHandler(_ handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        handlerSetCount += 1
    }

    func setEnabled(_ enabled: Bool) {
        enabledValues.append(enabled)
    }

    func invalidate() {
        invalidateCallCount += 1
        handler = nil
    }

    func trigger() {
        handler?()
    }
}
