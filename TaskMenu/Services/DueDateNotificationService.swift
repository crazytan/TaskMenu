import Foundation
@preconcurrency import UserNotifications

protocol DueDateNotificationServicing: Sendable {
    func syncNotifications(for tasks: [TaskItem], in list: TaskList) async
    func removeNotifications(forTaskIDs taskIDs: [String], inListID listID: String) async
    func removeAllNotifications() async
}

enum NotificationAuthorizationStatus: Sendable, Equatable {
    case notDetermined
    case denied
    case authorized
    case provisional
    case ephemeral
}

enum DueDateNotificationTrigger: Sendable, Equatable {
    case calendar(DateComponents)
    case timeInterval(TimeInterval)
}

struct DueDateNotificationRequestData: Sendable, Equatable {
    let identifier: String
    let title: String
    let body: String
    let trigger: DueDateNotificationTrigger
}

protocol UserNotificationCenterClientProtocol: Sendable {
    func authorizationStatus() async -> NotificationAuthorizationStatus
    func requestAuthorization() async throws -> Bool
    func pendingNotificationRequestIdentifiers() async -> [String]
    func deliveredNotificationIdentifiers() async -> [String]
    func add(_ request: DueDateNotificationRequestData) async throws
    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) async
    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) async
    func removeAllPendingNotificationRequests() async
    func removeAllDeliveredNotifications() async
}

struct DueDateNotificationService: DueDateNotificationServicing, Sendable {
    private let center: any UserNotificationCenterClientProtocol
    private let calendar: Calendar
    private let now: @Sendable () -> Date

    init(
        center: any UserNotificationCenterClientProtocol = UserNotificationCenterClient(),
        calendar: Calendar = .current,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.center = center
        self.calendar = calendar
        self.now = now
    }

    func syncNotifications(for tasks: [TaskItem], in list: TaskList) async {
        let prefix = Self.identifierPrefix(forListID: list.id)
        let desiredRequests = tasks.compactMap { notificationRequest(for: $0, in: list, now: now()) }
        let desiredIdentifiers = Set(desiredRequests.map(\.identifier))

        let pendingIdentifiers = Set(
            await center.pendingNotificationRequestIdentifiers()
                .filter { $0.hasPrefix(prefix) }
        )
        let deliveredIdentifiers = Set(
            await center.deliveredNotificationIdentifiers()
                .filter { $0.hasPrefix(prefix) }
        )

        let stalePendingIdentifiers = Array(pendingIdentifiers.subtracting(desiredIdentifiers))
        if !stalePendingIdentifiers.isEmpty {
            await center.removePendingNotificationRequests(withIdentifiers: stalePendingIdentifiers)
        }

        let staleDeliveredIdentifiers = Array(deliveredIdentifiers.subtracting(desiredIdentifiers))
        if !staleDeliveredIdentifiers.isEmpty {
            await center.removeDeliveredNotifications(withIdentifiers: staleDeliveredIdentifiers)
        }

        let hasDueTasks = tasks.contains { !$0.isCompleted && $0.dueDate != nil }
        guard hasDueTasks else { return }

        let authorizationStatus = await center.authorizationStatus()
        switch authorizationStatus {
        case .notDetermined:
            let granted = (try? await center.requestAuthorization()) ?? false
            guard granted else { return }
        case .denied:
            return
        case .authorized, .provisional, .ephemeral:
            break
        }

        for request in desiredRequests {
            if case .timeInterval = request.trigger, deliveredIdentifiers.contains(request.identifier) {
                continue
            }

            try? await center.add(request)
        }
    }

