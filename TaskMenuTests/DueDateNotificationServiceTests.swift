import XCTest
@testable import TaskMenu

final class DueDateNotificationServiceTests: XCTestCase {
    func testSyncSchedulesFutureDueTaskAtNineAM() async {
        let center = TestUserNotificationCenterClient(authorizationStatus: .authorized)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = DateFormatting.parseRFC3339("2026-03-10T08:00:00.000Z")!
        let service = DueDateNotificationService(center: center, calendar: calendar, now: { now }, defaults: makeDefaults())
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
        let service = DueDateNotificationService(center: center, calendar: calendar, now: { now }, defaults: makeDefaults())
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
        let service = DueDateNotificationService(center: center, calendar: calendar, now: { now }, defaults: makeDefaults())
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
        let service = DueDateNotificationService(center: center, calendar: calendar, now: { now }, defaults: makeDefaults())
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
        let service = DueDateNotificationService(center: center, calendar: calendar, now: { now }, defaults: makeDefaults())
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
            pendingRequests: [
                PendingNotificationRequestData(identifier: staleIdentifier, trigger: .timeInterval(1)),
                PendingNotificationRequestData(identifier: otherListIdentifier, trigger: .timeInterval(1)),
            ],
            deliveredIdentifiers: [staleIdentifier, otherListIdentifier]
        )
        let service = DueDateNotificationService(center: center, defaults: makeDefaults())
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
        let service = DueDateNotificationService(center: center, calendar: calendar, now: { now }, defaults: makeDefaults())
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

    func testSyncSuppressesImmediateDuplicateAfterCalendarTriggerScheduledForToday() async {
        let defaults = makeDefaults()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let list = TaskList(id: "list1", title: "Inbox", selfLink: nil, updated: nil)
        let task = makeTask(id: "task1", title: "Pay rent", due: "2026-03-10T00:00:00.000Z")

        // Pre-9AM sync schedules a calendar trigger for today's 9 AM.
        let earlyNow = DateFormatting.parseRFC3339("2026-03-10T08:55:00.000Z")!
        let firstCenter = TestUserNotificationCenterClient(authorizationStatus: .authorized)
        let firstService = DueDateNotificationService(center: firstCenter, calendar: calendar, now: { earlyNow }, defaults: defaults)
        await firstService.syncNotifications(for: [task], in: list)
        let firstAdded = await firstCenter.addedRequests()
        XCTAssertEqual(firstAdded.count, 1)
        XCTAssertEqual(
            firstAdded[0].trigger,
            .calendar(DateComponents(calendar: calendar, timeZone: calendar.timeZone, year: 2026, month: 3, day: 10, hour: 9, minute: 0, second: 0))
        )

        // Post-9AM sync after the user dismissed the delivered notification
        // (empty delivered list) must not fire a second "Due today".
        let laterNow = DateFormatting.parseRFC3339("2026-03-10T10:00:00.000Z")!
        let secondCenter = TestUserNotificationCenterClient(authorizationStatus: .authorized)
        let secondService = DueDateNotificationService(center: secondCenter, calendar: calendar, now: { laterNow }, defaults: defaults)
        await secondService.syncNotifications(for: [task], in: list)
        let secondAdded = await secondCenter.addedRequests()
        XCTAssertTrue(secondAdded.isEmpty)
    }

    func testSyncSuppressesImmediateDuplicateAfterTriggerScheduledDayBefore() async {
        let defaults = makeDefaults()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let list = TaskList(id: "list1", title: "Inbox", selfLink: nil, updated: nil)
        let task = makeTask(id: "task1", title: "Pay rent", due: "2026-03-10T00:00:00.000Z")

        // The day before the due day, sync schedules the 9 AM calendar
        // trigger for the due day.
        let dayBefore = DateFormatting.parseRFC3339("2026-03-09T15:00:00.000Z")!
        let firstCenter = TestUserNotificationCenterClient(authorizationStatus: .authorized)
        let firstService = DueDateNotificationService(center: firstCenter, calendar: calendar, now: { dayBefore }, defaults: defaults)
        await firstService.syncNotifications(for: [task], in: list)
        let firstAdded = await firstCenter.addedRequests()
        XCTAssertEqual(firstAdded.count, 1)
        XCTAssertEqual(
            firstAdded[0].trigger,
            .calendar(DateComponents(calendar: calendar, timeZone: calendar.timeZone, year: 2026, month: 3, day: 10, hour: 9, minute: 0, second: 0))
        )

        // On the due day after 9 AM the trigger fired with no app
        // involvement and the user dismissed the banner (pending and
        // delivered both empty); the sync must not fire a second reminder.
        let dueDay = DateFormatting.parseRFC3339("2026-03-10T10:00:00.000Z")!
        let secondCenter = TestUserNotificationCenterClient(authorizationStatus: .authorized)
        let secondService = DueDateNotificationService(center: secondCenter, calendar: calendar, now: { dueDay }, defaults: defaults)
        await secondService.syncNotifications(for: [task], in: list)
        let secondAdded = await secondCenter.addedRequests()
        XCTAssertTrue(secondAdded.isEmpty)
    }

