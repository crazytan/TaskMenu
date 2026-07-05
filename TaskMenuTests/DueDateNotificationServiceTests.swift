import XCTest
@testable import TaskMenu

final class DueDateNotificationServiceTests: XCTestCase {
    func testSyncSchedulesFutureDueTaskAtNineAM() async {
        let center = TestUserNotificationCenterClient(authorizationStatus: .authorized)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = DateFormatting.parseRFC3339("2026-03-10T08:00:00.000Z")!
        let service = DueDateNotificationService(center: center, calendar: calendar, now: { now })
        let list = TaskList(id: "list1", title: "Work", selfLink: nil, updated: nil)
        let task = makeTask(id: "task1", title: "File taxes", due: "2026-03-11T00:00:00.000Z")

        await service.syncNotifications(for: [task], in: list)

        let addedRequests = await center.addedRequests()
        XCTAssertEqual(addedRequests.count, 1)
        XCTAssertEqual(addedRequests[0].identifier, DueDateNotificationService.identifier(forTaskID: "task1", listID: "list1"))
        XCTAssertEqual(addedRequests[0].title, "File taxes")
        XCTAssertEqual(addedRequests[0].body, "Due in Work")
        XCTAssertEqual(
            addedRequests[0].trigger,
            .calendar(DateComponents(calendar: calendar, timeZone: calendar.timeZone, year: 2026, month: 3, day: 11, hour: 9, minute: 0, second: 0))
        )
    }

