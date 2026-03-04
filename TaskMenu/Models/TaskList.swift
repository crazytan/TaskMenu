import Foundation

struct TaskList: Codable, Identifiable, Sendable {
    let id: String
    var title: String
    let selfLink: String?
    let updated: String?
}

struct TaskListCollection: Codable, Sendable {
    let kind: String?
    let etag: String?
    let items: [TaskList]?
}