    func testSyncReschedulesTodayTriggerAfterDueDateFlipsTomorrowAndBack() async {
        let center = TestUserNotificationCenterClient(authorizationStatus: .authorized)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = DateFormatting.parseRFC3339("2026-03-10T08:00:00.000Z")!
        let service = DueDateNotificationService(center: center, calendar: calendar, now: { now }, defaults: makeDefaults())
        let list = TaskList(id: "list1", title: "Inbox", selfLink: nil, updated: nil)
        let todayTrigger = DueDateNotificationTrigger.calendar(
            DateComponents(calendar: calendar, timeZone: calendar.timeZone, year: 2026, month: 3, day: 10, hour: 9, minute: 0, second: 0)
        )

        // Pre-9AM: due today, then moved to tomorrow, then moved back to
        // today. Each due-day change must re-add so the pending request
        // ends up holding today's trigger, not the stale tomorrow one.
        await service.syncNotifications(for: [makeTask(id: "task1", title: "Pay rent", due: "2026-03-10T00:00:00.000Z")], in: list)
        await service.syncNotifications(for: [makeTask(id: "task1", title: "Pay rent", due: "2026-03-11T00:00:00.000Z")], in: list)
        await service.syncNotifications(for: [makeTask(id: "task1", title: "Pay rent", due: "2026-03-10T00:00:00.000Z")], in: list)

        let addedRequests = await center.addedRequests()
        XCTAssertEqual(addedRequests.count, 3)
        XCTAssertEqual(addedRequests[2].trigger, todayTrigger)
        let pendingRequests = await center.pendingRequests()
        XCTAssertEqual(
            pendingRequests,
            [
                PendingNotificationRequestData(
                    identifier: DueDateNotificationService.identifier(forTaskID: "task1", listID: "list1"),
                    trigger: todayTrigger
                ),
            ]
        )
    }

    func testSyncKeepsDeliveredNotificationForIncompleteOverdueTask() async {
        let overdueIdentifier = DueDateNotificationService.identifier(forTaskID: "task1", listID: "list1")
        let completedIdentifier = DueDateNotificationService.identifier(forTaskID: "task2", listID: "list1")
        let center = TestUserNotificationCenterClient(
            authorizationStatus: .authorized,
            deliveredIdentifiers: [overdueIdentifier, completedIdentifier]
        )
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = DateFormatting.parseRFC3339("2026-03-11T10:00:00.000Z")!
        let service = DueDateNotificationService(center: center, calendar: calendar, now: { now }, defaults: makeDefaults())
        let list = TaskList(id: "list1", title: "Inbox", selfLink: nil, updated: nil)
        let overdueTask = makeTask(id: "task1", title: "Pay rent", due: "2026-03-10T00:00:00.000Z")
        let completedTask = makeTask(id: "task2", title: "File taxes", due: "2026-03-10T00:00:00.000Z", status: .completed)

        await service.syncNotifications(for: [overdueTask, completedTask], in: list)

        // The overdue-but-incomplete task keeps its delivered reminder; only
        // the completed task's delivered notification is cleared.
        let removedDeliveredIdentifiers = await center.removedDeliveredIdentifiers()
        XCTAssertEqual(removedDeliveredIdentifiers, [completedIdentifier])
        let addedRequests = await center.addedRequests()
        XCTAssertTrue(addedRequests.isEmpty)
    }

