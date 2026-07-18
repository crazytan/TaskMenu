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

struct PendingNotificationRequestData: Sendable, Equatable {
    let identifier: String
    /// `nil` means the request has no trigger and delivers immediately.
    let trigger: DueDateNotificationTrigger?
}

protocol UserNotificationCenterClientProtocol: Sendable {
    func authorizationStatus() async -> NotificationAuthorizationStatus
    func requestAuthorization() async throws -> Bool
    func pendingNotificationRequests() async -> [PendingNotificationRequestData]
    func deliveredNotificationIdentifiers() async -> [String]
    func add(_ request: DueDateNotificationRequestData) async throws
    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) async
    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) async
    func removeAllPendingNotificationRequests() async
    func removeAllDeliveredNotifications() async
}

struct DueDateNotificationService: DueDateNotificationServicing, Sendable {
    // The defaults key predates the record covering calendar triggers; the
    // string is kept for continuity with existing installs.
    private static let scheduledRecordKey = "dev.crazytan.TaskMenu.dueDate.scheduledImmediateNotifications"
    // The system keeps only the ~64 soonest-firing pending requests and
    // silently drops the rest, so cap all due-date requests across every
    // list below that with headroom left for other notifications; later
    // syncs pick up the remainder as earlier ones fire.
    static let maxScheduledRequestCount = 60

    private let center: any UserNotificationCenterClientProtocol
    private let calendar: Calendar
    private let now: @Sendable () -> Date
    private nonisolated(unsafe) let defaults: UserDefaults
    private let serialQueue = SerialTaskQueue()

    init(
        center: any UserNotificationCenterClientProtocol = UserNotificationCenterClient(),
        calendar: Calendar = .current,
        now: @escaping @Sendable () -> Date = Date.init,
        defaults: UserDefaults = .standard
    ) {
        self.center = center
        self.calendar = calendar
        self.now = now
        self.defaults = defaults
    }

    func syncNotifications(for tasks: [TaskItem], in list: TaskList) async {
        await serialQueue.run {
            await self.performSyncNotifications(for: tasks, in: list)
        }
    }

    func removeNotifications(forTaskIDs taskIDs: [String], inListID listID: String) async {
        await serialQueue.run {
            await self.performRemoveNotifications(forTaskIDs: taskIDs, inListID: listID)
        }
    }

    func removeAllNotifications() async {
        await serialQueue.run {
            await self.performRemoveAllNotifications()
        }
    }

    private struct DesiredNotification: Sendable {
        let request: DueDateNotificationRequestData
        let firesToday: Bool
        let fireDate: Date
    }

