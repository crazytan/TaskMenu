import SwiftUI
import WidgetKit

/// Pure rendering of one `TaskListWidgetEntry`: it reads only `entry` and
/// builds `Link`s (from `TaskWidgetDeepLink.url(forListID:)`) and
/// `Button(intent:)`s (backed by `CompleteTaskIntent`) — no file, Keychain,
/// or network access anywhere in this file.
struct TaskListWidgetView: View {
    let entry: TaskListWidgetEntry

    private var deepLinkURL: URL? {
        entry.content.listID.flatMap(TaskWidgetDeepLink.url(forListID:))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            content
            Spacer(minLength: 0)
            footer
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(for: .widget) {
            Color(nsColor: .windowBackgroundColor)
        }
    }

    // MARK: Header — always a Link to the configured list when known.

    @ViewBuilder
    private var header: some View {
        let title = entry.content.listTitle ?? "TaskMenu"
        if let deepLinkURL {
            Link(destination: deepLinkURL) {
                Label(title, systemImage: "checklist")
                    .font(.headline)
                    .lineLimit(1)
            }
            .accessibilityLabel("Open \(title) in TaskMenu")
        } else {
            Label(title, systemImage: "checklist")
                .font(.headline)
                .lineLimit(1)
        }
    }

    // MARK: Body by status

    @ViewBuilder
    private var content: some View {
        switch entry.content.status {
        case .signedOut:
            messageBody(systemImage: "person.crop.circle.badge.exclamationmark", text: "Open TaskMenu to sign in")
        case .listUnavailable:
            messageBody(systemImage: "exclamationmark.triangle", text: "List unavailable — open TaskMenu")
        case .noCache:
            messageBody(systemImage: "tray", text: "Open TaskMenu to load this list")
        case .live, .stale:
            if let projection = entry.content.projection {
                if projection.rows.isEmpty {
                    messageBody(systemImage: "checkmark.circle", text: "Nothing due — nice work")
                } else {
                    rows(projection)
                }
            } else {
                messageBody(systemImage: "tray", text: "Open TaskMenu to load this list")
            }
        }
    }