    func testSyncCapsScheduledRequestsToSoonestFireDates() async {
        let center = TestUserNotificationCenterClient(authorizationStatus: .authorized)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = DateFormatting.parseRFC3339("2026-03-01T08:00:00.000Z")!
        let service = DueDateNotificationService(center: center, calendar: calendar, now: { now }, defaults: makeDefaults())
        let list = TaskList(id: "list1", title: "Inbox", selfLink: nil, updated: nil)

        // 65 future-due tasks, one per day starting tomorrow; shuffled so the
        // cap must sort by fire date rather than input order.
        let tasks = (1...65).map { offset in
            makeTask(
                id: "task\(offset)",
                title: "Task \(offset)",
                due: dueString(daysAfter: now, days: offset, calendar: calendar)
            )
        }

        await service.syncNotifications(for: tasks.shuffled(), in: list)

        let addedRequests = await center.addedRequests()
        XCTAssertEqual(addedRequests.count, DueDateNotificationService.maxScheduledRequestCount)
        let addedIdentifiers = Set(addedRequests.map(\.identifier))
        let expectedIdentifiers = Set(
            (1...DueDateNotificationService.maxScheduledRequestCount).map {
                DueDateNotificationService.identifier(forTaskID: "task\($0)", listID: "list1")
            }
        )
        XCTAssertEqual(addedIdentifiers, expectedIdentifiers)
    }

    func testSyncCapsScheduledRequestsGloballyAcrossLists() async {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = DateFormatting.parseRFC3339("2026-03-01T08:00:00.000Z")!

        // Another list already holds pending requests firing on odd day
        // offsets 1, 3, ..., 79; this list wants even offsets 2, 4, ..., 80.
        let otherListPendingRequests = stride(from: 1, through: 79, by: 2).map { offset in
            PendingNotificationRequestData(
                identifier: DueDateNotificationService.identifier(forTaskID: "other\(offset)", listID: "list2"),
                trigger: calendarTrigger(daysAfter: now, days: offset, calendar: calendar)
            )
        }
        let center = TestUserNotificationCenterClient(
            authorizationStatus: .authorized,
            pendingRequests: otherListPendingRequests
        )
        let service = DueDateNotificationService(center: center, calendar: calendar, now: { now }, defaults: makeDefaults())
        let list = TaskList(id: "list1", title: "Inbox", selfLink: nil, updated: nil)
        let tasks = stride(from: 2, through: 80, by: 2).map { offset in
            makeTask(
                id: "task\(offset)",
                title: "Task \(offset)",
                due: dueString(daysAfter: now, days: offset, calendar: calendar)
            )
        }

        await service.syncNotifications(for: tasks.shuffled(), in: list)

        // The soonest 60 fire dates are day offsets 1...60: 30 adds from
        // this list and 30 kept pending from the other list. The other
        // list's furthest requests (offsets 61...79) are evicted.
        let addedIdentifiers = Set(await center.addedRequests().map(\.identifier))
        let expectedAddedIdentifiers = Set(
            stride(from: 2, through: 60, by: 2).map {
                DueDateNotificationService.identifier(forTaskID: "task\($0)", listID: "list1")
            }
        )
        XCTAssertEqual(addedIdentifiers, expectedAddedIdentifiers)
        let removedPendingIdentifiers = Set(await center.removedPendingIdentifiers())
        let expectedEvictedIdentifiers = Set(
            stride(from: 61, through: 79, by: 2).map {
                DueDateNotificationService.identifier(forTaskID: "other\($0)", listID: "list2")
            }
        )
        XCTAssertEqual(removedPendingIdentifiers, expectedEvictedIdentifiers)
        let pendingCount = await center.pendingRequests().count
        XCTAssertEqual(pendingCount, DueDateNotificationService.maxScheduledRequestCount)
    }