    private func performSyncNotifications(for tasks: [TaskItem], in list: TaskList) async {
        let prefix = Self.identifierPrefix(forListID: list.id)
        let currentDate = now()
        let desiredNotifications = tasks.compactMap { desiredNotification(for: $0, in: list, now: currentDate) }
        let desiredIdentifiers = Set(desiredNotifications.map(\.request.identifier))

        let allPendingRequests = await center.pendingNotificationRequests()
        let pendingIdentifiers = Set(
            allPendingRequests.map(\.identifier).filter { $0.hasPrefix(prefix) }
        )
        let deliveredIdentifiers = Set(
            await center.deliveredNotificationIdentifiers()
                .filter { $0.hasPrefix(prefix) }
        )

        let stalePendingIdentifiers = Array(pendingIdentifiers.subtracting(desiredIdentifiers))
        if !stalePendingIdentifiers.isEmpty {
            await center.removePendingNotificationRequests(withIdentifiers: stalePendingIdentifiers)
        }

        // Delivered reminders stay visible while their task is incomplete and
        // still has a due date (overdue included); only tasks that were
        // completed, deleted, or had their due date cleared lose them.
        let activeDueTaskIdentifiers = Set(
            tasks
                .filter { !$0.isCompleted && $0.due != nil }
                .map { Self.identifier(forTaskID: $0.id, listID: list.id) }
        )
        let staleDeliveredIdentifiers = Array(deliveredIdentifiers.subtracting(activeDueTaskIdentifiers))
        if !staleDeliveredIdentifiers.isEmpty {
            await center.removeDeliveredNotifications(withIdentifiers: staleDeliveredIdentifiers)
        }

        // Clean the record before the early returns below: a task that is no
        // longer due-desired (completed, deleted, or due cleared) must be
        // able to notify again if it becomes due once more, so its record
        // entry goes away with its notifications.
        let today = dayString(for: currentDate)
        var scheduledRecord = loadScheduledRecord()
        for identifier in Array(scheduledRecord.keys)
        where identifier.hasPrefix(prefix) && !desiredIdentifiers.contains(identifier) {
            scheduledRecord.removeValue(forKey: identifier)
        }
        pruneScheduledRecord(&scheduledRecord, keepingDaysOnOrAfter: today)
        saveScheduledRecord(scheduledRecord)

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

        // Dedup first so skipped reminders do not consume cap slots. The
        // record maps identifier -> the fire DAY it was last scheduled for:
        // a task is skipped only when a request for that same due day was
        // already scheduled once (calendar 9 AM and immediate alike), so a
        // trigger scheduled the day before still suppresses the immediate
        // re-add after it fires, while a changed due day always re-adds.
        var notificationsToAdd: [DesiredNotification] = []
        for notification in desiredNotifications {
            let request = notification.request
            let fireDay = dayString(for: notification.fireDate)
            if notification.firesToday, deliveredIdentifiers.contains(request.identifier) {
                // Already fired for this due day; remember that so a later
                // sync after the user dismisses the banner does not re-add.
                scheduledRecord[request.identifier] = fireDay
                continue
            }
            if scheduledRecord[request.identifier] == fireDay {
                continue
            }
            notificationsToAdd.append(notification)
        }

        // Global cap reconciliation: this list's adds compete with every
        // list's still-pending due-date requests for the soonest slots.
        let globalPrefix = "\(Constants.Notifications.dueDateIdentifierPrefix)."
        let addIdentifiers = Set(notificationsToAdd.map(\.request.identifier))
        let staleIdentifierSet = Set(stalePendingIdentifiers)
        var capEntries: [(fireDate: Date, identifier: String, notification: DesiredNotification?)] =
            notificationsToAdd.map { ($0.fireDate, $0.request.identifier, $0) }
        for pending in allPendingRequests {
            guard pending.identifier.hasPrefix(globalPrefix) else { continue }
            guard !staleIdentifierSet.contains(pending.identifier) else { continue }
            guard !addIdentifiers.contains(pending.identifier) else { continue }
            capEntries.append((fireDate(for: pending.trigger, now: currentDate), pending.identifier, nil))
        }
        capEntries.sort { ($0.fireDate, $0.identifier) < ($1.fireDate, $1.identifier) }

        let keptEntries = capEntries.prefix(Self.maxScheduledRequestCount)
        let evictedEntries = capEntries.dropFirst(Self.maxScheduledRequestCount)

        // Remove every evicted identifier that is actually pending — that
        // covers other lists' evicted requests AND an evicted add whose
        // identifier still holds an old-trigger request in the center.
        let allDueDatePendingIdentifiers = Set(
            allPendingRequests.map(\.identifier).filter { $0.hasPrefix(globalPrefix) }
        )
        let evictedPendingIdentifiers = evictedEntries
            .filter { allDueDatePendingIdentifiers.contains($0.identifier) }
            .map(\.identifier)
        if !evictedPendingIdentifiers.isEmpty {
            await center.removePendingNotificationRequests(withIdentifiers: evictedPendingIdentifiers)
        }
        // Evicted requests must reschedule once slots free up, so drop
        // their record entries.
        for entry in evictedEntries {
            scheduledRecord.removeValue(forKey: entry.identifier)
        }

        for entry in keptEntries {
            guard let notification = entry.notification else { continue }
            do {
                // add(_:) with an existing identifier replaces the pending
                // request, so a changed fire day swaps the trigger in place.
                try await center.add(notification.request)
                scheduledRecord[notification.request.identifier] = dayString(for: notification.fireDate)
            } catch {
                continue
            }
        }

        pruneScheduledRecord(&scheduledRecord, keepingDaysOnOrAfter: today)
        saveScheduledRecord(scheduledRecord)
    }

