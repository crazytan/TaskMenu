import AppIntents
import Foundation

/// AppIntents wrapper around `TaskWidgetListCatalogEntry`
/// (`TaskMenu/WidgetSupport/TaskWidgetListCatalog.swift`) — identity is the
/// Google list id; the display representation carries only the title (never
/// notes/account data), so renaming a list elsewhere never invalidates a
/// widget's configuration.
struct TaskListEntity: AppEntity {
    let id: String
    let title: String

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Task List"
    static let defaultQuery = TaskListEntityQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)")
    }

    init(id: String, title: String) {
        self.id = id
        self.title = title
    }

    init(_ entry: TaskWidgetListCatalogEntry) {
        self.id = entry.id
        self.title = entry.title
    }
}

/// Reads the list catalog from the shared snapshot only — never a live
/// Google fetch, and never a fabricated list when the snapshot is missing or
/// empty. All decision logic lives in `TaskWidgetListCatalog` so it stays
/// unit-testable from the app target (see `TaskMenuTests/TaskWidgetProviderTests.swift`).
struct TaskListEntityQuery: EntityQuery {
    var store: TaskWidgetSnapshotStore

    /// Satisfies `EntityQuery`'s required no-argument initializer (used when
    /// AppIntents constructs a query on its own, e.g. `AppEntity.defaultQuery`'s
    /// stored instance already covers that; this keeps the type constructible
    /// exactly that way too). Production always resolves the real App Group
    /// container via `TaskWidgetSnapshotStore()`'s own default init.
    init() {
        self.store = TaskWidgetSnapshotStore()
    }

    /// Test/injection initializer.
    init(store: TaskWidgetSnapshotStore) {
        self.store = store
    }

    func entities(for identifiers: [TaskListEntity.ID]) async throws -> [TaskListEntity] {
        TaskWidgetListCatalog.entries(for: identifiers, in: store.read()).map(TaskListEntity.init)
    }

    func suggestedEntities() async throws -> [TaskListEntity] {
        TaskWidgetListCatalog.suggestedEntries(in: store.read()).map(TaskListEntity.init)
    }

    func defaultResult() async -> TaskListEntity? {
        TaskWidgetListCatalog.defaultEntry(in: store.read()).map(TaskListEntity.init)
    }
}

/// `sortOrder`'s `AppEnum`, mapping 1:1 onto `TaskSortOrder`. Kept as its own
/// type because `AppEnum`/`DisplayRepresentation` require `AppIntents`, which
/// `TaskSortOrder` (shared with the app and `TaskWidgetProjection`) must not
/// import.
enum TaskWidgetSortOrderOption: String, AppEnum {
    case myOrder
    case dueDate

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Sort Order"
    static let caseDisplayRepresentations: [TaskWidgetSortOrderOption: DisplayRepresentation] = [
        .myOrder: "My order",
        .dueDate: "Due date",
    ]

    var sortOrder: TaskSortOrder {
        switch self {
        case .myOrder: .myOrder
        case .dueDate: .dueDate
        }
    }
}

/// Per-widget configuration: a list plus a sort order, defaulting to
/// `TaskListEntityQuery.defaultResult()` and `.myOrder` respectively.
///
/// `list` is `Optional` at the Swift type level — required by AppIntents for
/// every dynamic-entity `WidgetConfigurationIntent` parameter (the framework
/// warns "all parameter types must be optional" otherwise; see
/// `TaskMenuWidget/README.md`) — even though the product requirement is that
/// a widget always has one selected: `TaskListEntityQuery.defaultResult()`
/// resolves it before the user ever sees an unconfigured widget, and
/// `TaskListWidgetProvider` treats a `nil` list (only reachable pre-first-
/// resolution, or if the snapshot has no lists at all) as `.noCache`.
struct TaskListWidgetConfigurationIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Task List"
    static let description = IntentDescription("Choose a Google Tasks list and sort order to show on your desktop.")

    @Parameter(title: "List")
    var list: TaskListEntity?

    @Parameter(title: "Sort Order", default: .myOrder)
    var sortOrder: TaskWidgetSortOrderOption

    init() {}

    init(list: TaskListEntity?, sortOrder: TaskWidgetSortOrderOption = .myOrder) {
        self.list = list
        self.sortOrder = sortOrder
    }
}
