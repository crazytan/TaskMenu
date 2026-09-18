import Foundation

/// Decides what the widget should render for one configured list: reads the
/// shared cache, optionally attempts a live Google refresh, and applies
/// `TaskWidgetProjection`'s row budget. Foundation-only and fully
/// dependency-injected (`TasksAPIProtocol`, `KeychainServiceProtocol`,
/// `TaskWidgetSnapshotStore`) so `TaskListWidgetProvider` (extension-only, in
/// `TaskMenuWidget` — wires up the real `GoogleTasksAPI`/
/// `WidgetGoogleAccessTokenProvider`) and its tests share exactly one
/// decision path.
enum TaskWidgetTimelineLoader {
    /// Cache-only projection: never touches the network. Used for the
    /// gallery/preview snapshot (`context.isPreview`) and as the fallback
    /// for every live-fetch failure path in `loadLive`.
    static func cachedContent(
        listID: String,
        listTitle: String?,
        sortOrder: TaskSortOrder,
        rowBudget: Int,
        snapshot: TaskWidgetSnapshot,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> TaskWidgetEntryContent {
        guard snapshot.authentication == .signedIn else {
            return TaskWidgetEntryContent(status: .signedOut, listID: listID, listTitle: listTitle, sortOrder: sortOrder, projection: nil)
        }
        guard let cachedList = snapshot.lists.first(where: { $0.id == listID }) else {
            return TaskWidgetEntryContent(status: .noCache, listID: listID, listTitle: listTitle, sortOrder: sortOrder, projection: nil)
        }
        let projection = TaskWidgetProjection.project(
            tasks: cachedList.tasks, sortOrder: sortOrder, rowBudget: rowBudget, now: now, calendar: calendar
        )
        return TaskWidgetEntryContent(
            status: .stale(lastUpdated: cachedList.refreshedAt),
            listID: listID,
            listTitle: cachedList.title,
            sortOrder: sortOrder,
            projection: projection
        )
    }

    /// Live-first, cache-fallback load for the timeline. Reads the shared
    /// snapshot itself (rather than taking one as a parameter) so the
    /// "no credentials" check always sees the latest state right before the
    /// network attempt.
    ///
    /// - Parameters:
    ///   - store: the shared App Group snapshot store.
    ///   - keychain: the shared-access-group Keychain, used only to clear
    ///     credentials on a definitive auth rejection; never read directly
    ///     here — token handling belongs to `api`'s injected token provider.
    ///   - api: the Google Tasks client for this one request. Production
    ///     passes `GoogleTasksAPI(tokenProvider: WidgetGoogleAccessTokenProvider())`;
    ///     tests pass a fake conforming to `TasksAPIProtocol`.
    static func loadLive(
        listID: String,
        listTitle: String?,
        sortOrder: TaskSortOrder,
        rowBudget: Int,
        store: TaskWidgetSnapshotStore,
        keychain: any KeychainServiceProtocol,
        api: any TasksAPIProtocol,
        now: Date = Date(),
        calendar: Calendar = .current
    ) async -> TaskWidgetEntryContent {
        let snapshot = store.read()

        guard snapshot.authentication == .signedIn else {
            return cachedContent(
                listID: listID, listTitle: listTitle, sortOrder: sortOrder, rowBudget: rowBudget,
                snapshot: snapshot, now: now, calendar: calendar
            )
        }

        // The network request's *start* time, not its completion time — see
        // `TaskWidgetSnapshotStore.replaceList(_:requestStartedAt:)`'s
        // stale-write protection, which this call relies on below.
        let requestStartedAt = Date()
        do {
            let tasks = try await api.listTasks(listId: listID, showCompleted: false, showHidden: false)
            let minimized = minimize(tasks)
            let resolvedTitle = snapshot.lists.first(where: { $0.id == listID })?.title ?? listTitle ?? listID
            let listSnapshot = TaskWidgetListSnapshot(
                id: listID, title: resolvedTitle, refreshedAt: Date(), refreshStartedAt: requestStartedAt, tasks: minimized
            )
            // Best-effort: a rejected (stale) write still leaves valid cache
            // in place for the next timeline refresh to pick up; this call
            // must never crash the extension.
            _ = try? store.replaceList(listSnapshot, requestStartedAt: requestStartedAt)

            let projection = TaskWidgetProjection.project(
                tasks: minimized, sortOrder: sortOrder, rowBudget: rowBudget, now: now, calendar: calendar
            )
            return TaskWidgetEntryContent(status: .live, listID: listID, listTitle: resolvedTitle, sortOrder: sortOrder, projection: projection)
        } catch APIError.unauthorized {
            // Definitive rejection (or no valid refresh token at all): clear
            // both the shared credentials and every cached task title so
            // nothing private survives in the widget.
            try? keychain.deleteAll()
            try? store.clear()
            return TaskWidgetEntryContent(status: .signedOut, listID: listID, listTitle: listTitle, sortOrder: sortOrder, projection: nil)
        } catch APIError.serverError(404, _) {
            // The configured list is gone. Never fall back to another list;
            // show the dedicated "unavailable" state instead.
            return TaskWidgetEntryContent(status: .listUnavailable, listID: listID, listTitle: listTitle, sortOrder: sortOrder, projection: nil)
        } catch {
            // Every other failure — offline/network, other server errors,
            // decode errors, and Task cancellation (surfaces through
            // `GoogleTasksAPI` as `URLError.cancelled`) — is transient: keep
            // showing the cache, never persist the error itself.
            return cachedContent(
                listID: listID, listTitle: listTitle, sortOrder: sortOrder, rowBudget: rowBudget,
                snapshot: snapshot, now: now, calendar: calendar
            )
        }
    }

    /// Minimizes fetched tasks to the snapshot DTO, defensively re-filtering
    /// to `needsAction` even though the request already asked for
    /// `showCompleted: false` — the snapshot invariant (open tasks only)
    /// must hold regardless of what the server actually returned. Shared
    /// with `TaskWidgetCompletionCoordinator`'s post-completion refetch.
    static func minimize(_ tasks: [TaskItem]) -> [TaskWidgetTaskSnapshot] {
        tasks.filter { $0.status == .needsAction }.map {
            TaskWidgetTaskSnapshot(id: $0.id, title: $0.title, status: $0.status, due: $0.due, parent: $0.parent, position: $0.position)
        }
    }
}
