import Foundation

/// Narrow view of `AppState` that widget deep-link routing depends on. Lets
/// `TaskWidgetDeepLinkRouter` be unit-tested with a fake instead of a real
/// `AppState` (which needs live services to construct). `AppState` conforms
/// below with no behavior changes.
@MainActor
protocol DeepLinkAppStateRouting: AnyObject {
    var isSignedIn: Bool { get }
    var taskLists: [TaskList] { get }
    var primaryPane: TaskListPane { get }
    func bootstrapSignedInState() async
    func selectList(_ listId: String, in pane: TaskListPane?) async
}

extension AppState: DeepLinkAppStateRouting {}

/// Narrow view of `StatusBarController` that widget deep-link routing
/// depends on. Lets routing be unit-tested without a live `NSStatusItem`.
@MainActor
protocol DeepLinkPopoverPresenting: AnyObject {
    /// Idempotent: presents the popover if it is not already visible. Must
    /// never toggle a visible popover closed.
    func showPopover()
}

/// Routes one parsed `taskmenu://widget/list?id=...` URL into the running
/// app. Pure decision logic: no `NSAppleEventManager`, no AppKit event
/// plumbing, and no direct dependency on a live status item — those are
/// supplied by the caller through `activate` and the two protocols above, so
/// this type is fully unit-testable with fakes.
///
/// Routing order, matching the implementation spec:
/// 1. Reject anything `TaskWidgetDeepLink.parse(_:)` does not accept, with
///    no side effects at all.
/// 2. Activate TaskMenu.
/// 3. If signed out, show the popover (on the sign-in screen) and stop.
/// 4. If signed in but the list catalog has not loaded yet, bootstrap it.
/// 5. If the list still exists, select it in the primary pane.
/// 6. Present the popover either way — a deleted/unknown list still opens
///    the popover without switching lists, and normal refresh reconciles it.
///    This never surfaces an error alert.
@MainActor
enum TaskWidgetDeepLinkRouter {
    static func route(
        url: URL,
        activate: () -> Void,
        appState: any DeepLinkAppStateRouting,
        popover: any DeepLinkPopoverPresenting
    ) async {
        guard case let .list(id)? = TaskWidgetDeepLink.parse(url) else { return }

        activate()

        guard appState.isSignedIn else {
            popover.showPopover()
            return
        }

        if appState.taskLists.isEmpty {
            await appState.bootstrapSignedInState()
        }

        if appState.taskLists.contains(where: { $0.id == id }) {
            await appState.selectList(id, in: appState.primaryPane)
        }

        popover.showPopover()
    }
}

/// Buffers at most one deep-link URL received before the app is ready to
/// route it — `TaskMenuAppDelegate`, `AppState`, and `StatusBarController`
/// all constructed. This is what lets a cold-launch "Get URL" Apple Event
/// (which can arrive before `applicationDidFinishLaunching` finishes
/// standing up the status item) survive to be routed once the app is ready,
/// without ever growing into a queue: a second URL arriving before the first
/// is flushed simply replaces it.
@MainActor
final class DeepLinkColdStartBuffer {
    private(set) var isReady = false
    private(set) var bufferedURL: URL?

    /// Call for every URL the app receives, cold or warm. Returns the URL to
    /// route immediately once the buffer is ready. While not yet ready,
    /// buffers `url` — replacing anything already buffered — and returns
    /// nil.
    func receive(_ url: URL) -> URL? {
        guard isReady else {
            bufferedURL = url
            return nil
        }
        return url
    }

    /// Marks the buffer ready and returns the buffered URL to flush, if any,
    /// clearing it. Call exactly once, after the delegate, `AppState`, and
    /// `StatusBarController` are all constructed. Safe to call when nothing
    /// was ever buffered (returns nil).
    func markReady() -> URL? {
        isReady = true
        defer { bufferedURL = nil }
        return bufferedURL
    }
}
