import Foundation
@testable import TaskMenu

actor TestDueDateNotificationService: DueDateNotificationServicing {
    struct SyncCall: Sendable {
        let tasks: [TaskItem]
        let list: TaskList
    }

    private(set) var syncCalls: [SyncCall] = []
    private(set) var removedTaskIDs: [[String]] = []
    private(set) var removedListIDs: [String] = []
    private(set) var removeAllCallCount = 0

    func syncNotifications(for tasks: [TaskItem], in list: TaskList) async {
        syncCalls.append(SyncCall(tasks: tasks, list: list))
    }

    func removeNotifications(forTaskIDs taskIDs: [String], inListID listID: String) async {
        removedTaskIDs.append(taskIDs)
        removedListIDs.append(listID)
    }

    func removeAllNotifications() async {
        removeAllCallCount += 1
    }

    func latestSyncCall() -> SyncCall? {
        syncCalls.last
    }
}