    @ViewBuilder
    private func messageBody(systemImage: String, text: String) -> some View {
        if let deepLinkURL {
            Link(destination: deepLinkURL) {
                Label(text, systemImage: systemImage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .accessibilityLabel(text)
        } else {
            Label(text, systemImage: systemImage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private func rows(_ projection: TaskWidgetProjectedList) -> some View {
        let listID = entry.content.listID ?? ""
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(projection.rows) { row in
                TaskListWidgetRowView(row: row, listID: listID, deepLinkURL: deepLinkURL)
            }
        }
    }

    // MARK: Footer — "Last updated" (medium/large only) and "+N more".

    @ViewBuilder
    private var footer: some View {
        VStack(alignment: .leading, spacing: 2) {
            if entry.family != .systemSmall, case .stale(let lastUpdated) = entry.content.status {
                lastUpdatedText(lastUpdated)
            }
            if let projection = entry.content.projection, projection.remainderCount > 0, let deepLinkURL {
                Link(destination: deepLinkURL) {
                    Text("+\(projection.remainderCount) more")
                        .font(.caption)
                }
                .accessibilityLabel("View \(projection.remainderCount) more tasks in \(entry.content.listTitle ?? "this list") in TaskMenu")
            }
        }
    }

    @ViewBuilder
    private func lastUpdatedText(_ date: Date?) -> some View {
        Group {
            if let date {
                Text("Last updated ") + Text(date, style: .relative)
            } else {
                Text("Offline")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
}

/// One task row: a leading `Button(intent:)` completion control that owns
/// only its own hit region (never the whole row), and a `Link` over the task
/// text/due badge.
private struct TaskListWidgetRowView: View {
    let row: TaskWidgetProjectedRow
    let listID: String
    let deepLinkURL: URL?

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Button(intent: CompleteTaskIntent(listID: listID, taskID: row.task.id, taskTitle: row.task.title)) {
                Image(systemName: "circle")
                    .imageScale(.medium)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Complete \(row.task.title)")

            textContent
        }
        .padding(.leading, row.isSubtask ? 14 : 0)
    }

    @ViewBuilder
    private var textContent: some View {
        let rowText = VStack(alignment: .leading, spacing: 1) {
            Text(row.task.title)
                .font(.subheadline)
                .lineLimit(1)
                .truncationMode(.tail)
            if let dueText {
                Text(dueText)
                    .font(.caption2)
                    .foregroundStyle(dueColor)
            }
        }

        if let deepLinkURL {
            Link(destination: deepLinkURL) { rowText }
                .accessibilityLabel(dueText.map { "\(row.task.title), \($0)" } ?? row.task.title)
        } else {
            rowText
        }
    }

    private var dueText: String? {
        switch row.dueTreatment {
        case .undated: nil
        case .overdue: "Overdue"
        case .dueToday: "Today"
        case .dueTomorrow: "Tomorrow"
        case .dated(let date): DateFormatting.displayString(date)
        }
    }

    private var dueColor: Color {
        switch row.dueTreatment {
        case .overdue: .red
        case .dueToday: .orange
        case .dueTomorrow: .yellow
        case .dated, .undated: .secondary
        }
    }
}

// MARK: - Previews

#if DEBUG
/// Fixture builders for previews only — never used by production code.
/// Required states per `implementation-spec.md`: signed-out, empty,
/// offline-cache, overdue, subtasks, and truncated, across all three
/// families, plus list-unavailable and no-cache for completeness.
private enum WidgetPreviewFixture {
    static let listID = "preview-list"
    static let listTitle = "Personal"

    private static func rowBudget(for family: WidgetFamily) -> Int {
        TaskListWidgetProvider.rowBudget(for: family)
    }

    static func signedOut(_ family: WidgetFamily) -> TaskListWidgetEntry {
        TaskListWidgetEntry(date: .now, family: family, content: TaskWidgetEntryContent(
            status: .signedOut, listID: listID, listTitle: listTitle, sortOrder: .myOrder, projection: nil
        ))
    }

    static func listUnavailable(_ family: WidgetFamily) -> TaskListWidgetEntry {
        TaskListWidgetEntry(date: .now, family: family, content: TaskWidgetEntryContent(
            status: .listUnavailable, listID: listID, listTitle: listTitle, sortOrder: .myOrder, projection: nil
        ))
    }

    static func noCache(_ family: WidgetFamily) -> TaskListWidgetEntry {
        TaskListWidgetEntry(date: .now, family: family, content: TaskWidgetEntryContent(
            status: .noCache, listID: listID, listTitle: listTitle, sortOrder: .myOrder, projection: nil
        ))
    }

    static func empty(_ family: WidgetFamily) -> TaskListWidgetEntry {
        TaskListWidgetEntry(date: .now, family: family, content: TaskWidgetEntryContent(
            status: .live, listID: listID, listTitle: listTitle, sortOrder: .myOrder,
            projection: TaskWidgetProjectedList(rows: [], remainderCount: 0)
        ))
    }

    static func offlineCache(_ family: WidgetFamily) -> TaskListWidgetEntry {
        let tasks = [
            TaskWidgetTaskSnapshot(id: "1", title: "Renew passport", position: "1"),
            TaskWidgetTaskSnapshot(id: "2", title: "Email the landlord", position: "2"),
        ]
        let projection = TaskWidgetProjection.project(tasks: tasks, sortOrder: .myOrder, rowBudget: rowBudget(for: family))
        return TaskListWidgetEntry(date: .now, family: family, content: TaskWidgetEntryContent(
            status: .stale(lastUpdated: Date().addingTimeInterval(-3 * 3600)),
            listID: listID, listTitle: listTitle, sortOrder: .myOrder, projection: projection
        ))
    }

    static func overdue(_ family: WidgetFamily) -> TaskListWidgetEntry {
        let now = Date()
        let calendar = Calendar.current
        func due(_ dayOffset: Int) -> String {
            DateFormatting.formatGoogleTaskDueDate(calendar.date(byAdding: .day, value: dayOffset, to: now)!, calendar: calendar)
        }
        let tasks = [
            TaskWidgetTaskSnapshot(id: "1", title: "Submit expense report", due: due(-3), position: "1"),
            TaskWidgetTaskSnapshot(id: "2", title: "Call the plumber", due: due(0), position: "2"),
            TaskWidgetTaskSnapshot(id: "3", title: "Plan weekend trip", due: due(1), position: "3"),
        ]
        let projection = TaskWidgetProjection.project(tasks: tasks, sortOrder: .dueDate, rowBudget: rowBudget(for: family), now: now, calendar: calendar)
        return TaskListWidgetEntry(date: .now, family: family, content: TaskWidgetEntryContent(
            status: .live, listID: listID, listTitle: listTitle, sortOrder: .dueDate, projection: projection
        ))
    }

    static func subtasks(_ family: WidgetFamily) -> TaskListWidgetEntry {
        let tasks = [
            TaskWidgetTaskSnapshot(id: "1", title: "Plan the offsite", position: "1"),
            TaskWidgetTaskSnapshot(id: "1a", title: "Book the venue", parent: "1", position: "1"),
            TaskWidgetTaskSnapshot(id: "1b", title: "Send calendar invites", parent: "1", position: "2"),
            TaskWidgetTaskSnapshot(id: "2", title: "Review Q3 budget", position: "2"),
        ]
        let projection = TaskWidgetProjection.project(tasks: tasks, sortOrder: .myOrder, rowBudget: rowBudget(for: family))
        return TaskListWidgetEntry(date: .now, family: family, content: TaskWidgetEntryContent(
            status: .live, listID: listID, listTitle: listTitle, sortOrder: .myOrder, projection: projection
        ))
    }

    static func truncated(_ family: WidgetFamily) -> TaskListWidgetEntry {
        let tasks = (1...12).map { index in
            TaskWidgetTaskSnapshot(
                id: "\(index)",
                title: "Follow up on item number \(index) from the planning meeting",
                position: String(format: "%05d", index)
            )
        }
        let projection = TaskWidgetProjection.project(tasks: tasks, sortOrder: .myOrder, rowBudget: rowBudget(for: family))
        return TaskListWidgetEntry(date: .now, family: family, content: TaskWidgetEntryContent(
            status: .live, listID: listID, listTitle: "Long-Running Project With A Very Long Name", sortOrder: .myOrder, projection: projection
        ))
    }
}

#Preview("Signed Out — Small", as: .systemSmall) {
    TaskListWidget()
} timeline: {
    WidgetPreviewFixture.signedOut(.systemSmall)
}

#Preview("Signed Out — Medium", as: .systemMedium) {
    TaskListWidget()
} timeline: {
    WidgetPreviewFixture.signedOut(.systemMedium)
}

#Preview("Signed Out — Large", as: .systemLarge) {
    TaskListWidget()
} timeline: {
    WidgetPreviewFixture.signedOut(.systemLarge)
}

#Preview("Empty — Small", as: .systemSmall) {
    TaskListWidget()
} timeline: {
    WidgetPreviewFixture.empty(.systemSmall)
}

#Preview("Empty — Medium", as: .systemMedium) {
    TaskListWidget()
} timeline: {
    WidgetPreviewFixture.empty(.systemMedium)
}

#Preview("Empty — Large", as: .systemLarge) {
    TaskListWidget()
} timeline: {
    WidgetPreviewFixture.empty(.systemLarge)
}

