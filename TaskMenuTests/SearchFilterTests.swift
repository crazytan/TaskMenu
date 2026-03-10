import XCTest
@testable import TaskMenu

@MainActor
final class SearchFilterTests: XCTestCase {

    // MARK: - Helpers

    private func makeTask(
        id: String,
        title: String,
        notes: String? = nil,
        parent: String? = nil,
        status: TaskItem.TaskStatus = .needsAction
    ) -> TaskItem {
        TaskItem(
            id: id,
            title: title,
            notes: notes,
            status: status,
            due: nil,
            selfLink: nil,
            parent: parent,
            position: nil,
            updated: nil
        )
    }

    private func makeAppState(tasks: [TaskItem]) -> AppState {
        let state = AppState()
        state.tasks = tasks
        return state
    }

    // MARK: - Empty Search Returns All Tasks

    func testEmptySearchReturnsAllTasks() {
        let tasks = [
            makeTask(id: "1", title: "Buy groceries"),
            makeTask(id: "2", title: "Walk the dog"),
        ]
        let state = makeAppState(tasks: tasks)
        state.searchText = ""

        XCTAssertEqual(state.searchFilteredTasks.count, 2)
        XCTAssertFalse(state.isSearching)
    }

    func testWhitespaceOnlySearchReturnsAllTasks() {
        let tasks = [
            makeTask(id: "1", title: "Buy groceries"),
        ]
        let state = makeAppState(tasks: tasks)
        state.searchText = "   "

        XCTAssertEqual(state.searchFilteredTasks.count, 1)
        XCTAssertFalse(state.isSearching)
    }

    // MARK: - Title Matching

    func testSearchMatchesTitleCaseInsensitive() {
        let tasks = [
            makeTask(id: "1", title: "Buy Groceries"),
            makeTask(id: "2", title: "Walk the dog"),
        ]
        let state = makeAppState(tasks: tasks)
        state.searchText = "buy"

        XCTAssertTrue(state.isSearching)
        XCTAssertEqual(state.searchFilteredTasks.count, 1)
        XCTAssertEqual(state.searchFilteredTasks.first?.id, "1")
    }

    func testSearchMatchesPartialTitle() {
        let tasks = [
            makeTask(id: "1", title: "Buy groceries"),
            makeTask(id: "2", title: "Walk the dog"),
        ]
        let state = makeAppState(tasks: tasks)
        state.searchText = "groc"

        XCTAssertEqual(state.searchFilteredTasks.count, 1)
        XCTAssertEqual(state.searchFilteredTasks.first?.id, "1")
    }

    // MARK: - Notes Matching

    func testSearchMatchesNotes() {
        let tasks = [
            makeTask(id: "1", title: "Shopping", notes: "Milk, eggs, bread"),
            makeTask(id: "2", title: "Exercise"),
        ]
        let state = makeAppState(tasks: tasks)
        state.searchText = "milk"

        XCTAssertEqual(state.searchFilteredTasks.count, 1)
        XCTAssertEqual(state.searchFilteredTasks.first?.id, "1")
    }

    func testSearchMatchesNotesCaseInsensitive() {
        let tasks = [
            makeTask(id: "1", title: "Shopping", notes: "Buy ORGANIC milk"),
        ]
        let state = makeAppState(tasks: tasks)
        state.searchText = "organic"

        XCTAssertEqual(state.searchFilteredTasks.count, 1)
    }

    // MARK: - No Results

    func testSearchWithNoMatchReturnsEmpty() {
        let tasks = [
            makeTask(id: "1", title: "Buy groceries"),
            makeTask(id: "2", title: "Walk the dog"),
        ]
        let state = makeAppState(tasks: tasks)
        state.searchText = "xyz"

        XCTAssertTrue(state.isSearching)
        XCTAssertTrue(state.searchFilteredTasks.isEmpty)
    }

    // MARK: - Subtask Visibility

