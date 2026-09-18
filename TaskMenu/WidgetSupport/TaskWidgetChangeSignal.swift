import Foundation

/// Thin wrapper around the Darwin notification center for signaling a
/// widget-originated task mutation across the process boundary between
/// `TaskMenuWidget` and the containing app. Darwin notifications carry no
/// payload and are delivered system-wide by name (scoped only by the name
/// string itself, not by App Group membership), which is why the name is a
/// long reverse-DNS constant (`TaskWidgetConstants.changeNotificationName`)
/// rather than something generic.
///
/// Usable from either process, and safe to construct/post/observe even in
/// an environment where notification delivery is otherwise unavailable —
/// posting with no observers, or observing with no posters, are both no-ops
/// rather than errors.
struct TaskWidgetChangeSignal: Sendable {
    let notificationName: String

    init(notificationName: String = TaskWidgetConstants.changeNotificationName) {
        self.notificationName = notificationName
    }

    private var cfName: CFNotificationName {
        CFNotificationName(notificationName as CFString)
    }

    /// Posts the change notification. Call after a widget-originated
    /// mutation (e.g. `CompleteTaskIntent`) commits to the shared snapshot,
    /// so a running TaskMenu process can reconcile its own state.
    func post() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            cfName,
            nil,
            nil,
            true
        )
    }

    /// Registers `handler` to run whenever this notification is posted by
    /// any process, including this one. `handler` runs on an unspecified
    /// thread; hop to the main actor yourself if the caller needs that.
    /// Keep the returned token alive for as long as observation should
    /// continue, and pass it to `stopObserving(_:)` to unregister —
    /// dropping it does not automatically unregister.
    @discardableResult
    func startObserving(_ handler: @escaping @Sendable () -> Void) -> TaskWidgetChangeSignalToken {
        let token = TaskWidgetChangeSignalToken(handler: handler)
        let observer = Unmanaged.passUnretained(token).toOpaque()
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            observer,
            taskWidgetChangeSignalCallback,
            notificationName as CFString,
            nil,
            .deliverImmediately
        )
        return token
    }

    /// Unregisters a token returned by `startObserving(_:)`. Safe to call
    /// more than once.
    func stopObserving(_ token: TaskWidgetChangeSignalToken) {
        let observer = Unmanaged.passUnretained(token).toOpaque()
        CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(), observer, cfName, nil)
    }
}

/// Holds the closure one `TaskWidgetChangeSignal.startObserving(_:)` call
/// runs on notification. The Darwin notify center only stores an
/// unretained opaque pointer to whatever `observer` you register, so the
/// caller must keep this token alive itself for as long as it wants to keep
/// observing.
final class TaskWidgetChangeSignalToken: @unchecked Sendable {
    fileprivate let handler: @Sendable () -> Void

    fileprivate init(handler: @escaping @Sendable () -> Void) {
        self.handler = handler
    }
}

/// C callback the Darwin notify center invokes on post. Must be a
/// capture-free top-level function so it converts to the `CFNotificationCallback`
/// function-pointer type; per-listener state travels through the `observer`
/// pointer (a `TaskWidgetChangeSignalToken`), not through captures.
private func taskWidgetChangeSignalCallback(
    center: CFNotificationCenter?,
    observer: UnsafeMutableRawPointer?,
    name: CFNotificationName?,
    object: UnsafeRawPointer?,
    userInfo: CFDictionary?
) {
    guard let observer else { return }
    let token = Unmanaged<TaskWidgetChangeSignalToken>.fromOpaque(observer).takeUnretainedValue()
    token.handler()
}
