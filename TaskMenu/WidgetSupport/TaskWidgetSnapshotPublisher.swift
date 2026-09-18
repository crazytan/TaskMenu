import Foundation
import WidgetKit

/// Narrow abstraction `AppState` depends on to keep the shared widget
/// snapshot current. `AppState.swift` must stay WidgetKit-free; this file is
/// the only place in the app target that imports it. See
/// `scratch/issue-11-desktop-widget/implementation-spec.md`'s "AppState
/// Integration" section and `CONTRACT.md`'s Shared Snapshot Contract.
///
/// Every method is synchronous and non-throwing, safe to call from
/// `AppState`'s main-actor mutation paths without `await`: a conforming type
/// must never block visibly or surface an error to the caller. Implementers
/// log only operation names and error descriptions on failure, never
/// task/list content.
protocol TaskWidgetSnapshotPublishing: Sendable {
    /// Full list-catalog convergence point: successful sign-in/bootstrap
    /// once lists are known, and every `loadTaskLists()` that replaces the
    /// authoritative list set (including the refetch a missing-list 404
    /// recovery triggers). Removes lists no longer present, adds newly-seen
    /// ones with an empty task placeholder until their own `publishList`
    /// call lands, and updates `authentication`/`defaultListID`.
    func publishCatalog(authentication: TaskWidgetAuthenticationState, lists: [TaskList], defaultListID: String?)

    /// One list's authoritative open-task content: every accepted
    /// `cacheFetchedTasks` (foreground load or account-wide/menu-bar sweep)
    /// and every `commitTaskChange` (local mutation, including a rollback).
    /// `tasks` may include completed tasks; the implementation filters to
    /// `needsAction` and minimizes before writing — never notes, account
    /// email, tokens, or raw API bodies. `requestStartedAt` is the
    /// wall-clock time the operation that produced `tasks` began (the
    /// network request's start for a fetch, "now" for a local commit) so
    /// `TaskWidgetSnapshotStore.replaceList`'s stale-write protection can
    /// reject an older in-flight response that completes later.
    func publishList(id: String, title: String, tasks: [TaskItem], requestStartedAt: Date)

    /// Primary-pane selection change.
    func setDefaultListID(_ id: String?)

    /// Sign-out, disconnect, or demo exit: wipes all shared widget state.
    func clear()
}

/// Default publisher for any context that must never write shared widget
/// state: used implicitly by every test that does not inject
/// `RecordingTaskWidgetSnapshotPublisher` (see `AppStateWidgetPublishingTests`)
/// and available for any other caller that wants a guaranteed no-op.
struct NoOpTaskWidgetSnapshotPublisher: TaskWidgetSnapshotPublishing {
    func publishCatalog(authentication: TaskWidgetAuthenticationState, lists: [TaskList], defaultListID: String?) {}
    func publishList(id: String, title: String, tasks: [TaskItem], requestStartedAt: Date) {}
    func setDefaultListID(_ id: String?) {}
    func clear() {}
}

/// Production publisher: writes through an injected `TaskWidgetSnapshotStore`
/// and requests a WidgetKit timeline reload after a meaningful, accepted
/// change. `import WidgetKit` is confined to this file.
///
/// The default initializer resolves the real App Group container via
/// `TaskWidgetSnapshotStore()` — except under XCTest (see
/// `isRunningUnderXCTest`), where it resolves a store with no directory
/// (`directoryURL: nil`) instead, so every write is a harmless no-op
/// (`StoreError.containerUnavailable`, logged and swallowed) regardless of
/// whether the test host happens to be signed with the App Group
/// entitlement. That guarantee does not depend on
/// `SharedConstants.appGroupIdentifier` resolving to nil in any particular
/// build configuration — it holds unconditionally for any process XCTest
/// launches, signed or not, today or after the App Group is registered.
/// `--testing-window` and any other caller that must stay off the real App
/// Group use `init(store:)` with a store pointed at a temporary directory
/// instead.
struct TaskWidgetSnapshotPublisher: TaskWidgetSnapshotPublishing {
    /// Internal (not `private`) so `@testable import` can assert
    /// `store.directoryURL` is `nil` for the default initializer under
    /// XCTest — the unconditional half of the "no test touches the real
    /// App Group" guarantee — without needing a dedicated test-only accessor.
    let store: TaskWidgetSnapshotStore

