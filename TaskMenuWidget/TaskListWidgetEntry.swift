import Foundation
import WidgetKit

/// One timeline entry: WidgetKit's per-render `date`, the family it was
/// rendered for (row budget already applied to `content.projection`), and
/// the pure `TaskWidgetEntryContent` `TaskListWidgetProvider`/
/// `TaskWidgetTimelineLoader` decided on.
struct TaskListWidgetEntry: TimelineEntry {
    let date: Date
    let family: WidgetFamily
    let content: TaskWidgetEntryContent

    /// `TaskListWidgetProvider.placeholder(in:)`: fictional sample content,
    /// faithful to `family`, with no I/O.
    static func placeholder(family: WidgetFamily) -> TaskListWidgetEntry {
        TaskListWidgetEntry(
            date: Date(),
            family: family,
            content: .placeholderSample(rowBudget: TaskListWidgetProvider.rowBudget(for: family))
        )
    }
}