#Preview("Offline Cache — Small", as: .systemSmall) {
    TaskListWidget()
} timeline: {
    WidgetPreviewFixture.offlineCache(.systemSmall)
}

#Preview("Offline Cache — Medium", as: .systemMedium) {
    TaskListWidget()
} timeline: {
    WidgetPreviewFixture.offlineCache(.systemMedium)
}

#Preview("Offline Cache — Large", as: .systemLarge) {
    TaskListWidget()
} timeline: {
    WidgetPreviewFixture.offlineCache(.systemLarge)
}

#Preview("Overdue — Small", as: .systemSmall) {
    TaskListWidget()
} timeline: {
    WidgetPreviewFixture.overdue(.systemSmall)
}

#Preview("Overdue — Medium", as: .systemMedium) {
    TaskListWidget()
} timeline: {
    WidgetPreviewFixture.overdue(.systemMedium)
}

#Preview("Overdue — Large", as: .systemLarge) {
    TaskListWidget()
} timeline: {
    WidgetPreviewFixture.overdue(.systemLarge)
}

#Preview("Subtasks — Small", as: .systemSmall) {
    TaskListWidget()
} timeline: {
    WidgetPreviewFixture.subtasks(.systemSmall)
}

#Preview("Subtasks — Medium", as: .systemMedium) {
    TaskListWidget()
} timeline: {
    WidgetPreviewFixture.subtasks(.systemMedium)
}

#Preview("Subtasks — Large", as: .systemLarge) {
    TaskListWidget()
} timeline: {
    WidgetPreviewFixture.subtasks(.systemLarge)
}

#Preview("Truncated — Small", as: .systemSmall) {
    TaskListWidget()
} timeline: {
    WidgetPreviewFixture.truncated(.systemSmall)
}

#Preview("Truncated — Medium", as: .systemMedium) {
    TaskListWidget()
} timeline: {
    WidgetPreviewFixture.truncated(.systemMedium)
}

#Preview("Truncated — Large", as: .systemLarge) {
    TaskListWidget()
} timeline: {
    WidgetPreviewFixture.truncated(.systemLarge)
}

#Preview("List Unavailable — Medium", as: .systemMedium) {
    TaskListWidget()
} timeline: {
    WidgetPreviewFixture.listUnavailable(.systemMedium)
}

#Preview("No Cache — Medium", as: .systemMedium) {
    TaskListWidget()
} timeline: {
    WidgetPreviewFixture.noCache(.systemMedium)
}
#endif
