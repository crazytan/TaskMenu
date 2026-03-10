import XCTest
@testable import TaskMenu

/// Comprehensive tests for the TaskItem model: isCompleted, TaskStatus encoding/decoding,
/// round-trip serialization, and edge cases.
final class TaskItemModelTests: XCTestCase {

    // MARK: - isCompleted Getter

    func testIsCompletedReturnsTrueForCompletedStatus() {
        let task = TaskItem(id: "t1", title: "Done", notes: nil, status: .completed, due: nil, selfLink: nil, parent: nil, position: nil, updated: nil)
        XCTAssertTrue(task.isCompleted)
    }

    func testIsCompletedReturnsFalseForNeedsActionStatus() {
        let task = TaskItem(id: "t1", title: "Todo", notes: nil, status: .needsAction, due: nil, selfLink: nil, parent: nil, position: nil, updated: nil)
        XCTAssertFalse(task.isCompleted)
    }

    // MARK: - isCompleted Setter

    func testIsCompletedSetterToTrueSetsCompleted() {
        var task = TaskItem(id: "t1", title: "Test", notes: nil, status: .needsAction, due: nil, selfLink: nil, parent: nil, position: nil, updated: nil)
        task.isCompleted = true
        XCTAssertEqual(task.status, .completed)
    }

    func testIsCompletedSetterToFalseSetsNeedsAction() {
        var task = TaskItem(id: "t1", title: "Test", notes: nil, status: .completed, due: nil, selfLink: nil, parent: nil, position: nil, updated: nil)
        task.isCompleted = false
        XCTAssertEqual(task.status, .needsAction)
    }

    func testIsCompletedToggle() {
        var task = TaskItem(id: "t1", title: "Test", notes: nil, status: .needsAction, due: nil, selfLink: nil, parent: nil, position: nil, updated: nil)
        XCTAssertFalse(task.isCompleted)

        task.isCompleted.toggle()
        XCTAssertTrue(task.isCompleted)
        XCTAssertEqual(task.status, .completed)

        task.isCompleted.toggle()
        XCTAssertFalse(task.isCompleted)
        XCTAssertEqual(task.status, .needsAction)
    }

    // MARK: - TaskStatus Encoding

    func testTaskStatusEncodesToCorrectRawValue() throws {
        let task = TaskItem(id: "t1", title: "Test", notes: nil, status: .needsAction, due: nil, selfLink: nil, parent: nil, position: nil, updated: nil)
        let data = try JSONEncoder().encode(task)
        let jsonString = String(data: data, encoding: .utf8)!
        XCTAssertTrue(jsonString.contains("\"needsAction\""))
    }

    func testCompletedStatusEncodesToCorrectRawValue() throws {
        let task = TaskItem(id: "t1", title: "Test", notes: nil, status: .completed, due: nil, selfLink: nil, parent: nil, position: nil, updated: nil)
        let data = try JSONEncoder().encode(task)
        let jsonString = String(data: data, encoding: .utf8)!
        XCTAssertTrue(jsonString.contains("\"completed\""))
    }

    // MARK: - TaskStatus Decoding

    func testTaskStatusDecodesNeedsAction() throws {
        let json = #"{"id":"t1","title":"T","status":"needsAction"}"#.data(using: .utf8)!
        let task = try JSONDecoder().decode(TaskItem.self, from: json)
        XCTAssertEqual(task.status, .needsAction)
    }

    func testTaskStatusDecodesCompleted() throws {
        let json = #"{"id":"t1","title":"T","status":"completed"}"#.data(using: .utf8)!
        let task = try JSONDecoder().decode(TaskItem.self, from: json)
        XCTAssertEqual(task.status, .completed)
    }

    func testTaskStatusDecodingFailsForInvalidValue() {
        let json = #"{"id":"t1","title":"T","status":"invalid"}"#.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(TaskItem.self, from: json))
    }

    // MARK: - Round-Trip Encoding/Decoding

    func testRoundTripPreservesAllFields() throws {
        let original = TaskItem(
            id: "t1",
            title: "Buy groceries",
            notes: "Milk, eggs",
            status: .needsAction,
            due: "2026-06-15T00:00:00.000Z",
            selfLink: "https://example.com/t1",
            parent: "parent1",
            position: "00000001",
            updated: "2026-03-01T12:00:00.000Z"
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TaskItem.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.title, original.title)
        XCTAssertEqual(decoded.notes, original.notes)
        XCTAssertEqual(decoded.status, original.status)
        XCTAssertEqual(decoded.due, original.due)
        XCTAssertEqual(decoded.selfLink, original.selfLink)
        XCTAssertEqual(decoded.parent, original.parent)
        XCTAssertEqual(decoded.position, original.position)
        XCTAssertEqual(decoded.updated, original.updated)
    }

    func testRoundTripWithNilOptionals() throws {
        let original = TaskItem(
            id: "t1",
            title: "Minimal",
            notes: nil,
            status: .completed,
            due: nil,
            selfLink: nil,
            parent: nil,
            position: nil,
            updated: nil
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TaskItem.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.title, original.title)
        XCTAssertNil(decoded.notes)
        XCTAssertEqual(decoded.status, .completed)
        XCTAssertNil(decoded.due)
        XCTAssertNil(decoded.selfLink)
        XCTAssertNil(decoded.parent)
        XCTAssertNil(decoded.position)
        XCTAssertNil(decoded.updated)
    }

    // MARK: - TaskItemList Pagination Model

    func testTaskItemListWithNextPageToken() throws {
        let json = """
        {
            "kind": "tasks#tasks",
            "items": [{"id": "t1", "title": "Task", "status": "needsAction"}],
            "nextPageToken": "token123"
        }
        """.data(using: .utf8)!

        let list = try JSONDecoder().decode(TaskItemList.self, from: json)
        XCTAssertEqual(list.nextPageToken, "token123")
        XCTAssertEqual(list.items?.count, 1)
    }

    func testTaskItemListWithoutNextPageToken() throws {
        let json = """
        {
            "kind": "tasks#tasks",
            "items": [{"id": "t1", "title": "Task", "status": "needsAction"}]
        }
        """.data(using: .utf8)!

        let list = try JSONDecoder().decode(TaskItemList.self, from: json)
        XCTAssertNil(list.nextPageToken)
    }

    // MARK: - Title Mutation

    func testTitleIsMutable() {
        var task = TaskItem(id: "t1", title: "Original", notes: nil, status: .needsAction, due: nil, selfLink: nil, parent: nil, position: nil, updated: nil)
        task.title = "Updated"
        XCTAssertEqual(task.title, "Updated")
    }

    // MARK: - Notes Mutation

    func testNotesMutation() {
        var task = TaskItem(id: "t1", title: "Test", notes: nil, status: .needsAction, due: nil, selfLink: nil, parent: nil, position: nil, updated: nil)
        XCTAssertNil(task.notes)

        task.notes = "Some notes"
        XCTAssertEqual(task.notes, "Some notes")

        task.notes = nil
        XCTAssertNil(task.notes)
    }

    // MARK: - Identifiable Conformance

    func testIdentifiableUsesIdProperty() {
        let task = TaskItem(id: "unique-id", title: "Test", notes: nil, status: .needsAction, due: nil, selfLink: nil, parent: nil, position: nil, updated: nil)
        XCTAssertEqual(task.id, "unique-id")
    }
}
