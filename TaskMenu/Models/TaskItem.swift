import Foundation

struct TaskItem: Codable, Identifiable, Sendable {
    let id: String
    var title: String
    var notes: String?
    var status: TaskStatus
    var due: String? // RFC 3339 date-time
    let selfLink: String?
    var parent: String?
    var position: String?
    let updated: String?

    enum TaskStatus: String, Codable, Sendable {
        case needsAction
        case completed
    }

    var isCompleted: Bool {
        get { status == .completed }
        set { status = newValue ? .completed : .needsAction }
    }

    var dueDate: Date? {
        get {
            dueDate(in: .current)
        }
        set {
            due = newValue.map { DateFormatting.formatGoogleTaskDueDate($0) }
        }
    }

    func dueDate(in calendar: Calendar) -> Date? {
        guard let due else { return nil }
        return DateFormatting.parseGoogleTaskDueDate(due, calendar: calendar)
    }

    mutating func enableDueDate(defaultDate: Date = Date()) {
        guard dueDate == nil else { return }
        dueDate = defaultDate
    }

    mutating func clearDueDate() {
        dueDate = nil
    }
}

struct TaskItemList: Codable, Sendable {
    let kind: String?
    let etag: String?
    let items: [TaskItem]?
    let nextPageToken: String?
}
