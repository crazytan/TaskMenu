import Foundation
import WidgetKit

/// `AppIntentTimelineProvider` for the single tasks widget. All decision
/// logic (cache reads, live-fetch attempt, error handling) lives in
/// `TaskWidgetTimelineLoader` (`TaskMenu/WidgetSupport/`, Foundation-only)
/// so it stays unit-testable from the app target (see
/// `TaskMenuTests/TaskWidgetProviderTests.swift`); this type only wires that
/// loader to WidgetKit's `Context`/`Timeline` types and maps `WidgetFamily`
/// to a row budget via `TaskWidgetProjectionConstants`, so `WidgetSupport`
/// itself never has to import WidgetKit.
struct TaskListWidgetProvider: AppIntentTimelineProvider {
    private let store: TaskWidgetSnapshotStore
    private let keychain: any KeychainServiceProtocol
    private let makeAPI: @Sendable () -> any TasksAPIProtocol

    init(
        store: TaskWidgetSnapshotStore = TaskWidgetSnapshotStore(),
        keychain: any KeychainServiceProtocol = KeychainService(accessGroup: SharedConstants.keychainAccessGroup),
        makeAPI: @escaping @Sendable () -> any TasksAPIProtocol = {
            GoogleTasksAPI(tokenProvider: WidgetGoogleAccessTokenProvider())
        }
    ) {
        self.store = store
        self.keychain = keychain
        self.makeAPI = makeAPI
    }

    static func rowBudget(for family: WidgetFamily) -> Int {
        switch family {
        case .systemSmall: TaskWidgetProjectionConstants.smallRowBudget
        case .systemLarge: TaskWidgetProjectionConstants.largeRowBudget
        default: TaskWidgetProjectionConstants.mediumRowBudget
        }
    }

    /// Never touches Keychain, the App Group, or the network — pure
    /// fictional sample content, faithful to `context.family`.
    func placeholder(in context: Context) -> TaskListWidgetEntry {
        .placeholder(family: context.family)
    }

    /// Gallery/preview snapshot: fictional sample content in preview
    /// context, otherwise a cache-only read. Never waits on Google.
    func snapshot(for configuration: TaskListWidgetConfigurationIntent, in context: Context) async -> TaskListWidgetEntry {
        if context.isPreview {
            return .placeholder(family: context.family)
        }
        guard let list = configuration.list else {
            return Self.unconfiguredEntry(family: context.family, sortOrder: configuration.sortOrder.sortOrder)
        }
        let content = TaskWidgetTimelineLoader.cachedContent(
            listID: list.id,
            listTitle: list.title,
            sortOrder: configuration.sortOrder.sortOrder,
            rowBudget: Self.rowBudget(for: context.family),
            snapshot: store.read()
        )
        return TaskListWidgetEntry(date: Date(), family: context.family, content: content)
    }

    /// Live-first, cache-fallback load; always returns exactly one entry and
    /// asks WidgetKit for the next refresh ~30 minutes out. WidgetKit owns
    /// actual scheduling — this is a request, not a guarantee.
    func timeline(for configuration: TaskListWidgetConfigurationIntent, in context: Context) async -> Timeline<TaskListWidgetEntry> {
        guard let list = configuration.list else {
            let entry = Self.unconfiguredEntry(family: context.family, sortOrder: configuration.sortOrder.sortOrder)
            return Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(30 * 60)))
        }
        let content = await TaskWidgetTimelineLoader.loadLive(
            listID: list.id,
            listTitle: list.title,
            sortOrder: configuration.sortOrder.sortOrder,
            rowBudget: Self.rowBudget(for: context.family),
            store: store,
            keychain: keychain,
            api: makeAPI()
        )
        let entry = TaskListWidgetEntry(date: Date(), family: context.family, content: content)
        return Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(30 * 60)))
    }

    /// `configuration.list` is only `nil` before `TaskListEntityQuery.defaultResult()`
    /// has ever resolved anything (i.e. the shared snapshot has no lists at
    /// all yet) — AppIntents requires the Swift type to be `Optional` for
    /// every dynamic-entity widget configuration parameter regardless of the
    /// product-level "required" selection. Rendered the same as `.noCache`.
    private static func unconfiguredEntry(family: WidgetFamily, sortOrder: TaskSortOrder) -> TaskListWidgetEntry {
        TaskListWidgetEntry(
            date: Date(),
            family: family,
            content: TaskWidgetEntryContent(status: .noCache, listID: nil, listTitle: nil, sortOrder: sortOrder, projection: nil)
        )
    }
}