    func testSyncEvictedAddWithStalePendingRequestStaysUnderCap() async {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = DateFormatting.parseRFC3339("2026-03-01T08:00:00.000Z")!
        let center = TestUserNotificationCenterClient(authorizationStatus: .authorized)
        let defaults = makeDefaults()
        let service = DueDateNotificationService(center: center, calendar: calendar, now: { now }, defaults: defaults)
        let list = TaskList(id: "list1", title: "Inbox", selfLink: nil, updated: nil)
        let movedTask = makeTask(id: "moved", title: "Moved", due: dueString(daysAfter: now, days: 5, calendar: calendar))

        // First sync leaves a pending request and record entry for day 5.
        await service.syncNotifications(for: [movedTask], in: list)

        // Second sync moves the task past the cap horizon while 60 sooner
        // tasks fill every slot: the evicted add's old day-5 pending request
        // must be removed, not left lingering beyond the cap.
        let rescheduledTask = makeTask(id: "moved", title: "Moved", due: dueString(daysAfter: now, days: 100, calendar: calendar))
        let soonerTasks = (1...60).map { offset in
            makeTask(id: "task\(offset)", title: "Task \(offset)", due: dueString(daysAfter: now, days: offset, calendar: calendar))
        }
        await service.syncNotifications(for: soonerTasks + [rescheduledTask], in: list)

        let pending = await center.pendingRequests()
        XCTAssertEqual(pending.count, DueDateNotificationService.maxScheduledRequestCount)
        let movedIdentifier = DueDateNotificationService.identifier(forTaskID: "moved", listID: "list1")
        XCTAssertFalse(pending.map(\.identifier).contains(movedIdentifier))
    }

    func testSyncReschedulesReminderWhenTaskCompletedAndRevertedSameDay() async {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = DateFormatting.parseRFC3339("2026-03-01T08:00:00.000Z")!
        let center = TestUserNotificationCenterClient(authorizationStatus: .authorized)
        let defaults = makeDefaults()
        let service = DueDateNotificationService(center: center, calendar: calendar, now: { now }, defaults: defaults)
        let list = TaskList(id: "list1", title: "Inbox", selfLink: nil, updated: nil)
        let dueToday = dueString(daysAfter: now, days: 0, calendar: calendar)

        // Schedule, then complete (pending removed), then revert the same
        // day: the reminder must come back rather than being suppressed by
        // a record entry that outlived its notification.
        await service.syncNotifications(for: [makeTask(id: "task1", title: "Task", due: dueToday)], in: list)
        await service.syncNotifications(for: [makeTask(id: "task1", title: "Task", due: dueToday, status: .completed)], in: list)
        let pendingAfterCompletion = await center.pendingRequests()
        XCTAssertTrue(pendingAfterCompletion.isEmpty)

        await service.syncNotifications(for: [makeTask(id: "task1", title: "Task", due: dueToday)], in: list)
        let pending = await center.pendingRequests()
        XCTAssertEqual(
            pending.map(\.identifier),
            [DueDateNotificationService.identifier(forTaskID: "task1", listID: "list1")]
        )
    }

    func testSyncDeliveredDedupDoesNotConsumeCapSlot() async {
        let deliveredIdentifier = DueDateNotificationService.identifier(forTaskID: "today", listID: "list1")
        let center = TestUserNotificationCenterClient(
            authorizationStatus: .authorized,
            deliveredIdentifiers: [deliveredIdentifier]
        )
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = DateFormatting.parseRFC3339("2026-03-01T12:00:00.000Z")!
        let service = DueDateNotificationService(center: center, calendar: calendar, now: { now }, defaults: makeDefaults())
        let list = TaskList(id: "list1", title: "Inbox", selfLink: nil, updated: nil)

        // A due-today task whose reminder was already delivered plus 60
        // future tasks: the delivered one must be skipped before the cap
        // so all 60 future reminders get scheduled.
        let todayTask = makeTask(id: "today", title: "Due today", due: dueString(daysAfter: now, days: 0, calendar: calendar))
        let futureTasks = (1...DueDateNotificationService.maxScheduledRequestCount).map { offset in
            makeTask(
                id: "task\(offset)",
                title: "Task \(offset)",
                due: dueString(daysAfter: now, days: offset, calendar: calendar)
            )
        }

        await service.syncNotifications(for: [todayTask] + futureTasks, in: list)

        let addedIdentifiers = Set(await center.addedRequests().map(\.identifier))
        let expectedIdentifiers = Set(
            (1...DueDateNotificationService.maxScheduledRequestCount).map {
                DueDateNotificationService.identifier(forTaskID: "task\($0)", listID: "list1")
            }
        )
        XCTAssertEqual(addedIdentifiers, expectedIdentifiers)
    }

