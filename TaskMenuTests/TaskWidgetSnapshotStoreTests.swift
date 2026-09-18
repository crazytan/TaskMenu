import XCTest
@testable import TaskMenu

/// Covers `TaskWidgetSnapshotStore`'s coordinated read/write contract. Every
/// test points at a fresh temporary directory — never the real App Group —
/// per `TaskMenu/WidgetSupport/README.md`'s testing rule.
final class TaskWidgetSnapshotStoreTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TaskWidgetSnapshotStoreTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
        super.tearDown()
    }

    private func makeStore() -> TaskWidgetSnapshotStore {
        TaskWidgetSnapshotStore(directoryURL: tempDirectory)
    }

    private var snapshotFileURL: URL {
        tempDirectory.appendingPathComponent(TaskWidgetConstants.snapshotFileName)
    }

    // MARK: Missing / corrupt / future-schema files

    func testMissingFileReturnsEmptySignedOutSnapshot() {
        let snapshot = makeStore().read()

        XCTAssertTrue(snapshot.lists.isEmpty)
        XCTAssertEqual(snapshot.authentication, .signedOut)
        XCTAssertNil(snapshot.defaultListID)
        XCTAssertEqual(snapshot.schemaVersion, TaskWidgetConstants.currentSchemaVersion)
    }

    func testCorruptJSONFallsBackToEmptySnapshot() throws {
        try Data("{ this is not valid json".utf8).write(to: snapshotFileURL)

        let snapshot = makeStore().read()

        XCTAssertTrue(snapshot.lists.isEmpty)
        XCTAssertEqual(snapshot.authentication, .signedOut)
    }

    func testUnsupportedFutureSchemaVersionFallsBackToEmptySnapshot() throws {
        let store = makeStore()
        try store.replaceList(TaskWidgetListSnapshot(id: "list-1", title: "Real Data"), requestStartedAt: Date())

        // Bump the on-disk schema version past what this build understands,
        // simulating a newer TaskMenu version writing a shape this one
        // cannot safely decode.
        var raw = try String(contentsOf: snapshotFileURL, encoding: .utf8)
        raw = raw.replacingOccurrences(
            of: "\"schemaVersion\":\(TaskWidgetConstants.currentSchemaVersion)",
            with: "\"schemaVersion\":\(TaskWidgetConstants.currentSchemaVersion + 1)"
        )
        try Data(raw.utf8).write(to: snapshotFileURL)

        let snapshot = store.read()

        XCTAssertTrue(snapshot.lists.isEmpty, "a future schema version must fail closed, not decode partially")
        XCTAssertEqual(snapshot.authentication, .signedOut)
    }

    // MARK: Atomic replacement

    func testAtomicWriteLeavesOnlyTheFinalFileOnDisk() throws {
        let store = makeStore()

        try store.write(.empty())
        try store.replaceList(TaskWidgetListSnapshot(id: "list-1", title: "List"), requestStartedAt: Date())
        try store.setAuthentication(.signedIn)

        let entries = try FileManager.default.contentsOfDirectory(at: tempDirectory, includingPropertiesForKeys: nil)
        XCTAssertEqual(entries.map(\.lastPathComponent), [TaskWidgetConstants.snapshotFileName], "no stray temp file should remain after an atomic write")

        // Every write must also leave the file fully valid and readable.
        let snapshot = store.read()
        XCTAssertEqual(snapshot.lists.map(\.id), ["list-1"])
        XCTAssertEqual(snapshot.authentication, .signedIn)
    }

    // MARK: Concurrent writers

    func testConcurrentAppAndExtensionStyleWritersBothPersist() {
        // Two independent store instances over the same directory model the
        // app process and the widget extension process writing at once.
        let appStore = makeStore()
        let extensionStore = makeStore()

        let appDone = expectation(description: "app-style writer finished")
        let extensionDone = expectation(description: "extension-style writer finished")

        DispatchQueue.global().async {
            for index in 0..<10 {
                _ = try? appStore.replaceList(TaskWidgetListSnapshot(id: "app-list", title: "App \(index)"), requestStartedAt: Date())
            }
            appDone.fulfill()
        }
        DispatchQueue.global().async {
            for index in 0..<10 {
                _ = try? extensionStore.replaceList(TaskWidgetListSnapshot(id: "widget-list", title: "Widget \(index)"), requestStartedAt: Date())
            }
            extensionDone.fulfill()
        }

        wait(for: [appDone, extensionDone], timeout: 10)

        let finalSnapshot = appStore.read()
        XCTAssertEqual(Set(finalSnapshot.lists.map(\.id)), ["app-list", "widget-list"])
    }

    // MARK: Stale-write protection

    func testStaleReplacementRejectedWhenStoredListStartedLater() throws {
        let store = makeStore()
        let widgetCompletionRequestStart = Date()
        let appRefreshRequestStart = widgetCompletionRequestStart.addingTimeInterval(-30) // began earlier

        // The widget completion's follow-up refetch started later and
        // finishes first, publishing its (newer) result.
        var widgetResult = TaskWidgetListSnapshot(id: "list-1", title: "List", tasks: [])
        widgetResult.refreshedAt = widgetCompletionRequestStart.addingTimeInterval(1)
        widgetResult.refreshStartedAt = widgetCompletionRequestStart
        XCTAssertTrue(try store.replaceList(widgetResult, requestStartedAt: widgetCompletionRequestStart))

        // An app-wide refresh that had already started before the widget
        // completion finishes afterward with a stale (older) result. It
        // must be rejected even though it "finishes" after the accepted write.
        var staleAppResult = TaskWidgetListSnapshot(id: "list-1", title: "Stale App Result", tasks: [])
        staleAppResult.refreshedAt = widgetCompletionRequestStart.addingTimeInterval(5)
        let accepted = try store.replaceList(staleAppResult, requestStartedAt: appRefreshRequestStart)

        XCTAssertFalse(accepted)
        XCTAssertEqual(store.read().lists.first(where: { $0.id == "list-1" })?.title, "List")
    }

    func testNewerReplacementAcceptedWhenRequestStartedAfterStoredRefresh() throws {
        let store = makeStore()
        let firstStart = Date()
        var first = TaskWidgetListSnapshot(id: "list-1", title: "First")
        first.refreshedAt = firstStart
        XCTAssertTrue(try store.replaceList(first, requestStartedAt: firstStart))

        let secondStart = firstStart.addingTimeInterval(60)
        var second = TaskWidgetListSnapshot(id: "list-1", title: "Second")
        second.refreshedAt = secondStart
        XCTAssertTrue(try store.replaceList(second, requestStartedAt: secondStart))

        XCTAssertEqual(store.read().lists.first?.title, "Second")
    }

    // MARK: Sub-second timestamp precision
    //
    // Regression coverage for a defect where the store's date encoding
    // (`.iso8601`, whose default formatter truncates to whole seconds)
    // silently weakened stale-write protection: two writes less than a
    // second apart could compare as equal and let the older one win. Both
    // tests below fail under that old whole-second-only encoding.

    func testTimestampRoundTripsWithSubSecondPrecisionIntact() throws {
        let store = makeStore()
        let preciseTimestamp = Date(timeIntervalSince1970: 1_763_000_000.123456)
        var list = TaskWidgetListSnapshot(id: "list-1", title: "List")
        list.refreshedAt = preciseTimestamp
        try store.write(TaskWidgetSnapshot(
            generatedAt: preciseTimestamp,
            authentication: .signedOut,
            defaultListID: nil,
            lists: [list]
        ))

        let readBack = store.read()
        let readTimestamp = try XCTUnwrap(readBack.lists.first?.refreshedAt)

        XCTAssertEqual(readTimestamp.timeIntervalSince1970, preciseTimestamp.timeIntervalSince1970, accuracy: 0.0001)
        XCTAssertEqual(readBack.generatedAt.timeIntervalSince1970, preciseTimestamp.timeIntervalSince1970, accuracy: 0.0001)
    }

    func testStaleReplacementRejectedWhenRequestStartedOnlyMillisecondsEarlier() throws {
        let store = makeStore()
        let storedRefreshedAt = Date()
        var stored = TaskWidgetListSnapshot(id: "list-1", title: "Newer")
        stored.refreshedAt = storedRefreshedAt
        XCTAssertTrue(try store.replaceList(stored, requestStartedAt: storedRefreshedAt))

        // A request that began only 50ms before the stored refresh must
        // still be rejected as stale — sub-second gaps between the app and
        // widget extension racing the network are the normal case, not an
        // edge case.
        let staleRequestStartedAt = storedRefreshedAt.addingTimeInterval(-0.05)
        var stale = TaskWidgetListSnapshot(id: "list-1", title: "Stale")
        stale.refreshedAt = storedRefreshedAt.addingTimeInterval(0.02)
        let accepted = try store.replaceList(stale, requestStartedAt: staleRequestStartedAt)

        XCTAssertFalse(accepted, "a request that started milliseconds before the stored refresh must be rejected")
        XCTAssertEqual(store.read().lists.first?.title, "Newer")
    }

    // MARK: Unrelated-list preservation / deleted-list removal

    func testReplaceListPreservesUnrelatedLists() throws {
        let store = makeStore()
        try store.replaceList(TaskWidgetListSnapshot(id: "list-1", title: "One"), requestStartedAt: Date())
        try store.replaceList(TaskWidgetListSnapshot(id: "list-2", title: "Two"), requestStartedAt: Date())

        try store.replaceList(TaskWidgetListSnapshot(id: "list-1", title: "One Updated"), requestStartedAt: Date())

        let snapshot = store.read()
        XCTAssertEqual(snapshot.lists.first(where: { $0.id == "list-1" })?.title, "One Updated")
        XCTAssertEqual(snapshot.lists.first(where: { $0.id == "list-2" })?.title, "Two")
    }

    func testPruneListsRemovesListsNotInValidSet() throws {
        let store = makeStore()
        try store.replaceList(TaskWidgetListSnapshot(id: "list-1", title: "Keep"), requestStartedAt: Date())
        try store.replaceList(TaskWidgetListSnapshot(id: "list-2", title: "Deleted On Google"), requestStartedAt: Date())

        try store.pruneLists(keeping: ["list-1"])

        let snapshot = store.read()
        XCTAssertEqual(snapshot.lists.map(\.id), ["list-1"])
    }

    // MARK: Explicit sign-out clear

    func testClearRemovesEveryListAndSignsOut() throws {
        let store = makeStore()
        try store.replaceList(TaskWidgetListSnapshot(id: "list-1", title: "One"), requestStartedAt: Date())
        try store.setAuthentication(.signedIn)
        try store.setDefaultListID("list-1")

        try store.clear()

        let snapshot = store.read()
        XCTAssertTrue(snapshot.lists.isEmpty)
        XCTAssertEqual(snapshot.authentication, .signedOut)
        XCTAssertNil(snapshot.defaultListID)
    }

    // MARK: Privacy — never write sensitive fields

    func testSerializedJSONContainsNoSensitiveKeysOrValues() throws {
        let store = makeStore()
        let task = TaskWidgetTaskSnapshot(
            id: "task-1",
            title: "Buy milk",
            status: .needsAction,
            due: "2026-03-15T00:00:00.000Z",
            parent: nil,
            position: "1"
        )
        try store.replaceList(TaskWidgetListSnapshot(id: "list-1", title: "Groceries", tasks: [task]), requestStartedAt: Date())
        try store.setAuthentication(.signedIn)

        let raw = try String(contentsOf: snapshotFileURL, encoding: .utf8)

        // Match on the quoted-key form (`"notes":`) rather than a bare
        // substring, since a legitimate task/list title is free to contain
        // any of these words as plain text without ever being a JSON key.
        for forbiddenKey in ["notes", "email", "access_token", "refresh_token", "token_expiration", "account_profile", "token"] {
            let keyPattern = "\"\(forbiddenKey)\":"
            XCTAssertFalse(
                raw.localizedCaseInsensitiveContains(keyPattern),
                "snapshot JSON must not contain the key \(keyPattern)"
            )
        }
    }

    // MARK: Unavailable container

    func testUnavailableContainerReadsEmptyAndMutationsThrow() {
        let store = TaskWidgetSnapshotStore(directoryURL: nil)

        XCTAssertTrue(store.read().lists.isEmpty)
        XCTAssertThrowsError(try store.write(.empty())) { error in
            XCTAssertEqual(error as? TaskWidgetSnapshotStore.StoreError, .containerUnavailable)
        }
        XCTAssertThrowsError(try store.replaceList(TaskWidgetListSnapshot(id: "x", title: "x"), requestStartedAt: Date()))
    }
}
