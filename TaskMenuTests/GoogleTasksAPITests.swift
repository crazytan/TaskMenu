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

    // MARK: - dueDate Computed Property

    func testDueDateGetReturnsDateWhenDueIsSet() throws {
        let json = """
        {"id": "t1", "title": "Test", "status": "needsAction", "due": "2026-06-15T00:00:00.000Z"}
        """.data(using: .utf8)!

        let task = try JSONDecoder().decode(TaskItem.self, from: json)
        XCTAssertNotNil(task.dueDate)
    }

    func testDueDateGetReturnsNilWhenNoDue() throws {
        let json = """
        {"id": "t1", "title": "Test", "status": "needsAction"}
        """.data(using: .utf8)!

        let task = try JSONDecoder().decode(TaskItem.self, from: json)
        XCTAssertNil(task.dueDate)
    }

    func testDueDateSetUpdatesRFC3339String() throws {
        let json = """
        {"id": "t1", "title": "Test", "status": "needsAction"}
        """.data(using: .utf8)!

        var task = try JSONDecoder().decode(TaskItem.self, from: json)
        let date = DateFormatting.parseGoogleTaskDueDate("2026-12-25T00:00:00.000Z")!
        task.dueDate = date
        XCTAssertNotNil(task.due)
        XCTAssertTrue(task.due!.contains("2026-12-25"))
    }

    func testDueDateSetToNilClearsDue() throws {
        let json = """
        {"id": "t1", "title": "Test", "status": "needsAction", "due": "2026-06-15T00:00:00.000Z"}
        """.data(using: .utf8)!

        var task = try JSONDecoder().decode(TaskItem.self, from: json)
        task.dueDate = nil
        XCTAssertNil(task.due)
    }

    // MARK: - Minimal Field Decoding

    func testDecodeTaskWithOnlyRequiredFields() throws {
        let json = """
        {"id": "minimal", "title": "", "status": "needsAction"}
        """.data(using: .utf8)!

        let task = try JSONDecoder().decode(TaskItem.self, from: json)
        XCTAssertEqual(task.id, "minimal")
        XCTAssertNil(task.notes)
        XCTAssertNil(task.due)
        XCTAssertNil(task.selfLink)
        XCTAssertNil(task.parent)
        XCTAssertNil(task.position)
        XCTAssertNil(task.updated)
    }

    func testDecodeTaskListWithOnlyRequiredFields() throws {
        let json = """
        {"id": "list-minimal", "title": "Untitled"}
        """.data(using: .utf8)!

        let list = try JSONDecoder().decode(TaskList.self, from: json)
        XCTAssertEqual(list.id, "list-minimal")
        XCTAssertNil(list.selfLink)
        XCTAssertNil(list.updated)
    }

    // MARK: - Empty Collection

    func testDecodeEmptyTaskListCollection() throws {
        let json = """
        {"kind": "tasks#taskLists"}
        """.data(using: .utf8)!

        let collection = try JSONDecoder().decode(TaskListCollection.self, from: json)
        XCTAssertNil(collection.items)
    }

    // MARK: - TaskItem with Parent

    func testDecodeTaskWithParent() throws {
        let json = """
        {"id": "child1", "title": "Sub-task", "status": "needsAction", "parent": "parent1", "position": "00000002"}
        """.data(using: .utf8)!

        let task = try JSONDecoder().decode(TaskItem.self, from: json)
        XCTAssertEqual(task.parent, "parent1")
        XCTAssertEqual(task.position, "00000002")
    }

    func testDecodeTaskWithoutParentHasNilParent() throws {
        let json = """
        {"id": "root1", "title": "Root task", "status": "needsAction"}
        """.data(using: .utf8)!

        let task = try JSONDecoder().decode(TaskItem.self, from: json)
        XCTAssertNil(task.parent)
    }

    // MARK: - Tree Building from Flat List

    func testRootTasksFilteredCorrectly() throws {
        let tasks = [
            makeTask(id: "root1", title: "Root 1"),
            makeTask(id: "child1", title: "Child 1", parent: "root1"),
            makeTask(id: "root2", title: "Root 2"),
            makeTask(id: "child2", title: "Child 2", parent: "root1"),
        ]

        let rootTasks = tasks.filter { $0.parent == nil }
        XCTAssertEqual(rootTasks.count, 2)
        XCTAssertEqual(rootTasks[0].id, "root1")
        XCTAssertEqual(rootTasks[1].id, "root2")
    }

    func testSubtasksFilteredByParent() throws {
        let tasks = [
            makeTask(id: "root1", title: "Root 1"),
            makeTask(id: "child1", title: "Child 1", parent: "root1"),
            makeTask(id: "child2", title: "Child 2", parent: "root1"),
            makeTask(id: "root2", title: "Root 2"),
            makeTask(id: "child3", title: "Child 3", parent: "root2"),
        ]

        let root1Children = tasks.filter { $0.parent == "root1" }
        XCTAssertEqual(root1Children.count, 2)
        XCTAssertEqual(root1Children[0].id, "child1")
        XCTAssertEqual(root1Children[1].id, "child2")

        let root2Children = tasks.filter { $0.parent == "root2" }
        XCTAssertEqual(root2Children.count, 1)
        XCTAssertEqual(root2Children[0].id, "child3")
    }

    func testTaskWithNoChildrenHasEmptySubtasks() throws {
        let tasks = [
            makeTask(id: "root1", title: "Root 1"),
            makeTask(id: "root2", title: "Root 2"),
        ]

        let children = tasks.filter { $0.parent == "root1" }
        XCTAssertTrue(children.isEmpty)
    }

    func testTreeBuildingPreservesOrder() throws {
        let tasks = [
            makeTask(id: "root1", title: "Root 1"),
            makeTask(id: "child1", title: "Child 1", parent: "root1", position: "00000000"),
            makeTask(id: "child2", title: "Child 2", parent: "root1", position: "00000001"),
            makeTask(id: "child3", title: "Child 3", parent: "root1", position: "00000002"),
        ]

        let children = tasks.filter { $0.parent == "root1" }
        XCTAssertEqual(children.map(\.id), ["child1", "child2", "child3"])
    }

    func testMixedCompletedAndActiveSubtasks() throws {
        let tasks = [
            makeTask(id: "root1", title: "Root 1"),
            makeTask(id: "child1", title: "Child 1", parent: "root1", status: .needsAction),
            makeTask(id: "child2", title: "Child 2", parent: "root1", status: .completed),
        ]

        let children = tasks.filter { $0.parent == "root1" }
        XCTAssertEqual(children.count, 2)
        XCTAssertFalse(children[0].isCompleted)
        XCTAssertTrue(children[1].isCompleted)
    }

    func testDecodeFlatListWithSubtasks() throws {
        let json = """
        {
            "kind": "tasks#tasks",
            "items": [
                {"id": "root1", "title": "Root", "status": "needsAction"},
                {"id": "child1", "title": "Sub 1", "status": "needsAction", "parent": "root1", "position": "00000000"},
                {"id": "child2", "title": "Sub 2", "status": "completed", "parent": "root1", "position": "00000001"},
                {"id": "root2", "title": "Root 2", "status": "needsAction"}
            ]
        }
        """.data(using: .utf8)!

        let list = try JSONDecoder().decode(TaskItemList.self, from: json)
        let items = list.items!
        XCTAssertEqual(items.count, 4)

        let roots = items.filter { $0.parent == nil }
        XCTAssertEqual(roots.count, 2)

        let root1Children = items.filter { $0.parent == "root1" }
        XCTAssertEqual(root1Children.count, 2)
        XCTAssertEqual(root1Children[0].title, "Sub 1")
        XCTAssertEqual(root1Children[1].title, "Sub 2")
    }

    // MARK: - Helpers

    private func makeTask(
        id: String,
        title: String,
        parent: String? = nil,
        position: String? = nil,
        status: TaskItem.TaskStatus = .needsAction
    ) -> TaskItem {
        TaskItem(
            id: id,
            title: title,
            notes: nil,
            status: status,
            due: nil,
            selfLink: nil,
            parent: parent,
            position: position,
            updated: nil
        )
    }
}
