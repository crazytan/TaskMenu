import Foundation

/// Outcome of `TaskWidgetCompletionCoordinator.complete(...)`.
enum TaskWidgetCompletionResult: Sendable, Equatable {
    /// The task (and every open direct child, if any) completed on Google;
    /// the authoritative refetch was published.
    case success
    /// The task itself completed, but at least one open direct child did
    /// not; the authoritative refetch was still attempted/published so the
    /// shared cache reflects server truth rather than a false "all done".
    case partialFailure
    /// The task-completion request itself failed transiently (network/
    /// server/decode). Nothing was written; the cached task remains visible.
    case transientFailure
    /// Google definitively rejected the credentials, or there were none to
    /// begin with. Shared credentials and the entire cached snapshot are
    /// cleared when there was something to clear.
    case authFailure
    /// `taskID` was not found under `listID` in the shared cache. Treated as
    /// untrusted input: refuse to mutate anything Google-side on the word of
    /// a persisted id/title the widget itself never confirmed.
    case taskNotInList
}

/// `complete(...)`'s full result: the outcome plus whether anything was
/// actually written to the shared snapshot/Keychain. `CompleteTaskIntent`
/// must only call `WidgetCenter.reloadTimelines`/post the change signal when
/// `sharedStateChanged` is `true` — never merely based on `result`, since a
/// `.partialFailure`'s refetch can itself fail, and a stale-write rejection
/// inside `store.replaceList` means a "successful" completion sometimes
/// writes nothing new either.
struct TaskWidgetCompletionOutcome: Sendable, Equatable {
    let result: TaskWidgetCompletionResult
    let sharedStateChanged: Bool
}

/// Orchestrates one widget-originated task completion: cache-membership
/// verification, the Google completion request, the open-direct-child
/// cascade, and the authoritative refetch/publish. Foundation-only and fully
/// dependency-injected so `CompleteTaskIntent` (extension-only, in
/// `TaskMenuWidget` — wires up the real `GoogleTasksAPI`/`KeychainService`)
/// and its tests share exactly one decision path.
enum TaskWidgetCompletionCoordinator {
    /// - Parameters:
    ///   - listID/taskID: stable ids carried by `CompleteTaskIntent`,
    ///     treated as untrusted persisted input — see `taskNotInList`. Used
    ///     only for API path/query construction, never as a file path/URL.
    ///   - store/keychain/api: the shared App Group store, the shared-group
    ///     Keychain (cleared only on `.authFailure`), and the Google Tasks
    ///     client for every request this call makes.
    static func complete(
        listID: String,
        taskID: String,
        store: TaskWidgetSnapshotStore,
        keychain: any KeychainServiceProtocol,
        api: any TasksAPIProtocol
    ) async -> TaskWidgetCompletionOutcome {
        let snapshot = store.read()
        guard snapshot.authentication == .signedIn else {
            return TaskWidgetCompletionOutcome(result: .authFailure, sharedStateChanged: false)
        }
        guard let cachedList = snapshot.lists.first(where: { $0.id == listID }),
              cachedList.tasks.contains(where: { $0.id == taskID })
        else {
            return TaskWidgetCompletionOutcome(result: .taskNotInList, sharedStateChanged: false)
        }

        // Captured before the first Google write so the authoritative
        // refetch below can reject an older, still-in-flight app/widget
        // fetch that happens to finish (i.e. get published) after this
        // completion commits.
        let requestStartedAt = Date()

        do {
            _ = try await api.setTaskCompleted(listId: listID, taskId: taskID)
        } catch APIError.unauthorized {
            try? keychain.deleteAll()
            let cleared = (try? store.clear()) != nil
            return TaskWidgetCompletionOutcome(result: .authFailure, sharedStateChanged: cleared)
        } catch {
            return TaskWidgetCompletionOutcome(result: .transientFailure, sharedStateChanged: false)
        }

        // Cascade: complete every open direct child. Bounded-sequential —
        // Google Tasks is one parent level deep, so this is at most a
        // handful of requests, never worth a parallel fan-out's added
        // complexity/rate-limit risk. `cachedList.tasks` already holds only
        // open tasks (the snapshot invariant), so an already-completed
        // child is never present here to begin with.
        var anyChildFailed = false
        for child in cachedList.tasks where child.parent == taskID {
            do {
                _ = try await api.setTaskCompleted(listId: listID, taskId: child.id)
            } catch {
                anyChildFailed = true
            }
        }

        // Always attempt the authoritative refetch/publish, whether or not
        // every child succeeded, so the shared cache never claims a
        // completion Google did not actually record.
        var sharedStateChanged = false
        if let refreshed = try? await api.listTasks(listId: listID, showCompleted: false, showHidden: false) {
            let minimized = TaskWidgetTimelineLoader.minimize(refreshed)
            let listSnapshot = TaskWidgetListSnapshot(
                id: listID, title: cachedList.title, refreshedAt: Date(), refreshStartedAt: requestStartedAt, tasks: minimized
            )
            if let accepted = try? store.replaceList(listSnapshot, requestStartedAt: requestStartedAt) {
                sharedStateChanged = accepted
            }
        }

        return TaskWidgetCompletionOutcome(
            result: anyChildFailed ? .partialFailure : .success,
            sharedStateChanged: sharedStateChanged
        )
    }
}