    func testMatchingSubtaskShowsParent() {
        let tasks = [
            makeTask(id: "parent1", title: "Shopping"),
            makeTask(id: "child1", title: "Buy milk", parent: "parent1"),
            makeTask(id: "parent2", title: "Work"),
        ]
        let state = makeAppState(tasks: tasks)
        state.searchText = "milk"

        let filtered = state.searchFilteredTasks
        let filteredIDs = Set(filtered.map(\.id))
        // Both the matching subtask and its parent should be visible
        XCTAssertTrue(filteredIDs.contains("child1"))
        XCTAssertTrue(filteredIDs.contains("parent1"))
        // Unrelated parent should not be visible
        XCTAssertFalse(filteredIDs.contains("parent2"))
    }

    func testMatchingSubtaskWithNonMatchingParent() {
        let tasks = [
            makeTask(id: "parent1", title: "Errands"),
            makeTask(id: "child1", title: "Pick up prescription", parent: "parent1"),
        ]
        let state = makeAppState(tasks: tasks)
        state.searchText = "prescription"

        let filteredIDs = Set(state.searchFilteredTasks.map(\.id))
        XCTAssertTrue(filteredIDs.contains("child1"))
        XCTAssertTrue(filteredIDs.contains("parent1"))
    }

    func testMatchingParentWithNonMatchingSubtask() {
        let tasks = [
            makeTask(id: "parent1", title: "Shopping list"),
            makeTask(id: "child1", title: "Eggs", parent: "parent1"),
            makeTask(id: "child2", title: "Bread", parent: "parent1"),
        ]
        let state = makeAppState(tasks: tasks)
        state.searchText = "shopping"

        let filteredIDs = Set(state.searchFilteredTasks.map(\.id))
        // Parent matches directly
        XCTAssertTrue(filteredIDs.contains("parent1"))
        // Non-matching subtasks should not appear
        XCTAssertFalse(filteredIDs.contains("child1"))
        XCTAssertFalse(filteredIDs.contains("child2"))
    }

    // MARK: - Completed Tasks in Search

    func testSearchIncludesCompletedTasks() {
        let tasks = [
            makeTask(id: "1", title: "Buy groceries", status: .completed),
            makeTask(id: "2", title: "Buy shoes", status: .needsAction),
            makeTask(id: "3", title: "Walk the dog"),
        ]
        let state = makeAppState(tasks: tasks)
        state.searchText = "buy"

        let filtered = state.searchFilteredTasks
        XCTAssertEqual(filtered.count, 2)
        let filteredIDs = Set(filtered.map(\.id))
        XCTAssertTrue(filteredIDs.contains("1"))
        XCTAssertTrue(filteredIDs.contains("2"))
    }

    // MARK: - Search Filtered Root Tasks

    func testSearchFilteredRootTasksExcludesSubtasks() {
        let tasks = [
            makeTask(id: "parent1", title: "Shopping"),
            makeTask(id: "child1", title: "Buy shopping bags", parent: "parent1"),
        ]
        let state = makeAppState(tasks: tasks)
        state.searchText = "shopping"

        // Only root tasks in the filtered root set
        XCTAssertEqual(state.searchFilteredRootTasks.count, 1)
        XCTAssertEqual(state.searchFilteredRootTasks.first?.id, "parent1")
    }

    // MARK: - Search Filtered Subtasks

    func testSearchFilteredSubtasks() {
        let tasks = [
            makeTask(id: "parent1", title: "Errands"),
            makeTask(id: "child1", title: "Buy milk", parent: "parent1"),
            makeTask(id: "child2", title: "Buy eggs", parent: "parent1"),
            makeTask(id: "child3", title: "Walk dog", parent: "parent1"),
        ]
        let state = makeAppState(tasks: tasks)
        state.searchText = "buy"

        let subtasks = state.searchFilteredSubtasks(of: "parent1")
        XCTAssertEqual(subtasks.count, 2)
        let subtaskIDs = Set(subtasks.map(\.id))
        XCTAssertTrue(subtaskIDs.contains("child1"))
        XCTAssertTrue(subtaskIDs.contains("child2"))
    }
}