    private func performRemoveNotifications(forTaskIDs taskIDs: [String], inListID listID: String) async {
        let identifiers = taskIDs.map { Self.identifier(forTaskID: $0, listID: listID) }
        guard !identifiers.isEmpty else { return }

        await center.removePendingNotificationRequests(withIdentifiers: identifiers)
        await center.removeDeliveredNotifications(withIdentifiers: identifiers)

        var scheduledRecord = loadScheduledRecord()
        for identifier in identifiers {
            scheduledRecord.removeValue(forKey: identifier)
        }
        saveScheduledRecord(scheduledRecord)
    }

    private func performRemoveAllNotifications() async {
        await center.removeAllPendingNotificationRequests()
        await center.removeAllDeliveredNotifications()
        saveScheduledRecord([:])
    }

    private func desiredNotification(for task: TaskItem, in list: TaskList, now: Date) -> DesiredNotification? {
        guard !task.isCompleted, let dueDate = task.dueDate(in: calendar) else { return nil }
        guard let trigger = notificationTrigger(for: dueDate, now: now) else { return nil }

        let firesToday = isDueToday(dueDate, relativeTo: now)
        let request = DueDateNotificationRequestData(
            identifier: Self.identifier(forTaskID: task.id, listID: list.id),
            title: task.title,
            body: firesToday ? "Due today" : "Due in \(list.title)",
            trigger: trigger
        )

        return DesiredNotification(
            request: request,
            firesToday: firesToday,
            fireDate: fireDate(for: trigger, now: now)
        )
    }

    private func fireDate(for trigger: DueDateNotificationTrigger?, now: Date) -> Date {
        switch trigger {
        case .calendar(let components):
            return calendar.date(from: components) ?? .distantFuture
        case .timeInterval(let interval):
            return now.addingTimeInterval(interval)
        case nil:
            // No trigger means immediate delivery; treat it as firing now.
            return now
        }
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

    private func dayString(for date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let year = components.year ?? 0
        let month = components.month ?? 0
        let day = components.day ?? 0
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    private func loadScheduledRecord() -> [String: String] {
        defaults.dictionary(forKey: Self.scheduledRecordKey) as? [String: String] ?? [:]
    }

    private func saveScheduledRecord(_ record: [String: String]) {
        if record.isEmpty {
            defaults.removeObject(forKey: Self.scheduledRecordKey)
        } else {
            defaults.set(record, forKey: Self.scheduledRecordKey)
        }
    }

    // Keep today's and future fire days so a trigger scheduled the day
    // before its due day still dedups on the due day itself; only past
    // days age out. Day strings are zero-padded, so string order matches
    // chronological order.
    private func pruneScheduledRecord(_ record: inout [String: String], keepingDaysOnOrAfter day: String) {
        record = record.filter { $0.value >= day }
    }

    static func identifier(forTaskID taskID: String, listID: String) -> String {
        "\(Constants.Notifications.dueDateIdentifierPrefix).\(listID).\(taskID)"
    }

    static func identifierPrefix(forListID listID: String) -> String {
        "\(Constants.Notifications.dueDateIdentifierPrefix).\(listID)."
    }
}

// Runs enqueued operations one at a time in FIFO order, including across
// their suspension points, so the scheduled-record read-modify-write in one
// call cannot interleave with a concurrent sync or removal. Actor isolation
// alone is not enough because actors are reentrant at await points.
private actor SerialTaskQueue {
    private var lastEnqueued: Task<Void, Never>?

    func run(_ operation: @escaping @Sendable () async -> Void) async {
        let previous = lastEnqueued
        let next = Task {
            await previous?.value
            await operation()
        }
        lastEnqueued = next
        await next.value
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

    func pendingNotificationRequests() async -> [PendingNotificationRequestData] {
        await withCheckedContinuation { continuation in
            center.getPendingNotificationRequests { requests in
                let pendingRequests = requests.map { request -> PendingNotificationRequestData in
                    let trigger: DueDateNotificationTrigger?
                    switch request.trigger {
                    case let calendarTrigger as UNCalendarNotificationTrigger:
                        trigger = .calendar(calendarTrigger.dateComponents)
                    case let intervalTrigger as UNTimeIntervalNotificationTrigger:
                        trigger = .timeInterval(intervalTrigger.timeInterval)
                    default:
                        trigger = nil
                    }
                    return PendingNotificationRequestData(identifier: request.identifier, trigger: trigger)
                }
                continuation.resume(returning: pendingRequests)
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
