import Foundation

/// Minimized, versioned DTOs written to the shared App Group container so
/// `TaskMenuWidget` can render without the app running. These are a
/// deliberately narrow projection of `AppState`'s task/list data — never
/// encode `TaskItem`/`TaskList` (or `AppState`) directly, and never add a
/// field carrying notes, account email, OAuth tokens/expirations, raw API
/// response bodies, or notification identifiers. See
/// `TaskMenu/WidgetSupport/README.md` and
/// `scratch/issue-11-desktop-widget/CONTRACT.md`.
struct TaskWidgetSnapshot: Codable, Sendable, Equatable {
    /// Schema version of this snapshot shape. `TaskWidgetSnapshotStore`
    /// treats a stored version greater than
    /// `TaskWidgetConstants.currentSchemaVersion` as unreadable and falls
    /// back to `.empty` rather than throwing into the widget.
    let schemaVersion: Int
    var generatedAt: Date
    var authentication: TaskWidgetAuthenticationState
    var defaultListID: String?
    var lists: [TaskWidgetListSnapshot]

    init(
        schemaVersion: Int = TaskWidgetConstants.currentSchemaVersion,
        generatedAt: Date,
        authentication: TaskWidgetAuthenticationState,
        defaultListID: String?,
        lists: [TaskWidgetListSnapshot]
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.authentication = authentication
        self.defaultListID = defaultListID
        self.lists = lists
    }

    /// A safe, empty snapshot: no lists, signed out. Returned for a missing
    /// file, corrupt JSON, an unsupported future schema, or after an
    /// explicit sign-out/disconnect/demo-exit clear.
    static func empty(generatedAt: Date = Date()) -> TaskWidgetSnapshot {
        TaskWidgetSnapshot(
            generatedAt: generatedAt,
            authentication: .signedOut,
            defaultListID: nil,
            lists: []
        )
    }
}

/// Whether a valid Google session is available to the widget. Deliberately
/// coarser than `AppState`'s auth state: the widget never needs to
/// distinguish OAuth error reasons, only whether it can trust the cache and
/// whether it should ask the user to open TaskMenu.
enum TaskWidgetAuthenticationState: String, Codable, Sendable, Equatable {
    case signedOut
    case signedIn
}

/// One Google Task list's minimized, open-task-only cache.
struct TaskWidgetListSnapshot: Codable, Sendable, Equatable, Identifiable {
    let id: String
    var title: String
    /// When this list's tasks were last confirmed fresh from Google. Used by
    /// `TaskWidgetSnapshotStore.replaceList(_:requestStartedAt:)` for
    /// stale-write protection and by the widget for a "Last updated"
    /// treatment.
    var refreshedAt: Date?
    /// When the network request that produced `refreshedAt`/`tasks` began.
    /// Distinct from `refreshedAt` (the completion time) so a slower request
    /// that started earlier can be rejected even if it completes later.
    var refreshStartedAt: Date?
    var tasks: [TaskWidgetTaskSnapshot]

    init(
        id: String,
        title: String,
        refreshedAt: Date? = nil,
        refreshStartedAt: Date? = nil,
        tasks: [TaskWidgetTaskSnapshot] = []
    ) {
        self.id = id
        self.title = title
        self.refreshedAt = refreshedAt
        self.refreshStartedAt = refreshStartedAt
        self.tasks = tasks
    }
}

/// One open task, minimized to what the widget can legitimately show or
/// needs to route a completion request: no `notes`.
struct TaskWidgetTaskSnapshot: Codable, Sendable, Equatable, Identifiable {
    let id: String
    var title: String
    var status: TaskItem.TaskStatus
    /// Raw Google due-date wire string (`yyyy-MM-ddT00:00:00.000Z`), parsed
    /// with `TaskItem.dueDate(in:)`/`DateFormatting` semantics by
    /// `TaskWidgetProjection`. Kept as the wire string here, not a `Date`,
    /// so the store never has to guess a time zone before it is displayed.
    var due: String?
    var parent: String?
    var position: String?

    init(
        id: String,
        title: String,
        status: TaskItem.TaskStatus = .needsAction,
        due: String? = nil,
        parent: String? = nil,
        position: String? = nil
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.due = due
        self.parent = parent
        self.position = position
    }
}
