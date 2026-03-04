import XCTest
@testable import TaskMenu

final class GoogleTasksAPITests: XCTestCase {

    // MARK: - Model Decoding Tests

    func testDecodeTaskItem() throws {
        let json = """
        {
            "id": "task1",
            "title": "Buy groceries",
            "notes": "Milk, eggs, bread",
            "status": "needsAction",
            "due": "2026-03-15T00:00:00.000Z",
            "selfLink": "https://example.com/task1",
            "position": "00000001",
            "updated": "2026-03-01T12:00:00.000Z"
        }
        """.data(using: .utf8)!

        let task = try JSONDecoder().decode(TaskItem.self, from: json)
        XCTAssertEqual(task.id, "task1")
        XCTAssertEqual(task.title, "Buy groceries")
        XCTAssertEqual(task.notes, "Milk, eggs, bread")
        XCTAssertEqual(task.status, .needsAction)
        XCTAssertFalse(task.isCompleted)
        XCTAssertNotNil(task.dueDate)
    }

    func testDecodeCompletedTask() throws {
        let json = """
        {
            "id": "task2",
            "title": "Done task",
            "status": "completed"
        }
        """.data(using: .utf8)!

        let task = try JSONDecoder().decode(TaskItem.self, from: json)
        XCTAssertEqual(task.status, .completed)
        XCTAssertTrue(task.isCompleted)
    }

    func testDecodeTaskList() throws {
        let json = """
        {
            "id": "list1",
            "title": "My Tasks",
            "selfLink": "https://example.com/list1",
            "updated": "2026-03-01T00:00:00.000Z"
        }
        """.data(using: .utf8)!

        let list = try JSONDecoder().decode(TaskList.self, from: json)
        XCTAssertEqual(list.id, "list1")
        XCTAssertEqual(list.title, "My Tasks")
    }

    func testDecodeTaskListCollection() throws {
        let json = """
        {
            "kind": "tasks#taskLists",
            "items": [
                {"id": "list1", "title": "My Tasks"},
                {"id": "list2", "title": "Work"}
            ]
        }
        """.data(using: .utf8)!

        let collection = try JSONDecoder().decode(TaskListCollection.self, from: json)
        XCTAssertEqual(collection.items?.count, 2)
        XCTAssertEqual(collection.items?.first?.title, "My Tasks")
    }

    func testDecodeTaskItemList() throws {
        let json = """
        {
            "kind": "tasks#tasks",
            "items": [
                {"id": "t1", "title": "Task 1", "status": "needsAction"},
                {"id": "t2", "title": "Task 2", "status": "completed"}
            ]
        }
        """.data(using: .utf8)!

        let list = try JSONDecoder().decode(TaskItemList.self, from: json)
        XCTAssertEqual(list.items?.count, 2)
    }

    func testDecodeEmptyItemsList() throws {
        let json = """
        {
            "kind": "tasks#tasks"
        }
        """.data(using: .utf8)!

        let list = try JSONDecoder().decode(TaskItemList.self, from: json)
        XCTAssertNil(list.items)
    }

    func testTaskToggle() throws {
        let json = """
        {"id": "t1", "title": "Test", "status": "needsAction"}
        """.data(using: .utf8)!

        var task = try JSONDecoder().decode(TaskItem.self, from: json)
        XCTAssertFalse(task.isCompleted)

        task.isCompleted = true
        XCTAssertEqual(task.status, .completed)

        task.isCompleted = false
        XCTAssertEqual(task.status, .needsAction)
    }

    func testTaskEncode() throws {
        let json = """
        {"id": "t1", "title": "Test", "status": "needsAction"}
        """.data(using: .utf8)!

        let task = try JSONDecoder().decode(TaskItem.self, from: json)
        let encoded = try JSONEncoder().encode(task)
        let decoded = try JSONDecoder().decode(TaskItem.self, from: encoded)
        XCTAssertEqual(decoded.id, "t1")
        XCTAssertEqual(decoded.title, "Test")
        XCTAssertEqual(decoded.status, .needsAction)
    }
}