    func testSyncSchedulesFutureDueTaskUsingLocalCalendarDay() async {
        let center = TestUserNotificationCenterClient(authorizationStatus: .authorized)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 8))!
        let service = DueDateNotificationService(center: center, calendar: calendar, now: { now })
        let list = TaskList(id: "list1", title: "Work", selfLink: nil, updated: nil)
        let task = makeTask(id: "task1", title: "File taxes", due: "2026-03-11T00:00:00.000Z")

        await service.syncNotifications(for: [task], in: list)

        let addedRequests = await center.addedRequests()
        XCTAssertEqual(addedRequests.count, 1)
        XCTAssertEqual(
            addedRequests[0].trigger,
            .calendar(DateComponents(calendar: calendar, timeZone: calendar.timeZone, year: 2026, month: 3, day: 11, hour: 9, minute: 0, second: 0))
        )
    }

    func testSyncSchedulesImmediateNotificationForPastDueTimeToday() async {
        let center = TestUserNotificationCenterClient(authorizationStatus: .authorized)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = DateFormatting.parseRFC3339("2026-03-10T12:00:00.000Z")!
        let service = DueDateNotificationService(center: center, calendar: calendar, now: { now })
        let list = TaskList(id: "list1", title: "Inbox", selfLink: nil, updated: nil)
        let task = makeTask(id: "task1", title: "Pay rent", due: "2026-03-10T00:00:00.000Z")

        await service.syncNotifications(for: [task], in: list)

        let addedRequests = await center.addedRequests()
        XCTAssertEqual(addedRequests.count, 1)
        XCTAssertEqual(addedRequests[0].body, "Due today")
        XCTAssertEqual(addedRequests[0].trigger, .timeInterval(1))
    }

    func testSyncRequestsPermissionOnFirstUse() async {
        let center = TestUserNotificationCenterClient(
            authorizationStatus: .notDetermined,
            requestAuthorizationResult: true
        )
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = DateFormatting.parseRFC3339("2026-03-10T08:00:00.000Z")!
        let service = DueDateNotificationService(center: center, calendar: calendar, now: { now })
        let list = TaskList(id: "list1", title: "Inbox", selfLink: nil, updated: nil)
        let task = makeTask(id: "task1", title: "Review PR", due: "2026-03-11T00:00:00.000Z")

        await service.syncNotifications(for: [task], in: list)

        let requestAuthorizationCallCount = await center.requestAuthorizationCallCount()
        let addedRequests = await center.addedRequests()
        XCTAssertEqual(requestAuthorizationCallCount, 1)
        XCTAssertEqual(addedRequests.count, 1)
    }

    func testSyncDoesNotScheduleWhenPermissionRequestIsDenied() async {
        let center = TestUserNotificationCenterClient(
            authorizationStatus: .notDetermined,
            requestAuthorizationResult: false
        )
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = DateFormatting.parseRFC3339("2026-03-10T08:00:00.000Z")!
        let service = DueDateNotificationService(center: center, calendar: calendar, now: { now })
        let list = TaskList(id: "list1", title: "Inbox", selfLink: nil, updated: nil)
        let task = makeTask(id: "task1", title: "Review PR", due: "2026-03-11T00:00:00.000Z")

        await service.syncNotifications(for: [task], in: list)

        let requestAuthorizationCallCount = await center.requestAuthorizationCallCount()
        let addedRequests = await center.addedRequests()
        XCTAssertEqual(requestAuthorizationCallCount, 1)
        XCTAssertTrue(addedRequests.isEmpty)
    }

    func testSyncRemovesStaleNotificationsForCurrentList() async {
        let staleIdentifier = DueDateNotificationService.identifier(forTaskID: "task1", listID: "list1")
        let otherListIdentifier = DueDateNotificationService.identifier(forTaskID: "task9", listID: "list9")
        let center = TestUserNotificationCenterClient(
            authorizationStatus: .authorized,
            pendingIdentifiers: [staleIdentifier, otherListIdentifier],
            deliveredIdentifiers: [staleIdentifier, otherListIdentifier]
        )
        let service = DueDateNotificationService(center: center)
        let list = TaskList(id: "list1", title: "Inbox", selfLink: nil, updated: nil)

        await service.syncNotifications(for: [], in: list)

        let removedPendingIdentifiers = await center.removedPendingIdentifiers()
        let removedDeliveredIdentifiers = await center.removedDeliveredIdentifiers()
        let addedRequests = await center.addedRequests()
        XCTAssertEqual(removedPendingIdentifiers, [staleIdentifier])
        XCTAssertEqual(removedDeliveredIdentifiers, [staleIdentifier])
        XCTAssertTrue(addedRequests.isEmpty)
    }

    func testSyncDoesNotRescheduleImmediateNotificationWhenAlreadyDelivered() async {
        let identifier = DueDateNotificationService.identifier(forTaskID: "task1", listID: "list1")
        let center = TestUserNotificationCenterClient(
            authorizationStatus: .authorized,
            deliveredIdentifiers: [identifier]
        )
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = DateFormatting.parseRFC3339("2026-03-10T12:00:00.000Z")!
        let service = DueDateNotificationService(center: center, calendar: calendar, now: { now })
        let list = TaskList(id: "list1", title: "Inbox", selfLink: nil, updated: nil)
        let task = makeTask(id: "task1", title: "Pay rent", due: "2026-03-10T00:00:00.000Z")

        await service.syncNotifications(for: [task], in: list)

        let addedRequests = await center.addedRequests()
        XCTAssertTrue(addedRequests.isEmpty)
    }

    func testSyncDoesNotRescheduleImmediateNotificationAlreadyScheduledSameDay() async {
        let defaults = makeDefaults()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = DateFormatting.parseRFC3339("2026-03-10T12:00:00.000Z")!
        let list = TaskList(id: "list1", title: "Inbox", selfLink: nil, updated: nil)
        let task = makeTask(id: "task1", title: "Pay rent", due: "2026-03-10T00:00:00.000Z")

        let firstCenter = TestUserNotificationCenterClient(authorizationStatus: .authorized)
        let firstService = DueDateNotificationService(center: firstCenter, calendar: calendar, now: { now }, defaults: defaults)
        await firstService.syncNotifications(for: [task], in: list)
        let firstAdded = await firstCenter.addedRequests()
        XCTAssertEqual(firstAdded.count, 1)
        XCTAssertEqual(firstAdded[0].trigger, .timeInterval(1))

        // Second sync same day with an empty delivered list must not re-add.
        let secondCenter = TestUserNotificationCenterClient(authorizationStatus: .authorized)
        let secondService = DueDateNotificationService(center: secondCenter, calendar: calendar, now: { now }, defaults: defaults)
        await secondService.syncNotifications(for: [task], in: list)
        let secondAdded = await secondCenter.addedRequests()
        XCTAssertTrue(secondAdded.isEmpty)
    }

    func testSyncReschedulesImmediateNotificationOnNewDay() async {
        let defaults = makeDefaults()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let list = TaskList(id: "list1", title: "Inbox", selfLink: nil, updated: nil)

        let firstNow = DateFormatting.parseRFC3339("2026-03-10T12:00:00.000Z")!
        let firstTask = makeTask(id: "task1", title: "Pay rent", due: "2026-03-10T00:00:00.000Z")
        let firstCenter = TestUserNotificationCenterClient(authorizationStatus: .authorized)
        let firstService = DueDateNotificationService(center: firstCenter, calendar: calendar, now: { firstNow }, defaults: defaults)
        await firstService.syncNotifications(for: [firstTask], in: list)
        let firstAdded = await firstCenter.addedRequests()
        XCTAssertEqual(firstAdded.count, 1)

        // Next day, same task due that later day should schedule again.
        let secondNow = DateFormatting.parseRFC3339("2026-03-11T12:00:00.000Z")!
        let secondTask = makeTask(id: "task1", title: "Pay rent", due: "2026-03-11T00:00:00.000Z")
        let secondCenter = TestUserNotificationCenterClient(authorizationStatus: .authorized)
        let secondService = DueDateNotificationService(center: secondCenter, calendar: calendar, now: { secondNow }, defaults: defaults)
        await secondService.syncNotifications(for: [secondTask], in: list)
        let secondAdded = await secondCenter.addedRequests()
        XCTAssertEqual(secondAdded.count, 1)
        XCTAssertEqual(secondAdded[0].trigger, .timeInterval(1))
    }

    func testRemoveAllNotificationsClearsScheduledRecordAllowingReschedule() async {
        let defaults = makeDefaults()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = DateFormatting.parseRFC3339("2026-03-10T12:00:00.000Z")!
        let list = TaskList(id: "list1", title: "Inbox", selfLink: nil, updated: nil)
        let task = makeTask(id: "task1", title: "Pay rent", due: "2026-03-10T00:00:00.000Z")

        let firstCenter = TestUserNotificationCenterClient(authorizationStatus: .authorized)
        let firstService = DueDateNotificationService(center: firstCenter, calendar: calendar, now: { now }, defaults: defaults)
        await firstService.syncNotifications(for: [task], in: list)
        let firstAdded = await firstCenter.addedRequests()
        XCTAssertEqual(firstAdded.count, 1)

        await firstService.removeAllNotifications()

        // After clearing the record, the same day sync should re-add.
        let secondCenter = TestUserNotificationCenterClient(authorizationStatus: .authorized)
        let secondService = DueDateNotificationService(center: secondCenter, calendar: calendar, now: { now }, defaults: defaults)
        await secondService.syncNotifications(for: [task], in: list)
        let secondAdded = await secondCenter.addedRequests()
        XCTAssertEqual(secondAdded.count, 1)
        XCTAssertEqual(secondAdded[0].trigger, .timeInterval(1))
    }

    func testRemoveNotificationsTargetsSpecificTaskIdentifiers() async {
        let center = TestUserNotificationCenterClient(authorizationStatus: .authorized)
        let service = DueDateNotificationService(center: center)

        await service.removeNotifications(forTaskIDs: ["task1", "task2"], inListID: "list1")

        let removedPendingIdentifiers = await center.removedPendingIdentifiers()
        let removedDeliveredIdentifiers = await center.removedDeliveredIdentifiers()
        XCTAssertEqual(
            removedPendingIdentifiers,
            [
                DueDateNotificationService.identifier(forTaskID: "task1", listID: "list1"),
                DueDateNotificationService.identifier(forTaskID: "task2", listID: "list1"),
            ]
        )
        XCTAssertEqual(
            removedDeliveredIdentifiers,
            [
                DueDateNotificationService.identifier(forTaskID: "task1", listID: "list1"),
                DueDateNotificationService.identifier(forTaskID: "task2", listID: "list1"),
            ]
        )
    }

    private func makeDefaults(function: String = #function) -> UserDefaults {
        let suiteName = "DueDateNotificationServiceTests.\(function).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeTask(
        id: String,
        title: String,
        due: String?,
        status: TaskItem.TaskStatus = .needsAction
    ) -> TaskItem {
        TaskItem(
            id: id,
            title: title,
            notes: nil,
            status: status,
            due: due,
            selfLink: nil,
            parent: nil,
            position: nil,
            updated: nil
        )
    }
}