    /// Production initializer: resolves the real App Group container,
    /// unless running under XCTest, in which case it resolves a store with
    /// no directory so no test can ever write to the real container.
    init() {
        self.store = Self.isRunningUnderXCTest
            ? TaskWidgetSnapshotStore(directoryURL: nil)
            : TaskWidgetSnapshotStore()
    }

    /// Explicit-store initializer for `--testing-window` (a temporary
    /// directory) and any other caller that needs a non-production
    /// container. Tests should prefer the injected recording double; this
    /// exists so `--testing-window` can still prove real store behavior
    /// (load/mutation/sign-out snapshots) without the production App Group.
    /// Unaffected by the XCTest guard above: an explicit store is used
    /// exactly as given.
    init(store: TaskWidgetSnapshotStore) {
        self.store = store
    }

    /// Same `ProcessInfo`-based check `KeychainService` uses to detect an
    /// XCTest host (see also `TaskMenuApp.isUnitTesting`, not referenced
    /// here directly since this file also compiles into the
    /// `TaskMenuWidget` extension target, which must not depend on
    /// `TaskMenuApp.swift`). Deliberately independent of
    /// `SharedConstants.appGroupIdentifier`/signing state: this must stay
    /// true for every XCTest run regardless of whether the App Group
    /// entitlement resolves in that build.
    private static var isRunningUnderXCTest: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    func publishCatalog(authentication: TaskWidgetAuthenticationState, lists: [TaskList], defaultListID: String?) {
        let existingIDs = Set(store.read().lists.map(\.id))
        let currentIDs = Set(lists.map(\.id))
        do {
            try store.pruneLists(keeping: currentIDs)
            for list in lists where !existingIDs.contains(list.id) {
                // Placeholder entry so a brand-new list appears in the
                // catalog immediately; a subsequent `publishList` fills in
                // its tasks. `.distantPast` guarantees this can never win a
                // race against a real task publish for the same list id.
                try store.replaceList(
                    TaskWidgetListSnapshot(id: list.id, title: list.title),
                    requestStartedAt: .distantPast
                )
            }
            try store.setDefaultListID(defaultListID)
            try store.setAuthentication(authentication)
            reloadTimelines()
        } catch {
            logFailure("publishCatalog", error)
        }
    }

    func publishList(id: String, title: String, tasks: [TaskItem], requestStartedAt: Date) {
        let openTasks = tasks.filter { $0.status == .needsAction }
        let snapshot = TaskWidgetListSnapshot(
            id: id,
            title: title,
            refreshedAt: Date(),
            refreshStartedAt: requestStartedAt,
            tasks: openTasks.map {
                TaskWidgetTaskSnapshot(
                    id: $0.id,
                    title: $0.title,
                    status: $0.status,
                    due: $0.due,
                    parent: $0.parent,
                    position: $0.position
                )
            }
        )
        do {
            let accepted = try store.replaceList(snapshot, requestStartedAt: requestStartedAt)
            if accepted {
                reloadTimelines()
            }
        } catch {
            logFailure("publishList", error)
        }
    }

    func setDefaultListID(_ id: String?) {
        do {
            try store.setDefaultListID(id)
            reloadTimelines()
        } catch {
            logFailure("setDefaultListID", error)
        }
    }

    func clear() {
        do {
            try store.clear()
            reloadTimelines()
        } catch {
            logFailure("clear", error)
        }
    }

    private func reloadTimelines() {
        WidgetCenter.shared.reloadTimelines(ofKind: TaskWidgetConstants.widgetKind)
    }

    /// Metadata-only logging: operation name and error description, never
    /// task/list content. A publishing failure must never surface as a
    /// user-facing error.
    private func logFailure(_ operation: String, _ error: Error) {
        #if DEBUG
        print("TaskWidgetSnapshotPublisher.\(operation) failed: \(error)")
        #endif
    }
}
