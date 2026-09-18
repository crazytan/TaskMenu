import Foundation

/// Coarse state the widget UI renders, decided by `TaskWidgetTimelineLoader`.
/// Foundation-only (no WidgetKit) so both the loader and its tests can
/// construct/compare it without importing WidgetKit; `TaskListWidgetEntry`
/// (extension-only, in `TaskMenuWidget`) wraps this together with a
/// `TimelineEntry` `date`.
enum TaskWidgetTimelineStatus: Sendable, Equatable {
    /// No shared Google credentials, or a definitive auth rejection just
    /// cleared them. No cached task titles should render alongside this.
    case signedOut
    /// The configured list no longer exists on Google (404 on the latest
    /// live fetch). Never silently substitute another list.
    case listUnavailable
    /// Signed in, but no cached tasks exist yet for this list (first run, or
    /// no live fetch has ever succeeded for it).
    case noCache
    /// A live Google fetch just succeeded; `projection` reflects fresh data.
    case live
    /// A live fetch was skipped or failed transiently (offline, timeout,
    /// cancellation, decode/server error); `projection` reflects the most
    /// recent cache. `lastUpdated` backs the "Last updated" treatment.
    case stale(lastUpdated: Date?)
}

/// Everything one widget rendering needs, independent of `WidgetFamily`
/// beyond the already-applied `rowBudget`. Pure data — no WidgetKit/SwiftUI
/// import here, so it stays constructible/comparable from plain unit tests.
struct TaskWidgetEntryContent: Sendable, Equatable {
    let status: TaskWidgetTimelineStatus
    /// The configured Google list id, when known. `nil` only for the
    /// fictional placeholder sample, which must never carry a real id.
    let listID: String?
    let listTitle: String?
    let sortOrder: TaskSortOrder
    /// `nil` for `.signedOut`, `.listUnavailable`, and `.noCache`; present
    /// for `.live`/`.stale` (including an empty list, which projects to zero
    /// rows and a zero remainder).
    let projection: TaskWidgetProjectedList?

    /// Fictional, clearly-sample content for the widget placeholder and the
    /// gallery/preview snapshot when `context.isPreview` is true. Never
    /// reads Keychain, the App Group container, or the network — every field
    /// here is constructed in memory from literals. `listID` is deliberately
    /// `nil` so a `Button`/`Link` built from this content can never address
    /// a real list or task, even outside the OS's redacted placeholder
    /// rendering.
    static func placeholderSample(rowBudget: Int, now: Date = Date(), calendar: Calendar = .current) -> TaskWidgetEntryContent {
        func due(_ dayOffset: Int) -> String? {
            guard let date = calendar.date(byAdding: .day, value: dayOffset, to: now) else { return nil }
            return DateFormatting.formatGoogleTaskDueDate(date, calendar: calendar)
        }

        let sampleTasks: [TaskWidgetTaskSnapshot] = [
            TaskWidgetTaskSnapshot(id: "sample-1", title: "Draft the quarterly outline", due: due(-1), position: "00001"),
            TaskWidgetTaskSnapshot(id: "sample-2", title: "Reply to Sam about the offsite", due: due(0), position: "00002"),
            TaskWidgetTaskSnapshot(id: "sample-3", title: "Book the dentist appointment", position: "00003"),
            TaskWidgetTaskSnapshot(id: "sample-3a", title: "Confirm insurance details", parent: "sample-3", position: "00001"),
            TaskWidgetTaskSnapshot(id: "sample-4", title: "Pack for the trip", due: due(1), position: "00004"),
            TaskWidgetTaskSnapshot(id: "sample-5", title: "Review the open pull request", position: "00005"),
        ]
        let projection = TaskWidgetProjection.project(
            tasks: sampleTasks,
            sortOrder: .myOrder,
            rowBudget: rowBudget,
            now: now,
            calendar: calendar
        )
        return TaskWidgetEntryContent(status: .live, listID: nil, listTitle: "Sample List", sortOrder: .myOrder, projection: projection)
    }
}