    func testSyncRecordDedupDoesNotConsumeCapSlot() async {
        let defaults = makeDefaults()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = DateFormatting.parseRFC3339("2026-03-01T12:00:00.000Z")!
        let list = TaskList(id: "list1", title: "Inbox", selfLink: nil, updated: nil)
        let todayTask = makeTask(id: "today", title: "Due today", due: dueString(daysAfter: now, days: 0, calendar: calendar))

        // First sync schedules the immediate due-today reminder and records it.
        let firstCenter = TestUserNotificationCenterClient(authorizationStatus: .authorized)
        let firstService = DueDateNotificationService(center: firstCenter, calendar: calendar, now: { now }, defaults: defaults)
        await firstService.syncNotifications(for: [todayTask], in: list)
        let firstAdded = await firstCenter.addedRequests()
        XCTAssertEqual(firstAdded.count, 1)

        // A later same-day sync (reminder fired and was dismissed) with 60
        // future tasks: the record-deduped task must not occupy a cap slot.
        let futureTasks = (1...DueDateNotificationService.maxScheduledRequestCount).map { offset in
            makeTask(
                id: "task\(offset)",
                title: "Task \(offset)",
                due: dueString(daysAfter: now, days: offset, calendar: calendar)
            )
        }
        let secondCenter = TestUserNotificationCenterClient(authorizationStatus: .authorized)
        let secondService = DueDateNotificationService(center: secondCenter, calendar: calendar, now: { now }, defaults: defaults)
        await secondService.syncNotifications(for: [todayTask] + futureTasks, in: list)

        let addedIdentifiers = Set(await secondCenter.addedRequests().map(\.identifier))
        let expectedIdentifiers = Set(
            (1...DueDateNotificationService.maxScheduledRequestCount).map {
                DueDateNotificationService.identifier(forTaskID: "task\($0)", listID: "list1")
            }
        )
        XCTAssertEqual(addedIdentifiers, expectedIdentifiers)
    }