private actor TestUserNotificationCenterClient: UserNotificationCenterClientProtocol {
    private let fixedAuthorizationStatus: NotificationAuthorizationStatus
    private let requestAuthorizationResultValue: Bool
    private var pendingIdentifiersStorage: [String]
    private var deliveredIdentifiersStorage: [String]
    private var addedRequestsStorage: [DueDateNotificationRequestData] = []
    private var removedPendingIdentifiersStorage: [String] = []
    private var removedDeliveredIdentifiersStorage: [String] = []
    private var requestAuthorizationCallCountStorage = 0

    init(
        authorizationStatus: NotificationAuthorizationStatus,
        requestAuthorizationResult: Bool = true,
        pendingIdentifiers: [String] = [],
        deliveredIdentifiers: [String] = []
    ) {
        self.fixedAuthorizationStatus = authorizationStatus
        self.requestAuthorizationResultValue = requestAuthorizationResult
        self.pendingIdentifiersStorage = pendingIdentifiers
        self.deliveredIdentifiersStorage = deliveredIdentifiers
    }

    func authorizationStatus() async -> NotificationAuthorizationStatus {
        fixedAuthorizationStatus
    }

    func requestAuthorization() async throws -> Bool {
        requestAuthorizationCallCountStorage += 1
        return requestAuthorizationResultValue
    }

    func pendingNotificationRequestIdentifiers() async -> [String] {
        pendingIdentifiersStorage
    }

    func deliveredNotificationIdentifiers() async -> [String] {
        deliveredIdentifiersStorage
    }

    func add(_ request: DueDateNotificationRequestData) async throws {
        addedRequestsStorage.append(request)
        pendingIdentifiersStorage.removeAll { $0 == request.identifier }
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) async {
        removedPendingIdentifiersStorage.append(contentsOf: identifiers)
        pendingIdentifiersStorage.removeAll { identifiers.contains($0) }
    }

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) async {
        removedDeliveredIdentifiersStorage.append(contentsOf: identifiers)
        deliveredIdentifiersStorage.removeAll { identifiers.contains($0) }
    }

    func removeAllPendingNotificationRequests() async {
        pendingIdentifiersStorage.removeAll()
    }

    func removeAllDeliveredNotifications() async {
        deliveredIdentifiersStorage.removeAll()
    }

    func addedRequests() -> [DueDateNotificationRequestData] {
        addedRequestsStorage
    }

    func removedPendingIdentifiers() -> [String] {
        removedPendingIdentifiersStorage
    }

    func removedDeliveredIdentifiers() -> [String] {
        removedDeliveredIdentifiersStorage
    }

    func requestAuthorizationCallCount() -> Int {
        requestAuthorizationCallCountStorage
    }
}
