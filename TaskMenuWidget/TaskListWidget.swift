import SwiftUI
import WidgetKit

/// The single tasks widget: `AppIntentConfiguration`-backed list/sort-order
/// selection (`TaskListWidgetConfigurationIntent`), a live/cache-fallback
/// provider (`TaskListWidgetProvider`), and a pure SwiftUI view
/// (`TaskListWidgetView`). See `TaskMenuWidget/README.md`.
struct TaskListWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: TaskWidgetConstants.widgetKind,
            intent: TaskListWidgetConfigurationIntent.self,
            provider: TaskListWidgetProvider()
        ) { entry in
            TaskListWidgetView(entry: entry)
        }
        .configurationDisplayName("TaskMenu")
        .description("View and complete a Google Tasks list from your desktop.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