    func testRemoveDuringInFlightSyncIsNotOverwrittenByRecordSave() async {
        let defaults = makeDefaults()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = DateFormatting.parseRFC3339("2026-03-10T12:00:00.000Z")!
        let list = TaskList(id: "list1", title: "Inbox", selfLink: nil, updated: nil)
        let task = makeTask(id: "task1", title: "Pay rent", due: "2026-03-10T00:00:00.000Z")

        let gatedCenter = GatedUserNotificationCenterClient()
        let service = DueDateNotificationService(center: gatedCenter, calendar: calendar, now: { now }, defaults: defaults)

        let syncTask = Task {
            await service.syncNotifications(for: [task], in: list)
        }
        await gatedCenter.waitForAddStarted()

        // A removal racing the in-flight sync must not have its record
        // cleanup overwritten by the sync's final record save.
        let removeTask = Task {
            await service.removeNotifications(forTaskIDs: ["task1"], inListID: "list1")
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        await gatedCenter.releaseAdds()
        await syncTask.value
        await removeTask.value

        // The record entry must be gone, so a same-day sync re-adds the
        // immediate reminder instead of treating it as already scheduled.
        let verifyCenter = TestUserNotificationCenterClient(authorizationStatus: .authorized)
        let verifyService = DueDateNotificationService(center: verifyCenter, calendar: calendar, now: { now }, defaults: defaults)
        await verifyService.syncNotifications(for: [task], in: list)
        let verifyAdded = await verifyCenter.addedRequests()
        XCTAssertEqual(verifyAdded.count, 1)
        XCTAssertEqual(verifyAdded[0].trigger, .timeInterval(1))
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
        let service = DueDateNotificationService(center: center, defaults: makeDefaults())

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

    private func dueString(daysAfter date: Date, days: Int, calendar: Calendar) -> String {
        let dayDate = calendar.date(byAdding: .day, value: days, to: date) ?? date
        let components = calendar.dateComponents([.year, .month, .day], from: dayDate)
        return String(
            format: "%04d-%02d-%02dT00:00:00.000Z",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    private func calendarTrigger(daysAfter date: Date, days: Int, calendar: Calendar) -> DueDateNotificationTrigger {
        let dayDate = calendar.date(byAdding: .day, value: days, to: date) ?? date
        let components = calendar.dateComponents([.year, .month, .day], from: dayDate)
        return .calendar(
            DateComponents(
                calendar: calendar,
                timeZone: calendar.timeZone,
                year: components.year,
                month: components.month,
                day: components.day,
                hour: 9,
                minute: 0,
                second: 0
            )
        )
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

// Blocks add(_:) until releaseAdds() so tests can hold a sync mid-flight and
// race other service calls against it.
private actor GatedUserNotificationCenterClient: UserNotificationCenterClientProtocol {
    private var addStartedCount = 0
    private var addStartedContinuations: [CheckedContinuation<Void, Never>] = []
    private var addGateContinuations: [CheckedContinuation<Void, Never>] = []
    private var released = false

    func authorizationStatus() async -> NotificationAuthorizationStatus {
        .authorized
    }

    func requestAuthorization() async throws -> Bool {
        true
    }

    func pendingNotificationRequests() async -> [PendingNotificationRequestData] {
        []
    }

    func deliveredNotificationIdentifiers() async -> [String] {
        []
    }

    func add(_ request: DueDateNotificationRequestData) async throws {
        addStartedCount += 1
        let startWaiters = addStartedContinuations
        addStartedContinuations = []
        for waiter in startWaiters {
            waiter.resume()
        }

        guard !released else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            addGateContinuations.append(continuation)
        }
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) async {}

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) async {}

    func removeAllPendingNotificationRequests() async {}

    func removeAllDeliveredNotifications() async {}

    func waitForAddStarted() async {
        guard addStartedCount == 0 else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            addStartedContinuations.append(continuation)
        }
    }

    func releaseAdds() {
        released = true
        let gateWaiters = addGateContinuations
        addGateContinuations = []
        for waiter in gateWaiters {
            waiter.resume()
        }
    }
}

private actor TestUserNotificationCenterClient: UserNotificationCenterClientProtocol {
    private let fixedAuthorizationStatus: NotificationAuthorizationStatus
    private let requestAuthorizationResultValue: Bool
    private var pendingRequestsStorage: [PendingNotificationRequestData]
    private var deliveredIdentifiersStorage: [String]
    private var addedRequestsStorage: [DueDateNotificationRequestData] = []
    private var removedPendingIdentifiersStorage: [String] = []
    private var removedDeliveredIdentifiersStorage: [String] = []
    private var requestAuthorizationCallCountStorage = 0

    init(
        authorizationStatus: NotificationAuthorizationStatus,
        requestAuthorizationResult: Bool = true,
        pendingRequests: [PendingNotificationRequestData] = [],
        deliveredIdentifiers: [String] = []
    ) {
        self.fixedAuthorizationStatus = authorizationStatus
        self.requestAuthorizationResultValue = requestAuthorizationResult
        self.pendingRequestsStorage = pendingRequests
        self.deliveredIdentifiersStorage = deliveredIdentifiers
    }

    func authorizationStatus() async -> NotificationAuthorizationStatus {
        fixedAuthorizationStatus
    }

    func requestAuthorization() async throws -> Bool {
        requestAuthorizationCallCountStorage += 1
        return requestAuthorizationResultValue
    }

    func pendingNotificationRequests() async -> [PendingNotificationRequestData] {
        pendingRequestsStorage
    }

    func deliveredNotificationIdentifiers() async -> [String] {
        deliveredIdentifiersStorage
    }

    func add(_ request: DueDateNotificationRequestData) async throws {
        addedRequestsStorage.append(request)
        // Adding with an existing identifier replaces the pending request,
        // matching UNUserNotificationCenter behavior.
        pendingRequestsStorage.removeAll { $0.identifier == request.identifier }
        pendingRequestsStorage.append(
            PendingNotificationRequestData(identifier: request.identifier, trigger: request.trigger)
        )
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) async {
        removedPendingIdentifiersStorage.append(contentsOf: identifiers)
        pendingRequestsStorage.removeAll { identifiers.contains($0.identifier) }
    }

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) async {
        removedDeliveredIdentifiersStorage.append(contentsOf: identifiers)
        deliveredIdentifiersStorage.removeAll { identifiers.contains($0) }
    }

    func removeAllPendingNotificationRequests() async {
        pendingRequestsStorage.removeAll()
    }

    func removeAllDeliveredNotifications() async {
        deliveredIdentifiersStorage.removeAll()
    }

    func addedRequests() -> [DueDateNotificationRequestData] {
        addedRequestsStorage
    }

    func pendingRequests() -> [PendingNotificationRequestData] {
        pendingRequestsStorage
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