    func removeNotifications(forTaskIDs taskIDs: [String], inListID listID: String) async {
        let identifiers = taskIDs.map { Self.identifier(forTaskID: $0, listID: listID) }
        guard !identifiers.isEmpty else { return }

        await center.removePendingNotificationRequests(withIdentifiers: identifiers)
        await center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    func removeAllNotifications() async {
        await center.removeAllPendingNotificationRequests()
        await center.removeAllDeliveredNotifications()
    }

    private func notificationRequest(for task: TaskItem, in list: TaskList, now: Date) -> DueDateNotificationRequestData? {
        guard !task.isCompleted, let dueDate = task.dueDate(in: calendar) else { return nil }
        guard let trigger = notificationTrigger(for: dueDate, now: now) else { return nil }

        return DueDateNotificationRequestData(
            identifier: Self.identifier(forTaskID: task.id, listID: list.id),
            title: task.title,
            body: isDueToday(dueDate, relativeTo: now) ? "Due today" : "Due in \(list.title)",
            trigger: trigger
        )
    }

    private func notificationTrigger(for dueDate: Date, now: Date) -> DueDateNotificationTrigger? {
        let dueComponents = dueDateComponents(from: dueDate)
        guard
            let year = dueComponents.year,
            let month = dueComponents.month,
            let day = dueComponents.day,
            let localDueDate = calendar.date(from: DateComponents(year: year, month: month, day: day))
        else {
            return nil
        }

        let startOfToday = calendar.startOfDay(for: now)
        if localDueDate < startOfToday {
            return nil
        }

        guard let nineAM = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: localDueDate) else {
            return nil
        }

        if calendar.isDate(localDueDate, inSameDayAs: now), nineAM <= now {
            return .timeInterval(1)
        }

        var triggerDateComponents = calendar.dateComponents(
            [.calendar, .timeZone, .year, .month, .day, .hour, .minute],
            from: nineAM
        )
        triggerDateComponents.second = 0
        return .calendar(triggerDateComponents)
    }

    private func isDueToday(_ dueDate: Date, relativeTo now: Date) -> Bool {
        let dueComponents = dueDateComponents(from: dueDate)
        let nowComponents = calendar.dateComponents([.year, .month, .day], from: now)

        return dueComponents.year == nowComponents.year
            && dueComponents.month == nowComponents.month
            && dueComponents.day == nowComponents.day
    }

    private func dueDateComponents(from dueDate: Date) -> DateComponents {
        calendar.dateComponents([.year, .month, .day], from: dueDate)
    }

    static func identifier(forTaskID taskID: String, listID: String) -> String {
        "\(Constants.Notifications.dueDateIdentifierPrefix).\(listID).\(taskID)"
    }

    static func identifierPrefix(forListID listID: String) -> String {
        "\(Constants.Notifications.dueDateIdentifierPrefix).\(listID)."
    }
}

private final class UserNotificationCenterClient: @unchecked Sendable, UserNotificationCenterClientProtocol {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func authorizationStatus() async -> NotificationAuthorizationStatus {
        await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                let status: NotificationAuthorizationStatus
                switch settings.authorizationStatus {
                case .notDetermined:
                    status = .notDetermined
                case .denied:
                    status = .denied
                case .authorized:
                    status = .authorized
                case .provisional:
                    status = .provisional
                case .ephemeral:
                    status = .ephemeral
                @unknown default:
                    status = .denied
                }
                continuation.resume(returning: status)
            }
        }
    }

    func requestAuthorization() async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            center.requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    func pendingNotificationRequestIdentifiers() async -> [String] {
        await withCheckedContinuation { continuation in
            center.getPendingNotificationRequests { requests in
                continuation.resume(returning: requests.map(\.identifier))
            }
        }
    }

    func deliveredNotificationIdentifiers() async -> [String] {
        await withCheckedContinuation { continuation in
            center.getDeliveredNotifications { notifications in
                continuation.resume(returning: notifications.map(\.request.identifier))
            }
        }
    }

    func add(_ request: DueDateNotificationRequestData) async throws {
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        content.sound = .default

        let trigger: UNNotificationTrigger
        switch request.trigger {
        case .calendar(let dateComponents):
            trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: false)
        case .timeInterval(let interval):
            trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        }

        let notificationRequest = UNNotificationRequest(
            identifier: request.identifier,
            content: content,
            trigger: trigger
        )

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            center.add(notificationRequest) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) async {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) async {
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    func removeAllPendingNotificationRequests() async {
        center.removeAllPendingNotificationRequests()
    }

    func removeAllDeliveredNotifications() async {
        center.removeAllDeliveredNotifications()
    }
}
