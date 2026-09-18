import Foundation

/// One selectable Google Task list, independent of AppIntents' `AppEntity`
/// protocol so `TaskListEntityQuery`'s decision logic (identity/order/
/// default resolution) can be unit-tested from the app target — the actual
/// `TaskListEntity`/`TaskListEntityQuery` types live in `TaskMenuWidget`
/// (extension-only, requires `AppIntents`) and just wrap these results.
struct TaskWidgetListCatalogEntry: Sendable, Equatable, Identifiable {
    let id: String
    let title: String
}

/// Reads the widget's list-configuration catalog from the shared snapshot
/// only — never a live Google fetch, and never a fabricated list when the
/// snapshot is missing or empty. Identity is always the Google list id, so
/// renaming a list elsewhere never invalidates a widget's configuration.
enum TaskWidgetListCatalog {
    /// `TaskListEntityQuery.entities(for:)`: returns only entries that still
    /// exist in `snapshot`, in the order `identifiers` was given, and drops
    /// unmatched ids rather than fabricating a placeholder list.
    static func entries(for identifiers: [String], in snapshot: TaskWidgetSnapshot) -> [TaskWidgetListCatalogEntry] {
        let byID = Dictionary(uniqueKeysWithValues: snapshot.lists.map { ($0.id, $0) })
        return identifiers.compactMap { id in
            byID[id].map { TaskWidgetListCatalogEntry(id: $0.id, title: $0.title) }
        }
    }

    /// `TaskListEntityQuery.suggestedEntities()`: every list, preserving the
    /// snapshot's stored (Google) order. A missing/empty snapshot yields no
    /// entities — never fake user lists.
    static func suggestedEntries(in snapshot: TaskWidgetSnapshot) -> [TaskWidgetListCatalogEntry] {
        snapshot.lists.map { TaskWidgetListCatalogEntry(id: $0.id, title: $0.title) }
    }

    /// `TaskListEntityQuery.defaultResult()`: `snapshot.defaultListID` when
    /// it still exists, otherwise the first list in Google order, otherwise
    /// `nil` when there is nothing to default to.
    static func defaultEntry(in snapshot: TaskWidgetSnapshot) -> TaskWidgetListCatalogEntry? {
        if let defaultListID = snapshot.defaultListID,
           let match = snapshot.lists.first(where: { $0.id == defaultListID }) {
            return TaskWidgetListCatalogEntry(id: match.id, title: match.title)
        }
        return snapshot.lists.first.map { TaskWidgetListCatalogEntry(id: $0.id, title: $0.title) }
    }
}
